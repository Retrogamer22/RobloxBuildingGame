--[[
	CrosshairUI
	Simple crosshair for first-person building
]]

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Create crosshair GUI
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CrosshairGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 100
screenGui.Parent = playerGui

-- Crosshair frame (container)
local crosshairFrame = Instance.new("Frame")
crosshairFrame.Name = "Crosshair"
crosshairFrame.Size = UDim2.new(0, 24, 0, 24)
crosshairFrame.Position = UDim2.new(0.5, -12, 0.5, -12)
crosshairFrame.BackgroundTransparency = 1
crosshairFrame.Active = false -- Don't intercept input
crosshairFrame.Parent = screenGui

-- Horizontal line
local horizontal = Instance.new("Frame")
horizontal.Name = "Horizontal"
horizontal.Size = UDim2.new(0, 16, 0, 2)
horizontal.Position = UDim2.new(0.5, -8, 0.5, -1)
horizontal.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
horizontal.BorderSizePixel = 0
horizontal.Parent = crosshairFrame

-- Horizontal shadow
local hShadow = Instance.new("Frame")
hShadow.Size = UDim2.new(1, 2, 1, 2)
hShadow.Position = UDim2.new(0, -1, 0, -1)
hShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
hShadow.BackgroundTransparency = 0.5
hShadow.BorderSizePixel = 0
hShadow.ZIndex = 0
hShadow.Parent = horizontal

-- Vertical line
local vertical = Instance.new("Frame")
vertical.Name = "Vertical"
vertical.Size = UDim2.new(0, 2, 0, 16)
vertical.Position = UDim2.new(0.5, -1, 0.5, -8)
vertical.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
vertical.BorderSizePixel = 0
vertical.Parent = crosshairFrame

-- Vertical shadow
local vShadow = Instance.new("Frame")
vShadow.Size = UDim2.new(1, 2, 1, 2)
vShadow.Position = UDim2.new(0, -1, 0, -1)
vShadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
vShadow.BackgroundTransparency = 0.5
vShadow.BorderSizePixel = 0
vShadow.ZIndex = 0
vShadow.Parent = vertical

print("Crosshair UI loaded")

-- ============================================
-- VISIBILITY CONTROL
-- ============================================

local RunService = game:GetService("RunService")

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

local function isSaveLoadUIOpen()
	local saveLoadUI = playerGui:FindFirstChild("SaveLoadUI")
	if saveLoadUI and saveLoadUI.Enabled then
		return true
	end
	return false
end

local function isTitleScreenOpen()
	if _G.TitleScreen and _G.TitleScreen.IsOpen then
		return _G.TitleScreen.IsOpen()
	end
	return false
end

local function isPrivateServerSettingsOpen()
	if _G.PrivateServerSettingsUI and _G.PrivateServerSettingsUI.IsOpen then
		return _G.PrivateServerSettingsUI.IsOpen()
	end
	return false
end

local function isPlayerInteractionOpen()
	if _G.PlayerInteractionUI and _G.PlayerInteractionUI.IsOpen then
		return _G.PlayerInteractionUI.IsOpen()
	end
	return false
end

local function isSignEditing()
	if _G.SignEditController and _G.SignEditController.IsEditing then
		return _G.SignEditController.IsEditing()
	end
	return false
end

local function isShopUIOpen()
	if _G.ShopUI and _G.ShopUI.IsOpen then
		return _G.ShopUI.IsOpen()
	end
	return false
end

local function isBlockUIOpen()
	if _G.BlockInteractionController and _G.BlockInteractionController.IsAnyBlockUIOpen then
		return _G.BlockInteractionController.IsAnyBlockUIOpen()
	end
	return false
end

local function isThirdPerson()
	if _G.CameraController and _G.CameraController.IsFirstPerson then
		return not _G.CameraController.IsFirstPerson()
	end
	return false
end

local function isInBed()
	if _G.BedController and _G.BedController.IsLayingDown then
		return _G.BedController.IsLayingDown()
	end
	return false
end

local function isHelpBookOpen()
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

local function isAnyUIOpen()
	return isInventoryOpen() or isBiomeUIOpen() or isSaveLoadUIOpen()
		or isTitleScreenOpen() or isPrivateServerSettingsOpen()
		or isPlayerInteractionOpen() or isSignEditing()
		or isShopUIOpen() or isBlockUIOpen() or isHelpBookOpen()
		or isPlusUIOpen()
end

-- Update crosshair visibility based on UI state
RunService.RenderStepped:Connect(function()
	-- Hide crosshair in third person (the camera is angled down at the player,
	-- so a screen-center crosshair would misleadingly point at the ground.
	-- Interaction raycasts use the head's horizontal forward direction instead.)
	crosshairFrame.Visible = not isAnyUIOpen() and not isThirdPerson() and not isInBed()
end)
