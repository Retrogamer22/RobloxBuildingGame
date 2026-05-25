--[[
	FlightController
	Minecraft-style creative mode flying
	Double-tap Space to toggle flight, Space/Shift for vertical movement
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- Settings
local FLIGHT_SPEED = 50           -- Horizontal movement speed
local VERTICAL_SPEED = 40         -- Up/down speed
local SPRINT_MULTIPLIER = 2       -- Speed when sprinting (hold W twice or Ctrl)
local DOUBLE_TAP_TIME = 0.3       -- Max time between taps to count as double-tap
local DECELERATION = 0.85         -- How quickly you slow down (lower = faster stop)
local NORMAL_FOV = 70             -- Default FOV
local SPRINT_FOV = 90             -- FOV when sprinting
local FOV_TWEEN_TIME = 0.2        -- How fast FOV changes
local NORMAL_WALK_SPEED = 16      -- Default walk speed
local SPRINT_WALK_SPEED = 24      -- Walk speed when sprinting on ground

-- State
local isFlying = false
local isSprinting = false
local lastSpaceTap = 0
local lastWTap = 0
local flyVelocity = Vector3.new(0, 0, 0)
local bodyGyro = nil
local bodyVelocity = nil
local fovTween = nil
local flightStartTime = 0 -- Track when flight started for grace period
local flyingAnimation = nil -- Track flying animation
local flyingAnimTrack = nil -- Animation track for flying pose

-- Mobile detection
local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Input state
local keysHeld = {
	W = false,
	A = false,
	S = false,
	D = false,
	Space = false,
	Shift = false,
	Ctrl = false,
}

-- ============================================
-- HELPERS
-- ============================================

local function getCharacter()
	return LocalPlayer.Character
end

local function getHumanoid()
	local character = getCharacter()
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function getRootPart()
	local character = getCharacter()
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function isInventoryOpen()
	if _G.InventoryController and _G.InventoryController.IsInventoryOpen then
		return _G.InventoryController.IsInventoryOpen()
	end
	return false
end

local function isBiomeUIOpen()
	if _G.BiomeUI and _G.BiomeUI.IsOpen then
		return _G.BiomeUI.IsOpen()
	end
	return false
end

local function isAnyUIOpen()
	return isInventoryOpen() or isBiomeUIOpen()
end

-- ============================================
-- SPRINT FOV
-- ============================================

local function setSprinting(sprinting)
	if sprinting == isSprinting then return end
	isSprinting = sprinting
	
	-- Cancel any existing FOV tween
	if fovTween then
		fovTween:Cancel()
	end
	
	-- Tween FOV
	local targetFOV = sprinting and SPRINT_FOV or NORMAL_FOV
	fovTween = TweenService:Create(
		Camera,
		TweenInfo.new(FOV_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{FieldOfView = targetFOV}
	)
	fovTween:Play()
	
	-- Update walk speed for ground sprinting
	if not isFlying then
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.WalkSpeed = sprinting and SPRINT_WALK_SPEED or NORMAL_WALK_SPEED
		end
	end
end

-- ============================================
-- FLIGHT MECHANICS
-- ============================================

local function createFlightBodies(rootPart)
	-- Clean up existing
	if bodyGyro then bodyGyro:Destroy() end
	if bodyVelocity then bodyVelocity:Destroy() end
	
	-- BodyGyro to prevent tumbling
	bodyGyro = Instance.new("BodyGyro")
	bodyGyro.Name = "FlightGyro"
	bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	bodyGyro.P = 10000
	bodyGyro.D = 500
	bodyGyro.CFrame = rootPart.CFrame
	bodyGyro.Parent = rootPart
	
	-- BodyVelocity for smooth movement
	bodyVelocity = Instance.new("BodyVelocity")
	bodyVelocity.Name = "FlightVelocity"
	bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bodyVelocity.Velocity = Vector3.new(0, 0, 0)
	bodyVelocity.Parent = rootPart
end

local function removeFlightBodies()
	if bodyGyro then
		bodyGyro:Destroy()
		bodyGyro = nil
	end
	if bodyVelocity then
		bodyVelocity:Destroy()
		bodyVelocity = nil
	end
end

-- Flying pose control
local function setFlyingPose(enable)
	local character = getCharacter()
	if not character then return end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	
	local animator = humanoid:FindFirstChildOfClass("Animator")
	
	if enable then
		-- Stop all playing animations to prevent falling animation
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				track:Stop(0.1)
			end
		end
		
		-- Set humanoid state to Physics to prevent default animations
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		
		-- Set a neutral/T-pose by resetting all Motor6D transforms
		for _, motor in ipairs(character:GetDescendants()) do
			if motor:IsA("Motor6D") then
				-- Store original transform if not stored
				if not motor:GetAttribute("OriginalC0") then
					-- We don't need to store, just reset Transform to identity
				end
				motor.Transform = CFrame.new() -- Reset to default pose
			end
		end
	else
		-- Restore normal humanoid state
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

local function updateMobileUI() end -- Forward declaration

local function enableFlight()
	print("[FlightController] enableFlight called")
	local humanoid = getHumanoid()
	local rootPart = getRootPart()
	
	if not humanoid then
		print("[FlightController] No humanoid found!")
		return false
	end
	if not rootPart then
		print("[FlightController] No rootPart found!")
		return false
	end
	
	print("[FlightController] Character found, enabling flight...")
	isFlying = true
	flightStartTime = tick() -- Record when flight started
	
	-- Create physics bodies
	createFlightBodies(rootPart)
	
	-- Set flying pose (stops falling animation)
	setFlyingPose(true)
	
	-- Give upward velocity to lift off the ground
	if bodyVelocity then
		bodyVelocity.Velocity = Vector3.new(0, 20, 0) -- Strong upward push
	end
	flyVelocity = Vector3.new(0, 20, 0) -- Also set flyVelocity so ground check doesn't trigger
	
	-- Update mobile UI if exists
	updateMobileUI()
	
	print("Flight enabled - Double-tap Space to disable")
	return true
end

local function disableFlight()
	local humanoid = getHumanoid()
	local rootPart = getRootPart()
	
	isFlying = false
	flyVelocity = Vector3.new(0, 0, 0)
	
	-- If Ctrl is still held, keep sprinting but apply ground walk speed
	if keysHeld.Ctrl then
		if humanoid then
			humanoid.WalkSpeed = SPRINT_WALK_SPEED
		end
	else
		setSprinting(false)
	end
	
	-- Remove physics bodies
	removeFlightBodies()
	
	-- Restore normal pose
	setFlyingPose(false)
	
	-- Update mobile UI if exists
	updateMobileUI()
	
	print("Flight disabled")
end

local function toggleFlight()
	print("[FlightController] toggleFlight called, isFlying = " .. tostring(isFlying))
	if isFlying then
		disableFlight()
	else
		local success = enableFlight()
		print("[FlightController] enableFlight returned: " .. tostring(success))
	end
end

-- ============================================
-- MOVEMENT CALCULATION
-- ============================================

local function calculateFlightVelocity(deltaTime)
	if not isFlying then return Vector3.new(0, 0, 0) end
	
	local rootPart = getRootPart()
	if not rootPart then return Vector3.new(0, 0, 0) end
	
	-- Get camera direction for horizontal movement
	local camCFrame = Camera.CFrame
	local lookVector = camCFrame.LookVector
	local rightVector = camCFrame.RightVector
	
	-- Flatten look vector for horizontal movement (no pitch influence)
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude > 0.01 then
		flatLook = flatLook.Unit
	else
		flatLook = Vector3.new(0, 0, -1)
	end
	
	local flatRight = Vector3.new(rightVector.X, 0, rightVector.Z)
	if flatRight.Magnitude > 0.01 then
		flatRight = flatRight.Unit
	else
		flatRight = Vector3.new(1, 0, 0)
	end
	
	-- Calculate target velocity from input
	local moveDirection = Vector3.new(0, 0, 0)
	
	-- Check for mobile joystick input via Humanoid.MoveDirection
	local humanoid = getHumanoid()
	if isMobile and humanoid then
		local humanoidMove = humanoid.MoveDirection
		if humanoidMove.Magnitude > 0.1 then
			-- Use the joystick direction directly (it's already in world space)
			moveDirection = Vector3.new(humanoidMove.X, 0, humanoidMove.Z)
		end
	end
	
	-- Horizontal movement (WASD) - desktop fallback or override
	if keysHeld.W then
		moveDirection = moveDirection + flatLook
	end
	if keysHeld.S then
		moveDirection = moveDirection - flatLook
	end
	if keysHeld.A then
		moveDirection = moveDirection - flatRight
	end
	if keysHeld.D then
		moveDirection = moveDirection + flatRight
	end
	
	-- Vertical movement (Space/Shift)
	if keysHeld.Space then
		moveDirection = moveDirection + Vector3.new(0, 1, 0)
	end
	if keysHeld.Shift then
		moveDirection = moveDirection - Vector3.new(0, 1, 0)
	end
	
	-- Normalize if there's any input
	if moveDirection.Magnitude > 0.01 then
		moveDirection = moveDirection.Unit
	end
	
	-- Calculate speed
	local speed = FLIGHT_SPEED
	if isSprinting then
		speed = speed * SPRINT_MULTIPLIER
	end
	
	-- Set target velocity
	local targetVelocity = moveDirection * speed
	
	-- Smooth interpolation toward target velocity
	if targetVelocity.Magnitude > 0.01 then
		-- Accelerate toward target
		flyVelocity = flyVelocity:Lerp(targetVelocity, 1 - math.pow(0.001, deltaTime))
	else
		-- Decelerate to stop
		flyVelocity = flyVelocity * math.pow(DECELERATION, deltaTime * 60)
		if flyVelocity.Magnitude < 0.1 then
			flyVelocity = Vector3.new(0, 0, 0)
		end
	end
	
	return flyVelocity
end

-- ============================================
-- MOBILE UI
-- ============================================

local flyButton = nil

function updateMobileUI()
	if flyButton then
		flyButton.Text = isFlying and "🦅" or "✈️"
		flyButton.BackgroundColor3 = isFlying and Color3.fromRGB(80, 150, 255) or Color3.fromRGB(50, 50, 50)
	end
end

local function createMobileUI()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	
	-- Check if already exists
	local existingGui = playerGui:FindFirstChild("FlightMobileGui")
	if existingGui then
		existingGui:Destroy() -- Recreate to ensure proper setup
	end
	
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "FlightMobileGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui
	
	-- Fly toggle button - positioned on right side, below camera toggle
	local toggleButton = Instance.new("TextButton")
	toggleButton.Name = "FlyToggleButton"
	toggleButton.Size = UDim2.new(0, 50, 0, 50)
	toggleButton.Position = UDim2.new(1, -65, 1, -180) -- Right side, below camera toggle
	toggleButton.AnchorPoint = Vector2.new(0, 0)
	toggleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	toggleButton.BackgroundTransparency = 0.15
	toggleButton.Text = "✈️"
	toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleButton.TextSize = 24
	toggleButton.Font = Enum.Font.Arcade
	toggleButton.Parent = screenGui
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = toggleButton
	
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 80, 100)
	stroke.Thickness = 1
	stroke.Parent = toggleButton
	
	-- Use MouseButton1Click AND touch tap for better mobile response
	toggleButton.MouseButton1Click:Connect(function()
		toggleFlight()
	end)
	
	-- Also handle touch tap directly for reliability
	toggleButton.TouchTap:Connect(function()
		toggleFlight()
	end)
	
	flyButton = toggleButton
	
	-- Vertical control buttons (only visible when flying)
	-- Positioned to the left of the fly toggle
	local upButton = Instance.new("TextButton")
	upButton.Name = "FlyUpButton"
	upButton.Size = UDim2.new(0, 50, 0, 50)
	upButton.Position = UDim2.new(1, -125, 1, -180) -- Left of fly toggle
	upButton.BackgroundColor3 = Color3.fromRGB(60, 130, 200)
	upButton.BackgroundTransparency = 0.15
	upButton.Text = "⬆"
	upButton.TextSize = 24
	upButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	upButton.Font = Enum.Font.Arcade
	upButton.Visible = false
	upButton.Parent = screenGui
	
	local upCorner = Instance.new("UICorner")
	upCorner.CornerRadius = UDim.new(0, 10)
	upCorner.Parent = upButton
	
	local downButton = Instance.new("TextButton")
	downButton.Name = "FlyDownButton"
	downButton.Size = UDim2.new(0, 50, 0, 50)
	downButton.Position = UDim2.new(1, -185, 1, -180) -- Left of up button
	downButton.BackgroundColor3 = Color3.fromRGB(200, 100, 60)
	downButton.BackgroundTransparency = 0.15
	downButton.Text = "⬇"
	downButton.TextSize = 24
	downButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	downButton.Font = Enum.Font.Arcade
	downButton.Visible = false
	downButton.Parent = screenGui
	
	local downCorner = Instance.new("UICorner")
	downCorner.CornerRadius = UDim.new(0, 10)
	downCorner.Parent = downButton
	
	-- Touch events for up button - use MouseButton1Down/Up for held state
	upButton.MouseButton1Down:Connect(function()
		keysHeld.Space = true
		upButton.BackgroundColor3 = Color3.fromRGB(100, 170, 255)
	end)
	upButton.MouseButton1Up:Connect(function()
		keysHeld.Space = false
		upButton.BackgroundColor3 = Color3.fromRGB(60, 130, 200)
	end)
	-- Handle touch ending outside button
	upButton.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			keysHeld.Space = false
			upButton.BackgroundColor3 = Color3.fromRGB(60, 130, 200)
		end
	end)
	
	-- Touch events for down button
	downButton.MouseButton1Down:Connect(function()
		keysHeld.Shift = true
		downButton.BackgroundColor3 = Color3.fromRGB(255, 140, 100)
	end)
	downButton.MouseButton1Up:Connect(function()
		keysHeld.Shift = false
		downButton.BackgroundColor3 = Color3.fromRGB(200, 100, 60)
	end)
	-- Handle touch ending outside button
	downButton.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			keysHeld.Shift = false
			downButton.BackgroundColor3 = Color3.fromRGB(200, 100, 60)
		end
	end)
	
	-- Update visibility based on flight state
	RunService.Heartbeat:Connect(function()
		upButton.Visible = isFlying
		downButton.Visible = isFlying
	end)
end

-- ============================================
-- INPUT HANDLING
-- ============================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if isAnyUIOpen() then return end
	
	-- Don't process input while editing signs
	if _G.SignEditController and _G.SignEditController.IsEditing() then return end
	
	-- Track key states
	if input.KeyCode == Enum.KeyCode.W then
		keysHeld.W = true
		
		-- Check for double-tap W to sprint
		local now = tick()
		if now - lastWTap < DOUBLE_TAP_TIME then
			setSprinting(true)
		end
		lastWTap = now
		
	elseif input.KeyCode == Enum.KeyCode.A then
		keysHeld.A = true
		
	elseif input.KeyCode == Enum.KeyCode.S then
		keysHeld.S = true
		
	elseif input.KeyCode == Enum.KeyCode.D then
		keysHeld.D = true
		
	elseif input.KeyCode == Enum.KeyCode.Space then
		keysHeld.Space = true
		
		-- Check for double-tap Space to toggle flight
		local now = tick()
		if now - lastSpaceTap < DOUBLE_TAP_TIME then
			toggleFlight()
			lastSpaceTap = 0  -- Reset to prevent triple-tap
		else
			lastSpaceTap = now
		end
		
	elseif input.KeyCode == Enum.KeyCode.LeftShift then
		keysHeld.Shift = true
		
	elseif input.KeyCode == Enum.KeyCode.LeftControl then
		keysHeld.Ctrl = true
		setSprinting(true)
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	-- Always track key releases
	if input.KeyCode == Enum.KeyCode.W then
		keysHeld.W = false
		-- Only stop sprinting if Ctrl isn't held
		if not keysHeld.Ctrl then
			setSprinting(false)
		end
		
	elseif input.KeyCode == Enum.KeyCode.A then
		keysHeld.A = false
		
	elseif input.KeyCode == Enum.KeyCode.S then
		keysHeld.S = false
		
	elseif input.KeyCode == Enum.KeyCode.D then
		keysHeld.D = false
		
	elseif input.KeyCode == Enum.KeyCode.Space then
		keysHeld.Space = false
		
	elseif input.KeyCode == Enum.KeyCode.LeftShift then
		keysHeld.Shift = false
		
	elseif input.KeyCode == Enum.KeyCode.LeftControl then
		keysHeld.Ctrl = false
		setSprinting(false)
	end
end)

-- ============================================
-- MAIN UPDATE LOOP
-- ============================================

RunService.Heartbeat:Connect(function(deltaTime)
	if not isFlying then return end
	
	local rootPart = getRootPart()
	if not rootPart then
		disableFlight()
		return
	end
	
	-- Keep the flying pose (prevent falling animation from playing)
	local character = getCharacter()
	if character then
		for _, motor in ipairs(character:GetDescendants()) do
			if motor:IsA("Motor6D") then
				motor.Transform = CFrame.new()
			end
		end
	end
	
	-- Grace period: don't check ground for first 1 second after enabling flight
	local timeSinceStart = tick() - flightStartTime
	if timeSinceStart > 1.0 then
		-- Check if player touched the ground (raycast down)
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = {getCharacter()}
		
		local rayResult = workspace:Raycast(rootPart.Position, Vector3.new(0, -3.5, 0), rayParams)
		if rayResult and flyVelocity.Y <= 0 then
			-- Only disable if moving down or stationary (not ascending)
			disableFlight()
			return
		end
	end
	
	-- Update gyro to match camera orientation (just yaw, not pitch)
	if bodyGyro then
		local camCFrame = Camera.CFrame
		local yaw = math.atan2(-camCFrame.LookVector.X, -camCFrame.LookVector.Z)
		bodyGyro.CFrame = CFrame.new(rootPart.Position) * CFrame.Angles(0, yaw, 0)
	end
	
	-- Calculate and apply velocity
	local velocity = calculateFlightVelocity(deltaTime)
	if bodyVelocity then
		bodyVelocity.Velocity = velocity
	end
end)

-- ============================================
-- CHARACTER RESPAWN HANDLING
-- ============================================

LocalPlayer.CharacterAdded:Connect(function(character)
	-- Wait for character to load
	task.wait(0.5)
	
	-- Reset flight state on respawn
	if isFlying then
		disableFlight()
	end
	
	-- Reset sprint and FOV
	setSprinting(false)
	
	-- Reset key states
	keysHeld = {
		W = false,
		A = false,
		S = false,
		D = false,
		Space = false,
		Shift = false,
		Ctrl = false,
	}
end)

-- ============================================
-- INITIALIZATION
-- ============================================

task.wait(0.5)

-- Don't create mobile UI here - MobileControls.client.luau handles all mobile buttons
-- to prevent overlapping and conflicts
if isMobile then
	print("FlightController loaded (Mobile) - MobileControls handles UI")
else
	print("FlightController loaded (Desktop) - Double-tap Space to toggle flight")
end

-- Export for other scripts
_G.FlightController = {
	IsFlying = function()
		return isFlying
	end,
	ToggleFlight = toggleFlight,
	EnableFlight = enableFlight,
	DisableFlight = disableFlight,
	-- Sprint state (mobile sprint button + anything else that wants to toggle it)
	IsSprinting = function()
		return isSprinting
	end,
	SetSprinting = setSprinting,
	ToggleSprint = function()
		setSprinting(not isSprinting)
	end,
	-- Mobile controls for vertical movement
	SetAscending = function(ascending)
		keysHeld.Space = ascending
	end,
	SetDescending = function(descending)
		keysHeld.Shift = descending
	end,
}

print("[FlightController] _G.FlightController exported")
