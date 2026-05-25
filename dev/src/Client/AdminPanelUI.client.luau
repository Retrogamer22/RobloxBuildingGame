--[[
	AdminPanelUI
	Client-side admin panel with toggles for admin features
	
	Features:
	- Invisibility toggle
	- God mode toggle
	- Noclip toggle (with flight that ignores ground)
	- Speed slider
	- Teleport to players
	- Kick players with reason
	- Analytics dashboard (Top 10, Block stats, Server stats)
	
	Opens with a floating button (only visible to admins)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for admin remotes
local AdminRemotes = ReplicatedStorage:WaitForChild("AdminRemotes", 10)
if not AdminRemotes then
	warn("[AdminPanel] Admin remotes not found - not an admin or server not ready")
	return
end

local IsAdmin = AdminRemotes:WaitForChild("IsAdmin")
local ToggleInvisibility = AdminRemotes:WaitForChild("ToggleInvisibility")
local InvisibilitySync = AdminRemotes:WaitForChild("InvisibilitySync")
local ToggleGodMode = AdminRemotes:WaitForChild("ToggleGodMode")
local ToggleNoclip = AdminRemotes:WaitForChild("ToggleNoclip")
local SetSpeed = AdminRemotes:WaitForChild("SetSpeed")
local TeleportToPlayer = AdminRemotes:WaitForChild("TeleportToPlayer")
local KickPlayer = AdminRemotes:WaitForChild("KickPlayer")
local GetPlayerList = AdminRemotes:WaitForChild("GetPlayerList")

-- Analytics remotes (wait for them, may not exist yet)
local GetTopPlayers = AdminRemotes:WaitForChild("GetTopPlayers", 5)
local GetTopBlocks = AdminRemotes:WaitForChild("GetTopBlocks", 5)
local GetServerStats = AdminRemotes:WaitForChild("GetServerStats", 5)

-- Check if player is admin
local isAdmin = IsAdmin:InvokeServer()
if not isAdmin then
	print("[AdminPanel] Player is not an admin, panel disabled")
	return
end

print("[AdminPanel] Admin detected! Initializing panel...")

-- State
local panelOpen = false
local states = {
	invisible = false,
	godMode = false,
	noclip = false,
	speed = 16,
}

-- Kick state
local selectedKickPlayer = nil

-- Ghost effect for invisibility
local ghostHighlight = nil
local ghostConnection = nil
local ghostTransparency = 0.75 -- How transparent the ghost looks (higher = more transparent)

-- Noclip connections
local noclipConnection = nil
local noclipFlightConnection = nil
local noclipBodyVelocity = nil
local noclipBodyGyro = nil

-- Expose global noclip state for FlightController
_G.AdminNoclip = {
	IsActive = function()
		return states.noclip
	end
}

-- UI Colors
local COLORS = {
	background = Color3.fromRGB(30, 30, 35),
	panel = Color3.fromRGB(40, 40, 48),
	accent = Color3.fromRGB(88, 166, 255), -- Nice blue
	accentHover = Color3.fromRGB(120, 185, 255),
	toggleOn = Color3.fromRGB(76, 175, 80), -- Green
	toggleOff = Color3.fromRGB(80, 80, 90),
	text = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(180, 180, 190),
	danger = Color3.fromRGB(220, 60, 60),
	dangerHover = Color3.fromRGB(255, 80, 80),
	inputBg = Color3.fromRGB(50, 50, 58),
	gold = Color3.fromRGB(255, 215, 0),
	silver = Color3.fromRGB(192, 192, 192),
	bronze = Color3.fromRGB(205, 127, 50),
}

-- Noclip flight settings
local NOCLIP_SPEED = 60
local NOCLIP_VERTICAL_SPEED = 50

-- Noclip key states
local noclipKeys = {
	W = false,
	A = false,
	S = false,
	D = false,
	Space = false,
	Shift = false,
}

local function getCharacter()
	return player.Character
end

local function getRootPart()
	local character = getCharacter()
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local character = getCharacter()
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- Ghost effect function (for invisibility)
local function applyGhostEffect(enabled)
	local character = getCharacter()
	if not character then 
		print("[AdminPanel] Ghost effect: No character found")
		return 
	end
	
	print("[AdminPanel] Applying ghost effect:", enabled)
	
	if enabled then
		-- Create highlight for ghost outline
		if ghostHighlight then
			ghostHighlight:Destroy()
			ghostHighlight = nil
		end
		
		ghostHighlight = Instance.new("Highlight")
		ghostHighlight.Name = "GhostHighlight"
		ghostHighlight.Adornee = character
		ghostHighlight.FillColor = Color3.fromRGB(100, 180, 255)
		ghostHighlight.FillTransparency = 0.5
		ghostHighlight.OutlineColor = Color3.fromRGB(150, 220, 255)
		ghostHighlight.OutlineTransparency = 0
		ghostHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		ghostHighlight.Parent = character
		
		print("[AdminPanel] Ghost highlight created and parented to character")
		
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = -0.5
			elseif part:IsA("Decal") or part:IsA("Texture") then
				if not part:GetAttribute("GhostOriginalTransparency") then
					part:SetAttribute("GhostOriginalTransparency", part.Transparency)
				end
				part.Transparency = 0.5
			end
		end
		
		if ghostConnection then
			ghostConnection:Disconnect()
		end
		
		ghostConnection = RunService.Heartbeat:Connect(function()
			if not states.invisible then return end
			local char = getCharacter()
			if char then
				for _, part in ipairs(char:GetDescendants()) do
					if part:IsA("BasePart") then
						part.LocalTransparencyModifier = -0.5
					end
				end
			end
		end)
	else
		if ghostHighlight then
			ghostHighlight:Destroy()
			ghostHighlight = nil
		end
		
		if ghostConnection then
			ghostConnection:Disconnect()
			ghostConnection = nil
		end
		
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				part.LocalTransparencyModifier = 0
			elseif part:IsA("Decal") or part:IsA("Texture") then
				local original = part:GetAttribute("GhostOriginalTransparency")
				if original then
					part.Transparency = original
				end
			end
		end
		
		print("[AdminPanel] Ghost effect removed")
	end
end

-- Listen for invisibility sync from server
InvisibilitySync.OnClientEvent:Connect(function(enabled)
	applyGhostEffect(enabled)
end)

-- Create noclip flight bodies
local function createNoclipBodies(rootPart)
	if noclipBodyGyro then noclipBodyGyro:Destroy() end
	if noclipBodyVelocity then noclipBodyVelocity:Destroy() end
	
	noclipBodyGyro = Instance.new("BodyGyro")
	noclipBodyGyro.Name = "NoclipGyro"
	noclipBodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
	noclipBodyGyro.P = 10000
	noclipBodyGyro.D = 500
	noclipBodyGyro.CFrame = rootPart.CFrame
	noclipBodyGyro.Parent = rootPart
	
	noclipBodyVelocity = Instance.new("BodyVelocity")
	noclipBodyVelocity.Name = "NoclipVelocity"
	noclipBodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	noclipBodyVelocity.Velocity = Vector3.new(0, 0, 0)
	noclipBodyVelocity.Parent = rootPart
end

local function removeNoclipBodies()
	if noclipBodyGyro then
		noclipBodyGyro:Destroy()
		noclipBodyGyro = nil
	end
	if noclipBodyVelocity then
		noclipBodyVelocity:Destroy()
		noclipBodyVelocity = nil
	end
end

local function calculateNoclipVelocity()
	local camera = workspace.CurrentCamera
	local camCFrame = camera.CFrame
	local lookVector = camCFrame.LookVector
	local rightVector = camCFrame.RightVector
	
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
	
	local moveDirection = Vector3.new(0, 0, 0)
	
	if noclipKeys.W then
		moveDirection = moveDirection + flatLook
	end
	if noclipKeys.S then
		moveDirection = moveDirection - flatLook
	end
	if noclipKeys.A then
		moveDirection = moveDirection - flatRight
	end
	if noclipKeys.D then
		moveDirection = moveDirection + flatRight
	end
	
	if noclipKeys.Space then
		moveDirection = moveDirection + Vector3.new(0, 1, 0)
	end
	if noclipKeys.Shift then
		moveDirection = moveDirection - Vector3.new(0, 1, 0)
	end
	
	if moveDirection.Magnitude > 0.01 then
		moveDirection = moveDirection.Unit * NOCLIP_SPEED
	end
	
	return moveDirection
end

local function enableNoclip()
	local rootPart = getRootPart()
	local humanoid = getHumanoid()
	local character = getCharacter()
	
	if not rootPart or not humanoid or not character then
		return false
	end
	
	if _G.FlightController and _G.FlightController.IsFlying and _G.FlightController.IsFlying() then
		_G.FlightController.DisableFlight()
	end
	
	createNoclipBodies(rootPart)
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	
	noclipConnection = RunService.Stepped:Connect(function()
		local char = getCharacter()
		if char then
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end
	end)
	
	noclipFlightConnection = RunService.Heartbeat:Connect(function(deltaTime)
		local root = getRootPart()
		local char = getCharacter()
		
		if not root or not noclipBodyVelocity then
			return
		end
		
		if char then
			for _, motor in ipairs(char:GetDescendants()) do
				if motor:IsA("Motor6D") then
					motor.Transform = CFrame.new()
				end
			end
		end
		
		if noclipBodyGyro then
			local camCFrame = workspace.CurrentCamera.CFrame
			local yaw = math.atan2(-camCFrame.LookVector.X, -camCFrame.LookVector.Z)
			noclipBodyGyro.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
		end
		
		local velocity = calculateNoclipVelocity()
		noclipBodyVelocity.Velocity = velocity
	end)
	
	print("[AdminPanel] Noclip enabled with flight")
	return true
end

local function disableNoclip()
	if noclipConnection then
		noclipConnection:Disconnect()
		noclipConnection = nil
	end
	
	if noclipFlightConnection then
		noclipFlightConnection:Disconnect()
		noclipFlightConnection = nil
	end
	
	removeNoclipBodies()
	
	local character = getCharacter()
	if character then
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
				part.CanCollide = true
			end
		end
	end
	
	local humanoid = getHumanoid()
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	
	noclipKeys = {
		W = false,
		A = false,
		S = false,
		D = false,
		Space = false,
		Shift = false,
	}
	
	print("[AdminPanel] Noclip disabled")
end

local noclipInputBeganConnection = nil
local noclipInputEndedConnection = nil

local function setupNoclipInput()
	if noclipInputBeganConnection then
		noclipInputBeganConnection:Disconnect()
	end
	if noclipInputEndedConnection then
		noclipInputEndedConnection:Disconnect()
	end
	
	noclipInputBeganConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not states.noclip then return end
		if gameProcessed then return end
		
		if input.KeyCode == Enum.KeyCode.W then
			noclipKeys.W = true
		elseif input.KeyCode == Enum.KeyCode.A then
			noclipKeys.A = true
		elseif input.KeyCode == Enum.KeyCode.S then
			noclipKeys.S = true
		elseif input.KeyCode == Enum.KeyCode.D then
			noclipKeys.D = true
		elseif input.KeyCode == Enum.KeyCode.Space then
			noclipKeys.Space = true
		elseif input.KeyCode == Enum.KeyCode.LeftShift then
			noclipKeys.Shift = true
		end
	end)
	
	noclipInputEndedConnection = UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if input.KeyCode == Enum.KeyCode.W then
			noclipKeys.W = false
		elseif input.KeyCode == Enum.KeyCode.A then
			noclipKeys.A = false
		elseif input.KeyCode == Enum.KeyCode.S then
			noclipKeys.S = false
		elseif input.KeyCode == Enum.KeyCode.D then
			noclipKeys.D = false
		elseif input.KeyCode == Enum.KeyCode.Space then
			noclipKeys.Space = false
		elseif input.KeyCode == Enum.KeyCode.LeftShift then
			noclipKeys.Shift = false
		end
	end)
end

setupNoclipInput()

-- ============================================
-- UTILITY FUNCTIONS
-- ============================================

local function formatTime(seconds)
	seconds = math.floor(seconds or 0)
	
	if seconds < 60 then
		return seconds .. "s"
	elseif seconds < 3600 then
		local mins = math.floor(seconds / 60)
		local secs = seconds % 60
		return mins .. "m " .. secs .. "s"
	else
		local hours = math.floor(seconds / 3600)
		local mins = math.floor((seconds % 3600) / 60)
		return hours .. "h " .. mins .. "m"
	end
end

local function formatNumber(num)
	num = num or 0
	if num >= 1000000 then
		return string.format("%.1fM", num / 1000000)
	elseif num >= 1000 then
		return string.format("%.1fK", num / 1000)
	else
		return tostring(num)
	end
end

-- ============================================
-- CREATE UI
-- ============================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AdminPanel"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 999
screenGui.Parent = playerGui

-- Admin button (floating, always visible when admin)
local adminButton = Instance.new("TextButton")
adminButton.Name = "AdminButton"
adminButton.Size = UDim2.new(0, 50, 0, 50)
adminButton.Position = UDim2.new(0, 20, 0.5, -25)
adminButton.AnchorPoint = Vector2.new(0, 0.5)
adminButton.BackgroundColor3 = COLORS.accent
adminButton.Text = "⚙"
adminButton.TextColor3 = COLORS.text
adminButton.TextSize = 28
adminButton.Font = Enum.Font.Arcade
adminButton.AutoButtonColor = false
adminButton.Parent = screenGui

local adminButtonCorner = Instance.new("UICorner")
adminButtonCorner.CornerRadius = UDim.new(0, 12)
adminButtonCorner.Parent = adminButton

local adminButtonStroke = Instance.new("UIStroke")
adminButtonStroke.Color = COLORS.accentHover
adminButtonStroke.Thickness = 2
adminButtonStroke.Transparency = 0.5
adminButtonStroke.Parent = adminButton

-- Panel container (wider for analytics)
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.new(0, 520, 0, 600)
panel.Position = UDim2.new(0.5, 0, 0.5, 0)
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.BackgroundColor3 = COLORS.panel
panel.BackgroundTransparency = 0.05
panel.Visible = false
panel.Parent = screenGui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 16)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(60, 60, 70)
panelStroke.Thickness = 1
panelStroke.Parent = panel

local shadow = Instance.new("Frame")
shadow.Name = "Shadow"
shadow.Size = UDim2.new(1, 10, 1, 10)
shadow.Position = UDim2.new(0, 5, 0, 5)
shadow.AnchorPoint = Vector2.new(0, 0)
shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
shadow.BackgroundTransparency = 0.7
shadow.ZIndex = -1
shadow.Parent = panel

local shadowCorner = Instance.new("UICorner")
shadowCorner.CornerRadius = UDim.new(0, 16)
shadowCorner.Parent = shadow

-- Header
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 50)
header.Position = UDim2.new(0, 0, 0, 0)
header.BackgroundColor3 = COLORS.background
header.BackgroundTransparency = 0.3
header.Parent = panel

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 16)
headerCorner.Parent = header

local headerFix = Instance.new("Frame")
headerFix.Name = "CornerFix"
headerFix.Size = UDim2.new(1, 0, 0, 16)
headerFix.Position = UDim2.new(0, 0, 1, -16)
headerFix.BackgroundColor3 = COLORS.background
headerFix.BackgroundTransparency = 0.3
headerFix.BorderSizePixel = 0
headerFix.Parent = header

local headerTitle = Instance.new("TextLabel")
headerTitle.Name = "Title"
headerTitle.Size = UDim2.new(1, -20, 1, 0)
headerTitle.Position = UDim2.new(0, 15, 0, 0)
headerTitle.BackgroundTransparency = 1
headerTitle.Text = "⚙ Admin Panel"
headerTitle.TextColor3 = COLORS.text
headerTitle.TextSize = 18
headerTitle.Font = Enum.Font.Arcade
headerTitle.TextXAlignment = Enum.TextXAlignment.Left
headerTitle.Parent = header

-- Two-column layout container
local columnsContainer = Instance.new("Frame")
columnsContainer.Name = "ColumnsContainer"
columnsContainer.Size = UDim2.new(1, -20, 1, -60)
columnsContainer.Position = UDim2.new(0, 10, 0, 55)
columnsContainer.BackgroundTransparency = 1
columnsContainer.Parent = panel

-- Left column (original admin controls)
local leftColumn = Instance.new("ScrollingFrame")
leftColumn.Name = "LeftColumn"
leftColumn.Size = UDim2.new(0.48, 0, 1, 0)
leftColumn.Position = UDim2.new(0, 0, 0, 0)
leftColumn.BackgroundTransparency = 1
leftColumn.ScrollBarThickness = 4
leftColumn.ScrollBarImageColor3 = COLORS.accent
leftColumn.CanvasSize = UDim2.new(0, 0, 0, 0)
leftColumn.AutomaticCanvasSize = Enum.AutomaticSize.Y
leftColumn.Parent = columnsContainer

local leftLayout = Instance.new("UIListLayout")
leftLayout.Padding = UDim.new(0, 8)
leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
leftLayout.Parent = leftColumn

-- Right column (analytics)
local rightColumn = Instance.new("Frame")
rightColumn.Name = "RightColumn"
rightColumn.Size = UDim2.new(0.50, 0, 1, 0)
rightColumn.Position = UDim2.new(0.50, 0, 0, 0)
rightColumn.BackgroundTransparency = 1
rightColumn.Parent = columnsContainer

-- Analytics header
local analyticsHeader = Instance.new("TextLabel")
analyticsHeader.Name = "AnalyticsHeader"
analyticsHeader.Size = UDim2.new(1, 0, 0, 25)
analyticsHeader.BackgroundTransparency = 1
analyticsHeader.Text = "📊 ANALYTICS"
analyticsHeader.TextColor3 = COLORS.textDim
analyticsHeader.TextSize = 11
analyticsHeader.Font = Enum.Font.Arcade
analyticsHeader.TextXAlignment = Enum.TextXAlignment.Left
analyticsHeader.Parent = rightColumn

-- Analytics tabs
local tabsContainer = Instance.new("Frame")
tabsContainer.Name = "TabsContainer"
tabsContainer.Size = UDim2.new(1, 0, 0, 30)
tabsContainer.Position = UDim2.new(0, 0, 0, 28)
tabsContainer.BackgroundTransparency = 1
tabsContainer.Parent = rightColumn

local tabsLayout = Instance.new("UIListLayout")
tabsLayout.FillDirection = Enum.FillDirection.Horizontal
tabsLayout.Padding = UDim.new(0, 4)
tabsLayout.Parent = tabsContainer

local function createTabButton(name, text, order)
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.new(0, 78, 1, 0)
	btn.BackgroundColor3 = COLORS.toggleOff
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.Arcade
	btn.Text = text
	btn.TextColor3 = COLORS.textDim
	btn.TextSize = 10
	btn.LayoutOrder = order
	btn.AutoButtonColor = false
	btn.Parent = tabsContainer
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	
	return btn
end

local topPlayersTab = createTabButton("TopPlayersTab", "🏆 Top 10", 1)
local topBlocksTab = createTabButton("TopBlocksTab", "🧱 Blocks", 2)
local serverStatsTab = createTabButton("ServerStatsTab", "📈 Server", 3)

-- Analytics content area
local analyticsContent = Instance.new("ScrollingFrame")
analyticsContent.Name = "AnalyticsContent"
analyticsContent.Size = UDim2.new(1, 0, 1, -68)
analyticsContent.Position = UDim2.new(0, 0, 0, 63)
analyticsContent.BackgroundColor3 = COLORS.background
analyticsContent.BackgroundTransparency = 0.5
analyticsContent.BorderSizePixel = 0
analyticsContent.ScrollBarThickness = 4
analyticsContent.ScrollBarImageColor3 = COLORS.accent
analyticsContent.CanvasSize = UDim2.new(0, 0, 0, 0)
analyticsContent.Parent = rightColumn

local analyticsContentCorner = Instance.new("UICorner")
analyticsContentCorner.CornerRadius = UDim.new(0, 8)
analyticsContentCorner.Parent = analyticsContent

local analyticsContentPadding = Instance.new("UIPadding")
analyticsContentPadding.PaddingTop = UDim.new(0, 6)
analyticsContentPadding.PaddingBottom = UDim.new(0, 6)
analyticsContentPadding.PaddingLeft = UDim.new(0, 6)
analyticsContentPadding.PaddingRight = UDim.new(0, 6)
analyticsContentPadding.Parent = analyticsContent

local analyticsLayout = Instance.new("UIListLayout")
analyticsLayout.Padding = UDim.new(0, 4)
analyticsLayout.Parent = analyticsContent

-- Refresh button
local refreshButton = Instance.new("TextButton")
refreshButton.Name = "RefreshButton"
refreshButton.Size = UDim2.new(0, 24, 0, 24)
refreshButton.Position = UDim2.new(1, -28, 0, 0)
refreshButton.BackgroundColor3 = COLORS.accent
refreshButton.Text = "🔄"
refreshButton.TextColor3 = COLORS.text
refreshButton.TextSize = 12
refreshButton.Font = Enum.Font.Arcade
refreshButton.AutoButtonColor = false
refreshButton.Parent = rightColumn

local refreshCorner = Instance.new("UICorner")
refreshCorner.CornerRadius = UDim.new(0, 6)
refreshCorner.Parent = refreshButton

-- ============================================
-- LEFT COLUMN CONTROLS (Original admin features)
-- ============================================

local content = leftColumn -- Alias for existing code

local function createToggle(name, label, layoutOrder, callback)
	local container = Instance.new("Frame")
	container.Name = name .. "Toggle"
	container.Size = UDim2.new(1, 0, 0, 40)
	container.BackgroundColor3 = COLORS.background
	container.BackgroundTransparency = 0.5
	container.LayoutOrder = layoutOrder
	container.Parent = content
	
	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UDim.new(0, 8)
	containerCorner.Parent = container
	
	local labelText = Instance.new("TextLabel")
	labelText.Name = "Label"
	labelText.Size = UDim2.new(0.6, 0, 1, 0)
	labelText.Position = UDim2.new(0, 10, 0, 0)
	labelText.BackgroundTransparency = 1
	labelText.Text = label
	labelText.TextColor3 = COLORS.text
	labelText.TextSize = 12
	labelText.Font = Enum.Font.Arcade
	labelText.TextXAlignment = Enum.TextXAlignment.Left
	labelText.Parent = container
	
	local toggleBg = Instance.new("Frame")
	toggleBg.Name = "ToggleBg"
	toggleBg.Size = UDim2.new(0, 44, 0, 22)
	toggleBg.Position = UDim2.new(1, -52, 0.5, -11)
	toggleBg.BackgroundColor3 = COLORS.toggleOff
	toggleBg.Parent = container
	
	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(1, 0)
	toggleCorner.Parent = toggleBg
	
	local toggleKnob = Instance.new("Frame")
	toggleKnob.Name = "Knob"
	toggleKnob.Size = UDim2.new(0, 18, 0, 18)
	toggleKnob.Position = UDim2.new(0, 2, 0.5, -9)
	toggleKnob.BackgroundColor3 = COLORS.text
	toggleKnob.Parent = toggleBg
	
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = toggleKnob
	
	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.Size = UDim2.new(1, 0, 1, 0)
	button.BackgroundTransparency = 1
	button.Text = ""
	button.Parent = container
	
	local isOn = false
	
	local function setToggle(on, skipCallback)
		isOn = on
		local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		
		if on then
			TweenService:Create(toggleBg, tweenInfo, {BackgroundColor3 = COLORS.toggleOn}):Play()
			TweenService:Create(toggleKnob, tweenInfo, {Position = UDim2.new(1, -20, 0.5, -9)}):Play()
		else
			TweenService:Create(toggleBg, tweenInfo, {BackgroundColor3 = COLORS.toggleOff}):Play()
			TweenService:Create(toggleKnob, tweenInfo, {Position = UDim2.new(0, 2, 0.5, -9)}):Play()
		end
		
		if not skipCallback and callback then
			callback(on)
		end
	end
	
	button.MouseButton1Click:Connect(function()
		setToggle(not isOn)
	end)
	
	return {
		container = container,
		setToggle = setToggle,
		getState = function() return isOn end,
	}
end

local function createSlider(name, label, min, max, default, layoutOrder, callback)
	local container = Instance.new("Frame")
	container.Name = name .. "Slider"
	container.Size = UDim2.new(1, 0, 0, 55)
	container.BackgroundColor3 = COLORS.background
	container.BackgroundTransparency = 0.5
	container.LayoutOrder = layoutOrder
	container.Parent = content
	
	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UDim.new(0, 8)
	containerCorner.Parent = container
	
	local labelText = Instance.new("TextLabel")
	labelText.Name = "Label"
	labelText.Size = UDim2.new(0.6, 0, 0, 18)
	labelText.Position = UDim2.new(0, 10, 0, 6)
	labelText.BackgroundTransparency = 1
	labelText.Text = label
	labelText.TextColor3 = COLORS.text
	labelText.TextSize = 12
	labelText.Font = Enum.Font.Arcade
	labelText.TextXAlignment = Enum.TextXAlignment.Left
	labelText.Parent = container
	
	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.Size = UDim2.new(0.4, -10, 0, 18)
	valueLabel.Position = UDim2.new(0.6, 0, 0, 6)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Text = tostring(default)
	valueLabel.TextColor3 = COLORS.accent
	valueLabel.TextSize = 12
	valueLabel.Font = Enum.Font.Arcade
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Parent = container
	
	local sliderBg = Instance.new("Frame")
	sliderBg.Name = "SliderBg"
	sliderBg.Size = UDim2.new(1, -20, 0, 8)
	sliderBg.Position = UDim2.new(0, 10, 0, 34)
	sliderBg.BackgroundColor3 = COLORS.toggleOff
	sliderBg.Parent = container
	
	local sliderCorner = Instance.new("UICorner")
	sliderCorner.CornerRadius = UDim.new(1, 0)
	sliderCorner.Parent = sliderBg
	
	local sliderFill = Instance.new("Frame")
	sliderFill.Name = "Fill"
	sliderFill.Size = UDim2.new((default - min) / (max - min), 0, 1, 0)
	sliderFill.BackgroundColor3 = COLORS.accent
	sliderFill.Parent = sliderBg
	
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = sliderFill
	
	local sliderKnob = Instance.new("Frame")
	sliderKnob.Name = "Knob"
	sliderKnob.Size = UDim2.new(0, 14, 0, 14)
	sliderKnob.Position = UDim2.new((default - min) / (max - min), -7, 0.5, -7)
	sliderKnob.BackgroundColor3 = COLORS.text
	sliderKnob.Parent = sliderBg
	
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = sliderKnob
	
	local currentValue = default
	local dragging = false
	
	local function updateSlider(value)
		currentValue = math.clamp(math.floor(value), min, max)
		local ratio = (currentValue - min) / (max - min)
		sliderFill.Size = UDim2.new(ratio, 0, 1, 0)
		sliderKnob.Position = UDim2.new(ratio, -7, 0.5, -7)
		valueLabel.Text = tostring(currentValue)
	end
	
	local function onInput(input)
		if dragging then
			local relativeX = input.Position.X - sliderBg.AbsolutePosition.X
			local ratio = math.clamp(relativeX / sliderBg.AbsoluteSize.X, 0, 1)
			local value = min + ratio * (max - min)
			updateSlider(value)
		end
	end
	
	sliderBg.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			onInput(input)
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			onInput(input)
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				dragging = false
				if callback then
					callback(currentValue)
				end
			end
		end
	end)
	
	return {
		container = container,
		setValue = updateSlider,
		getValue = function() return currentValue end,
	}
end

local function createDropdownButton(name, label, layoutOrder, onRefresh, onSelect)
	local container = Instance.new("Frame")
	container.Name = name .. "Dropdown"
	container.Size = UDim2.new(1, 0, 0, 40)
	container.BackgroundColor3 = COLORS.background
	container.BackgroundTransparency = 0.5
	container.LayoutOrder = layoutOrder
	container.ClipsDescendants = false
	container.Parent = content
	
	local containerCorner = Instance.new("UICorner")
	containerCorner.CornerRadius = UDim.new(0, 8)
	containerCorner.Parent = container
	
	local labelText = Instance.new("TextLabel")
	labelText.Name = "Label"
	labelText.Size = UDim2.new(0.45, 0, 1, 0)
	labelText.Position = UDim2.new(0, 10, 0, 0)
	labelText.BackgroundTransparency = 1
	labelText.Text = label
	labelText.TextColor3 = COLORS.text
	labelText.TextSize = 11
	labelText.Font = Enum.Font.Arcade
	labelText.TextXAlignment = Enum.TextXAlignment.Left
	labelText.Parent = container
	
	local dropButton = Instance.new("TextButton")
	dropButton.Name = "DropButton"
	dropButton.Size = UDim2.new(0.50, -10, 0, 28)
	dropButton.Position = UDim2.new(0.50, 0, 0.5, -14)
	dropButton.BackgroundColor3 = COLORS.accent
	dropButton.Text = "Select ▼"
	dropButton.TextColor3 = COLORS.text
	dropButton.TextSize = 10
	dropButton.Font = Enum.Font.Arcade
	dropButton.AutoButtonColor = false
	dropButton.Parent = container
	
	local dropCorner = Instance.new("UICorner")
	dropCorner.CornerRadius = UDim.new(0, 6)
	dropCorner.Parent = dropButton
	
	local dropdownMenu = Instance.new("Frame")
	dropdownMenu.Name = "Menu"
	dropdownMenu.Size = UDim2.new(1, 0, 0, 0)
	dropdownMenu.Position = UDim2.new(0, 0, 1, 5)
	dropdownMenu.BackgroundColor3 = COLORS.panel
	dropdownMenu.Visible = false
	dropdownMenu.ZIndex = 10
	dropdownMenu.Parent = container
	
	local menuCorner = Instance.new("UICorner")
	menuCorner.CornerRadius = UDim.new(0, 8)
	menuCorner.Parent = dropdownMenu
	
	local menuStroke = Instance.new("UIStroke")
	menuStroke.Color = Color3.fromRGB(60, 60, 70)
	menuStroke.Thickness = 1
	menuStroke.Parent = dropdownMenu
	
	local menuLayout = Instance.new("UIListLayout")
	menuLayout.Padding = UDim.new(0, 2)
	menuLayout.Parent = dropdownMenu
	
	local menuPadding = Instance.new("UIPadding")
	menuPadding.PaddingTop = UDim.new(0, 5)
	menuPadding.PaddingBottom = UDim.new(0, 5)
	menuPadding.PaddingLeft = UDim.new(0, 5)
	menuPadding.PaddingRight = UDim.new(0, 5)
	menuPadding.Parent = dropdownMenu
	
	local isOpen = false
	
	local function closeMenu()
		isOpen = false
		dropdownMenu.Visible = false
		dropButton.Text = "Select ▼"
	end
	
	local function populateMenu(items)
		for _, child in ipairs(dropdownMenu:GetChildren()) do
			if child:IsA("TextButton") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		
		if #items == 0 then
			local noItems = Instance.new("TextLabel")
			noItems.Name = "NoItems"
			noItems.Size = UDim2.new(1, 0, 0, 28)
			noItems.BackgroundTransparency = 1
			noItems.Text = "No players"
			noItems.TextColor3 = COLORS.textDim
			noItems.TextSize = 11
			noItems.Font = Enum.Font.Arcade
			noItems.Parent = dropdownMenu
		else
			for i, item in ipairs(items) do
				local itemButton = Instance.new("TextButton")
				itemButton.Name = "Item" .. i
				itemButton.Size = UDim2.new(1, 0, 0, 28)
				itemButton.BackgroundColor3 = COLORS.background
				itemButton.BackgroundTransparency = 0.5
				itemButton.Text = item.displayName or item.name
				itemButton.TextColor3 = COLORS.text
				itemButton.TextSize = 11
				itemButton.Font = Enum.Font.Arcade
				itemButton.AutoButtonColor = false
				itemButton.ZIndex = 11
				itemButton.Parent = dropdownMenu
				
				local itemCorner = Instance.new("UICorner")
				itemCorner.CornerRadius = UDim.new(0, 4)
				itemCorner.Parent = itemButton
				
				itemButton.MouseEnter:Connect(function()
					itemButton.BackgroundTransparency = 0
				end)
				
				itemButton.MouseLeave:Connect(function()
					itemButton.BackgroundTransparency = 0.5
				end)
				
				itemButton.MouseButton1Click:Connect(function()
					closeMenu()
					if onSelect then
						onSelect(item)
					end
				end)
			end
		end
		
		local itemCount = math.max(#items, 1)
		dropdownMenu.Size = UDim2.new(1, 0, 0, itemCount * 30 + 10)
	end
	
	dropButton.MouseButton1Click:Connect(function()
		if isOpen then
			closeMenu()
		else
			local items = onRefresh and onRefresh() or {}
			populateMenu(items)
			isOpen = true
			dropdownMenu.Visible = true
			dropButton.Text = "Select ▲"
		end
	end)
	
	return {
		container = container,
		close = closeMenu,
		setButtonText = function(text)
			dropButton.Text = text
		end,
	}
end

-- Create toggles
local invisToggle = createToggle("Invisible", "👻 Invisible", 1, function(on)
	states.invisible = on
	ToggleInvisibility:FireServer(on)
	task.delay(0.1, function()
		applyGhostEffect(on)
	end)
end)

local godToggle = createToggle("GodMode", "💪 God Mode", 2, function(on)
	states.godMode = on
	ToggleGodMode:FireServer(on)
end)

local noclipToggle = createToggle("Noclip", "🚶 Noclip + Fly", 3, function(on)
	states.noclip = on
	ToggleNoclip:FireServer(on)
	
	if on then
		enableNoclip()
	else
		disableNoclip()
	end
end)

local speedSlider = createSlider("Speed", "🏃 Walk Speed", 0, 200, 16, 4, function(value)
	states.speed = value
	SetSpeed:FireServer(value)
	
	if not states.noclip then
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = value
			end
		end
	end
end)

-- Section headers and dropdowns
local teleportHeader = Instance.new("TextLabel")
teleportHeader.Name = "TeleportHeader"
teleportHeader.Size = UDim2.new(1, 0, 0, 22)
teleportHeader.BackgroundTransparency = 1
teleportHeader.Text = "TELEPORT"
teleportHeader.TextColor3 = COLORS.textDim
teleportHeader.TextSize = 10
teleportHeader.Font = Enum.Font.Arcade
teleportHeader.TextXAlignment = Enum.TextXAlignment.Left
teleportHeader.LayoutOrder = 5
teleportHeader.Parent = content

local teleportDropdown = createDropdownButton("Teleport", "📍 To Player", 6, 
	function()
		return GetPlayerList:InvokeServer()
	end,
	function(item)
		TeleportToPlayer:FireServer(item.name)
	end
)

local kickHeader = Instance.new("TextLabel")
kickHeader.Name = "KickHeader"
kickHeader.Size = UDim2.new(1, 0, 0, 22)
kickHeader.BackgroundTransparency = 1
kickHeader.Text = "KICK PLAYER"
kickHeader.TextColor3 = COLORS.textDim
kickHeader.TextSize = 10
kickHeader.Font = Enum.Font.Arcade
kickHeader.TextXAlignment = Enum.TextXAlignment.Left
kickHeader.LayoutOrder = 7
kickHeader.Parent = content

local kickDropdown = createDropdownButton("Kick", "🚫 Player", 8,
	function()
		return GetPlayerList:InvokeServer()
	end,
	function(item)
		selectedKickPlayer = item
		kickDropdown.setButtonText(item.displayName)
	end
)

local reasonContainer = Instance.new("Frame")
reasonContainer.Name = "ReasonContainer"
reasonContainer.Size = UDim2.new(1, 0, 0, 60)
reasonContainer.BackgroundColor3 = COLORS.background
reasonContainer.BackgroundTransparency = 0.5
reasonContainer.LayoutOrder = 9
reasonContainer.Parent = content

local reasonContainerCorner = Instance.new("UICorner")
reasonContainerCorner.CornerRadius = UDim.new(0, 8)
reasonContainerCorner.Parent = reasonContainer

local reasonLabel = Instance.new("TextLabel")
reasonLabel.Name = "Label"
reasonLabel.Size = UDim2.new(1, -20, 0, 18)
reasonLabel.Position = UDim2.new(0, 10, 0, 6)
reasonLabel.BackgroundTransparency = 1
reasonLabel.Text = "📝 Reason"
reasonLabel.TextColor3 = COLORS.text
reasonLabel.TextSize = 11
reasonLabel.Font = Enum.Font.Arcade
reasonLabel.TextXAlignment = Enum.TextXAlignment.Left
reasonLabel.Parent = reasonContainer

local reasonInput = Instance.new("TextBox")
reasonInput.Name = "ReasonInput"
reasonInput.Size = UDim2.new(1, -20, 0, 26)
reasonInput.Position = UDim2.new(0, 10, 0, 28)
reasonInput.BackgroundColor3 = COLORS.inputBg
reasonInput.Text = ""
reasonInput.PlaceholderText = "Enter reason..."
reasonInput.PlaceholderColor3 = COLORS.textDim
reasonInput.TextColor3 = COLORS.text
reasonInput.TextSize = 11
reasonInput.Font = Enum.Font.Arcade
reasonInput.ClearTextOnFocus = false
reasonInput.Parent = reasonContainer

local reasonInputCorner = Instance.new("UICorner")
reasonInputCorner.CornerRadius = UDim.new(0, 6)
reasonInputCorner.Parent = reasonInput

local reasonInputPadding = Instance.new("UIPadding")
reasonInputPadding.PaddingLeft = UDim.new(0, 6)
reasonInputPadding.PaddingRight = UDim.new(0, 6)
reasonInputPadding.Parent = reasonInput

local kickButtonContainer = Instance.new("Frame")
kickButtonContainer.Name = "KickButtonContainer"
kickButtonContainer.Size = UDim2.new(1, 0, 0, 38)
kickButtonContainer.BackgroundTransparency = 1
kickButtonContainer.LayoutOrder = 10
kickButtonContainer.Parent = content

local kickButton = Instance.new("TextButton")
kickButton.Name = "KickButton"
kickButton.Size = UDim2.new(1, 0, 0, 34)
kickButton.Position = UDim2.new(0, 0, 0, 0)
kickButton.BackgroundColor3 = COLORS.danger
kickButton.Text = "⛔ Kick Player"
kickButton.TextColor3 = COLORS.text
kickButton.TextSize = 12
kickButton.Font = Enum.Font.Arcade
kickButton.AutoButtonColor = false
kickButton.Parent = kickButtonContainer

local kickButtonCorner = Instance.new("UICorner")
kickButtonCorner.CornerRadius = UDim.new(0, 8)
kickButtonCorner.Parent = kickButton

kickButton.MouseEnter:Connect(function()
	TweenService:Create(kickButton, TweenInfo.new(0.15), {
		BackgroundColor3 = COLORS.dangerHover,
	}):Play()
end)

kickButton.MouseLeave:Connect(function()
	TweenService:Create(kickButton, TweenInfo.new(0.15), {
		BackgroundColor3 = COLORS.danger,
	}):Play()
end)

kickButton.MouseButton1Click:Connect(function()
	if not selectedKickPlayer then
		local dropdown = kickDropdown.container:FindFirstChild("DropButton", true)
		if dropdown then
			TweenService:Create(dropdown, TweenInfo.new(0.1), {BackgroundColor3 = COLORS.danger}):Play()
			task.wait(0.1)
			TweenService:Create(dropdown, TweenInfo.new(0.1), {BackgroundColor3 = COLORS.accent}):Play()
		end
		return
	end
	
	local reason = reasonInput.Text
	KickPlayer:FireServer(selectedKickPlayer.name, reason)
	
	selectedKickPlayer = nil
	kickDropdown.setButtonText("Select ▼")
	reasonInput.Text = ""
	
	kickButton.Text = "✓ Kicked!"
	kickButton.BackgroundColor3 = COLORS.toggleOn
	task.wait(1)
	kickButton.Text = "⛔ Kick Player"
	kickButton.BackgroundColor3 = COLORS.danger
end)

-- ============================================
-- ANALYTICS FUNCTIONS
-- ============================================

local currentAnalyticsTab = "topPlayers"

local function clearAnalyticsContent()
	for _, child in ipairs(analyticsContent:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
end

local function createLeaderboardEntry(rank, name, playtime)
	local entry = Instance.new("Frame")
	entry.Name = "Entry_" .. rank
	entry.Size = UDim2.new(1, 0, 0, 36)
	entry.BackgroundColor3 = COLORS.background
	entry.BackgroundTransparency = 0.3
	entry.LayoutOrder = rank
	entry.Parent = analyticsContent
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = entry
	
	local rankColors = {
		[1] = COLORS.gold,
		[2] = COLORS.silver,
		[3] = COLORS.bronze
	}
	
	local rankLabel = Instance.new("TextLabel")
	rankLabel.Size = UDim2.new(0, 28, 0, 28)
	rankLabel.Position = UDim2.new(0, 4, 0.5, -14)
	rankLabel.BackgroundColor3 = rankColors[rank] or COLORS.toggleOff
	rankLabel.BorderSizePixel = 0
	rankLabel.Font = Enum.Font.Arcade
	rankLabel.Text = "#" .. rank
	rankLabel.TextColor3 = rank <= 3 and Color3.fromRGB(30, 30, 30) or COLORS.text
	rankLabel.TextSize = 11
	rankLabel.Parent = entry
	
	local rankCorner = Instance.new("UICorner")
	rankCorner.CornerRadius = UDim.new(0, 6)
	rankCorner.Parent = rankLabel
	
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(0.5, -40, 1, 0)
	nameLabel.Position = UDim2.new(0, 38, 0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.Arcade
	nameLabel.Text = name
	nameLabel.TextColor3 = COLORS.text
	nameLabel.TextSize = 11
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = entry
	
	local timeLabel = Instance.new("TextLabel")
	timeLabel.Size = UDim2.new(0.4, 0, 1, 0)
	timeLabel.Position = UDim2.new(0.6, 0, 0, 0)
	timeLabel.BackgroundTransparency = 1
	timeLabel.Font = Enum.Font.Arcade
	timeLabel.Text = formatTime(playtime)
	timeLabel.TextColor3 = Color3.fromRGB(150, 220, 150)
	timeLabel.TextSize = 11
	timeLabel.TextXAlignment = Enum.TextXAlignment.Right
	timeLabel.Parent = entry
	
	return entry
end

local function createBlockEntry(rank, blockName, count)
	local entry = Instance.new("Frame")
	entry.Name = "Block_" .. rank
	entry.Size = UDim2.new(1, 0, 0, 32)
	entry.BackgroundColor3 = COLORS.background
	entry.BackgroundTransparency = 0.3
	entry.LayoutOrder = rank
	entry.Parent = analyticsContent
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = entry
	
	local rankLabel = Instance.new("TextLabel")
	rankLabel.Size = UDim2.new(0, 24, 1, 0)
	rankLabel.Position = UDim2.new(0, 6, 0, 0)
	rankLabel.BackgroundTransparency = 1
	rankLabel.Font = Enum.Font.Arcade
	rankLabel.Text = rank .. "."
	rankLabel.TextColor3 = COLORS.textDim
	rankLabel.TextSize = 11
	rankLabel.Parent = entry
	
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(0.5, -30, 1, 0)
	nameLabel.Position = UDim2.new(0, 30, 0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.Arcade
	nameLabel.Text = blockName
	nameLabel.TextColor3 = COLORS.text
	nameLabel.TextSize = 11
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = entry
	
	local countLabel = Instance.new("TextLabel")
	countLabel.Size = UDim2.new(0.4, 0, 1, 0)
	countLabel.Position = UDim2.new(0.6, 0, 0, 0)
	countLabel.BackgroundTransparency = 1
	countLabel.Font = Enum.Font.Arcade
	countLabel.Text = formatNumber(count)
	countLabel.TextColor3 = Color3.fromRGB(150, 180, 220)
	countLabel.TextSize = 11
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.Parent = entry
	
	return entry
end

local function createStatRow(label, value, order)
	local entry = Instance.new("Frame")
	entry.Name = "Stat_" .. order
	entry.Size = UDim2.new(1, 0, 0, 40)
	entry.BackgroundColor3 = COLORS.background
	entry.BackgroundTransparency = 0.3
	entry.LayoutOrder = order
	entry.Parent = analyticsContent
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = entry
	
	local labelText = Instance.new("TextLabel")
	labelText.Size = UDim2.new(1, -12, 0, 16)
	labelText.Position = UDim2.new(0, 6, 0, 4)
	labelText.BackgroundTransparency = 1
	labelText.Font = Enum.Font.Arcade
	labelText.Text = label
	labelText.TextColor3 = COLORS.textDim
	labelText.TextSize = 10
	labelText.TextXAlignment = Enum.TextXAlignment.Left
	labelText.Parent = entry
	
	local valueText = Instance.new("TextLabel")
	valueText.Size = UDim2.new(1, -12, 0, 18)
	valueText.Position = UDim2.new(0, 6, 0, 18)
	valueText.BackgroundTransparency = 1
	valueText.Font = Enum.Font.Arcade
	valueText.Text = value
	valueText.TextColor3 = COLORS.text
	valueText.TextSize = 14
	valueText.TextXAlignment = Enum.TextXAlignment.Left
	valueText.Parent = entry
	
	return entry
end

local function refreshTopPlayers()
	clearAnalyticsContent()
	
	if not GetTopPlayers then
		local noData = Instance.new("TextLabel")
		noData.Size = UDim2.new(1, 0, 0, 40)
		noData.BackgroundTransparency = 1
		noData.Text = "Analytics not available"
		noData.TextColor3 = COLORS.textDim
		noData.TextSize = 12
		noData.Font = Enum.Font.Arcade
		noData.Parent = analyticsContent
		return
	end
	
	local success, topPlayers = pcall(function()
		return GetTopPlayers:InvokeServer(10)
	end)
	
	if not success or not topPlayers or #topPlayers == 0 then
		local noData = Instance.new("TextLabel")
		noData.Size = UDim2.new(1, 0, 0, 40)
		noData.BackgroundTransparency = 1
		noData.Text = "No data yet"
		noData.TextColor3 = COLORS.textDim
		noData.TextSize = 12
		noData.Font = Enum.Font.Arcade
		noData.Parent = analyticsContent
		return
	end
	
	for _, data in ipairs(topPlayers) do
		createLeaderboardEntry(data.rank, data.name, data.playtime)
	end
	
	analyticsContent.CanvasSize = UDim2.new(0, 0, 0, #topPlayers * 40)
end

local function refreshTopBlocks()
	clearAnalyticsContent()
	
	if not GetTopBlocks then
		local noData = Instance.new("TextLabel")
		noData.Size = UDim2.new(1, 0, 0, 40)
		noData.BackgroundTransparency = 1
		noData.Text = "Analytics not available"
		noData.TextColor3 = COLORS.textDim
		noData.TextSize = 12
		noData.Font = Enum.Font.Arcade
		noData.Parent = analyticsContent
		return
	end
	
	local success, topBlocks = pcall(function()
		return GetTopBlocks:InvokeServer(15)
	end)
	
	if not success or not topBlocks or #topBlocks == 0 then
		local noData = Instance.new("TextLabel")
		noData.Size = UDim2.new(1, 0, 0, 40)
		noData.BackgroundTransparency = 1
		noData.Text = "No blocks placed yet"
		noData.TextColor3 = COLORS.textDim
		noData.TextSize = 12
		noData.Font = Enum.Font.Arcade
		noData.Parent = analyticsContent
		return
	end
	
	for i, data in ipairs(topBlocks) do
		createBlockEntry(i, data.name, data.count)
	end
	
	analyticsContent.CanvasSize = UDim2.new(0, 0, 0, #topBlocks * 36)
end

local function refreshServerStats()
	clearAnalyticsContent()
	
	if not GetServerStats then
		local noData = Instance.new("TextLabel")
		noData.Size = UDim2.new(1, 0, 0, 40)
		noData.BackgroundTransparency = 1
		noData.Text = "Analytics not available"
		noData.TextColor3 = COLORS.textDim
		noData.TextSize = 12
		noData.Font = Enum.Font.Arcade
		noData.Parent = analyticsContent
		return
	end
	
	local success, stats = pcall(function()
		return GetServerStats:InvokeServer()
	end)
	
	if not success or not stats then
		local noData = Instance.new("TextLabel")
		noData.Size = UDim2.new(1, 0, 0, 40)
		noData.BackgroundTransparency = 1
		noData.Text = "Failed to load stats"
		noData.TextColor3 = COLORS.textDim
		noData.TextSize = 12
		noData.Font = Enum.Font.Arcade
		noData.Parent = analyticsContent
		return
	end
	
	createStatRow("Current Players", tostring(stats.currentPlayers or 0), 1)
	createStatRow("New Players (Session)", tostring(stats.newPlayers or 0) .. " ✨", 2)
	createStatRow("Returning Players", tostring(stats.returningPlayers or 0) .. " 🔄", 3)
	createStatRow("Avg Session Time", formatTime(stats.averageSessionTime or 0), 4)
	
	analyticsContent.CanvasSize = UDim2.new(0, 0, 0, 180)
end

local function switchAnalyticsTab(tabName)
	currentAnalyticsTab = tabName
	
	local tabs = {
		topPlayers = topPlayersTab,
		topBlocks = topBlocksTab,
		serverStats = serverStatsTab
	}
	
	for name, btn in pairs(tabs) do
		if name == tabName then
			btn.BackgroundColor3 = COLORS.accent
			btn.TextColor3 = COLORS.text
		else
			btn.BackgroundColor3 = COLORS.toggleOff
			btn.TextColor3 = COLORS.textDim
		end
	end
	
	if tabName == "topPlayers" then
		refreshTopPlayers()
	elseif tabName == "topBlocks" then
		refreshTopBlocks()
	elseif tabName == "serverStats" then
		refreshServerStats()
	end
end

-- Connect tab buttons
topPlayersTab.MouseButton1Click:Connect(function()
	switchAnalyticsTab("topPlayers")
end)

topBlocksTab.MouseButton1Click:Connect(function()
	switchAnalyticsTab("topBlocks")
end)

serverStatsTab.MouseButton1Click:Connect(function()
	switchAnalyticsTab("serverStats")
end)

refreshButton.MouseButton1Click:Connect(function()
	-- Spin animation
	local spinTween = TweenService:Create(refreshButton, TweenInfo.new(0.5, Enum.EasingStyle.Linear), {
		Rotation = refreshButton.Rotation + 360
	})
	spinTween:Play()
	
	-- Refresh current tab
	switchAnalyticsTab(currentAnalyticsTab)
end)

-- ============================================
-- PANEL TOGGLE AND CONTROLS
-- ============================================

adminButton.MouseEnter:Connect(function()
	TweenService:Create(adminButton, TweenInfo.new(0.15), {
		BackgroundColor3 = COLORS.accentHover,
		Size = UDim2.new(0, 54, 0, 54),
	}):Play()
end)

adminButton.MouseLeave:Connect(function()
	TweenService:Create(adminButton, TweenInfo.new(0.15), {
		BackgroundColor3 = COLORS.accent,
		Size = UDim2.new(0, 50, 0, 50),
	}):Play()
end)

local function togglePanel()
	panelOpen = not panelOpen
	
	if panelOpen then
		panel.Visible = true
		panel.Position = UDim2.new(0.5, 0, 0.5, -20)
		panel.BackgroundTransparency = 1
		
		TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0.5, 0),
			BackgroundTransparency = 0.05,
		}):Play()
		
		TweenService:Create(adminButton, TweenInfo.new(0.2), {
			Rotation = 90,
		}):Play()
		
		-- Refresh analytics when opening
		switchAnalyticsTab(currentAnalyticsTab)
	else
		TweenService:Create(panel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 0.5, -20),
			BackgroundTransparency = 1,
		}):Play()
		
		TweenService:Create(adminButton, TweenInfo.new(0.2), {
			Rotation = 0,
		}):Play()
		
		task.wait(0.2)
		if not panelOpen then
			panel.Visible = false
		end
	end
end

adminButton.MouseButton1Click:Connect(togglePanel)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	
	if input.KeyCode == Enum.KeyCode.F8 then
		togglePanel()
	end
end)

player.CharacterAdded:Connect(function(character)
	task.wait(0.5)
	
	if states.noclip then
		enableNoclip()
	else
		if states.speed ~= 16 then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = states.speed
			end
		end
	end
	
	if states.invisible then
		task.delay(0.2, function()
			applyGhostEffect(true)
		end)
	end
end)

-- Initialize with top players tab
switchAnalyticsTab("topPlayers")

print("[AdminPanelUI] Initialized with Analytics - Press F8 or click the ⚙ button to toggle")
