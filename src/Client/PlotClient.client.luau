--[[
	PlotClient
	Client-side plot tracking
	
	Since baseplates are destroyed after terrain generation,
	we store virtual baseplate info from the stored attributes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlotAssigned = Remotes:WaitForChild("PlotAssigned", 30)
local GetPlotInfo = Remotes:WaitForChild("GetPlotInfo", 30)

local LocalPlayer = Players.LocalPlayer

local MyPlot = {
	PlotNumber = nil,
	BuildArea = nil,
	BasePlate = nil,  -- Virtual baseplate info
}

-- Create a virtual baseplate table from stored attributes
local function createVirtualBasePlate(buildArea)
	if not buildArea then return nil end
	
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posY = buildArea:GetAttribute("BasePlatePositionY")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeY = buildArea:GetAttribute("BasePlateSizeY")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if posX and posY and posZ and sizeX and sizeY and sizeZ then
		return {
			Position = Vector3.new(posX, posY, posZ),
			Size = Vector3.new(sizeX, sizeY, sizeZ),
		}
	end
	
	-- Fallback: try to find actual baseplate (might still exist during early loading)
	local actualBasePlate = buildArea:FindFirstChild("BasePlate")
	if actualBasePlate then
		return {
			Position = actualBasePlate.Position,
			Size = actualBasePlate.Size,
		}
	end
	
	return nil
end

if not PlotAssigned then warn("[PlotClient] PlotAssigned remote not found!") end
if not GetPlotInfo then warn("[PlotClient] GetPlotInfo remote not found!") end

if PlotAssigned then
PlotAssigned.OnClientEvent:Connect(function(plotNumber, buildArea)
	MyPlot.PlotNumber = plotNumber
	MyPlot.BuildArea = buildArea
	MyPlot.BasePlate = createVirtualBasePlate(buildArea)
	print("Assigned to plot " .. plotNumber)
end)
end

task.spawn(function()
	task.wait(1)
	if not MyPlot.PlotNumber and GetPlotInfo then
		local info = GetPlotInfo:InvokeServer()
		if info then
			MyPlot.PlotNumber = info.PlotNumber
			MyPlot.BuildArea = info.BuildArea
			
			-- Use position/size from server response
			if info.BasePlatePosition and info.BasePlateSize then
				MyPlot.BasePlate = {
					Position = info.BasePlatePosition,
					Size = info.BasePlateSize,
				}
			else
				MyPlot.BasePlate = createVirtualBasePlate(info.BuildArea)
			end
		end
	end
end)

-- ============================================
-- MEGAPLOT MODE OVERRIDE
-- ============================================
-- When MegaPlot mode is active, the effective build area and baseplate
-- should come from MegaPlotBuildArea, not the individual BuildArea

local function isMegaPlotMode()
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	return modeValue and modeValue.Value == "MegaPlot"
end

local function getMegaPlotBuildArea()
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		return megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
	end
	return nil
end

-- Build a virtual basePlate specifically for MegaPlotBuildArea
-- Uses BasePlateTop + known attributes (doesn't require Y pos/size attributes)
local function createMegaPlotVirtualBasePlate(megaBuildArea)
	local posX = megaBuildArea:GetAttribute("BasePlatePositionX")
	local posZ = megaBuildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = megaBuildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = megaBuildArea:GetAttribute("BasePlateSizeZ")
	local plateTop = megaBuildArea:GetAttribute("BasePlateTop")
	
	if not (posX and posZ and sizeX and sizeZ and plateTop) then
		return nil
	end
	
	-- Reconstruct Y position and size from plateTop (basePlate is 3 studs thick like regular plots)
	local sizeY = 3
	local posY = plateTop - sizeY / 2
	
	return {
		Position = Vector3.new(posX, posY, posZ),
		Size = Vector3.new(sizeX, sizeY, sizeZ),
	}
end

local megaPlotDebugPrinted = false
local function getEffectivePlot()
	if isMegaPlotMode() then
		local megaBuildArea = getMegaPlotBuildArea()
		if megaBuildArea then
			local basePlate = createMegaPlotVirtualBasePlate(megaBuildArea)
			if basePlate then
				if not megaPlotDebugPrinted then
					megaPlotDebugPrinted = true
					print("[PlotClient] MegaPlot mode active! Using MegaPlotBuildArea")
					print("[PlotClient] BasePlate pos:", basePlate.Position, "size:", basePlate.Size)
				end
				return {
					PlotNumber = MyPlot.PlotNumber,
					BuildArea = megaBuildArea,
					BasePlate = basePlate,
				}
			else
				if not megaPlotDebugPrinted then
					megaPlotDebugPrinted = true
					print("[PlotClient] MegaPlot createVirtualBasePlate nil! posX=", megaBuildArea:GetAttribute("BasePlatePositionX"),
						"posZ=", megaBuildArea:GetAttribute("BasePlatePositionZ"),
						"sizeX=", megaBuildArea:GetAttribute("BasePlateSizeX"),
						"sizeZ=", megaBuildArea:GetAttribute("BasePlateSizeZ"),
						"plateTop=", megaBuildArea:GetAttribute("BasePlateTop"))
				end
			end
		else
			if not megaPlotDebugPrinted then
				megaPlotDebugPrinted = true
				print("[PlotClient] MegaPlot mode BUT MegaPlotBuildArea not found!")
			end
		end
	end
	return MyPlot
end

_G.PlotClient = {
	GetMyPlot = function() return getEffectivePlot() end,
	GetPlotNumber = function() return MyPlot.PlotNumber end,
	GetBuildArea = function()
		if isMegaPlotMode() then
			return getMegaPlotBuildArea() or MyPlot.BuildArea
		end
		return MyPlot.BuildArea
	end,
	GetBasePlate = function()
		return getEffectivePlot().BasePlate
	end,
	IsMegaPlotMode = function() return isMegaPlotMode() end,
}
