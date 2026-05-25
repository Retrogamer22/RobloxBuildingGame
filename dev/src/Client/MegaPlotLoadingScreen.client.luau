--[[
	MegaPlotLoadingScreen (Client)
	Shows a loading screen while MegaPlot terrain is being generated
	
	Handles BOTH:
	- Initial join when already in MegaPlot mode
	- Mid-session mode switch from Individual → MegaPlot
	
	Fires MegaPlotPlayerReady when loading is complete to release player protection
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Check immediately for private server status
local isPrivateServerValue = ReplicatedStorage:FindFirstChild("IsPrivateServer")
if not isPrivateServerValue then
	isPrivateServerValue = ReplicatedStorage:WaitForChild("IsPrivateServer", 5)
end

-- Exit if not a private server
if not isPrivateServerValue or not isPrivateServerValue.Value then
	return
end

local modeValue = ReplicatedStorage:WaitForChild("PrivateServerMode", 5)
if not modeValue then return end

-- Get remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local PlayerReadyRemote = nil
local ShowLoadingScreenRemote = nil
if Remotes then
	PlayerReadyRemote = Remotes:WaitForChild("MegaPlotPlayerReady", 10)
	ShowLoadingScreenRemote = Remotes:FindFirstChild("ShowMegaPlotLoadingScreen")
	if not ShowLoadingScreenRemote then
		ShowLoadingScreenRemote = Remotes:WaitForChild("ShowMegaPlotLoadingScreen", 10)
	end
end

-- ============================================
-- BEVEL HELPER (matches InventoryController style)
-- ============================================
local BEVEL_SIZE = 3

local function addInsetBevel(frame, shadowColor, highlightColor)
	local sh = shadowColor or Color3.fromRGB(10, 10, 10)
	local hl = highlightColor or Color3.fromRGB(70, 70, 70)
	
	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = sh
	top.BackgroundTransparency = 0
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame
	
	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = sh
	left.BackgroundTransparency = 0
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame
	
	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL_SIZE)
	bottom.BackgroundColor3 = hl
	bottom.BackgroundTransparency = 0
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame
	
	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	right.Position = UDim2.new(1, -BEVEL_SIZE, 0, 0)
	right.BackgroundColor3 = hl
	right.BackgroundTransparency = 0
	right.BorderSizePixel = 0
	right.ZIndex = 5
	right.Parent = frame
end

-- ============================================
-- STATE
-- ============================================

local isShowingLoadingScreen = false
local currentScreenGui = nil

-- ============================================
-- CREATE & SHOW LOADING SCREEN
-- ============================================

local function showLoadingScreen()
	if isShowingLoadingScreen then return end
	isShowingLoadingScreen = true
	
	print("[MegaPlotLoadingScreen] Showing loading screen...")
	
	-- Remove any leftover loading screen
	local existing = playerGui:FindFirstChild("MegaPlotLoadingScreen")
	if existing then existing:Destroy() end
	
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MegaPlotLoadingScreen"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 999
	screenGui.Parent = playerGui
	currentScreenGui = screenGui
	
	-- Dark background
	local background = Instance.new("Frame")
	background.Name = "Background"
	background.Size = UDim2.new(1, 0, 1, 0)
	background.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
	background.BorderSizePixel = 0
	background.Parent = screenGui
	
	-- Logo
	local logo = Instance.new("ImageLabel")
	logo.Name = "Logo"
	logo.Size = UDim2.new(0, 400, 0, 120)
	logo.Position = UDim2.new(0.5, -200, 0.4, -60)
	logo.BackgroundTransparency = 1
	logo.Image = "rbxassetid://138853494655194"
	logo.ScaleType = Enum.ScaleType.Fit
	logo.Parent = background
	
	-- Loading bar background
	local loadingBarBg = Instance.new("Frame")
	loadingBarBg.Name = "LoadingBarBg"
	loadingBarBg.Size = UDim2.new(0.3, 0, 0, 20)
	loadingBarBg.Position = UDim2.new(0.35, 0, 0.55, 0)
	loadingBarBg.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
	loadingBarBg.BorderSizePixel = 0
	loadingBarBg.Parent = background
	
	-- Add inset bevel to loading bar (matches inventory slot style)
	addInsetBevel(loadingBarBg)
	
	-- Loading bar fill
	local loadingBarFill = Instance.new("Frame")
	loadingBarFill.Name = "Fill"
	loadingBarFill.Size = UDim2.new(0, 0, 1, 0)
	loadingBarFill.BackgroundColor3 = Color3.fromRGB(100, 200, 100)
	loadingBarFill.BorderSizePixel = 0
	loadingBarFill.Parent = loadingBarBg
	
	-- Loading text
	local loadingText = Instance.new("TextLabel")
	loadingText.Name = "LoadingText"
	loadingText.Size = UDim2.new(0.3, 0, 0.05, 0)
	loadingText.Position = UDim2.new(0.35, 0, 0.58, 0)
	loadingText.BackgroundTransparency = 1
	loadingText.Text = "Generating terrain..."
	loadingText.TextColor3 = Color3.fromRGB(180, 180, 180)
	loadingText.TextSize = 16
	loadingText.Font = Enum.Font.Arcade
	loadingText.Parent = background
	
	return screenGui, loadingBarFill, loadingText, background, logo, loadingBarBg
end

-- ============================================
-- HIDE LOADING SCREEN & SIGNAL READY
-- ============================================

local function hideLoadingScreen()
	if not isShowingLoadingScreen then return end
	isShowingLoadingScreen = false
	
	print("[MegaPlotLoadingScreen] Terrain ready! Hiding loading screen...")
	
	local gui = currentScreenGui
	if gui and gui.Parent then
		local bg = gui:FindFirstChild("Background")
		if bg then
			local fill = bg:FindFirstChild("LoadingBarBg") and bg.LoadingBarBg:FindFirstChild("Fill")
			local text = bg:FindFirstChild("LoadingText")
			local logo = bg:FindFirstChild("Logo")
			local barBg = bg:FindFirstChild("LoadingBarBg")
			
			-- Complete the bar
			if fill then
				TweenService:Create(fill, TweenInfo.new(0.3), {
					Size = UDim2.new(1, 0, 1, 0)
				}):Play()
			end
			
			if text then text.Text = "Ready!" end
			
			task.wait(0.4)
			
			-- Fade out all elements
			local fadeTime = 0.5
			TweenService:Create(bg, TweenInfo.new(fadeTime), {BackgroundTransparency = 1}):Play()
			if logo then TweenService:Create(logo, TweenInfo.new(fadeTime), {ImageTransparency = 1}):Play() end
			if barBg then
				TweenService:Create(barBg, TweenInfo.new(fadeTime), {BackgroundTransparency = 1}):Play()
				-- Fade bevel frames inside the bar
				for _, child in ipairs(barBg:GetChildren()) do
					if child:IsA("Frame") and child.Name:find("Bevel") then
						TweenService:Create(child, TweenInfo.new(fadeTime), {BackgroundTransparency = 1}):Play()
					end
				end
			end
			if fill then TweenService:Create(fill, TweenInfo.new(fadeTime), {BackgroundTransparency = 1}):Play() end
			if text then TweenService:Create(text, TweenInfo.new(fadeTime), {TextTransparency = 1}):Play() end
			
			task.wait(fadeTime + 0.1)
		end
		
		gui:Destroy()
	end
	
	currentScreenGui = nil
	
	-- CRITICAL: Signal server that we're ready so it releases player protection
	if PlayerReadyRemote then
		print("[MegaPlotLoadingScreen] Firing MegaPlotPlayerReady to release protection")
		PlayerReadyRemote:FireServer()
	else
		warn("[MegaPlotLoadingScreen] MegaPlotPlayerReady remote not found!")
	end
end

-- ============================================
-- WAIT FOR TERRAIN READY THEN HIDE
-- ============================================

local function waitForTerrainAndHide()
	-- Get or wait for the terrain ready value
	local terrainReadyValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
	if not terrainReadyValue then
		terrainReadyValue = ReplicatedStorage:WaitForChild("MegaPlotTerrainReady", 30)
	end
	
	-- Already ready?
	if terrainReadyValue and terrainReadyValue.Value then
		-- Small delay to ensure terrain is replicated to client
		task.wait(0.5)
		hideLoadingScreen()
		return
	end
	
	-- Track real progress from server instead of fake animation
	local animating = true
	local progressValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
	
	task.spawn(function()
		local hasSeenReset = false -- Wait for progress to reset before trusting it
		
		while animating and isShowingLoadingScreen do
			-- Get actual progress from server (0-1)
			local actualProgress = 0
			if progressValue then
				local rawValue = progressValue.Value
				-- Ignore stale high values until we see the server reset progress
				if rawValue < 0.1 then
					hasSeenReset = true
				end
				if hasSeenReset then
					actualProgress = rawValue
				end
			end
			
			if currentScreenGui and currentScreenGui.Parent then
				local bg = currentScreenGui:FindFirstChild("Background")
				if bg then
					local barBg = bg:FindFirstChild("LoadingBarBg")
					if barBg then
						local fill = barBg:FindFirstChild("Fill")
						if fill then
							-- Smooth transition to actual progress (never go backwards)
							local currentSize = fill.Size.X.Scale
							local targetProgress = math.max(currentSize, actualProgress)
							fill.Size = UDim2.new(targetProgress, 0, 1, 0)
						end
					end
					
					-- Update text with percentage
					local text = bg:FindFirstChild("LoadingText")
					if text and actualProgress > 0 then
						local baseText = text.Text:match("^(.-)%.%.%.") or "Loading world"
						text.Text = string.format("%s... %d%%", baseText, math.floor(actualProgress * 100))
					end
				end
			end
			task.wait(0.1)  -- Check every 100ms
		end
	end)
	
	-- Wait via Changed event + polling fallback
	local done = false
	local changedConnection = nil
	
	if terrainReadyValue then
		changedConnection = terrainReadyValue.Changed:Connect(function(ready)
			if ready and not done then
				done = true
				animating = false
				if changedConnection then changedConnection:Disconnect() end
				-- Small delay for client replication
				task.wait(0.5)
				hideLoadingScreen()
			end
		end)
	end
	
	-- Polling fallback with timeout
	local maxWait = 300 -- 5 minutes for large mega plots
	local waited = 0
	while not done and waited < maxWait do
		task.wait(0.5)
		waited = waited + 0.5
		
		if terrainReadyValue and terrainReadyValue.Value and not done then
			done = true
			animating = false
			if changedConnection then changedConnection:Disconnect() end
			task.wait(0.5)
			hideLoadingScreen()
			return
		end
	end
	
	-- Timeout - hide anyway
	if not done then
		done = true
		animating = false
		if changedConnection then changedConnection:Disconnect() end
		warn("[MegaPlotLoadingScreen] Timeout after", maxWait, "seconds - hiding anyway")
		hideLoadingScreen()
	end
end

-- ============================================
-- TRIGGER: Show loading screen when entering MegaPlot mode
-- ============================================

local function onModeChanged(newMode)
	if newMode == "MegaPlot" then
		-- Check if terrain is already ready (e.g. quick re-join)
		local terrainReadyValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
		if terrainReadyValue and terrainReadyValue.Value then
			-- Terrain is already loaded — just briefly show then dismiss
			showLoadingScreen()
			task.wait(0.3)
			hideLoadingScreen()
			return
		end
		
		-- Show loading screen and wait for terrain
		showLoadingScreen()
		task.spawn(waitForTerrainAndHide)
	else
		-- Switching away from MegaPlot — DON'T dismiss loading screen!
		-- The terrain regen for individual plots uses the same loading screen.
		-- It will be dismissed when MegaPlotTerrainReady becomes true.
		if isShowingLoadingScreen then
			print("[MegaPlotLoadingScreen] Mode changed to", newMode, "- keeping loading screen up for terrain regen")
			-- Update loading text
			if currentScreenGui and currentScreenGui.Parent then
				local bg = currentScreenGui:FindFirstChild("Background")
				if bg then
					local text = bg:FindFirstChild("LoadingText")
					if text then
						text.Text = "Switching to Individual Plots..."
					end
				end
			end
			-- Continue waiting for terrain ready
			task.spawn(waitForTerrainAndHide)
		end
	end
end

-- ============================================
-- INITIALIZATION
-- ============================================

-- Listen for mode changes (mid-session switches)
modeValue.Changed:Connect(function(newMode)
	print("[MegaPlotLoadingScreen] Mode changed to:", newMode)
	onModeChanged(newMode)
end)

-- Check current mode on startup
if modeValue.Value == "MegaPlot" then
	-- Delay slightly so the GUI is ready
	task.spawn(function()
		task.wait(0.1)
		onModeChanged("MegaPlot")
	end)
end

-- ============================================
-- TRIGGER: Show loading screen when server requests it (e.g., during reset)
-- ============================================

if ShowLoadingScreenRemote then
	ShowLoadingScreenRemote.OnClientEvent:Connect(function(reason)
		print("[MegaPlotLoadingScreen] Server requested loading screen:", reason or "terrain reset")
		
		-- Show loading screen and wait for terrain (works for any mode switch)
		showLoadingScreen()
		
		-- Update loading text if a reason was provided
		if reason and currentScreenGui and currentScreenGui.Parent then
			local bg = currentScreenGui:FindFirstChild("Background")
			if bg then
				local text = bg:FindFirstChild("LoadingText")
				if text then
					text.Text = reason
				end
			end
		end
		
		task.spawn(waitForTerrainAndHide)
	end)
	print("[MegaPlotLoadingScreen] Listening for ShowMegaPlotLoadingScreen remote")
end

-- ============================================
-- EXPOSE VIA _G (for other scripts to trigger immediately)
-- ============================================
_G.MegaPlotLoadingScreen = {
	Show = function(reason, waitForReset)
		showLoadingScreen()
		if reason and currentScreenGui and currentScreenGui.Parent then
			local bg = currentScreenGui:FindFirstChild("Background")
			if bg then
				local text = bg:FindFirstChild("LoadingText")
				if text then text.Text = reason end
			end
		end
		task.spawn(function()
			if waitForReset then
				-- Wait for TerrainReady to go false first (server sets it)
				local trv = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
				if trv and trv.Value then
					local maxWait = 15
					local waited = 0
					while trv.Value and waited < maxWait do
						task.wait(0.1)
						waited = waited + 0.1
					end
				end
			end
			waitForTerrainAndHide()
		end)
	end,
	IsShowing = function() return isShowingLoadingScreen end,
}

print("[MegaPlotLoadingScreen] Initialized - listening for mode changes")
