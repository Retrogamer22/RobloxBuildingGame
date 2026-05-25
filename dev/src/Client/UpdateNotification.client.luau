--[[
	UpdateNotification
	Shows a notification banner when a game update is available.
	Banner slides in from the top-left corner with a clean, modern design.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Configuration
local BANNER_WIDTH = 320
local BANNER_HEIGHT = 56
local BANNER_MARGIN = 12
local CORNER_RADIUS = 10

local COLORS = {
	background = Color3.fromRGB(35, 35, 45),
	accent = Color3.fromRGB(80, 180, 120),
	text = Color3.fromRGB(255, 255, 255),
	subtext = Color3.fromRGB(180, 180, 180)
}

-- Track if notification is already showing
local notificationShowing = false

local function createUpdateNotification(versionInfo)
	if notificationShowing then return end
	notificationShowing = true
	
	-- Create ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "UpdateNotification"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 100
	screenGui.Parent = playerGui
	
	-- Main container frame (positioned at bottom, left of hotbar)
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, BANNER_WIDTH, 0, BANNER_HEIGHT)
	container.AnchorPoint = Vector2.new(0, 1)
	container.Position = UDim2.new(0, BANNER_MARGIN, 1, BANNER_HEIGHT + 10) -- Start off-screen (below)
	container.BackgroundColor3 = COLORS.background
	container.BorderSizePixel = 0
	container.Parent = screenGui
	
	-- Drop shadow
	local shadow = Instance.new("ImageLabel")
	shadow.Name = "Shadow"
	shadow.Size = UDim2.new(1, 20, 1, 20)
	shadow.Position = UDim2.new(0, -10, 0, -5)
	shadow.BackgroundTransparency = 1
	shadow.Image = "rbxassetid://5554236805" -- Soft shadow
	shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
	shadow.ImageTransparency = 0.6
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.SliceCenter = Rect.new(23, 23, 277, 277)
	shadow.ZIndex = -1
	shadow.Parent = container
	
	-- Corner rounding
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, CORNER_RADIUS)
	corner.Parent = container
	
	-- Accent bar on the left
	local accentBar = Instance.new("Frame")
	accentBar.Name = "AccentBar"
	accentBar.Size = UDim2.new(0, 4, 1, 0)
	accentBar.Position = UDim2.new(0, 0, 0, 0)
	accentBar.BackgroundColor3 = COLORS.accent
	accentBar.BorderSizePixel = 0
	accentBar.Parent = container
	
	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(0, CORNER_RADIUS)
	accentCorner.Parent = accentBar
	
	-- Icon (refresh symbol using text)
	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Size = UDim2.new(0, 30, 0, 30)
	iconLabel.Position = UDim2.new(0, 14, 0.5, -15)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = "🔄"
	iconLabel.TextSize = 20
	iconLabel.Font = Enum.Font.SourceSans
	iconLabel.TextColor3 = COLORS.text
	iconLabel.Parent = container
	
	-- Text container
	local textContainer = Instance.new("Frame")
	textContainer.Name = "TextContainer"
	textContainer.Size = UDim2.new(1, -60, 1, -12)
	textContainer.Position = UDim2.new(0, 48, 0, 6)
	textContainer.BackgroundTransparency = 1
	textContainer.Parent = container
	
	-- Main text
	local mainText = Instance.new("TextLabel")
	mainText.Name = "MainText"
	mainText.Size = UDim2.new(1, 0, 0, 20)
	mainText.Position = UDim2.new(0, 0, 0, 2)
	mainText.BackgroundTransparency = 1
	mainText.Text = "Update Available!"
	mainText.TextColor3 = COLORS.text
	mainText.TextSize = 16
	mainText.Font = Enum.Font.GothamBold
	mainText.TextXAlignment = Enum.TextXAlignment.Left
	mainText.Parent = textContainer
	
	-- Sub text
	local subText = Instance.new("TextLabel")
	subText.Name = "SubText"
	subText.Size = UDim2.new(1, 0, 0, 16)
	subText.Position = UDim2.new(0, 0, 0, 22)
	subText.BackgroundTransparency = 1
	subText.Text = "Rejoin for the latest features"
	subText.TextColor3 = COLORS.subtext
	subText.TextSize = 13
	subText.Font = Enum.Font.Gotham
	subText.TextXAlignment = Enum.TextXAlignment.Left
	subText.Parent = textContainer
	
	-- Close button
	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.Size = UDim2.new(0, 24, 0, 24)
	closeButton.Position = UDim2.new(1, -30, 0.5, -12)
	closeButton.BackgroundTransparency = 1
	closeButton.Text = "✕"
	closeButton.TextColor3 = COLORS.subtext
	closeButton.TextSize = 16
	closeButton.Font = Enum.Font.GothamBold
	closeButton.Parent = container
	
	-- Close button hover effect
	closeButton.MouseEnter:Connect(function()
		closeButton.TextColor3 = COLORS.text
	end)
	
	closeButton.MouseLeave:Connect(function()
		closeButton.TextColor3 = COLORS.subtext
	end)
	
	-- Close functionality
	closeButton.MouseButton1Click:Connect(function()
		local slideOut = TweenService:Create(container, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {
			Position = UDim2.new(0, BANNER_MARGIN, 1, BANNER_HEIGHT + 10)
		})
		slideOut:Play()
		slideOut.Completed:Connect(function()
			screenGui:Destroy()
			notificationShowing = false
		end)
	end)
	
	-- Slide in animation (slide up from bottom)
	task.wait(0.1) -- Small delay to ensure UI is ready
	local slideIn = TweenService:Create(container, TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, BANNER_MARGIN, 1, -BANNER_MARGIN - 50) -- 50px above bottom
	})
	slideIn:Play()
	
	-- Optional: Gentle pulse on the accent bar
	task.spawn(function()
		while container and container.Parent do
			local pulseOut = TweenService:Create(accentBar, TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				BackgroundColor3 = Color3.fromRGB(100, 200, 140)
			})
			pulseOut:Play()
			pulseOut.Completed:Wait()
			
			if not container or not container.Parent then break end
			
			local pulseIn = TweenService:Create(accentBar, TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				BackgroundColor3 = COLORS.accent
			})
			pulseIn:Play()
			pulseIn.Completed:Wait()
		end
	end)
	
	return screenGui
end

-- Listen for update notifications from server
local UpdateNotify = ReplicatedStorage:WaitForChild("UpdateNotify", 30)
if UpdateNotify then
	UpdateNotify.OnClientEvent:Connect(function(versionInfo)
		print("[UpdateNotification] Update available! Current:", versionInfo.currentVersion, "New:", versionInfo.newVersion)
		createUpdateNotification(versionInfo)
	end)
	print("[UpdateNotification] Listening for updates...")
else
	warn("[UpdateNotification] Could not find UpdateNotify RemoteEvent")
end
