--[[
	BedController
	Handles laying down on / standing up from beds.
	
	Debug log prefix: [BB-BED] — filter Studio output to see only bed events.
	
	- Right-click a bed → lay down (positioned and rotated to match the bed)
	- WASD / Space / right-click anywhere → stand up
	- While laying down, the character's HumanoidRootPart is anchored and
	  PlatformStand is enabled so the character ragdolls flat on the bed
	  instead of trying to stand up.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local BLOCK_SIZE = 3

local BedController = {}

local isLayingDown = false
local currentBed = nil
local targetCFrame = nil -- the CFrame we want the root pinned to while laying
local savedState = nil
local lastStandUpTime = 0
local STAND_UP_GUARD = 0.15
local enforceConnection = nil -- RenderStepped connection that re-applies CFrame each frame
local cameraConnection = nil  -- RenderStepped connection that locks the camera in place
local savedCameraState = nil  -- { CameraType, CameraSubject } for restoration on stand-up
local layForwardDir = nil     -- horizontal direction the camera should look while in bed (away from pillow)

-- Sleep dim / blur effect (slowly darken + blur the screen while in bed)
local DimScreenGui = nil
local DimFrame = nil
local BlurEffect = nil
local CAMERA_HEAD_Y_OFFSET = 1.0 -- raise camera above head so view feels propped up
local DIM_TARGET_TRANSPARENCY = 0.3 -- 70% opaque black = ~70% screen darkening
local BLUR_TARGET_SIZE = 8
local FADE_IN_DURATION = 1.5
local FADE_OUT_DURATION = 0.4

-- ============================================
-- GET UP BUTTON UI
-- ============================================
-- Created lazily and re-used. Shown only while laying down.
local GetUpScreenGui = nil

local function createGetUpButton()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BedGetUpGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 150 -- above the hotbar
	screenGui.IgnoreGuiInset = true
	screenGui.Enabled = false
	screenGui.Parent = PlayerGui

	local btn = Instance.new("TextButton")
	btn.Name = "GetUpButton"
	btn.AnchorPoint = Vector2.new(0.5, 1)
	btn.Position = UDim2.new(0.5, 0, 1, -110) -- above the hotbar
	btn.Size = UDim2.new(0, 200, 0, 56)
	btn.BackgroundColor3 = Color3.fromRGB(75, 75, 75) -- darker grey to match inventory slots
	btn.BorderSizePixel = 0
	btn.Text = "GET UP"
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = 24
	btn.Font = Enum.Font.Arcade
	btn.AutoButtonColor = false
	btn.Parent = screenGui

	-- MC-style raised bevel (top/left light, bottom/right dark)
	local function edge(name, size, pos, color)
		local e = Instance.new("Frame")
		e.Name = name
		e.Size = size
		e.Position = pos
		e.BackgroundColor3 = color
		e.BorderSizePixel = 0
		e.ZIndex = 5
		e.Parent = btn
	end
	edge("BevelTop", UDim2.new(1, 0, 0, 3), UDim2.new(0, 0, 0, 0), Color3.fromRGB(120, 120, 120))
	edge("BevelLeft", UDim2.new(0, 3, 1, 0), UDim2.new(0, 0, 0, 0), Color3.fromRGB(120, 120, 120))
	edge("BevelBottom", UDim2.new(1, 0, 0, 3), UDim2.new(0, 0, 1, -3), Color3.fromRGB(40, 40, 40))
	edge("BevelRight", UDim2.new(0, 3, 1, 0), UDim2.new(1, -3, 0, 0), Color3.fromRGB(40, 40, 40))

	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = Color3.fromRGB(95, 95, 95)
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = Color3.fromRGB(75, 75, 75)
	end)
	btn.MouseButton1Click:Connect(function()
		if isLayingDown then
			print("[BB-BED] Get Up button clicked")
			BedController.StandUp()
		end
	end)

	return screenGui
end

local function showGetUpButton(visible)
	if not GetUpScreenGui then
		GetUpScreenGui = createGetUpButton()
	end
	GetUpScreenGui.Enabled = visible
end

-- ============================================
-- STANDUP POSITION FINDER
-- ============================================
-- Raycast around the bed to find an unobstructed spot where the player can
-- stand upright. Tries sides first (natural to step off the side of a bed),
-- then ends, and falls back to above the bed if nothing is clear.
-- Returns (standupPos, facingDir) where facingDir is a horizontal unit vector
-- pointing away from the bed (so the character faces away from the bed).
local function findClearStandupSpot(bed)
	local bedBoxCFrame, bedSize = bed:GetBoundingBox()
	local bedCenter = bedBoxCFrame.Position

	local bedRotation = bed:GetAttribute("Rotation") or 0
	local angleRad = math.rad(bedRotation)
	local lengthDir = Vector3.new(
		math.round(math.sin(angleRad)),
		0,
		math.round(math.cos(angleRad))
	)
	-- Perpendicular to bed length (rotate 90° around Y)
	local sideDir = Vector3.new(lengthDir.Z, 0, -lengthDir.X)

	local SIDE_DISTANCE = 3.5 -- 1 cell + a bit, off the side of the bed
	local END_DISTANCE = 5.0  -- 1 cell past the bed end

	-- (offset direction, facing direction) candidates
	local candidates = {
		{ sideDir * SIDE_DISTANCE, sideDir },
		{ -sideDir * SIDE_DISTANCE, -sideDir },
		{ lengthDir * END_DISTANCE, lengthDir },
		{ -lengthDir * END_DISTANCE, -lengthDir },
	}

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { LocalPlayer.Character }

	for i, c in ipairs(candidates) do
		local pos = bedCenter + c[1]
		local facing = c[2]

		-- Find ground below the candidate
		local downRay = workspace:Raycast(
			pos + Vector3.new(0, 6, 0),
			Vector3.new(0, -12, 0),
			rayParams
		)
		if downRay then
			local groundY = downRay.Position.Y
			-- Check 5 studs of vertical clearance above the ground
			local upRay = workspace:Raycast(
				Vector3.new(pos.X, groundY + 0.5, pos.Z),
				Vector3.new(0, 5, 0),
				rayParams
			)
			if not upRay then
				print(string.format("[BB-BED] Found clear standup spot #%d at (%.1f, %.1f, %.1f) facing=(%.1f,%.1f,%.1f)",
					i, pos.X, groundY, pos.Z, facing.X, facing.Y, facing.Z))
				return Vector3.new(pos.X, groundY + 3, pos.Z), facing
			end
		end
	end

	print("[BB-BED] No clear standup spot found, falling back to above bed")
	return bedCenter + Vector3.new(0, 5, 0), lengthDir
end

-- ============================================
-- CHARACTER HELPERS
-- ============================================

local function getCharacter()
	return LocalPlayer.Character
end

local function getHumanoid()
	local char = getCharacter()
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function getRootPart()
	local char = getCharacter()
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function fmtCFrame(cf)
	if not cf then return "nil" end
	local p = cf.Position
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	return string.format(
		"pos=(%.1f,%.1f,%.1f) look=(%.2f,%.2f,%.2f) up=(%.2f,%.2f,%.2f) right=(%.2f,%.2f,%.2f)",
		p.X, p.Y, p.Z, l.X, l.Y, l.Z, u.X, u.Y, u.Z, r.X, r.Y, r.Z
	)
end

-- ============================================
-- SLEEP DIM + BLUR
-- ============================================
-- Full-screen black overlay (lazy-created, reused) and a BlurEffect under
-- Lighting that tween in/out as the player lays down / stands up.
local function getOrCreateDim()
	if DimScreenGui and DimScreenGui.Parent then return DimScreenGui, DimFrame end

	local sg = Instance.new("ScreenGui")
	sg.Name = "BedDimOverlay"
	sg.ResetOnSpawn = false
	sg.DisplayOrder = 140 -- below the GET UP button (150) so the button stays clickable above it
	sg.IgnoreGuiInset = true
	sg.Enabled = false
	sg.Parent = PlayerGui

	local frame = Instance.new("Frame")
	frame.Name = "DimFrame"
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = UDim2.new(0, 0, 0, 0)
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = 1
	frame.Parent = sg

	DimScreenGui = sg
	DimFrame = frame
	return sg, frame
end

local function getOrCreateBlur()
	if BlurEffect and BlurEffect.Parent then return BlurEffect end
	local Lighting = game:GetService("Lighting")
	BlurEffect = Instance.new("BlurEffect")
	BlurEffect.Name = "BedBlur"
	BlurEffect.Size = 0
	BlurEffect.Enabled = true
	BlurEffect.Parent = Lighting
	return BlurEffect
end

local function fadeInDimBlur()
	local sg, frame = getOrCreateDim()
	sg.Enabled = true
	frame.BackgroundTransparency = 1
	TweenService:Create(
		frame,
		TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = DIM_TARGET_TRANSPARENCY }
	):Play()

	local blur = getOrCreateBlur()
	blur.Size = 0
	TweenService:Create(
		blur,
		TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = BLUR_TARGET_SIZE }
	):Play()
end

local function fadeOutDimBlur()
	if DimFrame then
		local frame = DimFrame
		local sg = DimScreenGui
		local tween = TweenService:Create(
			frame,
			TweenInfo.new(FADE_OUT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		)
		tween:Play()
		tween.Completed:Connect(function()
			if sg then sg.Enabled = false end
		end)
	end
	if BlurEffect then
		TweenService:Create(
			BlurEffect,
			TweenInfo.new(FADE_OUT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = 0 }
		):Play()
	end
end

local function resetDimBlurInstant()
	if DimFrame then DimFrame.BackgroundTransparency = 1 end
	if DimScreenGui then DimScreenGui.Enabled = false end
	if BlurEffect then BlurEffect.Size = 0 end
end

-- ============================================
-- CAMERA LOCK
-- ============================================
-- While laying down, force the camera into first-person and lock it to the
-- character's head orientation (no rotation/zoom while in bed).
local function lockCamera()
	local Camera = workspace.CurrentCamera
	local char = getCharacter()
	if not Camera or not char then return end

	local head = char:FindFirstChild("Head")
	local root = char:FindFirstChild("HumanoidRootPart")
	local pivotPart = head or root
	if not pivotPart then return end

	savedCameraState = {
		CameraType = Camera.CameraType,
		CameraSubject = Camera.CameraSubject,
	}

	Camera.CameraType = Enum.CameraType.Scriptable

	cameraConnection = RunService.RenderStepped:Connect(function()
		local c = getCharacter()
		local h = c and (c:FindFirstChild("Head") or c:FindFirstChild("HumanoidRootPart"))
		if h and h.Parent and layForwardDir then
			-- Camera at head position + small Y offset (propped-up feel), looking
			-- horizontally in the "forward from bed" direction (away from pillow).
			local pos = h.Position + Vector3.new(0, CAMERA_HEAD_Y_OFFSET, 0)
			Camera.CFrame = CFrame.lookAt(pos, pos + layForwardDir, Vector3.new(0, 1, 0))
		end
	end)
	print("[BB-BED] Camera locked (Scriptable, first-person at head)")
end

local function unlockCamera()
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local Camera = workspace.CurrentCamera
	if Camera and savedCameraState then
		Camera.CameraType = savedCameraState.CameraType
		Camera.CameraSubject = savedCameraState.CameraSubject
		print("[BB-BED] Camera restored")
	end
	savedCameraState = nil
end

-- ============================================
-- PUBLIC API
-- ============================================

function BedController.IsLayingDown()
	return isLayingDown
end

function BedController.JustStoodUp()
	return (tick() - lastStandUpTime) < STAND_UP_GUARD
end

function BedController.GetCurrentBed()
	return currentBed
end

-- Lay the player down on the given bed model.
function BedController.LayDown(bed)
	print("[BB-BED] LayDown called, bed =", bed and bed.Name, "isLayingDown =", isLayingDown)
	if isLayingDown then
		print("[BB-BED] Already laying down, aborting")
		return false
	end
	if not bed or not bed.Parent then
		print("[BB-BED] Bed invalid (nil or no parent), aborting")
		return false
	end
	
	local char = getCharacter()
	local humanoid = getHumanoid()
	local root = getRootPart()
	if not char or not humanoid or not root then
		print("[BB-BED] Missing char/humanoid/root, aborting. char=", char, "humanoid=", humanoid, "root=", root)
		return false
	end
	if humanoid.Health <= 0 then
		print("[BB-BED] Humanoid dead, aborting")
		return false
	end
	
	-- Read bed position + rotation
	local bedRotation = bed:GetAttribute("Rotation") or 0
	local px = bed:GetAttribute("BlockPosX")
	local py = bed:GetAttribute("BlockPosY")
	local pz = bed:GetAttribute("BlockPosZ")
	print(string.format("[BB-BED] Bed attrs: Rotation=%s BlockPosX=%s BlockPosY=%s BlockPosZ=%s",
		tostring(bedRotation), tostring(px), tostring(py), tostring(pz)))
	
	if not (px and py and pz) then
		local pivot = bed:GetPivot()
		px, py, pz = pivot.Position.X, pivot.Position.Y, pivot.Position.Z
		print(string.format("[BB-BED] Using bed pivot fallback: (%.1f, %.1f, %.1f)", px, py, pz))
	end
	local primaryPos = Vector3.new(px, py, pz)
	
	local angleRad = math.rad(bedRotation)
	local footDirection = Vector3.new(
		math.round(math.sin(angleRad)),
		0,
		math.round(math.cos(angleRad))
	)
	print(string.format("[BB-BED] footDirection = (%.1f, %.1f, %.1f)", footDirection.X, footDirection.Y, footDirection.Z))
	
	-- Position: use the bed model's actual geometric center (from its bounding
	-- box) instead of computing from primaryPos + offsets. This guarantees the
	-- character is dead-center on the bed regardless of how the bed model's
	-- pivot is set up.
	local bedBoxCFrame, bedSize = bed:GetBoundingBox()
	local bedTopY = bedBoxCFrame.Position.Y + bedSize.Y / 2
	-- Character Y = bed top + half body thickness (~0.5) so back rests on surface
	local centerPos = Vector3.new(
		bedBoxCFrame.Position.X,
		bedTopY + 0.5,
		bedBoxCFrame.Position.Z
	)
	print(string.format("[BB-BED] Bed bounding box: center=(%.2f,%.2f,%.2f) size=(%.2f,%.2f,%.2f) topY=%.2f",
		bedBoxCFrame.Position.X, bedBoxCFrame.Position.Y, bedBoxCFrame.Position.Z,
		bedSize.X, bedSize.Y, bedSize.Z, bedTopY))
	print(string.format("[BB-BED] centerPos = (%.2f, %.2f, %.2f)", centerPos.X, centerPos.Y, centerPos.Z))
	-- Head direction = footDirection (NOT -footDirection). In this codebase's
	-- bed convention, the bed's saved primaryPos is at the FOOT cell, and the
	-- pillow is one cell over in the footDirection direction. So the character's
	-- head should point in footDirection to align with the pillow.
	local pillowDirection = footDirection
	local layCFrame = CFrame.lookAt(centerPos, centerPos + Vector3.new(0, 1, 0), pillowDirection)
	-- Save the "forward from bed" direction (horizontal, opposite of where the
	-- head points) for the camera lock to use.
	layForwardDir = -pillowDirection
	
	print("[BB-BED] Computed layCFrame:", fmtCFrame(layCFrame))
	print("[BB-BED] Root.CFrame BEFORE:", fmtCFrame(root.CFrame))
	
	-- Save state for restoration on stand-up
	savedState = {
		WalkSpeed = humanoid.WalkSpeed,
		JumpPower = humanoid.JumpPower,
		AutoRotate = humanoid.AutoRotate,
		PlatformStand = humanoid.PlatformStand,
		AnimateDisabled = nil,
	}
	
	-- Disable the default Animate script. The Animate localscript inside the
	-- character constantly poses the body parts via the idle animation, which
	-- overrides our rotation.
	local animateScript = char:FindFirstChild("Animate")
	if animateScript then
		savedState.AnimateDisabled = animateScript.Disabled
		animateScript.Disabled = true
		print("[BB-BED] Animate script disabled (was disabled =", savedState.AnimateDisabled, ")")
	else
		print("[BB-BED] WARNING: No Animate script found on character")
	end
	
	-- Stop currently-playing animations
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		local tracks = animator:GetPlayingAnimationTracks()
		print("[BB-BED] Stopping", #tracks, "currently-playing animation tracks")
		for i, track in ipairs(tracks) do
			print("[BB-BED]   Track", i, "=", track.Name, "(Animation:", track.Animation and track.Animation.AnimationId or "nil", ")")
			track:Stop(0)
		end
	else
		print("[BB-BED] WARNING: No Animator found")
	end
	
	-- Apply lay-down state
	humanoid.PlatformStand = true
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.AutoRotate = false
	print("[BB-BED] Humanoid: PlatformStand=true, WalkSpeed=0, JumpPower=0, AutoRotate=false")
	
	-- ChangeState(Physics) puts the Humanoid into pure-physics / ragdoll mode
	-- and stops its internal state machine from auto-righting the root each
	-- frame (which caused the per-frame deviations we saw in the logs).
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	print("[BB-BED] Humanoid state changed to Physics")
	
	-- Anchor first, then set CFrame
	root.Anchored = true
	root.CFrame = layCFrame
	print("[BB-BED] Root anchored + CFrame set. Root.CFrame AFTER:", fmtCFrame(root.CFrame))
	
	isLayingDown = true
	currentBed = bed
	targetCFrame = layCFrame
	showGetUpButton(true)
	lockCamera()
	fadeInDimBlur()
	
	-- ============================================
	-- CFRAME ENFORCEMENT LOOP
	-- ============================================
	-- Re-apply the lay-down CFrame every frame. If anything else (Humanoid
	-- internals, animation, physics) tries to move/rotate the root, this
	-- catches it and snaps back. Logs the first 10 deviations so we can see
	-- what's happening on the user's end.
	local frameCount = 0
	local logCount = 0
	enforceConnection = RunService.Heartbeat:Connect(function()
		if not isLayingDown then return end
		local r = getRootPart()
		if not r then return end
		
		frameCount = frameCount + 1
		local currentCF = r.CFrame
		local posDelta = (currentCF.Position - targetCFrame.Position).Magnitude
		local lookDelta = (currentCF.LookVector - targetCFrame.LookVector).Magnitude
		
		if (posDelta > 0.01 or lookDelta > 0.01) and logCount < 10 then
			logCount = logCount + 1
			print(string.format(
				"[BB-BED] DEVIATION #%d on frame %d: posDelta=%.2f lookDelta=%.2f",
				logCount, frameCount, posDelta, lookDelta))
			print("[BB-BED]   Current:", fmtCFrame(currentCF))
			print("[BB-BED]   Target: ", fmtCFrame(targetCFrame))
			if logCount == 10 then
				print("[BB-BED]   (further deviations will not be logged)")
			end
		end
		
		-- Re-apply target CFrame regardless of whether it deviated
		r.CFrame = targetCFrame
	end)
	
	-- Bed broken → stand up
	bed.AncestryChanged:Connect(function(_, parent)
		if isLayingDown and currentBed == bed and not parent then
			print("[BB-BED] Bed unparented, forcing stand-up")
			BedController.StandUp()
		end
	end)
	
	print("[BB-BED] LayDown complete, enforcement loop active")
	return true
end

function BedController.StandUp()
	print("[BB-BED] StandUp called, isLayingDown =", isLayingDown)
	if not isLayingDown then return false end
	
	showGetUpButton(false)
	unlockCamera()
	fadeOutDimBlur()
	
	-- Disconnect enforcement loop FIRST so we don't keep re-anchoring
	if enforceConnection then
		enforceConnection:Disconnect()
		enforceConnection = nil
		print("[BB-BED] Enforcement loop disconnected")
	end
	
	local char = getCharacter()
	local humanoid = getHumanoid()
	local root = getRootPart()
	local bed = currentBed -- save before clearing state
	
	if root then
		root.Anchored = false
	end
	
	if char and savedState then
		local animateScript = char:FindFirstChild("Animate")
		if animateScript then
			animateScript.Disabled = savedState.AnimateDisabled or false
			print("[BB-BED] Animate script restored (disabled =", animateScript.Disabled, ")")
		end
	end
	
	if humanoid and savedState then
		humanoid.PlatformStand = savedState.PlatformStand
		humanoid.WalkSpeed = savedState.WalkSpeed
		humanoid.JumpPower = savedState.JumpPower
		humanoid.AutoRotate = savedState.AutoRotate
	elseif humanoid then
		humanoid.PlatformStand = false
		humanoid.WalkSpeed = 16
		humanoid.JumpPower = 50
		humanoid.AutoRotate = true
	end
	
	-- CRITICAL: transition the Humanoid state machine out of Physics back to
	-- a walking-capable state. Without this, the character is stuck in Physics
	-- mode and movement input is ignored.
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		print("[BB-BED] Humanoid state changed to GettingUp")
	end
	
	-- Teleport to a clear standing spot next to the bed (facing away from it)
	if root and bed and bed.Parent then
		local standupPos, facingDir = findClearStandupSpot(bed)
		local facing = Vector3.new(facingDir.X, 0, facingDir.Z)
		if facing.Magnitude < 0.01 then facing = Vector3.new(0, 0, 1) end
		facing = facing.Unit
		root.CFrame = CFrame.lookAt(standupPos, standupPos + facing)
		print(string.format("[BB-BED] Teleported to standup spot (%.1f, %.1f, %.1f)",
			standupPos.X, standupPos.Y, standupPos.Z))
	elseif root then
		-- Bed gone or character missing — fallback: just nudge up so we don't get stuck
		root.CFrame = root.CFrame + Vector3.new(0, 3, 0)
	end
	
	isLayingDown = false
	currentBed = nil
	savedState = nil
	targetCFrame = nil
	layForwardDir = nil
	lastStandUpTime = tick()
	print("[BB-BED] StandUp complete")
	return true
end

function BedController.TryInteract()
	if isLayingDown then
		BedController.StandUp()
		return true
	end
	return false
end

-- ============================================
-- INPUT: WAKE-UP KEYS
-- ============================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not isLayingDown then return end
	if gameProcessed then return end
	
	local kc = input.KeyCode
	-- Shift wakes up (NOT Space — user shouldn't be able to "jump up" out of bed).
	-- WASD also wakes up (any movement attempt).
	if kc == Enum.KeyCode.W
		or kc == Enum.KeyCode.A
		or kc == Enum.KeyCode.S
		or kc == Enum.KeyCode.D
		or kc == Enum.KeyCode.LeftShift
		or kc == Enum.KeyCode.RightShift then
		print("[BB-BED] Wake-up key pressed (", kc.Name, "), standing up")
		BedController.StandUp()
	end
end)

LocalPlayer.CharacterAdded:Connect(function()
	print("[BB-BED] CharacterAdded — resetting state")
	if enforceConnection then
		enforceConnection:Disconnect()
		enforceConnection = nil
	end
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	-- Best-effort camera restoration in case the player respawned mid-lay-down
	local Camera = workspace.CurrentCamera
	if Camera and savedCameraState then
		Camera.CameraType = savedCameraState.CameraType
		Camera.CameraSubject = savedCameraState.CameraSubject
	end
	savedCameraState = nil
	showGetUpButton(false)
	resetDimBlurInstant()
	isLayingDown = false
	currentBed = nil
	savedState = nil
	targetCFrame = nil
	layForwardDir = nil
end)

_G.BedController = BedController

print("[BB-BED] BedController initialized")

return BedController
