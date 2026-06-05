--[[
	WorldLoadingScreen.client.luau
	Shows a Minecraft-style loading screen while plots generate on first server boot.
	Only appears for players who join before all plots are ready.
	Hides automatically once terrain generation completes.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- SECOND-PLACE ONLY: the chunk place has no "9 plots generating" phase, so this
-- whole loading screen is meaningless there -- ChunkLoadingScreen handles it
-- instead. Bail out before creating anything so the two screens never stack.
local CHUNK_PLACE_IDS = {
	[117001994964531] = true, -- BuildBlox Free Build (public universe)
}
if CHUNK_PLACE_IDS[game.PlaceId] then
	return
end

-- Wait for remote
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then return end

local PlotsReady = Remotes:WaitForChild("PlotsReady", 10)
if not PlotsReady then return end

-- ============================================
-- CONFIG
-- ============================================

local COLORS = {
	bg = Color3.fromRGB(20, 18, 18),
	barBg = Color3.fromRGB(50, 50, 50),
	barFill = Color3.fromRGB(76, 175, 80),
	barBorder = Color3.fromRGB(30, 30, 30),
	text = Color3.fromRGB(255, 255, 255),
	textShadow = Color3.fromRGB(60, 60, 60),
	subtitle = Color3.fromRGB(170, 170, 170),
}

-- Tips removed

-- ============================================
-- STATE
-- ============================================

local showLoadingScreen = false
local totalPlots = 9
local screenGui = nil

-- ============================================
-- UI CREATION
-- ============================================

local function createLoadingScreen()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "WorldLoadingScreen"
	screenGui.DisplayOrder = 99  -- Behind title screen (100) but above game UI
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	-- Full screen background
	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = COLORS.bg
	bg.BorderSizePixel = 0
	bg.Parent = screenGui

	-- Center container
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, 400, 0, 160)
	container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.BackgroundTransparency = 1
	container.Parent = bg

	-- Title with shadow
	local titleShadow = Instance.new("TextLabel")
	titleShadow.Name = "TitleShadow"
	titleShadow.Size = UDim2.new(1, 0, 0, 40)
	titleShadow.Position = UDim2.new(0, 2, 0, 2)
	titleShadow.BackgroundTransparency = 1
	titleShadow.Font = Enum.Font.Arcade
	titleShadow.Text = "Building World..."
	titleShadow.TextSize = 32
	titleShadow.TextColor3 = COLORS.textShadow
	titleShadow.Parent = container

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 40)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Arcade
	title.Text = "Building World..."
	title.TextSize = 32
	title.TextColor3 = COLORS.text
	title.Parent = container

	-- Progress bar background (with border)
	local barBorder = Instance.new("Frame")
	barBorder.Name = "BarBorder"
	barBorder.Size = UDim2.new(1, 0, 0, 28)
	barBorder.Position = UDim2.new(0, 0, 0, 55)
	barBorder.BackgroundColor3 = COLORS.barBorder
	barBorder.BorderSizePixel = 0
	barBorder.Parent = container

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.new(1, -6, 1, -6)
	barBg.Position = UDim2.new(0, 3, 0, 3)
	barBg.BackgroundColor3 = COLORS.barBg
	barBg.BorderSizePixel = 0
	barBg.Parent = barBorder

	-- Progress bar fill
	local barFill = Instance.new("Frame")
	barFill.Name = "BarFill"
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = COLORS.barFill
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg

	-- Progress text
	local progressText = Instance.new("TextLabel")
	progressText.Name = "ProgressText"
	progressText.Size = UDim2.new(1, 0, 0, 24)
	progressText.Position = UDim2.new(0, 0, 0, 90)
	progressText.BackgroundTransparency = 1
	progressText.Font = Enum.Font.Arcade
	progressText.Text = "Generating plots... 0/" .. totalPlots
	progressText.TextSize = 18
	progressText.TextColor3 = COLORS.subtitle
	progressText.Parent = container

	return screenGui
end

local function updateProgress(readyCount, total)
	if not screenGui then return end
	local container = screenGui:FindFirstChild("Background")
	if not container then return end
	container = container:FindFirstChild("Container")
	if not container then return end

	local barBorder = container:FindFirstChild("BarBorder")
	if barBorder then
		local barBg = barBorder:FindFirstChild("BarBg")
		if barBg then
			local barFill = barBg:FindFirstChild("BarFill")
			if barFill then
				local fraction = math.clamp(readyCount / total, 0, 1)
				TweenService:Create(barFill, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = UDim2.new(fraction, 0, 1, 0)
				}):Play()
			end
		end
	end

	local progressText = container:FindFirstChild("ProgressText")
	if progressText then
		progressText.Text = "Generating plots... " .. readyCount .. "/" .. total
	end
end

local function hideLoadingScreen()
	if not screenGui then return end
	showLoadingScreen = false

	-- Disconnect title screen watcher
	if _G._WorldLoadingTitleWatch then
		_G._WorldLoadingTitleWatch:Disconnect()
		_G._WorldLoadingTitleWatch = nil
	end

	-- Update text to done
	local container = screenGui:FindFirstChild("Background")
	if container then
		container = container:FindFirstChild("Container")
		if container then
			local progressText = container:FindFirstChild("ProgressText")
			if progressText then
				progressText.Text = "All plots ready!"
			end
		end
	end

	-- Small delay so player sees "All plots ready!"
	task.wait(0.5)

	-- Fade out
	local bg = screenGui:FindFirstChild("Background")
	if bg then
		TweenService:Create(bg, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play()
		-- Fade all children
		for _, desc in bg:GetDescendants() do
			if desc:IsA("TextLabel") then
				TweenService:Create(desc, TweenInfo.new(0.5), {TextTransparency = 1}):Play()
			elseif desc:IsA("Frame") then
				TweenService:Create(desc, TweenInfo.new(0.5), {BackgroundTransparency = 1}):Play()
			end
		end
	end

	task.wait(0.6)
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	
	-- Re-show the title screen now that loading is done
	local titleScreen = playerGui:FindFirstChild("TitleScreen")
	if titleScreen then
		titleScreen.Enabled = true
	end
end

-- ============================================
-- STARTUP CHECK + LISTEN FOR SERVER SIGNALS
-- ============================================

-- Check if plots are already ready (joining an established server)
local allPlotsReadyValue = ReplicatedStorage:FindFirstChild("AllPlotsReady")
if allPlotsReadyValue and allPlotsReadyValue.Value == true then
	-- All plots already generated — no loading screen needed
	print("[WorldLoadingScreen] All plots already ready, no loading screen needed")
else
	-- Plots not ready yet — show loading screen and hide title screen until done
	showLoadingScreen = true
	createLoadingScreen()
	updateProgress(1, totalPlots)  -- Player's own plot is generating
	
	-- Hide the title screen while loading (it will be re-shown when loading completes)
	local titleScreen = playerGui:FindFirstChild("TitleScreen")
	if titleScreen then
		titleScreen.Enabled = false
	end
	-- Also watch for late-created title screen
	local titleWatchConn
	titleWatchConn = playerGui.ChildAdded:Connect(function(child)
		if child.Name == "TitleScreen" and showLoadingScreen then
			child.Enabled = false
		end
	end)
	-- Store connection so we can disconnect later
	_G._WorldLoadingTitleWatch = titleWatchConn
	
	print("[WorldLoadingScreen] Showing loading screen while plots generate")
end

PlotsReady.OnClientEvent:Connect(function(status, arg1, arg2)
	if status == "progress" then
		if showLoadingScreen and screenGui then
			local readyCount = arg1 or 0
			local total = arg2 or totalPlots
			updateProgress(readyCount, total)
		end

	elseif status == "ready" then
		-- All plots ready — hide loading screen
		if showLoadingScreen and screenGui then
			updateProgress(totalPlots, totalPlots)
			task.wait(0.3)
			hideLoadingScreen()
		end
	end
end)

print("[WorldLoadingScreen] Initialized")
