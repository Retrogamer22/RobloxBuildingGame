--[[
	BlockCollision
	Handles collision detection between blocks to prevent overlapping placement
	
	Key Features:
	- Full blocks occupy entire grid cell
	- Slabs occupy half a grid cell (6 orientations)
	- Stairs treated as full blocks (complex shape)
	- Fences treated as full blocks (thin but occupies cell)
	- Surface blocks (buttons, plates) don't block placement
	- Doors occupy 2 cells vertically
	- Decorations don't block placement
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for modules
local SlabPlacement = nil
local DoorPlacement = nil
local SurfacePlacement = nil
local FencePlacement = nil
local GridConfig = nil
local BlockSpatialIndex = nil

-- Lazy load dependencies
local function ensureDependencies()
	if not SlabPlacement then
		SlabPlacement = require(ReplicatedStorage:WaitForChild("SlabPlacement", 5))
	end
	if not DoorPlacement then
		DoorPlacement = require(ReplicatedStorage:WaitForChild("DoorPlacement", 5))
	end
	if not SurfacePlacement then
		SurfacePlacement = require(ReplicatedStorage:WaitForChild("SurfacePlacement", 5))
	end
	if not FencePlacement then
		FencePlacement = require(ReplicatedStorage:WaitForChild("FencePlacement", 5))
	end
	if not GridConfig then
		GridConfig = require(ReplicatedStorage:WaitForChild("Config", 5):WaitForChild("GridConfig", 5))
	end
	if not BlockSpatialIndex then
		BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 5))
	end
end

local BLOCK_SIZE = 3
local HALF_BLOCK = BLOCK_SIZE / 2  -- 1.5
local QUARTER_BLOCK = BLOCK_SIZE / 4  -- 0.75

-- Tolerance for grid position matching (handles floating point errors)
local GRID_TOLERANCE = 0.5

local BlockCollision = {}

-- Debug flag
local DEBUG_COLLISION = false

-- Cached basePlate reference for grid alignment
local cachedBasePlate = nil

-- Simple snap (fallback when no basePlate)
local function simpleSnapToGrid(pos: Vector3): Vector3
	return Vector3.new(
		math.round(pos.X / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(pos.Y / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(pos.Z / BLOCK_SIZE) * BLOCK_SIZE
	)
end

-- Baseplate-aware snap (matches BuildingController's grid)
local function snapToGrid(pos: Vector3, basePlate: BasePart?): Vector3
	if not basePlate then
		return simpleSnapToGrid(pos)
	end
	
	local platePos = basePlate.Position
	local plateSize = basePlate.Size
	local plateTop = platePos.Y + plateSize.Y / 2
	
	-- Grid origin is aligned to baseplate edges
	local originX = platePos.X - plateSize.X / 2 + BLOCK_SIZE / 2
	local originZ = platePos.Z - plateSize.Z / 2 + BLOCK_SIZE / 2
	
	-- Y grid: grass surface (just below plateTop) and extends both up and down
	local surfaceY = plateTop - BLOCK_SIZE / 2
	
	local relX = pos.X - originX
	local relY = pos.Y - surfaceY
	local relZ = pos.Z - originZ
	
	local gridX = math.round(relX / BLOCK_SIZE) * BLOCK_SIZE + originX
	local gridY = math.round(relY / BLOCK_SIZE) * BLOCK_SIZE + surfaceY
	local gridZ = math.round(relZ / BLOCK_SIZE) * BLOCK_SIZE + originZ
	
	return Vector3.new(gridX, gridY, gridZ)
end

-- Get the basePlate from a blocksFolder
local function getBasePlateFromBlocksFolder(blocksFolder: Folder?): BasePart?
	if not blocksFolder then return nil end
	
	-- BlocksFolder is inside BuildArea, which contains the BasePlate
	local buildArea = blocksFolder.Parent
	if buildArea then
		-- Try direct child first
		local basePlate = buildArea:FindFirstChild("BasePlate")
		if basePlate and basePlate:IsA("BasePart") then
			return basePlate
		end
		
		-- Maybe BasePlate is a Model containing a Part
		if basePlate and basePlate:IsA("Model") then
			local part = basePlate:FindFirstChildWhichIsA("BasePart")
			if part then return part end
		end
		
		-- Search for any child that looks like a baseplate (large flat part)
		for _, child in ipairs(buildArea:GetChildren()) do
			if child:IsA("BasePart") and child.Size.X > 20 and child.Size.Z > 20 then
				if DEBUG_COLLISION then
					print(string.format("[Collision] Found basePlate by size search: %s", child.Name))
				end
				return child
			end
		end
		
		-- Debug: print all children if we can't find it
		if DEBUG_COLLISION then
			print("[Collision] Could not find BasePlate! BuildArea children:")
			for _, child in ipairs(buildArea:GetChildren()) do
				print(string.format("  - %s (%s)", child.Name, child.ClassName))
			end
		end
	end
	
	return nil
end

-- Check if two positions are at the same grid cell
local function isSameGridCell(pos1: Vector3, pos2: Vector3): boolean
	local diff = pos1 - pos2
	return math.abs(diff.X) < GRID_TOLERANCE 
		and math.abs(diff.Y) < GRID_TOLERANCE 
		and math.abs(diff.Z) < GRID_TOLERANCE
end

-- Get the grid position of an existing block
local function getBlockGridPosition(block, basePlate: BasePart?): Vector3?
	if not block then return nil end
	
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return nil end
	
	local gridPos = nil
	
	-- For doors, use stored grid position (most reliable)
	if block:GetAttribute("IsDoor") then
		local gx = block:GetAttribute("GridPosX")
		local gy = block:GetAttribute("GridPosY")
		local gz = block:GetAttribute("GridPosZ")
		if gx and gy and gz then
			return Vector3.new(gx, gy, gz)
		end
	end
	
	-- For fences (unions), use GetPivot to get accurate grid position
	local isFence = block:GetAttribute("IsFence")
	if isFence and block:IsA("BasePart") then
		gridPos = block:GetPivot().Position
		return snapToGrid(gridPos, basePlate)
	end
	
	-- For glass (models), use GetPivot directly without Y offset compensation
	local isGlass = block:GetAttribute("IsGlass")
	if isGlass and block:IsA("Model") then
		gridPos = block:GetPivot().Position
		return snapToGrid(gridPos, basePlate)
	end
	
	-- For regular BaseParts
	if block:IsA("BasePart") then
		gridPos = block.Position
		return snapToGrid(gridPos, basePlate)
	end
	
	-- For Models
	if block:IsA("Model") then
		local primaryPart = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
		if primaryPart then
			-- Get the model's pivot position (more reliable than part position)
			gridPos = block:GetPivot().Position
			
			-- Models are offset by -BLOCK_SIZE/2 when placed, but the direction depends on rotation
			-- For sideways logs, the offset is applied in local space, so it shifts along X or Z
			-- The server does: cframe * CFrame.new(0, -1.5, 0) which applies offset in local space
			-- For X-axis (90° Z rotation): local Y points to world +X, so -1.5 local Y = +1.5 world X
			-- For Z-axis (90° X rotation): local Y points to world +Z, so -1.5 local Y = -1.5 world Z
			local isSurfaceBlock = block:GetAttribute("IsSurfaceBlock")
			if not isSurfaceBlock then
				local logAxis = block:GetAttribute("LogAxis")
				if logAxis and logAxis ~= "Y" and logAxis ~= "Y+" and logAxis ~= "Y-" then
					-- Sideways log - compensate based on axis direction
					if logAxis == "X" or logAxis == "X+" or logAxis == "X-" then
						-- Pivot was shifted +1.5 in world X, so subtract to get grid center
						gridPos = gridPos - Vector3.new(HALF_BLOCK, 0, 0)
					elseif logAxis == "Z" or logAxis == "Z+" or logAxis == "Z-" then
						-- Pivot was shifted -1.5 in world Z, so add to get grid center
						gridPos = gridPos + Vector3.new(0, 0, HALF_BLOCK)
					end
				else
					-- Vertical or other model - standard Y compensation
					gridPos = gridPos + Vector3.new(0, HALF_BLOCK, 0)
				end
			end
			
			return snapToGrid(gridPos, basePlate)
		end
	end
	
	return nil
end

-- Get the slab "sub-cell" that a slab occupies within a grid cell
-- Returns which half of the cell is occupied
local function getSlabSubCell(orientation: string): string
	if orientation == "bottom" then return "bottom_half"
	elseif orientation == "top" then return "top_half"
	elseif orientation == "north" then return "north_half"
	elseif orientation == "south" then return "south_half"
	elseif orientation == "east" then return "east_half"
	elseif orientation == "west" then return "west_half"
	end
	return "full" -- Unknown orientation, treat as full
end

-- Check if two slabs at the same grid position would overlap
local function doSlabsOverlap(orientation1: string, orientation2: string): boolean
	local sub1 = getSlabSubCell(orientation1)
	local sub2 = getSlabSubCell(orientation2)
	
	-- Same sub-cell = overlap
	if sub1 == sub2 then return true end
	
	-- Opposite halves don't overlap
	local opposites = {
		["bottom_half"] = "top_half",
		["top_half"] = "bottom_half",
		["north_half"] = "south_half",
		["south_half"] = "north_half",
		["east_half"] = "west_half",
		["west_half"] = "east_half",
	}
	
	if opposites[sub1] == sub2 then
		return false -- Opposite halves can coexist
	end
	
	-- Different axes (e.g., bottom + north) - these DO overlap because
	-- bottom slab occupies the entire bottom half of the cube
	-- north slab occupies the entire north half of the cube
	-- These two regions intersect
	return true
end

-- Check if a door at gridPos would collide with an existing block
-- Door occupies 2 grid cells: one at doorGridPos.Y, one at doorGridPos.Y + BLOCK_SIZE
local function checkDoorCollision(doorGridPos: Vector3, existingGridPos: Vector3, existingIsDoor: boolean): boolean
	-- Check X and Z alignment first (must be same horizontal grid cell)
	if math.abs(doorGridPos.X - existingGridPos.X) >= GRID_TOLERANCE then return false end
	if math.abs(doorGridPos.Z - existingGridPos.Z) >= GRID_TOLERANCE then return false end
	
	-- Door occupies 2 cells: bottom cell at doorGridPos.Y, top cell at doorGridPos.Y + BLOCK_SIZE
	local doorCell1 = doorGridPos.Y
	local doorCell2 = doorGridPos.Y + BLOCK_SIZE
	
	if existingIsDoor then
		-- Other door also occupies 2 cells
		local existingCell1 = existingGridPos.Y
		local existingCell2 = existingGridPos.Y + BLOCK_SIZE
		
		-- Check if any cells match
		if math.abs(doorCell1 - existingCell1) < GRID_TOLERANCE then return true end
		if math.abs(doorCell1 - existingCell2) < GRID_TOLERANCE then return true end
		if math.abs(doorCell2 - existingCell1) < GRID_TOLERANCE then return true end
		if math.abs(doorCell2 - existingCell2) < GRID_TOLERANCE then return true end
	else
		-- Single cell block - check if it matches either door cell
		if math.abs(doorCell1 - existingGridPos.Y) < GRID_TOLERANCE then return true end
		if math.abs(doorCell2 - existingGridPos.Y) < GRID_TOLERANCE then return true end
	end
	
	return false
end

-- Check if a new block can be placed at position without overlapping existing blocks
function BlockCollision.CanPlace(blockType: string, gridPos: Vector3, blocksFolder: Folder, extraData: {orientation: string?, isDoor: boolean?, isDecoration: boolean?, isBed: boolean?, basePlate: BasePart?}?): (boolean, string?)
	ensureDependencies()
	
	if not blocksFolder then
		return true, nil  -- No blocks folder, allow placement
	end
	
	-- Get the basePlate - prefer from extraData, fallback to finding it
	local basePlate = (extraData and extraData.basePlate) or getBasePlateFromBlocksFolder(blocksFolder)
	
	if DEBUG_COLLISION then
		print(string.format("[Collision] basePlate: %s (from %s)",
			basePlate and basePlate.Name or "NIL",
			(extraData and extraData.basePlate) and "extraData" or "folder lookup"))
	end
	
	-- Snap input position to grid for consistent comparison
	local snappedPos = snapToGrid(gridPos, basePlate)
	
	-- Surface blocks don't need collision checking (they attach to surfaces)
	if SurfacePlacement and SurfacePlacement.IsSurfaceBlock(blockType) then
		return true, nil
	end
	
	-- Decorations don't need collision checking (they sit on top of blocks)
	if extraData and extraData.isDecoration then
		return true, nil
	end
	
	-- Determine what kind of block we're placing
	local newIsSlab = SlabPlacement and SlabPlacement.IsSlab(blockType)
	local newOrientation = extraData and extraData.orientation
	local newIsDoor = extraData and extraData.isDoor or (DoorPlacement and DoorPlacement.IsDoor(blockType))
	
	if DEBUG_COLLISION then
		print(string.format("[Collision] Checking placement at (%.1f, %.1f, %.1f) -> snapped (%.1f, %.1f, %.1f) type=%s", 
			gridPos.X, gridPos.Y, gridPos.Z,
			snappedPos.X, snappedPos.Y, snappedPos.Z,
			blockType))
	end
	
	-- Use spatial index for O(1) lookups instead of scanning all blocks
	local spatialIndex = BlockSpatialIndex and BlockSpatialIndex.GetOrCreate(blocksFolder)
	
	-- Helper: check collision against blocks at a specific position
	local function checkBlocksAtPos(checkPos, isDoorCheck)
		local blocksAtPos
		if spatialIndex then
			blocksAtPos = spatialIndex:GetBlocksAt(checkPos)
		else
			-- Fallback if spatial index unavailable
			blocksAtPos = {}
			for _, b in ipairs(blocksFolder:GetChildren()) do
				local gp = getBlockGridPosition(b, basePlate)
				if gp and isSameGridCell(checkPos, gp) then
					table.insert(blocksAtPos, b)
				end
			end
		end
		
		for _, existingBlock in ipairs(blocksAtPos) do
			if existingBlock:GetAttribute("IsDecoration") then continue end
			if existingBlock:GetAttribute("IsSurfaceBlock") then continue end
			if existingBlock:GetAttribute("IsWater") then continue end -- Water is replaceable by blocks
			if existingBlock:GetAttribute("IsLava") then continue end -- Lava is replaceable by blocks (placing destroys it)
			if existingBlock:GetAttribute("IsFire") then continue end -- Fire is replaceable by blocks (placing snuffs it out)
			if existingBlock:GetAttribute("IsBed") then continue end -- Beds don't block placement (low-profile, like decorations)
			if existingBlock:GetAttribute("IsWallpaperFrame") then continue end -- Wallpaper is paper-thin, doesn't block placement
			
			-- Bed-specific extra leniency: beds are low-profile and the player expects
			-- them to be placeable next to (or sharing a cell-edge with) anything that's
			-- stuck to a face -- vines, ladders, signs, carpets, torches, lanterns. None
			-- of these meaningfully occupy the floor volume the bed needs.
			-- Mirrors the foot-cell skip list in BlockHandler.server.luau (bed branch).
			if extraData and extraData.isBed then
				if existingBlock:GetAttribute("IsVine") then continue end
				if existingBlock:GetAttribute("IsLadder") then continue end
				if existingBlock:GetAttribute("IsSignStanding") then continue end
				if existingBlock:GetAttribute("IsWallSign") then continue end
				if existingBlock:GetAttribute("IsCarpet") then continue end
				if existingBlock:GetAttribute("IsTorch") then continue end
				if existingBlock:GetAttribute("IsLantern") then continue end
			end
			
			local existingType = existingBlock:GetAttribute("BlockType")
			local existingIsDoor = existingBlock:GetAttribute("IsDoor")
			
			-- If we're placing a door, any block at this position is a collision
			if isDoorCheck then
				if DEBUG_COLLISION then
					print(string.format("  COLLISION (door) with %s", existingType or "unknown"))
				end
				return false, "Block would overlap with existing door space"
			end
			
			-- Check slab stacking at same position
			local existingIsSlab = existingBlock:GetAttribute("SlabOrientation") ~= nil
			local existingOrientation = existingBlock:GetAttribute("SlabOrientation")
			
			if newIsSlab and existingIsSlab and newOrientation and existingOrientation then
				if not doSlabsOverlap(newOrientation, existingOrientation) then
					if DEBUG_COLLISION then
						print(string.format("  Slabs can stack: %s + %s", newOrientation, existingOrientation))
					end
					continue
				end
			end
			
			if DEBUG_COLLISION then
				print(string.format("  COLLISION with %s", existingType or "unknown"))
			end
			return false, "Block would overlap with existing block"
		end
		return true, nil
	end
	
	-- Check blocks at the target position
	local canPlace, reason = checkBlocksAtPos(snappedPos, false)
	if not canPlace then return false, reason end
	
	-- Door checks: doors span 2 cells vertically
	if newIsDoor then
		-- Check the upper cell too
		local upperPos = snappedPos + Vector3.new(0, BLOCK_SIZE, 0)
		canPlace, reason = checkBlocksAtPos(upperPos, true)
		if not canPlace then return false, reason end
	end
	
	-- Check if an existing door below extends into our position
	local belowPos = snappedPos - Vector3.new(0, BLOCK_SIZE, 0)
	local blocksBelowList
	if spatialIndex then
		blocksBelowList = spatialIndex:GetBlocksAt(belowPos)
	else
		blocksBelowList = {}
		for _, b in ipairs(blocksFolder:GetChildren()) do
			local gp = getBlockGridPosition(b, basePlate)
			if gp and isSameGridCell(belowPos, gp) then
				table.insert(blocksBelowList, b)
			end
		end
	end
	for _, existingBlock in ipairs(blocksBelowList) do
		if existingBlock:GetAttribute("IsDoor") then
			if DEBUG_COLLISION then
				print("  COLLISION with door extending from below")
			end
			return false, "Block would overlap with existing door"
		end
	end
	
	if DEBUG_COLLISION then
		print("  No collision, placement OK")
	end
	
	return true, nil
end

-- Check if two slabs can stack (same grid cell, different halves)
function BlockCollision.CanSlabsStack(existingOrientation: string, newOrientation: string): boolean
	return not doSlabsOverlap(existingOrientation, newOrientation)
end

-- Set debug mode
function BlockCollision.SetDebug(enabled: boolean)
	DEBUG_COLLISION = enabled
end

return BlockCollision
