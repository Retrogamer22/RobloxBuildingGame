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
local BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)

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

local function useShears(player, targetBlock, _targetPosition)
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
