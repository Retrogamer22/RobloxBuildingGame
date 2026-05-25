--[[
	VineHandler
	Server-side handler for vine spreading mechanics (Minecraft-style)
	
	Spreading Rules:
	- Vines spread DOWNWARD naturally on the same face
	- Spreading stops when the vine hits any block below it
	- New vines must still have a solid host block behind them on the same face
	- Spread check runs on a tick interval with randomness
	- Vines do NOT spread if the cell below already has any non-decoration block
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local VinePlacement = require(ReplicatedStorage:WaitForChild("VinePlacement", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local BulkOperationFlags = nil
pcall(function()
	BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 5))
end)

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- ============================================
-- CONFIGURATION
-- ============================================

local CONFIG = {
	-- How often to run a spread tick (seconds)
	TICK_INTERVAL = 4.0,
	
	-- Chance for a vine to spread downward per tick (0-1)
	SPREAD_CHANCE = 0.15,
	
	-- Maximum number of vines to spread per tick (performance limit)
	MAX_SPREADS_PER_TICK = 5,
	
	-- Maximum vine chain length (how far down from the topmost vine)
	MAX_VINE_LENGTH = 24,
}

-- Debug flag
local DEBUG_VINES = false

-- Track active plots for vine spreading
local ActivePlots = {}
local IsRunning = false
local LastTickTime = 0

-- Forward declaration for ceiling vine update (defined after createVine)
local updateCeilingVine

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Get the Decorations folder for vine templates
local function getVineTemplate()
	local decorations = ReplicatedStorage:FindFirstChild("Decorations")
	if decorations then
		return decorations:FindFirstChild("Vine")
	end
	return nil
end

-- Count how many vines are in a chain above this position on the same face
local function getVineChainLength(position, face, blocksFolder)
	local count = 0
	local checkPos = position + Vector3.new(0, BLOCK_SIZE, 0)
	
	for _ = 1, CONFIG.MAX_VINE_LENGTH do
		local vineAbove = VinePlacement.GetVineAtPosition(checkPos, blocksFolder)
		if vineAbove and vineAbove.face == face then
			count = count + 1
			checkPos = checkPos + Vector3.new(0, BLOCK_SIZE, 0)
		else
			break
		end
	end
	
	return count
end

-- Check if a vine can spread to a target position on the given face
local function canSpreadToPosition(targetPos, vineFace, blocksFolder)
	-- Check if the target cell already has any block (including other vines)
	if VinePlacement.HasAnyBlockAt(targetPos, blocksFolder) then
		return false
	end
	
	-- Check if there's already a vine at the target position
	if not VinePlacement.CanPlaceAt(targetPos, blocksFolder) then
		return false
	end
	
	-- Check if there's a solid host block behind the target position
	local oppositeFace = VinePlacement.GetOppositeFace(vineFace)
	local hostOffset = VinePlacement.GetFaceOffset(oppositeFace) * BLOCK_SIZE
	local hostPos = targetPos + hostOffset
	
	if not VinePlacement.HasSolidBlockAt(hostPos, blocksFolder) then
		-- No host block behind - vines can hang freely downward,
		-- but upward spread REQUIRES a host block behind it
		return true
	end
	
	return true
end

-- Check if a vine can spread upward (requires a solid host block behind)
local function canSpreadUp(vinePosition, vineFace, blocksFolder)
	local abovePos = vinePosition + Vector3.new(0, BLOCK_SIZE, 0)
	
	-- Check if the target cell is empty
	if VinePlacement.HasAnyBlockAt(abovePos, blocksFolder) then
		return false
	end
	if not VinePlacement.CanPlaceAt(abovePos, blocksFolder) then
		return false
	end
	
	-- Upward spread REQUIRES a solid host block behind (no free-hanging upward)
	local oppositeFace = VinePlacement.GetOppositeFace(vineFace)
	local hostOffset = VinePlacement.GetFaceOffset(oppositeFace) * BLOCK_SIZE
	local hostPos = abovePos + hostOffset
	
	return VinePlacement.HasSolidBlockAt(hostPos, blocksFolder)
end

-- Create a vine block at the given position
local function createVine(position, face, blocksFolder, placedBy)
	local template = getVineTemplate()
	if not template then
		warn("[VineHandler] Vine template not found in Decorations folder!")
		return nil
	end
	
	local vine = template:Clone()
	vine.Name = "Vine"
	
	-- Anchor
	if vine:IsA("BasePart") then
		vine.Anchored = true
		vine.CanCollide = false
	elseif vine:IsA("Model") then
		for _, part in ipairs(vine:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
	end
	
	-- Position flush against the wall
	local vineCFrame = VinePlacement.GetVineCFrame(position, face)
	if vine:IsA("BasePart") then
		vine:PivotTo(vineCFrame)
	elseif vine:IsA("Model") then
		vine:PivotTo(vineCFrame)
	end
	
	-- Set attributes
	vine:SetAttribute("BlockType", "Vine")
	vine:SetAttribute("IsVine", true)
	vine:SetAttribute("VineFace", face)
	vine:SetAttribute("VineRotation", VinePlacement.GetVineRotation(face))
	vine:SetAttribute("BlockPosX", position.X)
	vine:SetAttribute("BlockPosY", position.Y)
	vine:SetAttribute("BlockPosZ", position.Z)
	vine:SetAttribute("IsNaturalVine", true) -- Mark as naturally spread (vs player-placed)
	if placedBy then
		vine:SetAttribute("PlacedBy", placedBy)
	end
	
	-- Add invisible hitbox for raycasting (thin, face-oriented)
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanQuery = true
	hitbox.CanTouch = false
	hitbox.CastShadow = false
	hitbox.Transparency = 1
	local VINE_HITBOX_THICKNESS = 1.0
	if face == "North" or face == "South" then
		hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, VINE_HITBOX_THICKNESS)
	elseif face == "East" or face == "West" then
		hitbox.Size = Vector3.new(VINE_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
	else
		hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
	end
	hitbox.CFrame = CFrame.new(vineCFrame.Position)
	hitbox.Parent = vine
	
	-- Add a climb sensor (slightly thicker than the vine, for touch detection)
	local climbSensor = Instance.new("Part")
	climbSensor.Name = "ClimbSensor"
	climbSensor.Anchored = true
	climbSensor.CanCollide = false
	climbSensor.CanQuery = false
	climbSensor.CanTouch = true
	climbSensor.CastShadow = false
	climbSensor.Transparency = 1
	climbSensor.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, 1.0) -- 1 stud thick for reliable touch
	climbSensor.CFrame = vineCFrame -- Same position as vine
	climbSensor:AddTag("VineClimbSensor")
	climbSensor.Parent = vine
	
	vine.Parent = blocksFolder
	
	-- Add ceiling piece if solid block above
	updateCeilingVine(vine, position, blocksFolder)
	
	if DEBUG_VINES then
		print(string.format("[VineHandler] Created vine at (%.1f, %.1f, %.1f) face=%s",
			position.X, position.Y, position.Z, face))
	end
	
	return vine
end

-- ============================================
-- CEILING VINE (underside of block above)
-- ============================================

-- Add or update the ceiling vine piece on a vine block
-- This creates a visual clone on the underside of the block above when applicable
updateCeilingVine = function(vineBlock, gridPosition, blocksFolder)
	local existingCeiling = vineBlock:FindFirstChild("CeilingVine")
	local shouldHave = VinePlacement.ShouldHaveCeiling and VinePlacement.ShouldHaveCeiling(gridPosition, blocksFolder)
	
	if shouldHave and not existingCeiling then
		local template = getVineTemplate()
		if not template then return end
		
		local ceiling = template:Clone()
		ceiling.Name = "CeilingVine"
		
		local ceilingCFrame = VinePlacement.GetCeilingCFrame(gridPosition)
		
		if ceiling:IsA("BasePart") then
			ceiling.Anchored = true
			ceiling.CanCollide = false
			ceiling.CanQuery = false
			ceiling.CastShadow = false
			ceiling:PivotTo(ceilingCFrame)
		elseif ceiling:IsA("Model") then
			for _, part in ipairs(ceiling:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CastShadow = false
				end
			end
			ceiling:PivotTo(ceilingCFrame)
		end
		
		ceiling.Parent = vineBlock
		
		if DEBUG_VINES then
			print(string.format("[VineHandler] Added ceiling vine at (%.1f, %.1f, %.1f)",
				gridPosition.X, gridPosition.Y, gridPosition.Z))
		end
	elseif not shouldHave and existingCeiling then
		existingCeiling:Destroy()
		if DEBUG_VINES then
			print(string.format("[VineHandler] Removed ceiling vine at (%.1f, %.1f, %.1f)",
				gridPosition.X, gridPosition.Y, gridPosition.Z))
		end
	end
end

-- Update ceiling vines for all vines in a blocks folder
local function updateAllCeilingVines(blocksFolder)
	if not blocksFolder then return end
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsVine") then
			local posX = block:GetAttribute("BlockPosX")
			local posY = block:GetAttribute("BlockPosY")
			local posZ = block:GetAttribute("BlockPosZ")
			if posX and posY and posZ then
				updateCeilingVine(block, Vector3.new(posX, posY, posZ), blocksFolder)
			end
		end
	end
end

-- ============================================
-- SPREAD TICK
-- ============================================

local function processPlotVines(blocksFolder)
	if not blocksFolder then return end
	
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return end
	
	-- Collect all vines
	local vines = {}
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsVine") then
			table.insert(vines, block)
		end
	end
	
	if #vines == 0 then return end
	
	local spreadCount = 0
	
	-- Shuffle for randomness
	for i = #vines, 2, -1 do
		local j = math.random(1, i)
		vines[i], vines[j] = vines[j], vines[i]
	end
	
	for _, vine in ipairs(vines) do
		if spreadCount >= CONFIG.MAX_SPREADS_PER_TICK then break end
		
		-- Trimmed vines (VineTrimmed, VineTrimmedEnd) are growth-stopped via Shears.
		-- They never spread and act as a hard stop for further chain growth.
		if vine:GetAttribute("IsVineTrimmed") then continue end
		
		-- Random chance check
		if math.random() > CONFIG.SPREAD_CHANCE then continue end
		
		local face = vine:GetAttribute("VineFace")
		if not face then continue end
		
		-- Get vine grid position
		local posX = vine:GetAttribute("BlockPosX")
		local posY = vine:GetAttribute("BlockPosY")
		local posZ = vine:GetAttribute("BlockPosZ")
		if not posX or not posY or not posZ then continue end
		
		local vinePos = Vector3.new(posX, posY, posZ)
		
		-- Check chain length (don't spread if too long)
		local chainLength = getVineChainLength(vinePos, face, blocksFolder)
		if chainLength >= CONFIG.MAX_VINE_LENGTH then continue end
		
		local belowPos = vinePos - Vector3.new(0, BLOCK_SIZE, 0)
		local abovePos = vinePos + Vector3.new(0, BLOCK_SIZE, 0)
		local vineBelow = VinePlacement.GetVineAtPosition(belowPos, blocksFolder)
		local vineAbove = VinePlacement.GetVineAtPosition(abovePos, blocksFolder)
		
		local spread = false
		
		-- Try spreading downward (from bottommost vine in chain)
		if not spread and not (vineBelow and vineBelow.face == face) then
			if canSpreadToPosition(belowPos, face, blocksFolder) then
				local newVine = createVine(belowPos, face, blocksFolder, vine:GetAttribute("PlacedBy"))
				if newVine then
					spreadCount = spreadCount + 1
					spread = true
					if DEBUG_VINES then
						print(string.format("[VineHandler] Vine spread DOWN from (%.1f,%.1f,%.1f) to (%.1f,%.1f,%.1f)",
							vinePos.X, vinePos.Y, vinePos.Z, belowPos.X, belowPos.Y, belowPos.Z))
					end
				end
			end
		end
		
		-- Try spreading upward (from topmost vine in chain, requires host block behind)
		if not spread and not (vineAbove and vineAbove.face == face) then
			if canSpreadUp(vinePos, face, blocksFolder) then
				local newVine = createVine(abovePos, face, blocksFolder, vine:GetAttribute("PlacedBy"))
				if newVine then
					spreadCount = spreadCount + 1
					spread = true
					if DEBUG_VINES then
						print(string.format("[VineHandler] Vine spread UP from (%.1f,%.1f,%.1f) to (%.1f,%.1f,%.1f)",
							vinePos.X, vinePos.Y, vinePos.Z, abovePos.X, abovePos.Y, abovePos.Z))
					end
				end
			end
		end
	end
	
	if spreadCount > 0 and DEBUG_VINES then
		print(string.format("[VineHandler] Spread %d vines this tick", spreadCount))
	end
	
	-- Update ceiling vines (handles loaded saves, block changes above vines)
	for _, vine in ipairs(vines) do
		local posX = vine:GetAttribute("BlockPosX")
		local posY = vine:GetAttribute("BlockPosY")
		local posZ = vine:GetAttribute("BlockPosZ")
		if posX and posY and posZ then
			updateCeilingVine(vine, Vector3.new(posX, posY, posZ), blocksFolder)
		end
	end
end

-- ============================================
-- PLOT TRACKING
-- ============================================

function RegisterPlot(blocksFolder)
	if not blocksFolder then return end
	ActivePlots[blocksFolder] = true
	
	if not IsRunning then
		IsRunning = true
		LastTickTime = tick()
	end
end

function UnregisterPlot(blocksFolder)
	ActivePlots[blocksFolder] = nil
	
	-- Stop running if no plots left
	local hasAny = false
	for _ in pairs(ActivePlots) do
		hasAny = true
		break
	end
	if not hasAny then
		IsRunning = false
	end
end

-- ============================================
-- MAIN LOOP
-- ============================================

RunService.Heartbeat:Connect(function()
	if not IsRunning then return end
	
	local now = tick()
	if now - LastTickTime < CONFIG.TICK_INTERVAL then return end
	LastTickTime = now
	
	-- Per-plot bulk check (not global). Previously we used IsAnyBulkOperationActive()
	-- which froze ALL plots' vine growth if any single plot had a stuck/leaked bulk
	-- flag (e.g. from a TerrainGenerator early-return path). Now we skip only the
	-- specific plot that's currently mid-generation/load, so a leaked flag on plot
	-- A can't stop vines from growing on plot B.
	for blocksFolder in pairs(ActivePlots) do
		if blocksFolder and blocksFolder.Parent then
			local buildArea = blocksFolder.Parent
			local busy = BulkOperationFlags and BulkOperationFlags.IsBulkOperation(buildArea)
			if not busy then
				processPlotVines(blocksFolder)
			end
		else
			ActivePlots[blocksFolder] = nil
		end
	end
end)

-- ============================================
-- AUTO-REGISTER EXISTING PLOTS
-- ============================================

task.spawn(function()
	task.wait(5) -- Wait for plots to initialize
	
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				RegisterPlot(blocksFolder)
			end
		end
	end
	
	-- Also check MegaPlot
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			local blocksFolder = megaBuildArea:FindFirstChild("Blocks")
			if blocksFolder then
				RegisterPlot(blocksFolder)
			end
		end
	end
	
	print("[VineHandler] Initialized, tracking " .. tostring(next(ActivePlots) and "active" or "no") .. " plots")
end)

-- Listen for new plots
workspace.ChildAdded:Connect(function(child)
	task.wait(1)
	if child.Name:find(GridConfig.BUILD_AREA_PREFIX) then
		local blocksFolder = child:FindFirstChild("Blocks")
		if blocksFolder then
			RegisterPlot(blocksFolder)
		end
	end
end)

print("[VineHandler] Vine spreading system loaded")
