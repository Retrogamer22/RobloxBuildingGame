--[[
	ToolHandler
	Handles tool actions like the shovel converting grass to path blocks
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local VinePlacement = require(ReplicatedStorage:WaitForChild("VinePlacement", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
local BreakFX = require(ReplicatedStorage:WaitForChild("BreakFX", 10)) -- [BB-BREAK-FX] shear particles

-- Load TerrainGenerator for lazy loading walls when making paths
local TerrainGenerator = nil
pcall(function()
	TerrainGenerator = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("TerrainGenerator"))
end)

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Create or get the UseTool remote event
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local UseTool = Remotes:FindFirstChild("UseTool")
if not UseTool then
	UseTool = Instance.new("RemoteEvent")
	UseTool.Name = "UseTool"
	UseTool.Parent = Remotes
end

-- Helper: Get player's build area
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

-- Helper: Check if position is in player's plot (or MegaPlot bounds)
local function isPositionInPlot(player, position)
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false end
	
	-- In MegaPlot mode, check against MegaPlot bounds
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if modeValue and modeValue.Value == "MegaPlot" then
		return true -- All positions within MegaPlot are valid for all players
	end
	
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posY = buildArea:GetAttribute("BasePlatePositionY")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeY = buildArea:GetAttribute("BasePlateSizeY")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	local platePos, plateSize
	
	if posX and posY and posZ and sizeX and sizeY and sizeZ then
		platePos = Vector3.new(posX, posY, posZ)
		plateSize = Vector3.new(sizeX, sizeY, sizeZ)
	else
		local basePlate = buildArea:FindFirstChild("BasePlate")
		if not basePlate then return false end
		platePos = basePlate.Position
		plateSize = basePlate.Size
	end
	
	local halfX = plateSize.X / 2
	local halfZ = plateSize.Z / 2
	
	if position.X < platePos.X - halfX or position.X > platePos.X + halfX then
		return false
	end
	if position.Z < platePos.Z - halfZ or position.Z > platePos.Z + halfZ then
		return false
	end
	
	return true
end

-- Helper: Find a block at a specific position
local function findBlockAtPosition(blocksFolder, position, tolerance)
	tolerance = tolerance or 1
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockPos
		if block:IsA("BasePart") then
			blockPos = block.Position
		elseif block:IsA("Model") then
			blockPos = block:GetPivot().Position
		end
		
		if blockPos and (blockPos - position).Magnitude < tolerance then
			return block
		end
	end
	
	return nil
end

-- Helper: Clone a block model from the Blocks folder
local function cloneBlockModel(blockName)
	if not BlocksFolder then return nil end
	
	local template = BlocksFolder:FindFirstChild(blockName)
	if not template then
		warn("[ToolHandler] Block model not found: " .. blockName)
		return nil
	end
	
	local block = template:Clone()
	
	if block:IsA("BasePart") then
		block.Anchored = true
	elseif block:IsA("Model") then
		for _, part in ipairs(block:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
	end
	
	return block
end

-- Shovel: Convert grass block to path block
local function useShovel(player, targetBlock, targetPosition)
	if not targetBlock then return false, "No target block" end
	
	local blockType = targetBlock:GetAttribute("BlockType")
	
	-- Only works on grass blocks
	if blockType ~= "GrassBlock" then
		return false, "Shovel only works on grass blocks"
	end
	
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false, "No build area" end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return false, "No blocks folder" end
	
	-- Verify the block is in the player's plot
	if targetBlock.Parent ~= blocksFolder then
		return false, "Block not in your plot"
	end
	
	-- Get the GRID position from attributes (this is the actual block center position)
	-- GrassBlock models have bottom-center pivots, so GetPivot() returns the wrong Y
	local gridPosition
	local blockPosX = targetBlock:GetAttribute("BlockPosX")
	local blockPosY = targetBlock:GetAttribute("BlockPosY")
	local blockPosZ = targetBlock:GetAttribute("BlockPosZ")
	
	if blockPosX and blockPosY and blockPosZ then
		-- Use stored grid position (most accurate)
		gridPosition = Vector3.new(blockPosX, blockPosY, blockPosZ)
	else
		-- Fallback: calculate from pivot (add back the offset for models)
		if targetBlock:IsA("BasePart") then
			gridPosition = targetBlock.Position
		elseif targetBlock:IsA("Model") then
			-- GrassBlock model pivot is at bottom-center, so add half block to get grid center
			gridPosition = targetBlock:GetPivot().Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
	end
	
	local placedBy = targetBlock:GetAttribute("PlacedBy")
	local isTerrainBlock = targetBlock:GetAttribute("IsTerrainBlock")
	
	-- Destroy any decorations sitting on this grass block (grass, flowers, sugar cane, saplings)
	-- They can't exist on a path block, so they get broken when the grass is converted
	local decorationsToDestroy = {}
	for _, item in ipairs(blocksFolder:GetChildren()) do
		if item:GetAttribute("IsDecoration") then
			local parentX = item:GetAttribute("ParentBlockX")
			local parentY = item:GetAttribute("ParentBlockY")
			local parentZ = item:GetAttribute("ParentBlockZ")
			
			if parentX and parentY and parentZ then
				local parentPos = Vector3.new(parentX, parentY, parentZ)
				if (parentPos - gridPosition).Magnitude < 1 then
					table.insert(decorationsToDestroy, item)
				end
			end
		end
	end
	
	for _, decoration in ipairs(decorationsToDestroy) do
		local decoType = decoration:GetAttribute("BlockType") or decoration.Name
		print(string.format("[Shovel] Destroying %s - can't exist on path block", decoType))
		decoration:Destroy()
	end
	
	-- Create the new path block
	local pathBlock = cloneBlockModel("PathBlock")
	if not pathBlock then
		return false, "Failed to create path block"
	end
	
	-- Position the new block at the grid position, raised up slightly
	local PATH_BLOCK_Y_OFFSET = 1.35  -- Raise path blocks up (tuned to close gap)
	local raisedPosition = gridPosition + Vector3.new(0, PATH_BLOCK_Y_OFFSET, 0)
	
	-- Models need the bottom-center offset (same as BlockHandler does)
	if pathBlock:IsA("BasePart") then
		pathBlock.Position = raisedPosition
	elseif pathBlock:IsA("Model") then
		-- Apply bottom-center pivot offset (standard for block models)
		local offsetCFrame = CFrame.new(raisedPosition - Vector3.new(0, BLOCK_SIZE / 2, 0))
		pathBlock:PivotTo(offsetCFrame)
	end
	
	-- Copy attributes with the Y offset (so it saves/loads properly)
	pathBlock:SetAttribute("BlockType", "PathBlock")
	pathBlock:SetAttribute("PlacedBy", placedBy or player.UserId)
	pathBlock:SetAttribute("PathYOffset", PATH_BLOCK_Y_OFFSET)  -- Store offset for save/load
	-- Store the ORIGINAL grid position (before raising) for accurate serialization
	pathBlock:SetAttribute("PathBaseX", gridPosition.X)
	pathBlock:SetAttribute("PathBaseY", gridPosition.Y)  -- Original Y before offset
	pathBlock:SetAttribute("PathBaseZ", gridPosition.Z)
	-- Store the raised position for BlockPosX/Y/Z (used by decoration cleanup and position checks)
	pathBlock:SetAttribute("BlockPosX", raisedPosition.X)
	pathBlock:SetAttribute("BlockPosY", raisedPosition.Y)
	pathBlock:SetAttribute("BlockPosZ", raisedPosition.Z)
	-- ALWAYS mark as LazyLoaded so PathBlocks get SAVED (not skipped as terrain)
	-- This is critical - without this, PathBlocks with IsTerrainBlock=true would be skipped during save!
	pathBlock:SetAttribute("IsLazyLoaded", true)
	if isTerrainBlock then
		pathBlock:SetAttribute("IsTerrainBlock", true)
	end
	
	-- Destroy the old grass block
	targetBlock:Destroy()
	
	-- Parent the new path block
	pathBlock.Parent = blocksFolder
	
	-- Trigger lazy loading to fill in walls around the path
	-- Since path blocks are raised, we need to fill blocks below the adjacent walls
	-- Trigger at a position BELOW the grass level so wall fill logic kicks in
	if TerrainGenerator then
		-- Get plot number from buildArea name
		local plotNumber = tonumber(buildArea.Name:match("%d+"))
		
		-- Mark the ORIGINAL grass position as "dug" so lazy loading doesn't spawn dirt there
		-- (The path block is raised, so without this mark, it would think the grass position is empty)
		TerrainGenerator.MarkPositionAsDug(gridPosition, plotNumber)
		
		-- Trigger lazy loading at a position BELOW the original grass
		-- This makes the wall fill code detect that adjacent surfaces are higher
		-- Pass true for skipMarkingAsDug so we don't mark the below-path position as dug
		-- (a real dirt block should exist there, we just want to trigger wall filling)
		local belowGrassPosition = gridPosition - Vector3.new(0, BLOCK_SIZE, 0)
		local blocksSpawned = TerrainGenerator.OnTerrainBlockBroken(belowGrassPosition, buildArea, plotNumber, true)
		if blocksSpawned > 0 then
			print(string.format("[Shovel] Lazy loaded %d wall blocks around path", blocksSpawned))
		end
	end
	
	print(string.format("[Shovel] Converted GrassBlock to PathBlock at (%.1f, %.1f, %.1f) - raised by %.1f", 
		raisedPosition.X, raisedPosition.Y, raisedPosition.Z, PATH_BLOCK_Y_OFFSET))
	
	return true, "Converted to path"
end

-- ============================================
-- SHEARS: Trim vines to stop their growth.
-- ============================================
-- Right-clicking a vine with Shears converts it:
--   - If the vine has NO neighboring vines on the same face above OR below => "VineTrimmed" (solo)
--   - Otherwise (a chain end or middle) => "VineTrimmedEnd"
-- Trimmed vines stop the spread system from growing further on that chain.
-- Trimming is a no-op if the vine is already trimmed.

local Decorations = ReplicatedStorage:FindFirstChild("Decorations")

-- Clone a vine template (Vine / VineTrimmed / VineTrimmedEnd) from Decorations
local function cloneVineTemplate(name)
	if not Decorations then return nil end
	local template = Decorations:FindFirstChild(name)
	if not template then
		warn("[Shears] Decoration template missing: " .. name)
		return nil
	end
	local clone = template:Clone()
	clone.Name = name
	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
	elseif clone:IsA("Model") then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
			end
		end
	end
	return clone
end

-- Destroy every vine directly below `startPos` on the same face, walking downward
-- one block at a time and stopping at the first cell that has no same-face vine.
-- Unlike BlockHandler's cascade-break-on-destroy (which only severs free-hanging
-- chains), this destroys walled vines too — it's how Shears severs a chain in the
-- middle. Returns the number of vines destroyed.
local function cascadeDestroyVinesBelow(startPos, face, blocksFolder)
	local count = 0
	local currentPos = startPos - Vector3.new(0, BLOCK_SIZE, 0)
	for _ = 1, 100 do -- safety cap matches MAX_VINE_LENGTH * 4 ish
		local vineInfo = VinePlacement.GetVineAtPosition(currentPos, blocksFolder)
		if not vineInfo then break end
		if vineInfo.face ~= face then break end
		BreakFX.Fire(vineInfo.instance)
		vineInfo.instance:Destroy()
		count = count + 1
		currentPos = currentPos - Vector3.new(0, BLOCK_SIZE, 0)
	end
	return count
end

-- Convert a sugar cane into SugarCaneTrimmed (Shears). The trimmed cane keeps its
-- exact position + parent cell so it saves/loads in place, and the SugarCaneHandler
-- growth system skips it (caps the column at that height). Works at any height.
local function trimSugarCane(player, targetBlock)
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false, "No build area" end
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return false, "No blocks folder" end
	if targetBlock.Parent ~= blocksFolder then
		return false, "Sugar cane not in your plot"
	end

	-- Preserve the cane's exact transform.
	local cframe
	if targetBlock:IsA("Model") then
		cframe = targetBlock:GetPivot()
	elseif targetBlock:IsA("BasePart") then
		cframe = targetBlock.CFrame
	else
		return false, "Unsupported sugar cane instance"
	end

	local newCane = cloneVineTemplate("SugarCaneTrimmed") -- generic clone+anchor helper
	if not newCane then return false, "Template not found: SugarCaneTrimmed" end
	-- The SugarCaneTrimmed model renders half a block high relative to its pivot
	-- (its geometry sits BLOCK_SIZE/2 above the pivot), so lower it to line up with
	-- the regular sugar cane. The load path applies the same correction.
	newCane:PivotTo(cframe * CFrame.new(0, -BLOCK_SIZE / 2, 0))

	newCane:SetAttribute("BlockType", "SugarCaneTrimmed")
	newCane:SetAttribute("IsDecoration", true)
	newCane:SetAttribute("IsSugarCaneTrimmed", true)
	-- Copy the parent-block cell (decorations save relative to it). Derive if missing.
	local px = targetBlock:GetAttribute("ParentBlockX")
	local py = targetBlock:GetAttribute("ParentBlockY")
	local pz = targetBlock:GetAttribute("ParentBlockZ")
	if not (px and py and pz) then
		local base = cframe.Position - Vector3.new(0, BLOCK_SIZE / 2, 0)
		px, py, pz = base.X, base.Y, base.Z
	end
	newCane:SetAttribute("ParentBlockX", px)
	newCane:SetAttribute("ParentBlockY", py)
	newCane:SetAttribute("ParentBlockZ", pz)
	-- PlacedBy must be set or PlotSerializer treats this as terrain and skips saving.
	newCane:SetAttribute("PlacedBy", targetBlock:GetAttribute("PlacedBy") or 0)

	-- Collect any sugar cane stacked ABOVE this one BEFORE destroying anything, so a
	-- mid-column trim drops everything above it (trimming caps the column here).
	-- The cane occupies the cell at parent + BLOCK_SIZE; walk up from there.
	local caneCell = Vector3.new(px, py, pz) + Vector3.new(0, BLOCK_SIZE, 0)
	local sugarCaneAbove = {}
	local idx = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if idx then
		local p = caneCell + Vector3.new(0, BLOCK_SIZE, 0)
		for _ = 1, 12 do
			local d = idx:GetDecorationAt(p)
			local dt = d and d:GetAttribute("BlockType")
			if d and (dt == "SugarCane" or dt == "SugarCaneTrimmed") then
				table.insert(sugarCaneAbove, d)
				p = p + Vector3.new(0, BLOCK_SIZE, 0)
			else
				break
			end
		end
	end

	BreakFX.Fire(targetBlock)
	targetBlock:Destroy()
	newCane.Parent = blocksFolder

	-- Break everything that was above the trimmed cane (each pops particles).
	for _, d in ipairs(sugarCaneAbove) do
		if d and d.Parent then BreakFX.Fire(d); d:Destroy() end
	end

	print(string.format("[Shears] Trimmed sugar cane at parent (%.1f, %.1f, %.1f)%s", px, py, pz,
		#sugarCaneAbove > 0 and string.format(" (broke %d above)", #sugarCaneAbove) or ""))
	return true, "Trimmed"
end

-- ============================================
-- SHEARS: Strip leaves into a Branch Block.
-- ============================================
-- Right-clicking a leaf block (OakLeaves / BirchLeaves / SpruceLeaves, or the
-- legacy "Leaves") with Shears converts it in place into a BranchBlock and pops
-- the same break-particle burst vines produce when sheared. The branch is a
-- normal placed block (BlockPresets auto-generates its preset from the Blocks
-- folder), so it saves/loads through the generic block path.
local BRANCH_BLOCK_NAME = "BranchBlock"

local function shearLeaves(player, targetBlock)
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false, "No build area" end
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return false, "No blocks folder" end
	if targetBlock.Parent ~= blocksFolder then
		return false, "Leaves not in your plot"
	end

	-- Resolve the cell centre. Leaf blocks are single Parts placed at the centre;
	-- prefer the stored grid attributes, fall back to the instance transform.
	local gridPosition
	local bx = targetBlock:GetAttribute("BlockPosX")
	local by = targetBlock:GetAttribute("BlockPosY")
	local bz = targetBlock:GetAttribute("BlockPosZ")
	if bx and by and bz then
		gridPosition = Vector3.new(bx, by, bz)
	elseif targetBlock:IsA("BasePart") then
		gridPosition = targetBlock.Position
	elseif targetBlock:IsA("Model") then
		gridPosition = targetBlock:GetPivot().Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
	else
		return false, "Unsupported leaf instance"
	end

	local placedBy = targetBlock:GetAttribute("PlacedBy")
	local isTerrainBlock = targetBlock:GetAttribute("IsTerrainBlock")

	-- Build the replacement branch block.
	local branch = cloneBlockModel(BRANCH_BLOCK_NAME)
	if not branch then
		return false, "Failed to create branch block"
	end

	-- Position at the same cell centre. Parts sit at the centre; models use the
	-- standard bottom-centre pivot offset (same convention as other block models).
	if branch:IsA("BasePart") then
		branch.Position = gridPosition
	elseif branch:IsA("Model") then
		branch:PivotTo(CFrame.new(gridPosition - Vector3.new(0, BLOCK_SIZE / 2, 0)))
	end

	branch:SetAttribute("BlockType", BRANCH_BLOCK_NAME)
	branch:SetAttribute("PlacedBy", placedBy or player.UserId)
	branch:SetAttribute("BlockPosX", gridPosition.X)
	branch:SetAttribute("BlockPosY", gridPosition.Y)
	branch:SetAttribute("BlockPosZ", gridPosition.Z)
	-- Mark LazyLoaded so a sheared TERRAIN leaf (tree foliage) persists through
	-- save/load -- mirrors how the shovel marks converted path blocks.
	branch:SetAttribute("IsLazyLoaded", true)
	if isTerrainBlock then
		branch:SetAttribute("IsTerrainBlock", true)
	end

	-- Pop the break particles at the leaf (same burst vines use), then swap it out.
	BreakFX.Fire(targetBlock)
	targetBlock:Destroy()
	branch.Parent = blocksFolder

	print(string.format("[Shears] Sheared leaves into BranchBlock at (%.1f, %.1f, %.1f)",
		gridPosition.X, gridPosition.Y, gridPosition.Z))
	return true, "Sheared into branch"
end

local function useShears(player, targetBlock, _targetPosition)
	-- Leaves: Shears strip a leaf block into a BranchBlock (+particle burst).
	-- Matches any per-type leaf (OakLeaves/BirchLeaves/SpruceLeaves) plus the
	-- legacy "Leaves" name, via substring -- same test LeafDecayManager uses.
	do
		local bt = targetBlock and targetBlock:GetAttribute("BlockType")
		if bt and string.find(bt, "Leaves") then
			return shearLeaves(player, targetBlock)
		end
	end

	-- Sugar cane: Shears convert the targeted cane into SugarCaneTrimmed, stopping
	-- its growth at the current height. Handled before the vine path.
	if targetBlock and targetBlock:GetAttribute("BlockType") == "SugarCane" then
		return trimSugarCane(player, targetBlock)
	end

	if not targetBlock or not targetBlock:GetAttribute("IsVine") then
		return false, "Shears only work on vines or sugar cane"
	end
	
	-- Already trimmed? Nothing to do.
	if targetBlock:GetAttribute("IsVineTrimmed") then
		return false, "Vine already trimmed"
	end
	
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false, "No build area" end
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return false, "No blocks folder" end
	if targetBlock.Parent ~= blocksFolder then
		return false, "Vine not in your plot"
	end
	
	local face = targetBlock:GetAttribute("VineFace")
	if not face then return false, "Vine missing face data" end
	
	-- Resolve grid position from stored attributes. SaveManager mirrors
	-- VineHandler.createVine on load, so any vine on the server has these set.
	-- Fallback to pivot+face computation is kept as defense in depth in case
	-- a vine slips through (e.g. from a future code path that forgets to set them).
	local vinePos
	local px = targetBlock:GetAttribute("BlockPosX")
	local py = targetBlock:GetAttribute("BlockPosY")
	local pz = targetBlock:GetAttribute("BlockPosZ")
	if px and py and pz then
		vinePos = Vector3.new(px, py, pz)
	else
		local pivot
		if targetBlock:IsA("BasePart") then
			pivot = targetBlock.Position
		elseif targetBlock:IsA("Model") then
			pivot = targetBlock:GetPivot().Position
		end
		if not pivot then return false, "Vine pivot unavailable" end
		local faceOffset = VinePlacement.GetFaceOffset(face)
		vinePos = pivot + faceOffset * (BLOCK_SIZE / 2)
		vinePos = Vector3.new(
			math.round(vinePos.X / BLOCK_SIZE) * BLOCK_SIZE,
			math.round(vinePos.Y / BLOCK_SIZE) * BLOCK_SIZE,
			math.round(vinePos.Z / BLOCK_SIZE) * BLOCK_SIZE
		)
		warn(string.format("[Shears] Vine had no BlockPosX/Y/Z attributes; reconstructed (%.1f, %.1f, %.1f) from pivot. This shouldn't happen post-SaveManager fix.",
			vinePos.X, vinePos.Y, vinePos.Z))
	end
	
	-- Check for same-face vine neighbors above & below.
	local abovePos = vinePos + Vector3.new(0, BLOCK_SIZE, 0)
	local belowPos = vinePos - Vector3.new(0, BLOCK_SIZE, 0)
	local vineAbove = VinePlacement.GetVineAtPosition(abovePos, blocksFolder)
	local vineBelow = VinePlacement.GetVineAtPosition(belowPos, blocksFolder)
	local hasAbove = vineAbove and vineAbove.face == face
	local hasBelow = vineBelow and vineBelow.face == face
	
	-- Pick replacement type and orientation:
	--   Solo (no neighbors)            → VineTrimmed
	--   Top of chain (below, no above) → VineTrimmedEnd FLIPPED (ragged end points up)
	--   Bottom of chain (above, none below) → VineTrimmedEnd (default orientation)
	--   Middle (above AND below)       → VineTrimmedEnd + sever the chain by destroying
	--                                    every vine below on the same face. The sheared
	--                                    piece becomes the new bottom of the chain.
	local newType
	local flipped = false
	local shearAwayBelow = false
	if not hasAbove and not hasBelow then
		newType = "VineTrimmed"
	elseif hasBelow and not hasAbove then
		newType = "VineTrimmedEnd"
		flipped = true
	elseif hasAbove and not hasBelow then
		newType = "VineTrimmedEnd"
	else
		-- Middle: sever the chain.
		newType = "VineTrimmedEnd"
		shearAwayBelow = true
	end
	
	-- Build replacement vine
	local newVine = cloneVineTemplate(newType)
	if not newVine then return false, "Template not found: " .. newType end
	
	-- Position flush against the wall (same orientation as the original, optionally flipped).
	local cframe = VinePlacement.GetVineCFrame(vinePos, face, flipped)
	newVine:PivotTo(cframe)
	
	-- Copy/set attributes (mirror VineHandler.createVine, plus trim markers)
	newVine:SetAttribute("BlockType", newType)
	newVine:SetAttribute("IsVine", true)
	newVine:SetAttribute("IsVineTrimmed", true)
	newVine:SetAttribute("VineFace", face)
	newVine:SetAttribute("VineRotation", VinePlacement.GetVineRotation(face))
	if flipped then
		newVine:SetAttribute("VineTrimmedFlipped", true)
	end
	newVine:SetAttribute("BlockPosX", vinePos.X)
	newVine:SetAttribute("BlockPosY", vinePos.Y)
	newVine:SetAttribute("BlockPosZ", vinePos.Z)
	local placedBy = targetBlock:GetAttribute("PlacedBy")
	if placedBy then newVine:SetAttribute("PlacedBy", placedBy) end
	
	-- Add invisible raycast hitbox (matches VineHandler.createVine sizing)
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanQuery = true
	hitbox.CanTouch = false
	hitbox.CastShadow = false
	hitbox.Transparency = 1
	local HITBOX_THICKNESS = 1.0
	if face == "North" or face == "South" then
		hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, HITBOX_THICKNESS)
	elseif face == "East" or face == "West" then
		hitbox.Size = Vector3.new(HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
	else
		hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
	end
	hitbox.CFrame = CFrame.new(cframe.Position)
	hitbox.Parent = newVine
	
	-- Add a climb sensor so trimmed vines still climb/slow-down like normal ones
	local climbSensor = Instance.new("Part")
	climbSensor.Name = "ClimbSensor"
	climbSensor.Anchored = true
	climbSensor.CanCollide = false
	climbSensor.CanQuery = false
	climbSensor.CanTouch = true
	climbSensor.CastShadow = false
	climbSensor.Transparency = 1
	climbSensor.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, 1.0)
	climbSensor.CFrame = cframe
	climbSensor:AddTag("VineClimbSensor")
	climbSensor.Parent = newVine
	
	-- Destroy the old vine and parent the new one (pops particles at the cut).
	BreakFX.Fire(targetBlock)
	targetBlock:Destroy()
	newVine.Parent = blocksFolder
	
	-- If we sheared a middle piece, sever the chain by destroying every vine below.
	local cascadeCount = 0
	if shearAwayBelow then
		cascadeCount = cascadeDestroyVinesBelow(vinePos, face, blocksFolder)
	end
	
	print(string.format("[Shears] Trimmed vine at (%.1f, %.1f, %.1f) face=%s -> %s%s%s",
		vinePos.X, vinePos.Y, vinePos.Z, face, newType,
		flipped and " (flipped)" or "",
		cascadeCount > 0 and string.format(" (severed %d below)", cascadeCount) or ""))
	
	return true, "Trimmed"
end

-- Main tool use handler
UseTool.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then return end
	
	local toolName = data.ToolName
	local targetBlock = data.TargetBlock
	local targetPosition = data.TargetPosition
	
	if not toolName then return end
	
	-- Validate position is in player's plot
	if targetPosition and not isPositionInPlot(player, targetPosition) then
		return
	end
	
	-- Handle different tools
	if toolName == "Shovel" then
		local success, message = useShovel(player, targetBlock, targetPosition)
		if not success then
			print(string.format("[ToolHandler] Shovel failed: %s", message))
		end
	elseif toolName == "Shears" then
		local success, message = useShears(player, targetBlock, targetPosition)
		if not success then
			print(string.format("[ToolHandler] Shears failed: %s", message))
		end
	else
		print(string.format("[ToolHandler] Unknown tool: %s", toolName))
	end
end)

print("[ToolHandler] Initialized - Shovel converts grass to path blocks, Shears trim vines")
