--[[
	SignInteractionController
	Handles sign interactions on mobile devices
	
	NOTE: This script is DISABLED because BuildingController already handles
	sign interaction via TrySignInteraction(). Having two scripts listen for
	the same touch events causes conflicts.
	
	On desktop, signs use RightMouseClick which works fine.
	On mobile, there's no right-click, so we handle taps on signs here.
	
	When a mobile player taps while looking at a sign they own (or LikeSign),
	we fire the appropriate remote event.
]]

-- DISABLED: BuildingController already handles sign interaction
do return end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

-- Only run on mobile devices
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
if not IsMobile then
	print("[SignInteractionController] Desktop detected, skipping mobile sign handling")
	return
end

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Wait for remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local OpenBiomeUI = Remotes:WaitForChild("OpenBiomeUI", 5)
local OpenSaveLoadUI = Remotes:WaitForChild("OpenSaveLoadUI", 5)
local LikePlayer = Remotes:WaitForChild("LikePlayer", 5)
local RequestSignInteraction = Remotes:WaitForChild("RequestSignInteraction", 10)

if not RequestSignInteraction then
	warn("[SignInteractionController] RequestSignInteraction remote not found!")
	return
end

print("[SignInteractionController] Found RequestSignInteraction remote")

-- Configuration
local REACH_DISTANCE = 15 -- How far player can interact with signs
local TAP_MAX_TIME = 0.5 -- Maximum time for a tap (not a hold)
local TOUCH_MOVE_THRESHOLD = 20 -- How much finger can move before it's not a tap

-- Touch state tracking
local TouchState = {
	activeId = nil,
	startTime = nil,
	startPos = nil,
	movedTooMuch = false,
}

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getCenterScreenRay()
	local viewportSize = Camera.ViewportSize
	return Camera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
end

-- Raycast from center of screen to find what we're looking at
local function raycastFromCenter()
	local ray = getCenterScreenRay()
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
	
	local result = workspace:Raycast(ray.Origin, ray.Direction * REACH_DISTANCE, raycastParams)
	return result
end

-- Get the build area a sign belongs to
local function getBuildAreaFromSign(sign)
	local current = sign.Parent
	while current and current ~= workspace do
		if string.match(current.Name, GridConfig.BUILD_AREA_PREFIX) then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Check if a part belongs to a sign
local function getSignFromPart(part)
	if not part then return nil end
	
	-- Walk up the hierarchy to find a sign
	local current = part
	while current and current ~= workspace do
		local name = current.Name
		if name == "BiomeSign" or name == "SaveLoadSign" or name == "LikeSign" then
			return current, name
		end
		current = current.Parent
	end
	return nil, nil
end

-- ============================================
-- SIGN INTERACTION
-- ============================================

local function tryInteractWithSign()
	local result = raycastFromCenter()
	if not result or not result.Instance then
		print("[SignInteractionController] Raycast hit nothing")
		return false
	end
	
	print("[SignInteractionController] Raycast hit:", result.Instance:GetFullName())
	
	-- Check if we hit a sign
	local sign, signType = getSignFromPart(result.Instance)
	if not sign then
		print("[SignInteractionController] Not a sign")
		return false
	end
	
	print("[SignInteractionController] Found sign:", signType)
	
	local buildArea = getBuildAreaFromSign(sign)
	if not buildArea then
		return false
	end
	
	-- Handle each sign type - let server validate ownership
	if signType == "BiomeSign" then
		RequestSignInteraction:FireServer("BiomeSign", buildArea)
		print("[SignInteractionController] Sent BiomeSign interaction request")
		return true
		
	elseif signType == "SaveLoadSign" then
		RequestSignInteraction:FireServer("SaveLoadSign", buildArea)
		print("[SignInteractionController] Sent SaveLoadSign interaction request")
		return true
		
	elseif signType == "LikeSign" then
		RequestSignInteraction:FireServer("LikeSign", buildArea)
		print("[SignInteractionController] Sent LikeSign interaction request")
		return true
	end
	
	return false
end

-- ============================================
-- TOUCH INPUT HANDLING
-- ============================================

UserInputService.TouchStarted:Connect(function(input, gameProcessed)
	if gameProcessed then 
		print("[SignInteractionController] Touch ignored - gameProcessed")
		return 
	end
	if TouchState.activeId then 
		print("[SignInteractionController] Touch ignored - already tracking")
		return 
	end
	
	-- Check if any UI is open that should block interaction
	if _G.InventoryController and _G.InventoryController.IsInventoryOpen and _G.InventoryController.IsInventoryOpen() then
		print("[SignInteractionController] Touch ignored - inventory open")
		return
	end
	
	-- Ignore touches on joystick area (left side)
	local screenSize = Camera.ViewportSize
	if input.Position.X < screenSize.X * 0.3 then 
		print("[SignInteractionController] Touch ignored - joystick area")
		return 
	end
	
	-- Ignore touches on hotbar area (bottom)
	if input.Position.Y > screenSize.Y - 100 then 
		print("[SignInteractionController] Touch ignored - hotbar area")
		return 
	end
	
	-- Ignore touches on mobile button area (right side, top portion)
	if input.Position.X > screenSize.X - 100 and input.Position.Y < 450 then 
		print("[SignInteractionController] Touch ignored - mobile button area")
		return 
	end
	
	print("[SignInteractionController] Touch started at", input.Position.X, input.Position.Y)
	TouchState.activeId = input
	TouchState.startTime = tick()
	TouchState.startPos = input.Position
	TouchState.movedTooMuch = false
end)

UserInputService.TouchMoved:Connect(function(input, gameProcessed)
	if input ~= TouchState.activeId then return end
	if not TouchState.startPos then return end
	
	if (input.Position - TouchState.startPos).Magnitude > TOUCH_MOVE_THRESHOLD then
		TouchState.movedTooMuch = true
	end
end)

UserInputService.TouchEnded:Connect(function(input, gameProcessed)
	if input ~= TouchState.activeId then return end
	
	local touchDuration = tick() - (TouchState.startTime or 0)
	
	-- Check if it was a quick tap (not a hold for breaking blocks)
	if not TouchState.movedTooMuch and touchDuration < TAP_MAX_TIME then
		print("[SignInteractionController] Quick tap detected, duration:", touchDuration)
		-- Try sign interaction first
		-- This happens BEFORE BuildingController processes the tap
		if tryInteractWithSign() then
			-- Sign was interacted with, don't let the tap place a block
			-- We can't actually stop BuildingController, but since signs
			-- are outside the plot, block placement should fail anyway
			print("[SignInteractionController] Sign interaction successful")
		end
	else
		print("[SignInteractionController] Not a quick tap - duration:", touchDuration, "moved:", TouchState.movedTooMuch)
	end
	
	-- Reset touch state
	TouchState.activeId = nil
	TouchState.startTime = nil
	TouchState.startPos = nil
	TouchState.movedTooMuch = false
end)

print("[SignInteractionController] Initialized (Mobile)")
