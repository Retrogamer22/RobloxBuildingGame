--[[
	MobileControls
	Centralized mobile button management to prevent overlaps
	All game control buttons are positioned here in one place
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Only run on mobile
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
if not IsMobile then
	return
end

-- Wait for other controllers to initialize their _G exports
print("[MobileControls] Waiting for controllers...")
task.wait(2)

-- Wait specifically for FlightController
local waitAttempts = 0
while not _G.FlightController and waitAttempts < 10 do
	task.wait(0.5)
	waitAttempts = waitAttempts + 1
	print("[MobileControls] Waiting for FlightController... attempt " .. waitAttempts)
end

if _G.FlightController then
	print("[MobileControls] FlightController found!")
else
	warn("[MobileControls] FlightController NOT found after waiting!")
end

-- ============================================
-- HIDE BUTTONS FROM OTHER SCRIPTS (just in case)
-- ============================================

local function cleanupOtherMobileButtons()
	-- Hide camera button from CameraController (if it exists)
	local cameraGui = playerGui:FindFirstChild("CameraMobileGui")
	if cameraGui then
		cameraGui:Destroy()
	end
	
	-- Hide flight buttons from FlightController (if it exists)
	local flightGui = playerGui:FindFirstChild("FlightMobileGui")
	if flightGui then
		flightGui:Destroy()
	end
	
	-- Hide inventory mobile buttons
	local invGui = playerGui:FindFirstChild("InventoryGui")
	if invGui then
		local mobileButtons = invGui:FindFirstChild("MobileButtons")
		if mobileButtons then
			mobileButtons:Destroy()
		end
	end
	
	-- Hide feedback button on mobile (too cluttered)
	local feedbackUI = playerGui:FindFirstChild("FeedbackUI")
	if feedbackUI then
		local feedbackBtn = feedbackUI:FindFirstChild("FeedbackButton")
		if feedbackBtn then
			feedbackBtn.Visible = false
		end
	end
end

cleanupOtherMobileButtons()

-- ============================================
-- CREATE UNIFIED MOBILE CONTROLS
-- ============================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MobileControlsGui"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 10
screenGui.Parent = playerGui

-- Button styling (matching MainMenuButton exactly)
local BUTTON_SIZE = 46
local BUTTON_GAP = 8
local MC_BG = Color3.fromRGB(110, 110, 110)
local MC_BG_HOVER = Color3.fromRGB(130, 130, 130)
local MC_BG_PRESS = Color3.fromRGB(90, 90, 90)
local MC_BEVEL_LIGHT = Color3.fromRGB(160, 160, 160)
local MC_BEVEL_DARK = Color3.fromRGB(55, 55, 55)
local BEVEL = 2

-- Compute bevel colors from a base color (lighter for highlight, darker for shadow)
local function getBevelColors(baseColor)
	local r, g, b = baseColor.R, baseColor.G, baseColor.B
	local light = Color3.new(math.min(r + 0.2, 1), math.min(g + 0.2, 1), math.min(b + 0.2, 1))
	local dark = Color3.new(math.max(r - 0.22, 0), math.max(g - 0.22, 0), math.max(b - 0.22, 0))
	return light, dark
end

local function updateBevelColors(borders, baseColor)
	local light, dark = getBevelColors(baseColor)
	borders.top.BackgroundColor3 = light
	borders.left.BackgroundColor3 = light
	borders.bottom.BackgroundColor3 = dark
	borders.right.BackgroundColor3 = dark
end

local function addBevel(parent, baseColor)
	local light, dark = getBevelColors(baseColor or parent.BackgroundColor3)
	
	local top = Instance.new("Frame")
	top.Name = "BorderTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL)
	top.BackgroundColor3 = light
	top.BorderSizePixel = 0
	top.ZIndex = parent.ZIndex + 1
	top.Parent = parent
	
	local left = Instance.new("Frame")
	left.Name = "BorderLeft"
	left.Size = UDim2.new(0, BEVEL, 1, 0)
	left.BackgroundColor3 = light
	left.BorderSizePixel = 0
	left.ZIndex = parent.ZIndex + 1
	left.Parent = parent
	
	local bottom = Instance.new("Frame")
	bottom.Name = "BorderBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL)
	bottom.BackgroundColor3 = dark
	bottom.BorderSizePixel = 0
	bottom.ZIndex = parent.ZIndex + 1
	bottom.Parent = parent
	
	local right = Instance.new("Frame")
	right.Name = "BorderRight"
	right.Size = UDim2.new(0, BEVEL, 1, 0)
	right.Position = UDim2.new(1, -BEVEL, 0, 0)
	right.BackgroundColor3 = dark
	right.BorderSizePixel = 0
	right.ZIndex = parent.ZIndex + 1
	right.Parent = parent
	
	return {top = top, left = left, bottom = bottom, right = right}
end

local function createButton(name, emoji, yOffsetFromBottom)
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.new(0, BUTTON_SIZE, 0, BUTTON_SIZE)
	btn.Position = UDim2.new(1, -(BUTTON_SIZE + 12), 1, -yOffsetFromBottom)
	btn.BackgroundColor3 = MC_BG
	btn.BackgroundTransparency = 0
	btn.Text = emoji
	btn.TextSize = 22
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.FredokaOne
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.Active = true
	btn.ZIndex = 100
	btn.Parent = screenGui
	
	local borders = addBevel(btn)
	
	-- Store borders and base color for external bevel updates
	btn:SetAttribute("_baseColorR", MC_BG.R)
	btn:SetAttribute("_baseColorG", MC_BG.G)
	btn:SetAttribute("_baseColorB", MC_BG.B)
	
	-- Press effect: invert bevel (same as menu button)
	btn.MouseButton1Down:Connect(function()
		local baseColor = btn.BackgroundColor3
		local light, dark = getBevelColors(baseColor)
		local r, g, b = baseColor.R, baseColor.G, baseColor.B
		btn.BackgroundColor3 = Color3.new(math.max(r - 0.08, 0), math.max(g - 0.08, 0), math.max(b - 0.08, 0))
		borders.top.BackgroundColor3 = dark
		borders.left.BackgroundColor3 = dark
		borders.bottom.BackgroundColor3 = light
		borders.right.BackgroundColor3 = light
	end)
	
	local function resetBevel()
		local baseR = btn:GetAttribute("_baseColorR") or MC_BG.R
		local baseG = btn:GetAttribute("_baseColorG") or MC_BG.G
		local baseB = btn:GetAttribute("_baseColorB") or MC_BG.B
		local baseColor = Color3.new(baseR, baseG, baseB)
		btn.BackgroundColor3 = baseColor
		updateBevelColors(borders, baseColor)
	end
	
	btn.MouseButton1Up:Connect(resetBevel)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			resetBevel()
		end
	end)
	
	return btn, btn, borders -- return borders too
end

-- ============================================
-- BUTTON POSITIONS (from bottom of screen)
-- Roblox jump button is around Y = 100 from bottom on right
-- We position our buttons ABOVE that area
-- ============================================

local BOTTOM_OFFSET = 160 -- Start above Roblox jump button
local RIGHT_OFFSET = 28 -- From right edge (pushed left to avoid overlapping other UI)

local TOTAL_SIZE = BUTTON_SIZE -- No border wrapper

-- Inventory button - lowest custom button (above jump area)
local inventoryBtn, inventoryBorder = createButton("InventoryBtn", "≡", BOTTOM_OFFSET)
inventoryBorder.Position = UDim2.new(1, -(TOTAL_SIZE + RIGHT_OFFSET), 1, -BOTTOM_OFFSET)
inventoryBtn.TextSize = 28

-- Fly toggle - above inventory  
local flyBtn, flyBorder, flyBorders = createButton("FlyBtn", "▲", 0)
flyBorder.Position = UDim2.new(1, -(TOTAL_SIZE + RIGHT_OFFSET), 1, -(BOTTOM_OFFSET + TOTAL_SIZE + BUTTON_GAP))
flyBtn.TextSize = 28

-- Camera toggle - above fly
local cameraBtn, cameraBorder = createButton("CameraBtn", "1P", 0)
cameraBorder.Position = UDim2.new(1, -(TOTAL_SIZE + RIGHT_OFFSET), 1, -(BOTTOM_OFFSET + (TOTAL_SIZE + BUTTON_GAP) * 2))
cameraBtn.Font = Enum.Font.Arcade
cameraBtn.TextSize = 18

-- Sprint toggle - to the LEFT of the 1P camera button (same row)
local sprintBtn, sprintBorder, sprintBorders = createButton("SprintBtn", "»", 0)
sprintBorder.Position = UDim2.new(1, -(TOTAL_SIZE * 2 + RIGHT_OFFSET + BUTTON_GAP), 1, -(BOTTOM_OFFSET + (TOTAL_SIZE + BUTTON_GAP) * 2))
sprintBtn.TextSize = 28

-- Fly up/down buttons (hidden by default, shown when flying)
-- These appear to the LEFT of the fly button when flying
local flyUpBtn, flyUpBorder, flyUpBorders = createButton("FlyUpBtn", "⬆", 0)
flyUpBorder.Position = UDim2.new(1, -(TOTAL_SIZE * 2 + RIGHT_OFFSET + BUTTON_GAP), 1, -(BOTTOM_OFFSET + TOTAL_SIZE + BUTTON_GAP))
local FLY_UP_COLOR = Color3.fromRGB(80, 140, 200)
flyUpBtn.BackgroundColor3 = FLY_UP_COLOR
flyUpBtn:SetAttribute("_baseColorR", FLY_UP_COLOR.R)
flyUpBtn:SetAttribute("_baseColorG", FLY_UP_COLOR.G)
flyUpBtn:SetAttribute("_baseColorB", FLY_UP_COLOR.B)
updateBevelColors(flyUpBorders, FLY_UP_COLOR)
flyUpBorder.Visible = false

local flyDownBtn, flyDownBorder, flyDownBorders = createButton("FlyDownBtn", "⬇", 0)
flyDownBorder.Position = UDim2.new(1, -(TOTAL_SIZE * 3 + RIGHT_OFFSET + BUTTON_GAP * 2), 1, -(BOTTOM_OFFSET + TOTAL_SIZE + BUTTON_GAP))
local FLY_DOWN_COLOR = Color3.fromRGB(200, 120, 80)
flyDownBtn.BackgroundColor3 = FLY_DOWN_COLOR
flyDownBtn:SetAttribute("_baseColorR", FLY_DOWN_COLOR.R)
flyDownBtn:SetAttribute("_baseColorG", FLY_DOWN_COLOR.G)
flyDownBtn:SetAttribute("_baseColorB", FLY_DOWN_COLOR.B)
updateBevelColors(flyDownBorders, FLY_DOWN_COLOR)
flyDownBorder.Visible = false

-- ============================================
-- BUTTON FUNCTIONALITY
-- ============================================

-- Camera toggle - use debounce to prevent multiple fires
local cameraDebounce = false
local function onCameraToggle()
	if cameraDebounce then return end
	cameraDebounce = true
	task.delay(0.3, function() cameraDebounce = false end)
	
	-- Toggle camera mode
	if _G.CameraController and _G.CameraController.ToggleCamera then
		_G.CameraController.ToggleCamera()
	end
end
cameraBtn.Activated:Connect(onCameraToggle)
cameraBtn.MouseButton1Click:Connect(onCameraToggle)
cameraBtn.TouchTap:Connect(onCameraToggle)

-- Inventory toggle - use debounce to prevent multiple fires
local invDebounce = false
local function onInventoryToggle()
	print("[MobileControls] Inventory button tapped!")
	if invDebounce then return end
	invDebounce = true
	task.delay(0.3, function() invDebounce = false end)
	
	if _G.InventoryController then
		print("[MobileControls] InventoryController found")
		if _G.InventoryController.IsInventoryOpen and _G.InventoryController.IsInventoryOpen() then
			print("[MobileControls] Closing inventory")
			if _G.InventoryController.CloseInventory then
				_G.InventoryController.CloseInventory()
			end
		else
			print("[MobileControls] Opening inventory")
			if _G.InventoryController.OpenInventory then
				_G.InventoryController.OpenInventory()
			else
				warn("[MobileControls] OpenInventory function not found!")
			end
		end
	else
		warn("[MobileControls] InventoryController not found!")
	end
end
inventoryBtn.Activated:Connect(onInventoryToggle)
inventoryBtn.MouseButton1Click:Connect(onInventoryToggle)
inventoryBtn.TouchTap:Connect(onInventoryToggle)

-- Fly toggle - use debounce to prevent multiple fires
local flyDebounce = false
local function onFlyToggle()
	if flyDebounce then return end
	flyDebounce = true
	task.delay(0.3, function() flyDebounce = false end)
	
	print("[MobileControls] Fly button tapped!")
	
	if _G.FlightController and _G.FlightController.ToggleFlight then
		_G.FlightController.ToggleFlight()
	else
		warn("[MobileControls] FlightController not found!")
	end
end
flyBtn.Activated:Connect(onFlyToggle)
flyBtn.MouseButton1Click:Connect(onFlyToggle)
flyBtn.TouchTap:Connect(onFlyToggle)

-- Sprint toggle - debounced to prevent multiple fires
local sprintDebounce = false
local function onSprintToggle()
	if sprintDebounce then return end
	sprintDebounce = true
	task.delay(0.3, function() sprintDebounce = false end)

	if _G.FlightController and _G.FlightController.ToggleSprint then
		_G.FlightController.ToggleSprint()
	else
		warn("[MobileControls] FlightController.ToggleSprint not found!")
	end
end
sprintBtn.Activated:Connect(onSprintToggle)
sprintBtn.MouseButton1Click:Connect(onSprintToggle)
sprintBtn.TouchTap:Connect(onSprintToggle)

-- Fly up (hold)
flyUpBtn.MouseButton1Down:Connect(function()
	if _G.FlightController and _G.FlightController.SetAscending then
		_G.FlightController.SetAscending(true)
	end
end)
flyUpBtn.MouseButton1Up:Connect(function()
	if _G.FlightController and _G.FlightController.SetAscending then
		_G.FlightController.SetAscending(false)
	end
end)
flyUpBtn.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		if _G.FlightController and _G.FlightController.SetAscending then
			_G.FlightController.SetAscending(false)
		end
	end
end)

-- Fly down (hold)
flyDownBtn.MouseButton1Down:Connect(function()
	if _G.FlightController and _G.FlightController.SetDescending then
		_G.FlightController.SetDescending(true)
	end
end)
flyDownBtn.MouseButton1Up:Connect(function()
	if _G.FlightController and _G.FlightController.SetDescending then
		_G.FlightController.SetDescending(false)
	end
end)
flyDownBtn.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		if _G.FlightController and _G.FlightController.SetDescending then
			_G.FlightController.SetDescending(false)
		end
	end
end)

-- ============================================
-- UPDATE LOOP
-- ============================================

-- Returns true if any modal UI (inventory, title screen, shop, etc.) is showing
-- and the mobile control buttons should be hidden.
local function shouldHideControls()
	if _G.InventoryController and _G.InventoryController.IsInventoryOpen and _G.InventoryController.IsInventoryOpen() then return true end
	if _G.TitleScreen and _G.TitleScreen.IsOpen and _G.TitleScreen.IsOpen() then return true end
	if _G.CameraController and _G.CameraController.IsGameStarted and not _G.CameraController.IsGameStarted() then return true end
	if _G.ShopUI and _G.ShopUI.IsOpen and _G.ShopUI.IsOpen() then return true end
	if _G.HelpBookUI and _G.HelpBookUI.IsOpen and _G.HelpBookUI.IsOpen() then return true end
	if _G.BiomeUI and _G.BiomeUI.IsOpen and _G.BiomeUI.IsOpen() then return true end
	if _G.DailyRewardsUI and _G.DailyRewardsUI.IsOpen and _G.DailyRewardsUI.IsOpen() then return true end
	if _G.PrivateServerSettingsUI and _G.PrivateServerSettingsUI.IsOpen and _G.PrivateServerSettingsUI.IsOpen() then return true end
	if _G.PlayerInteractionUI and _G.PlayerInteractionUI.IsOpen and _G.PlayerInteractionUI.IsOpen() then return true end
	if _G.SignEditController and _G.SignEditController.IsEditing and _G.SignEditController.IsEditing() then return true end
	if _G.BlockInteractionController and _G.BlockInteractionController.IsAnyBlockUIOpen and _G.BlockInteractionController.IsAnyBlockUIOpen() then return true end
	if _G.BedController and _G.BedController.IsLayingDown and _G.BedController.IsLayingDown() then return true end
	return false
end

game:GetService("RunService").Heartbeat:Connect(function()
	local hidden = shouldHideControls()
	
	-- Update fly button state
	local isFlying = _G.FlightController and _G.FlightController.IsFlying and _G.FlightController.IsFlying()
	
	flyBtn.Text = isFlying and "■" or "▲" -- Square when flying, up arrow when not
	local flyColor = isFlying and Color3.fromRGB(80, 140, 200) or MC_BG
	flyBtn.BackgroundColor3 = flyColor
	flyBtn:SetAttribute("_baseColorR", flyColor.R)
	flyBtn:SetAttribute("_baseColorG", flyColor.G)
	flyBtn:SetAttribute("_baseColorB", flyColor.B)
	updateBevelColors(flyBorders, flyColor)
	
	-- Sync camera button with actual state
	if _G.CameraController and _G.CameraController.IsFirstPerson then
		local isFirstPerson = _G.CameraController.IsFirstPerson()
		cameraBtn.Text = isFirstPerson and "1P" or "3P"
	end
	
	-- Hide ALL controls when any modal UI is open (inventory, title screen, shop, etc.).
	-- Toggle border frames (which contain the buttons)
	inventoryBorder.Visible = not hidden
	cameraBorder.Visible = not hidden
	flyBorder.Visible = not hidden
	sprintBorder.Visible = not hidden
	flyUpBorder.Visible = not hidden and isFlying
	flyDownBorder.Visible = not hidden and isFlying

	-- Sync sprint button with actual state. Green when sprinting, default otherwise.
	local isSprinting = _G.FlightController and _G.FlightController.IsSprinting and _G.FlightController.IsSprinting()
	local sprintColor = isSprinting and Color3.fromRGB(120, 195, 90) or MC_BG
	sprintBtn.BackgroundColor3 = sprintColor
	sprintBtn:SetAttribute("_baseColorR", sprintColor.R)
	sprintBtn:SetAttribute("_baseColorG", sprintColor.G)
	sprintBtn:SetAttribute("_baseColorB", sprintColor.B)
	updateBevelColors(sprintBorders, sprintColor)
end)

print("[MobileControls] Initialized - Unified mobile button layout")
