--[[
	CameraController
	First-person/third-person camera with toggle (C key or mobile button)
	Adapted from Ashborne for the building game
	
	Waits for game to start (title screen dismissed) before activating
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Settings
local THIRD_PERSON_DISTANCE = 15
local THIRD_PERSON_ANGLE = 40
local MIN_THIRD_PERSON_ANGLE = 25  -- angle when zoomed all the way in (above head, never below)
local MIN_THIRD_PERSON_DISTANCE = 2 -- closest the camera will ever get
local CAMERA_DISTANCE_SMOOTH_IN_SLOW = 3   -- normal pull-in speed (gentle glide)
local CAMERA_DISTANCE_SMOOTH_IN_FAST = 15  -- emergency pull-in speed (when about to clip)
local CAMERA_DISTANCE_SMOOTH_OUT = 1.5     -- push-out speed (lower = smoother, was 3)
local LOOKAT_SMOOTH_XZ = 15   -- horizontal follow smoothing (high = responsive, low = laggy)
local LOOKAT_SMOOTH_Y = 4      -- vertical follow smoothing (low so terrain steps don't jerk the camera)
local CAMERA_POS_SMOOTH = 18   -- final pass on the full camera position (catches mouse-input micro-jitter)
local ROTATE_SPEED = 0.3
local TOUCH_ROTATE_SPEED = 0.5
local FIELD_OF_VIEW = 80

-- Menu camera settings
local MENU_CAMERA_DISTANCE = 50  -- Distance from plot center
local MENU_CAMERA_HEIGHT = 25    -- Height above plot
local MENU_CAMERA_SPEED = 0.08   -- Rotation speed (degrees per frame)

-- Portal "drunk" camera wobble. Driven by PortalVisionEffect's 0..1 intensity
-- (which already ramps in/out with portal dwell). Roll-dominant + low position
-- drift = reads as woozy distortion without making the player motion-sick.
-- Layered sine frequencies that don't share a common period, so the motion
-- never visibly loops. Degrees / studs are at FULL intensity; everything is
-- scaled by the live intensity each frame, so it fades exactly in sync with
-- the purple tint.
local PORTAL_SWAY_PITCH = 1.2    -- deg, vertical bob
local PORTAL_SWAY_YAW   = 1.8    -- deg, horizontal weave
local PORTAL_SWAY_ROLL  = 3.5    -- deg, head-tilt -- the signature "drunk" axis
local PORTAL_DRIFT_X    = 0.18   -- studs, lateral drift (kept small on purpose)
local PORTAL_DRIFT_Y    = 0.12   -- studs, vertical drift
local PORTAL_SWAY_THRESHOLD = 0.002  -- skip the maths entirely below this

-- State
local isFirstPerson = true
local cameraYaw = 0
local cameraPitch = 0
local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local gameStarted = false  -- Track if we've left the title screen
local smoothedCameraDistance = nil -- smoothed third-person distance (nil = initialize on next frame)
local smoothedLookAt = nil -- smoothed lookAt position (filters out walking step jumps)
local smoothedCameraPos = nil -- smoothed final camera position (final-pass jitter filter)

-- Pitch limits
local MIN_PITCH = -89
local MAX_PITCH = 89

-- Touch tracking
local activeTouches = {}
local lastTouchPos = nil

-- ============================================
-- CHARACTER HELPERS
-- ============================================

local function getCharacterParts()
	local character = player.Character
	if not character then return nil, nil, nil end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	local humanoid = character:FindFirstChild("Humanoid")
	
	return rootPart, head, humanoid
end

local function setCharacterVisible(visible)
	local character = player.Character
	if not character then return end
	
	local transparency = visible and 0 or 1
	
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = transparency
		end
	end
end

-- ============================================
-- PLOT CENTER HELPER
-- ============================================

local function getPlotCenter()
	-- Check if we're in MegaPlot mode on a private server
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local isPrivateServerValue = ReplicatedStorage:FindFirstChild("IsPrivateServer")
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	
	if isPrivateServerValue and isPrivateServerValue.Value and modeValue and modeValue.Value == "MegaPlot" then
		-- Find the MegaPlotRoom and get its center
		local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then
			-- Find the MegaPlot baseplate
			local megaPlot = megaPlotRoom:FindFirstChild("MegaPlot")
			if not megaPlot then
				for _, child in ipairs(megaPlotRoom:GetDescendants()) do
					if child.Name == "MegaPlot" and child:IsA("BasePart") then
						megaPlot = child
						break
					end
				end
			end
			
			if megaPlot and megaPlot:IsA("BasePart") then
				return Vector3.new(
					megaPlot.Position.X,
					megaPlot.Position.Y + megaPlot.Size.Y / 2 + 5,
					megaPlot.Position.Z
				)
			end
		end
	end
	
	-- Normal mode: Try to get plot info from PlotClient
	if _G.PlotClient and _G.PlotClient.GetBasePlate then
		local basePlate = _G.PlotClient.GetBasePlate()
		if basePlate and basePlate.Position then
			-- Return the center of the plot at ground level
			return Vector3.new(
				basePlate.Position.X,
				basePlate.Position.Y + (basePlate.Size and basePlate.Size.Y / 2 or 0) + 5,
				basePlate.Position.Z
			)
		end
	end
	
	-- Fallback: try to get from character position
	local rootPart = getCharacterParts()
	if rootPart then
		return rootPart.Position + Vector3.new(0, 5, 0)
	end
	
	-- Last fallback: world origin
	return Vector3.new(0, 20, 0)
end

-- ============================================
-- PORTAL CAMERA SWAY
-- ============================================

-- Applies the portal "drunk" wobble to an already-computed camera CFrame and
-- returns the swayed CFrame. Reads the live 0..1 intensity from
-- PortalVisionEffect; when there's no portal effect active this is a near-free
-- early-out. Rotation is applied in the camera's LOCAL space (so the tilt is
-- relative to where you're looking, like your head lolling), while drift is a
-- small local-space translation.
local function applyPortalSway(cf)
	local pve = _G.PortalVisionEffect
	if not pve or not pve.GetIntensity then return cf end

	local intensity = pve.GetIntensity()
	if intensity <= PORTAL_SWAY_THRESHOLD then return cf end

	-- Respect the same reduced-effects setting the vision FX honors, so a
	-- player who turned effects down doesn't get a wobbling camera either.
	local settings = _G.BuildBloxSettings
	if settings and settings.ReducedEffects == true then return cf end

	local t = os.clock()

	-- Overlapping sines at non-harmonic frequencies -> organic, non-repeating.
	local pitch = math.sin(t * 0.88) * PORTAL_SWAY_PITCH
	local yaw   = math.sin(t * 0.66) * PORTAL_SWAY_YAW
	local roll  = math.sin(t * 0.39) * PORTAL_SWAY_ROLL
	local driftX = math.sin(t * 1.14) * PORTAL_DRIFT_X
	local driftY = math.sin(t * 1.59) * PORTAL_DRIFT_Y

	local s = intensity
	local swayRot = CFrame.Angles(
		math.rad(pitch * s),
		math.rad(yaw * s),
		math.rad(roll * s)
	)
	local swayPos = CFrame.new(driftX * s, driftY * s, 0)

	-- Right-multiply: applied in the camera's local frame so the wobble tracks
	-- the look direction instead of the world axes.
	return cf * swayRot * swayPos
end

-- ============================================
-- CAMERA MODES
-- ============================================

local function updateFirstPersonCamera()
	local rootPart, head, humanoid = getCharacterParts()
	if not rootPart then return end
	
	local cameraPos = rootPart.Position + Vector3.new(0, 1.5, 0)
	
	local yawRad = math.rad(cameraYaw)
	local pitchRad = math.rad(cameraPitch)
	
	local rotation = CFrame.Angles(0, yawRad, 0) * CFrame.Angles(pitchRad, 0, 0)
	
	camera.CFrame = applyPortalSway(CFrame.new(cameraPos) * rotation)
	
	setCharacterVisible(false)
	
	-- Rotate character body to match camera yaw
	rootPart.CFrame = CFrame.new(rootPart.Position) * CFrame.Angles(0, yawRad, 0)
end

-- Some blocks are collidable (for gameplay) but should still be transparent
-- to the camera, so the camera doesn't pull in when the player is near or
-- behind a screen of them. Vines are the main case: they're CanCollide=true
-- for climbing, but the player should see past them.
local function isSeeThroughForCamera(instance)
	if not instance then return false end
	local current = instance
	for _ = 1, 5 do
		if current:GetAttribute("IsVine") then return true end
		local blockType = current:GetAttribute("BlockType")
		if blockType and string.find(blockType, "Vine") then return true end
		current = current.Parent
		if not current or current == workspace then return false end
	end
	return false
end

-- Raycast that ignores non-collidable parts (grass, leaves, decals, vines).
-- The default workspace:Raycast hits the first part regardless of CanCollide,
-- which makes tall grass and foliage falsely trigger the camera clip pull-in.
-- This helper steps past non-collidable hits to find the first SOLID part.
local function raycastCollidable(origin, dir, params)
	local currentOrigin = origin
	local currentDir = dir
	local rayEnd = origin + dir
	
	for _ = 1, 8 do -- max 8 iterations as a safety bound
		local result = workspace:Raycast(currentOrigin, currentDir, params)
		if not result then return nil end
		local hitInstance = result.Instance
		local isSolid = hitInstance and hitInstance.CanCollide
		local isSeeThrough = isSeeThroughForCamera(hitInstance)
		if isSolid and not isSeeThrough then
			return result
		end
		-- Non-collidable OR see-through (vine): step past and continue
		local step = result.Position + currentDir.Unit * 0.05
		local remaining = rayEnd - step
		if remaining:Dot(currentDir) <= 0 then return nil end
		currentOrigin = step
		currentDir = remaining
	end
	return nil
end

local function updateThirdPersonCamera(dt)
	local rootPart, head, humanoid = getCharacterParts()
	if not rootPart then return end
	
	dt = dt or 1/60
	local rawLookAt = rootPart.Position + Vector3.new(0, 2, 0)
	
	-- Smooth the lookAt position so walking step jumps (when the player moves
	-- onto a higher block) don't translate to abrupt camera motion. X/Z is
	-- smoothed lightly (to stay responsive) while Y is smoothed heavily
	-- (since vertical step jumps are the main source of close-up jerkiness).
	if not smoothedLookAt then
		smoothedLookAt = rawLookAt
	else
		local alphaXZ = 1 - math.exp(-LOOKAT_SMOOTH_XZ * dt)
		local alphaY = 1 - math.exp(-LOOKAT_SMOOTH_Y * dt)
		smoothedLookAt = Vector3.new(
			smoothedLookAt.X + (rawLookAt.X - smoothedLookAt.X) * alphaXZ,
			smoothedLookAt.Y + (rawLookAt.Y - smoothedLookAt.Y) * alphaY,
			smoothedLookAt.Z + (rawLookAt.Z - smoothedLookAt.Z) * alphaXZ
		)
	end
	local lookAt = smoothedLookAt
	
	-- The "pivot" is the smoothed equivalent of rootPart.Position — base both
	-- cameraPos AND lookAt off the same smoothed point so they stay in sync.
	-- (If we used raw rootPart.Position for cameraPos, the camera would slip
	-- below the smoothed lookAt during falls/descents and tilt upward.)
	local smoothedPivot = lookAt - Vector3.new(0, 2, 0)
	
	-- Compute the desired camera position at full distance + full angle
	local fullAngleRad = math.rad(THIRD_PERSON_ANGLE)
	local fullHorizontalDist = THIRD_PERSON_DISTANCE * math.cos(fullAngleRad)
	local fullVerticalDist = THIRD_PERSON_DISTANCE * math.sin(fullAngleRad)
	local fullOffset = CFrame.Angles(0, math.rad(cameraYaw), 0) * Vector3.new(0, 0, fullHorizontalDist)
	local desiredCameraPos = smoothedPivot + Vector3.new(fullOffset.X, fullVerticalDist, fullOffset.Z)
	
	-- Raycast from player toward the desired camera position to detect any
	-- obstacle (wall, ceiling, block) in the way. We probe 5 parallel rays —
	-- center plus one block offset in each cardinal direction perpendicular
	-- to the camera ray — so the camera starts zooming in as the player
	-- approaches an obstacle, not just when it's right against it.
	local rayDir = desiredCameraPos - lookAt
	local rayLength = rayDir.Magnitude
	local rayUnit = rayLength > 0 and rayDir / rayLength or Vector3.new(0, 0, 1)
	local rightDir = rayUnit:Cross(Vector3.new(0, 1, 0))
	if rightDir.Magnitude < 0.01 then
		rightDir = Vector3.new(1, 0, 0) -- fallback if ray is straight up/down
	else
		rightDir = rightDir.Unit
	end
	local upDir = rightDir:Cross(rayUnit).Unit
	
	local PROBE_OFFSET = 3 -- 1 block out in each direction
	local probeOffsets = {
		Vector3.zero,
		rightDir * PROBE_OFFSET,
		-rightDir * PROBE_OFFSET,
		upDir * PROBE_OFFSET,
		-upDir * PROBE_OFFSET,
	}
	
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { player.Character }
	rayParams.IgnoreWater = true
	
	local minHitDistance = rayLength
	for _, offset in ipairs(probeOffsets) do
		local origin = lookAt + offset
		local result = raycastCollidable(origin, rayDir, rayParams)
		if result then
			local hitDist = (result.Position - origin).Magnitude
			if hitDist < minHitDistance then
				minHitDistance = hitDist
			end
		end
	end
	
	local targetDistance = THIRD_PERSON_DISTANCE
	if minHitDistance < rayLength then
		local margin = 0.5
		targetDistance = math.max(minHitDistance - margin, MIN_THIRD_PERSON_DISTANCE)
	end
	
	-- Asymmetric exponential smoothing: pull in fast (responsive to walls)
	-- but push out slowly. This prevents the camera from bouncing in/out as
	-- you walk under irregular geometry (trees, scattered blocks, overhangs)
	-- where the raycast results vary frame-to-frame. While the camera stays
	-- mostly pulled in, it only extends back to full distance once you've
	-- been clearly in the open for a moment.
	--
	-- The pull-in speed itself is adaptive: small gaps glide gently (so
	-- normal motion feels smooth), large gaps snap fast (so the camera never
	-- clips through a wall when the player rounds a tight corner).
	local k
	if not smoothedCameraDistance then
		-- First frame after toggle/respawn — snap to the target so the camera
		-- starts at the correct distance instead of smoothing in from 15.
		smoothedCameraDistance = targetDistance
	elseif targetDistance < smoothedCameraDistance then
		local gap = smoothedCameraDistance - targetDistance
		local urgency = math.clamp(gap / 4, 0, 1) -- 0 = no urgency, 1 = full urgency (gap >= 4 studs)
		k = CAMERA_DISTANCE_SMOOTH_IN_SLOW + (CAMERA_DISTANCE_SMOOTH_IN_FAST - CAMERA_DISTANCE_SMOOTH_IN_SLOW) * urgency
	else
		k = CAMERA_DISTANCE_SMOOTH_OUT -- pushing out
	end
	if k then
		local alpha = 1 - math.exp(-k * (dt or 1/60))
		smoothedCameraDistance = smoothedCameraDistance + (targetDistance - smoothedCameraDistance) * alpha
	end
	local actualDistance = smoothedCameraDistance
	
	-- Interpolate the down-angle based on how close the camera ended up:
	-- full distance → full angle (looking down on player from above),
	-- close in → min angle (level with player's face).
	local distProgress = math.clamp(
		(actualDistance - MIN_THIRD_PERSON_DISTANCE) / (THIRD_PERSON_DISTANCE - MIN_THIRD_PERSON_DISTANCE),
		0, 1
	)
	local effectiveAngle = MIN_THIRD_PERSON_ANGLE + (THIRD_PERSON_ANGLE - MIN_THIRD_PERSON_ANGLE) * distProgress
	local angleRad = math.rad(effectiveAngle)
	local horizontalDist = actualDistance * math.cos(angleRad)
	local verticalDist = actualDistance * math.sin(angleRad)
	local offset = CFrame.Angles(0, math.rad(cameraYaw), 0) * Vector3.new(0, 0, horizontalDist)
	
	local cameraPos = smoothedPivot + Vector3.new(offset.X, verticalDist, offset.Z)
	
	-- Clamp: camera never goes below the lookAt point. The lookAt is at
	-- pivot.Y + 2 (chest height). We pin the camera to at least lookAt.Y + 1
	-- (= pivot.Y + 3, above the head) so it's always tilting slightly DOWN
	-- at the player, never up. Without this, low-angle close shots would dip
	-- below the head and look up at the chin.
	local minCameraY = lookAt.Y + 1
	if cameraPos.Y < minCameraY then
		cameraPos = Vector3.new(cameraPos.X, minCameraY, cameraPos.Z)
	end
	
	-- Final-pass smoothing on the full camera position. This catches any
	-- remaining jitter from mouse-input yaw changes, clamp transitions, or
	-- frame-to-frame raycast results that the per-axis smoothing above missed.
	-- High smoothing constant = barely-noticeable lag, but enough to eliminate
	-- single-frame snaps and make the whole motion feel buttery.
	if not smoothedCameraPos then
		smoothedCameraPos = cameraPos
	else
		local alphaPos = 1 - math.exp(-CAMERA_POS_SMOOTH * dt)
		smoothedCameraPos = smoothedCameraPos + (cameraPos - smoothedCameraPos) * alphaPos
	end
	cameraPos = smoothedCameraPos
	
	camera.CFrame = applyPortalSway(CFrame.lookAt(cameraPos, lookAt))
end

-- ============================================
-- MENU CAMERA (for title screen)
-- ============================================

local menuCameraAngle = 0

local function updateMenuCamera()
	-- Get the plot center to orbit around
	local centerPos = getPlotCenter()
	
	-- Check if we're in MegaPlot mode - use larger camera distance
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local isPrivateServerValue = ReplicatedStorage:FindFirstChild("IsPrivateServer")
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	
	local cameraDistance = MENU_CAMERA_DISTANCE
	local cameraHeight = MENU_CAMERA_HEIGHT
	
	if isPrivateServerValue and isPrivateServerValue.Value and modeValue and modeValue.Value == "MegaPlot" then
		-- MegaPlot is much larger, increase camera distance
		cameraDistance = 200
		cameraHeight = 80
	end
	
	-- Slow rotation around the plot
	menuCameraAngle = menuCameraAngle + MENU_CAMERA_SPEED
	
	local angleRad = math.rad(menuCameraAngle)
	local cameraPos = centerPos + Vector3.new(
		math.cos(angleRad) * cameraDistance,
		cameraHeight,
		math.sin(angleRad) * cameraDistance
	)
	
	-- Look at the plot center (slightly above ground)
	local lookAt = centerPos + Vector3.new(0, -5, 0)
	
	camera.CFrame = CFrame.lookAt(cameraPos, lookAt)
end

-- ============================================
-- TOGGLE
-- ============================================

local function toggleCameraMode()
	if not gameStarted then return end -- Don't toggle if game hasn't started
	
	isFirstPerson = not isFirstPerson
	
	local rootPart, head, humanoid = getCharacterParts()
	
	if isFirstPerson then
		camera.CameraType = Enum.CameraType.Scriptable
		if not isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		setCharacterVisible(false)
		print("Switched to First Person")
	else
		camera.CameraType = Enum.CameraType.Scriptable
		player.CameraMinZoomDistance = THIRD_PERSON_DISTANCE
		player.CameraMaxZoomDistance = THIRD_PERSON_DISTANCE
		if not isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		setCharacterVisible(true)
		cameraPitch = 0
		-- Reset all smoothed state so the camera initializes cleanly from the
		-- current frame instead of interpolating from stale values (which
		-- caused a brief glitch on toggle to 3rd person near walls).
		smoothedLookAt = nil
		smoothedCameraPos = nil
		smoothedCameraDistance = nil
		print("Switched to Third Person")
	end
end

-- ============================================
-- GAME START HANDLER
-- ============================================

local function startGameCamera()
	if gameStarted then return end
	gameStarted = true
	
	print("[CameraController] Game started - activating first person camera")
	
	-- Initialize first person
	isFirstPerson = true
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = FIELD_OF_VIEW
	setCharacterVisible(false)
	
	if not isMobile then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
	
	-- Set initial camera yaw based on character facing direction
	local rootPart = getCharacterParts()
	if rootPart then
		local lookVector = rootPart.CFrame.LookVector
		cameraYaw = math.deg(math.atan2(-lookVector.X, -lookVector.Z))
	end
end

-- ============================================
-- INVENTORY CHECK
-- ============================================

local function isInventoryOpen()
	if _G.InventoryController and _G.InventoryController.IsInventoryOpen then
		return _G.InventoryController.IsInventoryOpen()
	end
	return false
end

local function isBiomeUIOpen()
	if _G.BiomeUI and _G.BiomeUI.IsOpen then
		local result = _G.BiomeUI.IsOpen()
		return result
	end
	return false
end

local function isSaveLoadUIOpen()
	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui then
		local saveLoadUI = playerGui:FindFirstChild("SaveLoadUI")
		if saveLoadUI and saveLoadUI.Enabled then
			return true
		end
	end
	return false
end

local function isFeedbackUIOpen()
	if _G.FeedbackUI and _G.FeedbackUI.IsOpen then
		return _G.FeedbackUI.IsOpen()
	end
	return false
end

local function isChangelogUIOpen()
	if _G.ChangelogUI and _G.ChangelogUI.IsOpen then
		return _G.ChangelogUI.IsOpen()
	end
	return false
end

local function isTitleScreenOpen()
	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui then
		local titleScreen = playerGui:FindFirstChild("TitleScreen")
		if titleScreen and titleScreen.Enabled then
			return true
		end
	end
	return false
end

local function isSignEditing()
	if _G.SignEditController and _G.SignEditController.IsEditing then
		return _G.SignEditController.IsEditing()
	end
	return false
end

local function isTextBlockEditing()
	if _G.TextBlockEditController and _G.TextBlockEditController.IsEditing then
		return _G.TextBlockEditController.IsEditing()
	end
	return false
end

local function isPlayerInteractionUIOpen()
	if _G.PlayerInteractionUI and _G.PlayerInteractionUI.IsOpen then
		return _G.PlayerInteractionUI.IsOpen()
	end
	return false
end

local function isShopUIOpen()
	if _G.ShopUI and _G.ShopUI.IsOpen then
		return _G.ShopUI.IsOpen()
	end
	return false
end

local function isHelpBookUIOpen()
	if _G.HelpBookUI and _G.HelpBookUI.IsOpen then
		return _G.HelpBookUI.IsOpen()
	end
	return false
end

local function isPlusUIOpen()
	if _G.PlusUI and _G.PlusUI.IsOpen then
		return _G.PlusUI.IsOpen()
	end
	return false
end

local function isBlockUIOpen()
	if _G.BlockInteractionController and _G.BlockInteractionController.IsAnyBlockUIOpen then
		return _G.BlockInteractionController.IsAnyBlockUIOpen()
	end
	return false
end

-- While laying in a bed, BedController owns the camera + root CFrame.
-- This check makes CameraController fully stand down so the two don't fight.
local function isInBed()
	if _G.BedController and _G.BedController.IsLayingDown then
		return _G.BedController.IsLayingDown()
	end
	return false
end

local function isAnyUIOpen()
	local invOpen = isInventoryOpen()
	local biomeOpen = isBiomeUIOpen()
	local saveLoadOpen = isSaveLoadUIOpen()
	local feedbackOpen = isFeedbackUIOpen()
	local changelogOpen = isChangelogUIOpen()
	local signEditing = isSignEditing()
	local textBlockEditing = isTextBlockEditing()
	local playerInteractionOpen = isPlayerInteractionUIOpen()
	local shopOpen = isShopUIOpen()
	local helpBookOpen = isHelpBookUIOpen()
	local plusUIOpen = isPlusUIOpen()
	local blockUIOpen = isBlockUIOpen()
	local dailyRewardsOpen = _G.DailyRewardsUI and _G.DailyRewardsUI.IsOpen and _G.DailyRewardsUI.IsOpen() or false
	return invOpen or biomeOpen or saveLoadOpen or feedbackOpen or changelogOpen or signEditing or textBlockEditing or playerInteractionOpen or shopOpen or helpBookOpen or plusUIOpen or blockUIOpen or dailyRewardsOpen
end

-- ============================================
-- MOBILE UI
-- ============================================

local function createMobileUI()
	local playerGui = player:WaitForChild("PlayerGui")
	
	local existingGui = playerGui:FindFirstChild("CameraMobileGui")
	if existingGui then
		existingGui:Destroy() -- Recreate to ensure proper positioning
	end
	
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CameraMobileGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui
	
	-- Camera toggle - positioned on right side, above Roblox jump button area
	local toggleButton = Instance.new("TextButton")
	toggleButton.Name = "CameraToggleButton"
	toggleButton.Size = UDim2.new(0, 50, 0, 50)
	toggleButton.Position = UDim2.new(1, -65, 1, -240) -- Right side, high enough to avoid Roblox icons
	toggleButton.AnchorPoint = Vector2.new(0, 0)
	toggleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	toggleButton.BackgroundTransparency = 0.15
	toggleButton.Text = "1P"
	toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleButton.TextSize = 20
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.Parent = screenGui
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = toggleButton
	
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 80, 100)
	stroke.Thickness = 1
	stroke.Parent = toggleButton
	
	toggleButton.MouseButton1Click:Connect(function()
		toggleCameraMode()
		toggleButton.Text = isFirstPerson and "1P" or "3P"
	end)
	
	-- Also handle touch tap for reliability
	toggleButton.TouchTap:Connect(function()
		toggleCameraMode()
		toggleButton.Text = isFirstPerson and "1P" or "3P"
	end)
	
	return screenGui
end

-- ============================================
-- INPUT HANDLERS
-- ============================================

local function onInputChanged(input, gameProcessed)
	if gameProcessed then return end
	if not gameStarted then return end -- Don't process input until game starts
	if isAnyUIOpen() then return end
	if isInBed() then return end -- Bed owns the camera while laying down
	
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		local delta = input.Delta
		
		if isFirstPerson then
			cameraYaw = cameraYaw - delta.X * ROTATE_SPEED
			cameraPitch = math.clamp(cameraPitch - delta.Y * ROTATE_SPEED, MIN_PITCH, MAX_PITCH)
		else
			cameraYaw = cameraYaw - delta.X * ROTATE_SPEED
		end
	end
end

local function onInputBegan(input, gameProcessed)
	if gameProcessed then return end
	if not gameStarted then return end -- Don't process input until game starts
	
	if input.KeyCode == Enum.KeyCode.C then
		if isAnyUIOpen() then return end
		toggleCameraMode()
		
		local playerGui = player:FindFirstChild("PlayerGui")
		if playerGui then
			local mobileGui = playerGui:FindFirstChild("CameraMobileGui")
			if mobileGui then
				local btn = mobileGui:FindFirstChild("CameraToggleButton")
				if btn then
					btn.Text = isFirstPerson and "1P" or "3P"
				end
			end
		end
	end
end

-- Touch input
local function onTouchStarted(input, gameProcessed)
	if gameProcessed then return end
	if not gameStarted then return end
	
	activeTouches[input] = true
	
	local screenSize = camera.ViewportSize
	if input.Position.X > screenSize.X * 0.4 then
		lastTouchPos = input.Position
	end
end

local function onTouchMoved(input, gameProcessed)
	if not activeTouches[input] then return end
	if not gameStarted then return end
	if isAnyUIOpen() then return end
	if isInBed() then return end -- Bed owns the camera while laying down
	
	if lastTouchPos then
		local screenSize = camera.ViewportSize
		if input.Position.X > screenSize.X * 0.4 then
			local delta = input.Position - lastTouchPos
			
			if isFirstPerson then
				cameraYaw = cameraYaw - delta.X * TOUCH_ROTATE_SPEED
				cameraPitch = math.clamp(cameraPitch - delta.Y * TOUCH_ROTATE_SPEED, MIN_PITCH, MAX_PITCH)
			else
				cameraYaw = cameraYaw - delta.X * TOUCH_ROTATE_SPEED
			end
			
			lastTouchPos = input.Position
		end
	end
end

local function onTouchEnded(input, gameProcessed)
	activeTouches[input] = nil
	
	local activeCount = 0
	for _ in pairs(activeTouches) do
		activeCount = activeCount + 1
	end
	if activeCount == 0 then
		lastTouchPos = nil
	end
end

-- ============================================
-- MAIN UPDATE LOOP
-- ============================================

local function onRenderStep(dt)
	-- If game hasn't started, use menu camera
	if not gameStarted then
		camera.CameraType = Enum.CameraType.Scriptable
		if not isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		updateMenuCamera()
		setCharacterVisible(false) -- Hide character on title screen
		return
	end
	
	-- BedController owns the camera + root while laying down. Don't touch
	-- camera CFrame or rotate the root, or we'll fight its enforcement loop.
	-- Also free the mouse so the user can click the "Get Up" button.
	if isInBed() then
		if not isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		return
	end
	
	if isAnyUIOpen() then
		if not isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		return
	end
	
	if not isMobile then
		UserInputService.MouseIconEnabled = false
	end
	
	if isFirstPerson then
		camera.CameraType = Enum.CameraType.Scriptable
		if not isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		updateFirstPersonCamera()
	else
		camera.CameraType = Enum.CameraType.Scriptable
		if not isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		updateThirdPersonCamera(dt)
	end
end

-- ============================================
-- CONNECTIONS
-- ============================================

UserInputService.InputChanged:Connect(onInputChanged)
UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.TouchStarted:Connect(onTouchStarted)
UserInputService.TouchMoved:Connect(onTouchMoved)
UserInputService.TouchEnded:Connect(onTouchEnded)

RunService.RenderStepped:Connect(onRenderStep)

player.CharacterAdded:Connect(function(character)
	-- Clear smoothed state so the camera doesn't briefly snap from the old
	-- character's position to the new one on respawn.
	smoothedLookAt = nil
	smoothedCameraPos = nil
	smoothedCameraDistance = nil
	
	task.wait(0.1)
	if not gameStarted then
		setCharacterVisible(false)
		return
	end
	
	if isFirstPerson then
		camera.CameraType = Enum.CameraType.Scriptable
		setCharacterVisible(false)
	else
		setCharacterVisible(true)
	end
end)

-- ============================================
-- INITIALIZATION
-- ============================================

task.wait(0.5)

-- Start in menu mode
camera.CameraType = Enum.CameraType.Scriptable
camera.FieldOfView = FIELD_OF_VIEW

-- Keep mouse free for title screen
if not isMobile then
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

-- Don't create mobile UI here - MobileControls.client.luau handles all mobile buttons
-- to prevent overlapping and conflicts
if isMobile then
	print("CameraController loaded (Mobile) - Waiting for game start")
else
	print("CameraController loaded (Desktop) - Waiting for game start")
end

-- Export for other scripts
_G.CameraController = {
	GetLookVector = function()
		return camera.CFrame.LookVector
	end,
	GetYaw = function()
		return cameraYaw
	end,
	GetPitch = function()
		return cameraPitch
	end,
	IsFirstPerson = function()
		return isFirstPerson
	end,
	ToggleCamera = toggleCameraMode,
	StartGame = startGameCamera,  -- Called by TitleScreen when game starts
	ReturnToMenu = function()
		if not gameStarted then return end
		gameStarted = false
		print("[CameraController] Returning to menu camera")
		
		-- Free the mouse
		if not isMobile then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
		
		-- Hide character
		setCharacterVisible(false)
	end,
	IsGameStarted = function()
		return gameStarted
	end,
}
