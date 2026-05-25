--[[
	SignTextHandler
	Server-side handling for sign text editing
	- Creates SurfaceGui on signs when placed
	- Updates text when players edit signs
	- Filters text through Roblox TextService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Create RemoteEvent
local UpdateSignText = Instance.new("RemoteEvent")
UpdateSignText.Name = "UpdateSignText"
UpdateSignText.Parent = Remotes

local MAX_LINES = 5
local MAX_CHARS_PER_LINE = 20

-- ============================================
-- SURFACEGUI CREATION
-- ============================================

local function createSignSurfaceGui(sign)
	-- Find the sign part (the board, not the post)
	local signPart = nil
	
	if sign:IsA("Model") then
		-- For standing signs, find "Sign" child
		signPart = sign:FindFirstChild("Sign")
		-- Fallback to primary part
		if not signPart then
			signPart = sign.PrimaryPart or sign:FindFirstChildWhichIsA("BasePart")
		end
	elseif sign:IsA("BasePart") then
		signPart = sign
	end
	
	if not signPart then
		warn("[SignText] Could not find sign part for SurfaceGui")
		return nil
	end
	
	-- Remove existing GUI
	local existingGui = signPart:FindFirstChild("SignTextGui")
	if existingGui then
		existingGui:Destroy()
	end
	
	-- Create SurfaceGui on front face
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignTextGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 100  -- Higher = sharper text
	gui.LightInfluence = 0
	gui.MaxDistance = 75  -- Viewable from further away
	gui.ClipsDescendants = true
	gui.Parent = signPart
	
	-- Container frame
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = gui
	
	-- Create text labels for each line
	for i = 1, MAX_LINES do
		local label = Instance.new("TextLabel")
		label.Name = "Line" .. i
		label.Size = UDim2.new(1, -8, 0, 30)
		label.Position = UDim2.new(0, 4, 0, 4 + (i - 1) * 32)
		label.BackgroundTransparency = 1
		label.Text = ""
		label.TextColor3 = Color3.fromRGB(0, 0, 0)
		label.TextSize = 24
		label.Font = Enum.Font.GothamBold  -- Cleaner font
		label.TextScaled = false
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.Parent = container
	end
	
	return gui
end

local function updateSignText(sign, lines)
	if not sign then return end
	
	-- Store text in attributes (for save/load)
	for i = 1, MAX_LINES do
		local text = lines[i] or ""
		sign:SetAttribute("SignLine" .. i, text)
	end
	
	-- Find the sign part
	local signPart = nil
	if sign:IsA("Model") then
		signPart = sign:FindFirstChild("Sign")
		if not signPart then
			signPart = sign.PrimaryPart or sign:FindFirstChildWhichIsA("BasePart")
		end
	elseif sign:IsA("BasePart") then
		signPart = sign
	end
	
	if not signPart then return end
	
	-- Get or create SurfaceGui
	local gui = signPart:FindFirstChild("SignTextGui")
	if not gui then
		gui = createSignSurfaceGui(sign)
	end
	
	if not gui then return end
	
	-- Update labels
	local container = gui:FindFirstChild("Container")
	if container then
		for i = 1, MAX_LINES do
			local label = container:FindFirstChild("Line" .. i)
			if label then
				label.Text = lines[i] or ""
			end
		end
	end
end

-- ============================================
-- HELPERS
-- ============================================

local function getPlayerBuildArea(player)
	-- Check MegaPlot mode first
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if modeValue and modeValue.Value == "MegaPlot" then
		local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then
			local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
			if megaBuildArea then
				return megaBuildArea
			end
		end
	end
	-- Individual plots
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea and buildArea:GetAttribute("OwnerUserId") == player.UserId then
			return buildArea
		end
	end
	return nil
end

-- Filter text through Roblox TextService
local function filterText(text, player)
	if not text or text == "" then
		return ""
	end
	
	local success, result = pcall(function()
		local filteredTextObject = TextService:FilterStringAsync(text, player.UserId)
		-- GetNonChatStringForBroadcastAsync is for text visible to all players (signs)
		return filteredTextObject:GetNonChatStringForBroadcastAsync()
	end)
	
	if success then
		return result
	else
		warn("[SignText] Text filter failed:", result)
		-- Return empty string if filtering fails (safer than showing unfiltered)
		return ""
	end
end

-- ============================================
-- REMOTE HANDLER
-- ============================================

UpdateSignText.OnServerEvent:Connect(function(player, sign, lines)
	-- Validate inputs
	if not sign then return end
	if not lines or type(lines) ~= "table" then return end
	
	-- Check if sign exists and is valid
	if not sign:GetAttribute("IsSignStanding") and not sign:GetAttribute("IsWallSign") then
		return
	end
	
	-- Check if sign is in player's build area
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder or sign.Parent ~= blocksFolder then
		return
	end
	
	-- Sanitize and filter lines
	local sanitizedLines = {}
	for i = 1, MAX_LINES do
		local text = lines[i]
		if type(text) == "string" then
			text = string.sub(text, 1, MAX_CHARS_PER_LINE)
			text = string.gsub(text, "[%c]", "") -- Remove control characters
			-- Filter through Roblox TextService
			if text ~= "" then
				text = filterText(text, player)
			end
		else
			text = ""
		end
		sanitizedLines[i] = text
	end
	
	-- Update the sign
	updateSignText(sign, sanitizedLines)
	
	print(string.format("[SignText] Player %s updated sign text", player.Name))
end)

-- ============================================
-- INITIALIZE SIGNS
-- ============================================

local function initializeSign(sign)
	if sign:GetAttribute("IsSignStanding") or sign:GetAttribute("IsWallSign") then
		-- Create SurfaceGui
		local gui = createSignSurfaceGui(sign)
		
		-- Load existing text from attributes (saved/loaded)
		local lines = {}
		local hasText = false
		for i = 1, MAX_LINES do
			lines[i] = sign:GetAttribute("SignLine" .. i) or ""
			if lines[i] ~= "" then
				hasText = true
			end
		end
		
		-- Apply text to SurfaceGui
		updateSignText(sign, lines)
		
		-- Debug logging
		if hasText then
			print(string.format("[SignText] Initialized sign with text: '%s', '%s', '%s', '%s', '%s'", 
				lines[1], lines[2], lines[3], lines[4], lines[5]))
		end
	end
end

local function watchBlocksFolder(blocksFolder)
	-- Initialize existing signs
	for _, child in ipairs(blocksFolder:GetChildren()) do
		initializeSign(child)
	end
	
	-- Watch for new signs
	blocksFolder.ChildAdded:Connect(function(child)
		task.defer(function()
			initializeSign(child)
		end)
	end)
end

-- Setup for all build areas
for i = 1, GridConfig.TOTAL_PLOTS do
	local buildAreaName = GridConfig.BUILD_AREA_PREFIX .. i
	
	local function setupBuildArea(buildArea)
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if blocksFolder then
			watchBlocksFolder(blocksFolder)
		end
		
		buildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" then
				watchBlocksFolder(child)
			end
		end)
	end
	
	local buildArea = workspace:FindFirstChild(buildAreaName)
	if buildArea then
		setupBuildArea(buildArea)
	end
	
	workspace.ChildAdded:Connect(function(child)
		if child.Name == buildAreaName then
			setupBuildArea(child)
		end
	end)
end

-- Also monitor MegaPlot build area (for private server MegaPlot mode)
local function setupMegaPlotSignMonitoring(megaPlotRoom)
	local function tryMonitorMegaBuildArea(megaBuildArea)
		local blocksFolder = megaBuildArea:FindFirstChild("Blocks")
		if blocksFolder then
			watchBlocksFolder(blocksFolder)
		end
		megaBuildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" then
				watchBlocksFolder(child)
			end
		end)
	end
	
	local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
	if megaBuildArea then
		tryMonitorMegaBuildArea(megaBuildArea)
	end
	megaPlotRoom.ChildAdded:Connect(function(child)
		if child.Name == "MegaPlotBuildArea" then
			task.wait(0.5)
			tryMonitorMegaBuildArea(child)
		end
	end)
end

local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
if megaPlotRoom then
	setupMegaPlotSignMonitoring(megaPlotRoom)
end
workspace.ChildAdded:Connect(function(child)
	if child.Name == "MegaPlotRoom" then
		setupMegaPlotSignMonitoring(child)
	end
end)

-- Safety re-scan: catch any signs that might have been missed during initial setup
-- This runs periodically to ensure all signs have SurfaceGuis
local function safetyScanBuildArea(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if child:GetAttribute("IsSignStanding") or child:GetAttribute("IsWallSign") then
			local signPart = nil
			if child:IsA("Model") then
				signPart = child:FindFirstChild("Sign") or child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
			elseif child:IsA("BasePart") then
				signPart = child
			end
			if signPart and not signPart:FindFirstChild("SignTextGui") then
				print("[SignText] Safety scan: Re-initializing sign missing SurfaceGui")
				initializeSign(child)
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(5) -- Check every 5 seconds
		
		for i = 1, GridConfig.TOTAL_PLOTS do
			local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
			if buildArea then
				safetyScanBuildArea(buildArea)
			end
		end
		
		-- Also scan MegaPlot build area
		local megaRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaRoom then
			local megaBuildArea = megaRoom:FindFirstChild("MegaPlotBuildArea")
			if megaBuildArea then
				safetyScanBuildArea(megaBuildArea)
			end
		end
	end
end)

print("SignTextHandler initialized")
