--[[
	LampHandler
	Server-side lamp/light state management
	- Listens for IsPowered attribute changes (from wiring signals)
	- Updates light enabled state and material
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function isLampBlock(block)
	if not block then return false end
	
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return false end
	
	-- Exclude Glowstones - they're always on and not controllable
	-- ("Light" matches "LightBlueGlowstone" and "LightGreenGlowstone" otherwise)
	if string.find(blockType, "Glowstone") then
		return false
	end
	
	return string.find(blockType, "Lamp") ~= nil or string.find(blockType, "Light") ~= nil
end

-- ============================================
-- LAMP POWER STATE
-- ============================================

local function SetLampPowered(lamp: Instance, powered: boolean)
	-- Update all light instances
	for _, descendant in ipairs(lamp:GetDescendants()) do
		if descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
			descendant.Enabled = powered
		end
	end
	
	-- Also check direct children
	local light = lamp:FindFirstChildWhichIsA("PointLight") or lamp:FindFirstChildWhichIsA("SpotLight")
	if light then
		light.Enabled = powered
	end
	
	-- Update material for visual feedback
	local targetPart = lamp
	if lamp:IsA("Model") then
		targetPart = lamp.PrimaryPart or lamp:FindFirstChildWhichIsA("BasePart")
	end
	
	if targetPart and targetPart:IsA("BasePart") then
		if powered then
			targetPart.Material = Enum.Material.Neon
		else
			targetPart.Material = Enum.Material.SmoothPlastic
		end
	end
	
	print(string.format("[Lamp] %s is now %s", lamp.Name, powered and "ON" or "OFF"))
end

-- Listen for IsPowered attribute changes on a lamp
local function SetupLampPowerListener(lamp: Instance)
	lamp:GetAttributeChangedSignal("IsPowered"):Connect(function()
		local isPowered = lamp:GetAttribute("IsPowered") or false
		SetLampPowered(lamp, isPowered)
	end)
	
	-- Initialize lamp to off state
	lamp:SetAttribute("IsPowered", false)
	SetLampPowered(lamp, false)
end

-- ============================================
-- MONITOR BUILD AREAS FOR LAMPS
-- ============================================

local function MonitorBuildArea(buildArea: Instance)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		buildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" and child:IsA("Folder") then
				MonitorBuildArea(buildArea)
			end
		end)
		return
	end
	
	-- Set up existing lamps
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if isLampBlock(block) then
			SetupLampPowerListener(block)
		end
	end
	
	-- Monitor for new lamps
	blocksFolder.ChildAdded:Connect(function(block)
		task.wait()
		if isLampBlock(block) then
			SetupLampPowerListener(block)
		end
	end)
end

-- ============================================
-- INITIALIZE
-- ============================================

local function Initialize()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			MonitorBuildArea(buildArea)
		end
	end
	
	workspace.ChildAdded:Connect(function(child)
		if string.find(child.Name, GridConfig.BUILD_AREA_PREFIX) then
			MonitorBuildArea(child)
		end
	end)
	
	-- Also monitor MegaPlot build area (for private server MegaPlot mode)
	local function setupMegaPlotMonitoring(megaPlotRoom)
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			MonitorBuildArea(megaBuildArea)
		end
		megaPlotRoom.ChildAdded:Connect(function(child)
			if child.Name == "MegaPlotBuildArea" then
				task.wait(0.5)
				MonitorBuildArea(child)
			end
		end)
	end
	
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		setupMegaPlotMonitoring(megaPlotRoom)
	end
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "MegaPlotRoom" then
			setupMegaPlotMonitoring(child)
		end
	end)
end

-- DISABLED: Lamp system temporarily disabled
-- The isLampBlock check matches "Light" which incorrectly catches
-- LightBlue/LightGreen wool, glass, etc. and overwrites their material.
-- TODO: Re-enable with proper block detection (use IsPowered/IsControllable attributes instead of name matching)
-- Initialize()

print("LampHandler DISABLED")
