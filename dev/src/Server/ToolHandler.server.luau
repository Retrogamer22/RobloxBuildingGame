--[[
	ToolHandler
	Handles tool actions like the shovel converting grass to path blocks
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local NetherConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("NetherConfig", 10))
local VinePlacement = require(ReplicatedStorage:WaitForChild("VinePlacement", 10))
local BreakFX = require(ReplicatedStorage:WaitForChild("BreakFX", 10))
local FencePlacement = require(ReplicatedStorage:WaitForChild("FencePlacement", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
local BlockTemplates = ReplicatedStorage:WaitForChild("BlockTemplates", 10)

-- Portal lighting (Flint & Steel). Loaded defensively so a missing/unsynced
-- module never takes down the rest of the tool handler.
local PortalHandler = nil
pcall(function()
	PortalHandler = require(ServerScriptService:WaitForChild("Modules", 10):WaitForChild("PortalHandler", 10))
end)

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
		vineInfo.instance:Destroy()
		count = count + 1
		currentPos = currentPos - Vector3.new(0, BLOCK_SIZE, 0)
	end
	return count
end

-- Fire a leaf-coloured break-particle burst for a leaf block / leaf-filled frame about
-- to be sheared. Samples a "Leaves" texture tint first (the leaf colour lives on the
-- texture, not the part) so the puff reads green, then fires the shared BreakFX burst.
local function fireLeafShearFX(targetBlock)
	local fxColor
	for _, d in ipairs(targetBlock:GetDescendants()) do
		if (d:IsA("Texture") or d:IsA("Decal")) and d.Name == "Leaves" then
			fxColor = d.Color3
			break
		end
	end
	if not fxColor and targetBlock:IsA("BasePart") then
		fxColor = targetBlock.Color
	end
	if fxColor then targetBlock:SetAttribute("BreakFXColor", fxColor) end
	BreakFX.Fire(targetBlock)
	targetBlock:SetAttribute("BreakFXColor", nil)
end

-- ============================================
-- SHEARS: Strip the leaves off a leaf-FILLED frame block, revealing its branches.
-- ============================================
-- A frame filled with leaves is a solid block carrying the leaf fill id on its
-- FrameFillBlockId attribute (its BlockType stays the frame's, e.g. "FrameBlock").
-- The fill copied BOTH the leaf model's "Branches" and "Leaves" face textures onto
-- it (BlockHandler fill path), with the branches keeping their own bark tint.
-- Shearing removes only the "Leaves" texture in place, leaving the "Branches"
-- texture, and re-tags the fill as the "<Wood>Branches" variant so save/load
-- (SaveManager / MegaPlotSaveManager) reproduce the sheared look.
local function shearFilledFrameLeaves(player, targetBlock)
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false, "No build area" end
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return false, "No blocks folder" end
	if targetBlock.Parent ~= blocksFolder then
		return false, "Block not in your plot"
	end

	local fillId = targetBlock:GetAttribute("FrameFillBlockId")
	if not fillId or not string.find(fillId, "Leaves") then
		return false, "Not a leaf-filled frame"
	end

	-- Pop a leaf-coloured particle burst (sample the tint before the leaves are stripped).
	fireLeafShearFX(targetBlock)

	-- Strip the leaf texture(s); the "Branches" texture stays put.
	local removed = BlockPresets.StripLeaves(targetBlock)
	if removed == 0 then
		return false, "Nothing to shear (no leaves)"
	end

	-- Re-tag the fill as the branches variant so it persists/reloads sheared.
	local branchFillId = (fillId:gsub("Leaves", "Branches"))
	targetBlock:SetAttribute("FrameFillBlockId", branchFillId)

	print(string.format("[Shears] Sheared leaf-filled frame -> %s (removed %d leaf texture%s)",
		branchFillId, removed, removed == 1 and "" or "s"))
	return true, "Sheared into branches"
end

-- ============================================
-- SHEARS: Strip the leaves off a standalone leaf block, revealing its branches.
-- ============================================
-- Per-type leaf blocks (OakLeaves/BirchLeaves/SpruceLeaves) carry stacked "Branches"
-- and "Leaves" face textures; the branches keep their own bark tint (BiomeConfig.
-- TintLeaves skips "Branches"). Shearing removes only the "Leaves" texture in place,
-- relabels the block "<Wood>Branches", and stops it from decaying / makes it persist.
-- On load the hidden "<Wood>Branches" preset (BranchesOnly) strips the leaves again.
-- (dev still ships the legacy generic "Leaves" model with no per-type leaf/branch
-- textures, so this is inert here until per-type leaf models are ported.)
local function shearLeaves(player, targetBlock)
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false, "No build area" end
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return false, "No blocks folder" end
	if targetBlock.Parent ~= blocksFolder then
		return false, "Leaves not in your plot"
	end

	local leafType = targetBlock:GetAttribute("BlockType")
	if not leafType or not string.find(leafType, "Leaves") then
		return false, "Not a leaf block"
	end

	-- Pop a leaf-coloured particle burst (sample the tint before the leaves are stripped).
	fireLeafShearFX(targetBlock)

	-- Strip the leaf texture(s); the "Branches" texture (its own bark tint) stays.
	local removed = BlockPresets.StripLeaves(targetBlock)
	if removed == 0 then
		return false, "Nothing to shear (no leaves)"
	end

	-- Relabel as the branches variant (OakLeaves -> OakBranches, etc.).
	local branchType = (leafType:gsub("Leaves", "Branches"))
	targetBlock:SetAttribute("BlockType", branchType)
	targetBlock.Name = branchType

	-- No longer a leaf: stop decay, and make sure it persists (terrain leaves have no
	-- PlacedBy and would otherwise be skipped on save).
	targetBlock:SetAttribute("CanDecay", nil)
	if targetBlock:GetAttribute("PlacedBy") == nil then
		targetBlock:SetAttribute("PlacedBy", player.UserId)
	end
	targetBlock:SetAttribute("IsLazyLoaded", true)

	print(string.format("[Shears] Sheared %s -> %s (removed %d leaf texture%s)",
		leafType, branchType, removed, removed == 1 and "" or "s"))
	return true, "Sheared into branches"
end

local function useShears(player, targetBlock, _targetPosition)
	-- Filled frame leaves: a frame filled with a leaf block carries the leaf id on
	-- FrameFillBlockId (its BlockType stays the frame's). Shearing strips the leaf
	-- texture in place, leaving the branches, and re-tags the fill for save/load.
	do
		local fillId = targetBlock and targetBlock:GetAttribute("FrameFillBlockId")
		if fillId and string.find(fillId, "Leaves") then
			return shearFilledFrameLeaves(player, targetBlock)
		end
	end

	-- Leaf blocks: Shears strip a standalone leaf block into its "<Wood>Branches"
	-- variant (matches any per-type leaf via the "Leaves" substring in BlockType).
	do
		local bt = targetBlock and targetBlock:GetAttribute("BlockType")
		if bt and string.find(bt, "Leaves") then
			return shearLeaves(player, targetBlock)
		end
	end

	if not targetBlock or not targetBlock:GetAttribute("IsVine") then
		return false, "Shears only work on vines"
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
	
	-- Destroy the old vine and parent the new one.
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

-- ============================================
-- FLINT & STEEL: Light an obsidian portal frame.
-- ============================================
-- Right-clicking an obsidian block with Flint & Steel looks for a valid 2x3
-- portal frame (obsidian border, corners optional) that the clicked block
-- belongs to, then fills the interior with walk-through NetherPortal blocks.
-- The client's generic tool handler already fires UseTool with
-- ToolName = "FlintAndSteel" on right-click (and continuously on hold), so no
-- client changes are needed -- this just answers that request.
--
-- The portal-building recipe (clone/orient/tag/parent) lives in
-- PortalHandler.BuildPortalBlock so it's shared with the save managers'
-- relight-on-load path; this handler just resolves the frame and lights it.

-- Verbose per-block placement logging for portal lighting. Off in production;
-- flip true alongside PortalHandler's DEBUG_PORTAL when debugging frame offsets.
local DEBUG_PORTAL_PLACEMENT = false

-- ============================================
-- FIRE: place a Fire block on top of the clicked block.
-- ============================================
-- When Flint & Steel is used on a block that is NOT part of an obsidian portal
-- frame, we instead drop a Fire block onto the block's top face.
--
-- buildFireBlock is the canonical recipe; the save managers + FireHandler keep an
-- identical copy (Three-File Rule + FireHandler). A fire sits on a FACE of its
-- host block, in the empty cell touching that face:
--   "Top"    -> 3x3x3 cube in the cell ABOVE (model pivot rests on top face)
--   "Bottom" -> FireBottom hung under the block (pivot on the bottom face)
--   side     -> FireSide mounted flat on a wall (pivot on that side face)

-- Face geometry (mirrors FireHandler).
local FIRE_FACE_NORMAL = {
	Top    = Vector3.new(0, 1, 0),
	Bottom = Vector3.new(0, -1, 0),
	PosX   = Vector3.new(1, 0, 0),
	NegX   = Vector3.new(-1, 0, 0),
	PosZ   = Vector3.new(0, 0, 1),
	NegZ   = Vector3.new(0, 0, -1),
}
local FIRE_SIDE_DEFAULT_FACING = "PosZ" -- keep in sync with FireHandler CONFIG
-- FireBottom fine-tuning (keep in sync with FireHandler CONFIG). The FireBottom
-- model is authored with a built-in orientation so its flame planes lie flat;
-- we PRESERVE that rotation and only reposition it. LIFT pushes it up toward
-- the block (its pivot is near the model centre, so it starts ~half-height too
-- low). EXTRA_ROT_* add rotation on top of the authored orientation if needed.
local FIRE_BOTTOM_NORMAL_NUDGE = 0
local FIRE_BOTTOM_LIFT = 1.5
local FIRE_BOTTOM_EXTRA_ROT_X = 180 -- flip upside-down to its correct resting look
local FIRE_BOTTOM_EXTRA_ROT_Y = 0
local FIRE_BOTTOM_EXTRA_ROT_Z = 0
local function fireSideYawFor(face)
	local function yawOf(f)
		local n = FIRE_FACE_NORMAL[f]
		return math.atan2(n.X, n.Z)
	end
	return yawOf(face) - yawOf(FIRE_SIDE_DEFAULT_FACING)
end

local function buildFireBlock(blocksFolder, hostCenter, placedByUserId, face)
	face = face or "Top"

	local templateName
	if face == "Top" then
		templateName = "Fire"
	elseif face == "Bottom" then
		templateName = "FireBottom"
	else
		templateName = "FireSide"
	end

	local template = BlockTemplates:FindFirstChild(templateName)
	if not template then
		if templateName ~= "Fire" then
			warn(string.format("[BB-FIRE] BlockTemplates.%s missing; falling back to Fire cube", templateName))
			template = BlockTemplates:FindFirstChild("Fire")
			face = "Top"
		end
		if not template then
			warn("[BB-FIRE] BlockTemplates.Fire template not found")
			return nil
		end
	end

	local fire = template:Clone()
	fire.Name = template.Name
	if fire:IsA("BasePart") then
		fire.Anchored = true
		fire.CanCollide = false
		fire.CanQuery = true
	elseif fire:IsA("Model") then
		for _, d in ipairs(fire:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = true
			end
		end
	end

	local normal = FIRE_FACE_NORMAL[face] or FIRE_FACE_NORMAL.Top
	local gridPos

	if face == "Top" then
		local visualPos = hostCenter + Vector3.new(0, BLOCK_SIZE, 0)
		gridPos = visualPos
		if fire:IsA("BasePart") then
			fire.Position = visualPos
		elseif fire:IsA("Model") then
			local pivotCF = fire:GetPivot()
			local boxCF = fire:GetBoundingBox()
			local off = pivotCF:ToObjectSpace(boxCF).Position
			fire:PivotTo(CFrame.new(visualPos - Vector3.new(off.X, 0, off.Z)))
		end
	elseif face == "Bottom" then
		-- FireBottom hangs under the host. The model is authored with a built-in
		-- orientation so its flame planes lie flat -- PRESERVE that rotation and only
		-- reposition it; LIFT pushes it up flush against the underside.
		local faceCenter = hostCenter + normal * (BLOCK_SIZE / 2)
			+ normal * FIRE_BOTTOM_NORMAL_NUDGE
			+ Vector3.new(0, FIRE_BOTTOM_LIFT, 0)
		gridPos = hostCenter + Vector3.new(0, -BLOCK_SIZE, 0)
		local authoredRot = fire:GetPivot().Rotation
		local extra = CFrame.Angles(
			math.rad(FIRE_BOTTOM_EXTRA_ROT_X),
			math.rad(FIRE_BOTTOM_EXTRA_ROT_Y),
			math.rad(FIRE_BOTTOM_EXTRA_ROT_Z))
		fire:PivotTo(CFrame.new(faceCenter) * authoredRot * extra)
	else
		local faceCenter = hostCenter + normal * (BLOCK_SIZE / 2)
		gridPos = hostCenter + normal * BLOCK_SIZE
		local yaw = fireSideYawFor(face)
		if fire:IsA("BasePart") then
			fire.CFrame = CFrame.new(faceCenter) * CFrame.Angles(0, yaw, 0)
		else
			fire:PivotTo(CFrame.new(faceCenter) * CFrame.Angles(0, yaw, 0))
		end
	end

	fire:SetAttribute("BlockType", "Fire")
	fire:SetAttribute("IsFire", true)
	fire:SetAttribute("FireFace", face)
	fire:SetAttribute("BlockPosX", gridPos.X)
	fire:SetAttribute("BlockPosY", gridPos.Y)
	fire:SetAttribute("BlockPosZ", gridPos.Z)
	fire:SetAttribute("HostBlockX", hostCenter.X)
	fire:SetAttribute("HostBlockY", hostCenter.Y)
	fire:SetAttribute("HostBlockZ", hostCenter.Z)
	if placedByUserId then
		fire:SetAttribute("PlacedBy", placedByUserId)
	end

	fire.Parent = blocksFolder
	return fire
end

-- Decide which FACE of the host the player clicked, from the raycast hit point.
-- We compare the hit position to the host centre and pick the axis the hit is
-- furthest along (the dominant face). Returns "Top"/"Bottom"/"PosX"/... .
local function faceFromHit(hostCenter, hitPos)
	if not hitPos then return "Top" end
	local d = hitPos - hostCenter
	local ax, ay, az = math.abs(d.X), math.abs(d.Y), math.abs(d.Z)
	if ay >= ax and ay >= az then
		return d.Y >= 0 and "Top" or "Bottom"
	elseif ax >= az then
		return d.X >= 0 and "PosX" or "NegX"
	else
		return d.Z >= 0 and "PosZ" or "NegZ"
	end
end

local function placeFire(player, targetBlock, blocksFolder, hitPos)
	if not targetBlock then return false, "Nothing to ignite" end

	if not BlockTemplates:FindFirstChild("Fire") then
		return false, "Fire template not found"
	end

	-- Resolve the clicked block's grid CENTER *exactly the way BlockSpatialIndex
	-- does* (stored BlockPos attrs first, else pivot + bottom-centre offset for
	-- models). This is critical: the fire stores HostBlock* from this value and
	-- FireHandler later looks the support up via the index -- if our value didn't
	-- match the index's, the fire would "lose support" and vanish, and would also
	-- be positioned against the wrong reference (the offset you saw). Do NOT round
	-- to a BLOCK_SIZE multiple -- terrain blocks sit at half-offsets, so rounding
	-- lands between cells.
	local hostCenter
	local px = targetBlock:GetAttribute("BlockPosX")
	local py = targetBlock:GetAttribute("BlockPosY")
	local pz = targetBlock:GetAttribute("BlockPosZ")
	if px and py and pz then
		hostCenter = Vector3.new(px, py, pz)
	elseif targetBlock:IsA("BasePart") then
		hostCenter = targetBlock.Position
	elseif targetBlock:IsA("Model") then
		-- Match BlockSpatialIndex.getBlockCenter's model fallback: fences/glass use
		-- the raw pivot; everything else is bottom-centre, so add half a block.
		local pivot = targetBlock:GetPivot().Position
		if targetBlock:GetAttribute("IsFence") or targetBlock:GetAttribute("IsGlass") then
			hostCenter = pivot
		else
			hostCenter = pivot + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
	end
	if not hostCenter then return false, "Could not resolve block position" end

	-- Which FACE did the player click? Top -> cube above, Bottom -> hung under,
	-- side -> mounted on that wall. Derived from the raycast hit point.
	local face = faceFromHit(hostCenter, hitPos)

	-- The empty cell the fire will occupy, for occupancy checks.
	local normal = FIRE_FACE_NORMAL[face] or FIRE_FACE_NORMAL.Top
	local fireCell = hostCenter + normal * BLOCK_SIZE

	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if spatialIndex then
		for _, occupant in ipairs(spatialIndex:GetBlocksAt(fireCell)) do
			if occupant:GetAttribute("IsFire") and (occupant:GetAttribute("FireFace") or "Top") == face then
				return false, "Already on fire"
			end
			local occType = occupant:GetAttribute("BlockType")
			if occType and FencePlacement.IsSolidBlock(occType) then
				return false, "That face is covered"
			end
		end
	end

	local fire = buildFireBlock(blocksFolder, hostCenter, player.UserId, face)
	if not fire then return false, "Failed to create Fire" end

	print(string.format("[BB-FIRE] Placed Fire (face=%s) on %s at cell (%.1f, %.1f, %.1f) for %s",
		face, tostring(targetBlock:GetAttribute("BlockType") or targetBlock.Name),
		fireCell.X, fireCell.Y, fireCell.Z, player.Name))

	return true, "Fire placed"
end

local function useFlintAndSteel(player, targetBlock, targetPosition)
	if not targetBlock then
		return false, "Nothing to ignite"
	end

	-- Resolve the build area FROM THE CLICKED BLOCK itself: its parent is a
	-- Blocks folder whose parent is the owning area. This works for both
	-- overworld BuildArea{N} and NetherPlot{N} without needing a location lookup
	-- (the player's location lookup only knows overworld plots, so it fails in
	-- the nether). We then sanity-check that area is a recognised plot.
	local blocksFolder = targetBlock.Parent
	if not blocksFolder or blocksFolder.Name ~= "Blocks" then
		return false, "Block not in a plot"
	end
	local buildArea = blocksFolder.Parent
	if not buildArea then return false, "No build area" end
	local isOverworld = buildArea.Name:match("^" .. GridConfig.BUILD_AREA_PREFIX .. "%d+$")
	local isNether = buildArea.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX .. "%d+$")
	local isMega = buildArea.Name == "MegaPlotBuildArea"
	if not (isOverworld or isNether or isMega) then
		return false, "Block not in a valid plot"
	end

	-- OBSIDIAN: try to light a portal frame first. If the obsidian is part of a
	-- valid 2x3 frame we light it; if not, we fall through to placing Fire on it
	-- like any other block.
	local blockType = targetBlock:GetAttribute("BlockType") or targetBlock.Name
	if blockType == "Obsidian" and PortalHandler then
		local frame = PortalHandler.FindFrameFromClick(blocksFolder, targetBlock)
		if frame then
			-- Block-creation closure: delegate to PortalHandler.BuildPortalBlock so the
			-- portal-building recipe lives in exactly ONE place (shared with the save
			-- managers' relight-on-load path). blocksFolder.ChildAdded auto-indexes it.
			-- portalType comes from LightFrame (resolved from the frame's material).
			local function createPortalBlock(cellPos, wideAxis, portalType)
				local block = PortalHandler.BuildPortalBlock(blocksFolder, cellPos, wideAxis, portalType)

				-- [BB-PORTAL] placement diagnostic: target cell vs where the block landed.
				if DEBUG_PORTAL_PLACEMENT and block then
					local visualPos = block:IsA("BasePart") and block.Position or block:GetPivot().Position
					local pivotPos = block:GetPivot().Position
					local sz = block:IsA("BasePart") and block.Size or block:GetExtentsSize()
					print(string.format("[BB-PORTAL]   placed: cell=(%.2f, %.2f, %.2f) -> visualPos=(%.2f, %.2f, %.2f) pivot=(%.2f, %.2f, %.2f) size=(%.2f, %.2f, %.2f)",
						cellPos.X, cellPos.Y, cellPos.Z,
						visualPos.X, visualPos.Y, visualPos.Z,
						pivotPos.X, pivotPos.Y, pivotPos.Z,
						sz.X, sz.Y, sz.Z))
				end

				return block
			end

			local lit = PortalHandler.LightFrame(blocksFolder, frame, createPortalBlock)
			if lit > 0 then
				print(string.format("[BB-PORTAL] Lit portal with %d block(s) for %s", lit, player.Name))
				return true, "Portal lit"
			end
			-- LightFrame found a frame but couldn't fill it; don't silently drop
			-- Fire into a portal opening. Report and stop.
			return false, "Failed to light portal"
		end
		-- No valid frame -> fall through and place Fire on the obsidian.
	end

	-- Default: place a Fire block on the face the player clicked.
	return placeFire(player, targetBlock, blocksFolder, targetPosition)
end

-- Main tool use handler
UseTool.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then return end
	
	local toolName = data.ToolName
	local targetBlock = data.TargetBlock
	local targetPosition = data.TargetPosition
	
	if not toolName then return end
	
	-- Validate position is in player's plot. FlintAndSteel is exempt from this
	-- location pre-check because it validates plot membership from the obsidian
	-- block itself (and the location lookup only knows overworld plots, so it
	-- would wrongly reject lighting a portal in the nether).
	if toolName ~= "FlintAndSteel" and targetPosition and not isPositionInPlot(player, targetPosition) then
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
	elseif toolName == "FlintAndSteel" then
		local success, message = useFlintAndSteel(player, targetBlock, targetPosition)
		if not success then
			print(string.format("[ToolHandler] FlintAndSteel: %s", message))
		end
	else
		print(string.format("[ToolHandler] Unknown tool: %s", toolName))
	end
end)

print("[ToolHandler] Initialized - Shovel converts grass to path blocks, Shears trim vines, Flint & Steel lights portals / places Fire")
