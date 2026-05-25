--[[
	PlotSerializer
	Handles converting plot data to/from a compact save format
	
	Save format optimized for DataStore (compact, serializable):
	{
		version = 1,
		biome = "Plains",
		terrainStyle = "Flat",
		blocks = {
			-- Each block: {x, y, z, typeId, rotation, extraData}
			-- extraData is optional and only present for blocks with special properties
		},
		dug = {
			-- Positions where terrain was removed at ANY depth
		}
	}
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotSerializer = {}

-- Glass debug levels: 0=off, 1=summary, 2=verbose
local DEBUG_GLASS_LEVEL = 1

-- Current save format version (increment when format changes)
PlotSerializer.VERSION = 2  -- Updated for multi-depth dug tracking

-- Block type ID mapping for compact storage
local TypeToId = {}
local IdToType = {}
local nextId = 1

-- Extra data keys mapped to short codes (for compression)
-- Attributes not in this list will still be saved, just with full names
local ExtraKeyShort = {
	["IsUpsideDown"] = "u",
	["CornerType"] = "c",
	["StairDirection"] = "sd",
	["LogAxis"] = "la",
	["SlabOrientation"] = "so",
	["DoorDirection"] = "dd",
	["DoorDepth"] = "dp",
	["DoorHingeSide"] = "dh",
	["IsOpen"] = "o",
	["SurfaceFace"] = "sf",
	["HostBlockX"] = "hx",
	["HostBlockY"] = "hy",
	["HostBlockZ"] = "hz",
	["FenceConnectionType"] = "fc",
	["BlockedDirections"] = "bd",  -- User-blocked fence connection directions
	["GlassConnectionType"] = "gc",
	["GlassOrientation"] = "go",
	["GlassPrimaryDir"] = "gp",
	["GlassSecondaryDir"] = "gs",
	["IsPowered"] = "pw",
	["IsOutputting"] = "out",
	["ParentBlockX"] = "px",
	["ParentBlockY"] = "py",
	["ParentBlockZ"] = "pz",
	["CustomColorR"] = "cr",
	["CustomColorG"] = "cg",
	["CustomColorB"] = "cb",
	["IsDecoration"] = "deco",
	["IsLazyLoaded"] = "lazy",
	["IsExtended"] = "ext",
	["BlockId"] = "bid",
	["Rotation"] = "r",
	["Biome"] = "bio",  -- Biome name for grass/leaf coloring
	["Season"] = "sea",  -- Season name for grass/leaf coloring
	-- Sign attributes
	["IsSignStanding"] = "sst",
	["IsWallSign"] = "swa",
	["IsOnFencePost"] = "sfp",  -- Sign is on a fence post (flush positioning)
	["SignRotation"] = "sr",
	["SignFace"] = "sfc",
	["SignType"] = "sty",  -- "standing" or "wall"
	["IsCarpet"] = "icp",  -- Carpet frame block
	["SignModelName"] = "smn",
	["SignLine1"] = "sl1",
	["SignLine2"] = "sl2",
	["SignLine3"] = "sl3",
	["SignLine4"] = "sl4",
	["SignLine5"] = "sl5",
	["PathYOffset"] = "pyo",  -- Y offset for path blocks created by shovel
	-- Column attributes
	["ColumnModelName"] = "cmn",
	["IsColumn"] = "icl",
	["IsArch"] = "iar",  -- Arch block (uses stair placement logic)
	-- Wallpaper attributes
	["IsWallpaperFrame"] = "wpf",
	["WallpaperFace"] = "wf2",
	-- Water attributes
	["WaterLevel"] = "wl",
	["IsWater"] = "iw",
	["IsFalling"] = "wf",
	-- Chest inventory
	["ChestContents"] = "cc",
	-- Bed attributes
	["IsBed"] = "ib",
	["BedSecondaryX"] = "bsx",
	["BedSecondaryY"] = "bsy",
	["BedSecondaryZ"] = "bsz",
	-- Rainbow block attributes
	["ColorMode"] = "cm",
	["HasPointLight"] = "hpl",
	["RainbowRotX"] = "rrx",
	["RainbowRotZ"] = "rrz",
	["RainbowPhase"] = "rph",
}

-- Attributes that should NOT be saved (transient/internal/computed)
local AttributeBlacklist = {
	["BlockType"] = true,        -- Saved separately
	["PlacedBy"] = true,         -- Saved separately  
	["IsTerrainBlock"] = true,   -- Regenerated
	["IsEdgeWall"] = true,       -- Regenerated
	["IsTreeBlock"] = true,      -- Regenerated
	["TerrainDepth"] = true,     -- Regenerated
	["SurfaceY"] = true,         -- Regenerated
	["BlockPosX"] = true,        -- Computed from position
	["BlockPosY"] = true,        -- Computed from position
	["BlockPosZ"] = true,        -- Computed from position
	["GridPosX"] = true,         -- Used for save/load position calculation
	["GridPosY"] = true,         -- Used for save/load position calculation
	["GridPosZ"] = true,         -- Used for save/load position calculation
	["DoorGridY"] = true,        -- Deprecated, replaced by GridPos
	["BeingPushed"] = true,      -- Transient piston state
	["BeingRemovedBySaveSystem"] = true, -- Internal flag
	["PathBaseX"] = true,        -- Used for grid calculation during save only
	["PathBaseY"] = true,        -- Used for grid calculation during save only
	["PathBaseZ"] = true,        -- Used for grid calculation during save only
}

local ShortToExtraKey = {}
for k, v in pairs(ExtraKeyShort) do
	ShortToExtraKey[v] = k
end

-- Register a block type and get its ID
local function registerType(typeName)
	if TypeToId[typeName] then
		return TypeToId[typeName]
	end
	
	TypeToId[typeName] = nextId
	IdToType[nextId] = typeName
	nextId = nextId + 1
	
	return TypeToId[typeName]
end

-- Serialize extra block data (saves ALL attributes except blacklisted ones)
-- Uses short codes for compression when available, full names otherwise
local function serializeExtraData(block)
	local extra = {}
	local hasExtra = false
	
	-- Get ALL attributes from the block
	local allAttributes = block:GetAttributes()
	
	for attrName, value in pairs(allAttributes) do
		-- Skip blacklisted attributes
		if AttributeBlacklist[attrName] then
			continue
		end
		
		-- Skip default/false boolean values to save space
		if type(value) == "boolean" and value == false then
			continue
		end
		
		-- Skip "normal" corner type (default)
		if attrName == "CornerType" and value == "normal" then
			continue
		end
		
		-- Handle dynamic WireConn_ attributes specially (collect into array)
		if string.sub(attrName, 1, 9) == "WireConn_" then
			-- Will be handled below
			continue
		end
		
		-- Use short code if available, otherwise use full name
		local key = ExtraKeyShort[attrName] or attrName
		extra[key] = value
		hasExtra = true
	end
	
	-- Handle dynamic WireConn_ attributes for wire connections
	-- These store BlockId references to connected output blocks
	local wireConnections = {}
	for attrName, value in pairs(allAttributes) do
		if string.sub(attrName, 1, 9) == "WireConn_" then
			table.insert(wireConnections, value)
		end
	end
	if #wireConnections > 0 then
		extra["wc"] = wireConnections  -- "wc" = wire connections array
		hasExtra = true
	end
	
	return hasExtra and extra or nil
end

-- Deserialize extra data back to attributes
-- Handles both short codes and full attribute names for forward compatibility
local function deserializeExtraData(extraData)
	if not extraData then return {} end
	
	local attributes = {}
	for key, value in pairs(extraData) do
		-- Handle wire connections array specially
		if key == "wc" and type(value) == "table" then
			attributes["_WireConnections"] = value  -- Store for special handling in SaveManager
		else
			-- Check if it's a short code, otherwise use key as-is (full name)
			local fullKey = ShortToExtraKey[key] or key
			attributes[fullKey] = value
			
			-- Debug: print slab orientation when deserializing
			if fullKey == "SlabOrientation" then
				print(string.format("[PlotSerializer] Deserialized SlabOrientation: %s", tostring(value)))
			end
			
			-- Debug: print door attributes when deserializing
			if fullKey == "DoorDirection" or fullKey == "DoorDepth" or fullKey == "DoorHingeSide" then
				print(string.format("[PlotSerializer] Deserialized %s: %s (type=%s) from key=%s", fullKey, tostring(value), type(value), key))
			end
		end
	end
	
	return attributes
end

-- Extract color from a block
local function extractBlockColor(block)
	if block:IsA("BasePart") then
		return block.Color
	elseif block:IsA("Model") then
		local part = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
		if part then
			return part.Color
		end
	end
	return nil
end

-- Serialize a single block
-- terrainOrigin: Vector3-like table {x, y, z} for relative grid calculation
local function serializeBlock(block, blockPos, BLOCK_SIZE, terrainOrigin)
	local blockType: string? = block:GetAttribute("BlockType")
	if not blockType then return nil end
	
	-- Skip terrain blocks - we regenerate those
	-- EXCEPT lazy-loaded blocks which should be saved
	if block:GetAttribute("IsTerrainBlock") and not block:GetAttribute("IsLazyLoaded") then
		return nil
	end
	
	-- Skip edge walls
	if block:GetAttribute("IsEdgeWall") then
		return nil
	end
	
	-- Skip terrain-generated decorations (they don't have PlacedBy attribute)
	if block:GetAttribute("IsDecoration") and not block:GetAttribute("PlacedBy") then
		return nil
	end
	
	-- Skip flowing water (recalculated from sources on load)
	if block:GetAttribute("IsWater") and (block:GetAttribute("WaterLevel") or 0) > 0 then
		return nil
	end
	
	-- Skip tree blocks (Leaves and Logs without PlacedBy are terrain-generated)
	if blockType == "Leaves" and not block:GetAttribute("PlacedBy") then
		return nil
	end
	
	-- Skip terrain-generated logs (they have IsTreeBlock attribute from TreeGenerator)
	if block:GetAttribute("IsTreeBlock") and not block:GetAttribute("PlacedBy") then
		return nil
	end
	
	-- Get grid position RELATIVE to terrain origin
	-- This ensures positions are consistent across save/load cycles
	local gridX, gridY, gridZ
	local positionSource = "unknown"
	
	-- For lazy-loaded blocks, use stored position attributes (guaranteed grid-aligned)
	local storedPosX = block:GetAttribute("BlockPosX")
	local storedPosY = block:GetAttribute("BlockPosY")
	local storedPosZ = block:GetAttribute("BlockPosZ")
	
	-- Calculate relative to origin for proper grid alignment
	local originX = terrainOrigin and terrainOrigin.x or 0
	local originY = terrainOrigin and terrainOrigin.y or 0
	local originZ = terrainOrigin and terrainOrigin.z or 0
	
	-- PathBlock special handling: use original base position (before Y offset was applied)
	local pathBaseX = block:GetAttribute("PathBaseX")
	local pathBaseY = block:GetAttribute("PathBaseY")
	local pathBaseZ = block:GetAttribute("PathBaseZ")
	
	if pathBaseX and pathBaseY and pathBaseZ then
		-- PathBlock: use the original grid position (before shovel raised it)
		gridX = math.round((pathBaseX - originX) / BLOCK_SIZE)
		gridY = math.round((pathBaseY - originY) / BLOCK_SIZE)
		gridZ = math.round((pathBaseZ - originZ) / BLOCK_SIZE)
		positionSource = string.format("PathBase(%.2f,%.2f,%.2f)", pathBaseX :: number, pathBaseY :: number, pathBaseZ :: number)
	elseif storedPosX and storedPosY and storedPosZ then
		-- Use stored position (grid-aligned), relative to origin
		gridX = math.round((storedPosX - originX) / BLOCK_SIZE)
		gridY = math.round((storedPosY - originY) / BLOCK_SIZE)
		gridZ = math.round((storedPosZ - originZ) / BLOCK_SIZE)
		positionSource = string.format("StoredPos(%.2f,%.2f,%.2f)", storedPosX :: number, storedPosY :: number, storedPosZ :: number)
	elseif block:GetAttribute("IsDecoration") then
		local parentX = block:GetAttribute("ParentBlockX")
		local parentY = block:GetAttribute("ParentBlockY")
		local parentZ = block:GetAttribute("ParentBlockZ")
		
		if parentX and parentY and parentZ then
			gridX = math.round((parentX - originX) / BLOCK_SIZE)
			gridY = math.round((parentY - originY) / BLOCK_SIZE)
			gridZ = math.round((parentZ - originZ) / BLOCK_SIZE)
			positionSource = string.format("ParentPos(%.2f,%.2f,%.2f)", parentX, parentY, parentZ)
		else
			gridX = math.round((blockPos.X - originX) / BLOCK_SIZE)
			gridY = math.round((blockPos.Y - originY) / BLOCK_SIZE)
			gridZ = math.round((blockPos.Z - originZ) / BLOCK_SIZE)
			positionSource = string.format("BlockPos(%.2f,%.2f,%.2f)", blockPos.X, blockPos.Y, blockPos.Z)
		end
	else
		-- Check for stored grid position (used by doors and other multi-block objects)
		local storedGridPosX = block:GetAttribute("GridPosX")
		local storedGridPosY = block:GetAttribute("GridPosY")
		local storedGridPosZ = block:GetAttribute("GridPosZ")
		
		if storedGridPosX and storedGridPosY and storedGridPosZ then
			-- Use stored grid position (exact placement position)
			gridX = math.round((storedGridPosX - originX) / BLOCK_SIZE)
			gridY = math.round((storedGridPosY - originY) / BLOCK_SIZE)
			gridZ = math.round((storedGridPosZ - originZ) / BLOCK_SIZE)
			positionSource = string.format("StoredGridPos(%.2f,%.2f,%.2f)", storedGridPosX, storedGridPosY, storedGridPosZ)
		else
			-- Default: calculate from block position
			gridX = math.round((blockPos.X - originX) / BLOCK_SIZE)
			gridY = math.round((blockPos.Y - originY) / BLOCK_SIZE)
			gridZ = math.round((blockPos.Z - originZ) / BLOCK_SIZE)
			positionSource = string.format("BlockPos(%.2f,%.2f,%.2f)", blockPos.X, blockPos.Y, blockPos.Z)
		end
	end
	
	-- Debug logging for lazy-loaded blocks
	if block:GetAttribute("IsLazyLoaded") then
		print(string.format("[SaveDebug] %s LazyLoaded -> Grid(%d,%d,%d) from %s",
			blockType, gridX, gridY, gridZ, positionSource))
	end
	
	-- Debug logging for doors (use string matching to catch all doors)
	local isDoorBlock = string.find(string.lower(blockType), "door") ~= nil
	if isDoorBlock then
		print(string.format("[SaveDebug] Door %s -> Grid(%d,%d,%d) from %s",
			blockType, gridX, gridY, gridZ, positionSource))
		-- Log all door attributes being saved
		print(string.format("[SaveDebug] Door attributes on block: DoorDirection=%s, DoorDepth=%s, DoorHingeSide=%s, Rotation=%s, IsDoor=%s",
			tostring(block:GetAttribute("DoorDirection")),
			tostring(block:GetAttribute("DoorDepth")),
			tostring(block:GetAttribute("DoorHingeSide")),
			tostring(block:GetAttribute("Rotation")),
			tostring(block:GetAttribute("IsDoor"))))
	end
	
	-- Debug logging for wallpaper frames
	if block:GetAttribute("IsWallpaperFrame") then
		local hostX = block:GetAttribute("HostBlockX")
		local hostY = block:GetAttribute("HostBlockY")
		local hostZ = block:GetAttribute("HostBlockZ")
		local bpX = block:GetAttribute("BlockPosX")
		local bpY = block:GetAttribute("BlockPosY")
		local bpZ = block:GetAttribute("BlockPosZ")
		local face = block:GetAttribute("WallpaperFace") or "?"
		local fillId = block:GetAttribute("FrameFillBlockId")
		print(string.format("[WP-SAVE] %s face=%s filled=%s -> Grid(%d,%d,%d) from %s",
			blockType, face, tostring(fillId), gridX, gridY, gridZ, positionSource))
		print(string.format("[WP-SAVE]   BlockPos=(%s,%s,%s) HostBlock=(%s,%s,%s) visualPos=(%.2f,%.2f,%.2f)",
			tostring(bpX), tostring(bpY), tostring(bpZ),
			tostring(hostX), tostring(hostY), tostring(hostZ),
			blockPos.X, blockPos.Y, blockPos.Z))
	end
	
	-- Register type and get ID
	local typeId = registerType(blockType)
	
	-- Get rotation
	local rotation = block:GetAttribute("Rotation") or 0
	
	-- Get extra data (attributes)
	local extra = serializeExtraData(block)
	
	-- Debug: log door extra data after serialization
	if isDoorBlock and extra then
		local extraStr = ""
		for k, v in pairs(extra) do
			extraStr = extraStr .. string.format("%s=%s, ", k, tostring(v))
		end
		print(string.format("[SaveDebug] Door serialized extra data: {%s}", extraStr))
	end
	
	-- Mark decorations
	if block:GetAttribute("IsDecoration") then
		extra = extra or {}
		extra["deco"] = true
	end
	
	-- Add color for template blocks
	local isTemplateBlock = string.find(blockType, "Stair") or 
							 string.find(blockType, "Slab") or 
							 string.find(blockType, "Fence") or
							 string.find(blockType, "Ladder") or
							 string.find(blockType, "GlassBlock") or
							 string.find(blockType, "Wool") or
							 block:GetAttribute("IsFence") or
							 block:GetAttribute("IsLadder") or
							 block:GetAttribute("IsGlass")
	
	-- Debug: print slab orientation when saving
	if string.find(blockType, "Slab") then
		local slabOrientation = block:GetAttribute("SlabOrientation")
		print(string.format("[PlotSerializer] Saving slab %s with orientation: %s", blockType, tostring(slabOrientation)))
	end
	
	if isTemplateBlock then
		local color = extractBlockColor(block)
		if color then
			extra = extra or {}
			extra["cr"] = math.round(color.R * 255)
			extra["cg"] = math.round(color.G * 255)
			extra["cb"] = math.round(color.B * 255)
			
			-- Debug: log ladder color being saved
			if string.find(blockType, "Ladder") then
				print(string.format("[Ladder SAVE] %s color: R=%d G=%d B=%d", 
					blockType, extra["cr"], extra["cg"], extra["cb"]))
			end
		else
			-- Debug: log if color extraction failed
			if string.find(blockType, "Ladder") then
				print(string.format("[Ladder SAVE] %s - WARNING: extractBlockColor returned nil!", blockType))
			end
		end
	end
	
	-- Debug: log chest save data
	if block:GetAttribute("IsChest") then
		local isDouble = block:GetAttribute("IsDoubleChest")
		local secX = block:GetAttribute("ChestSecondaryX")
		print(string.format("[Chest] SAVE type=%s grid=(%d,%d,%d) isDouble=%s hasSecondary=%s extraKeys=%s",
			blockType, gridX, gridY, gridZ, tostring(isDouble), tostring(secX ~= nil),
			extra and table.concat((function() local keys = {} for k in pairs(extra) do table.insert(keys, k) end return keys end)(), ",") or "nil"))
	end
	
	if extra then
		return {gridX, gridY, gridZ, typeId, rotation, extra}
	else
		return {gridX, gridY, gridZ, typeId, rotation}
	end
end

-- Serialize an entire plot
-- options: { noYield = bool } - skip yields during critical saves (shutdown)
function PlotSerializer.SerializePlot(buildArea, BLOCK_SIZE, options)
	local noYield = options and options.noYield or false
	
	-- Reset type registry for fresh serialization
	TypeToId = {}
	IdToType = {}
	nextId = 1
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		return nil, "No blocks folder found"
	end
	
	-- Get terrain info for origin calculation FIRST (needed for grid position calculation)
	local terrainSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	print(string.format("[PlotSerializer] DEBUG SAVE: terrainSurfaceY=%.4f, posX=%.4f, posZ=%.4f, sizeX=%.4f, sizeZ=%.4f, BLOCK_SIZE=%d",
		terrainSurfaceY or -999, posX or -999, posZ or -999, sizeX or -999, sizeZ or -999, BLOCK_SIZE))
	
	-- Calculate terrain origin for relative grid positions
	local terrainOrigin = nil
	if posX and posZ and sizeX and sizeZ then
		terrainOrigin = {
			x = posX - sizeX / 2 + BLOCK_SIZE / 2,
			y = terrainSurfaceY or 0,
			z = posZ - sizeZ / 2 + BLOCK_SIZE / 2,
		}
		print(string.format("[PlotSerializer] Using terrain origin: (%.4f, %.4f, %.4f)", 
			terrainOrigin.x, terrainOrigin.y, terrainOrigin.z))
	end
	
	local blocks = {}
	local totalBlocks = 0
	local skippedTerrain = 0
	
	-- Build a set of existing terrain block positions
	-- KEY FIX: Use RELATIVE grid coordinates (relative to terrain origin) consistently!
	local existingTerrainPositions = {}
	local terrainBlockCount = 0
	local missingBlockPosCount = 0
	
	-- Get children list once (more efficient than calling GetChildren in loop)
	local children = blocksFolder:GetChildren()
	
	for i, block in ipairs(children) do
		local blockPos
		local isFence = block:GetAttribute("IsFence")
		
		-- Get block position for grid calculation
		-- Use center position (Position/PrimaryPart.Position) for consistent grid mapping
		-- The loader will handle pivot offsets when recreating blocks
		-- EXCEPTION: Fences use pivot position since they have custom pivots
		local isGlass = block:GetAttribute("IsGlass")
		if block:IsA("BasePart") then
			if isFence then
				blockPos = block:GetPivot().Position
			elseif isGlass then
				-- Glass BasePart (Glass_3) has center pivot, use as-is
				blockPos = block:GetPivot().Position
			else
				blockPos = block.Position
			end
		elseif block:IsA("Model") then
			if isGlass then
				-- Glass Models: use pivot position directly (matches BlockHandler placement)
				blockPos = block:GetPivot().Position
			else
				local primaryPart = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
				if primaryPart then
					blockPos = primaryPart.Position
				end
			end
		end
		
		if blockPos then
			-- Track ALL terrain positions (not just surface)
			-- KEY FIX: Use RELATIVE grid coords (same as dug detection will use)
			-- IMPORTANT: Exclude IsLazyLoaded blocks (like PathBlocks) - they're modified blocks, not natural terrain
			if block:GetAttribute("IsTerrainBlock") and not block:GetAttribute("IsEdgeWall") and not block:GetAttribute("IsLazyLoaded") then
				local storedX = block:GetAttribute("BlockPosX")
				local storedY = block:GetAttribute("BlockPosY")
				local storedZ = block:GetAttribute("BlockPosZ")
				
				local relGridX, relGridY, relGridZ
				local usedStoredPos = false
				
				if storedX and storedY and storedZ and terrainOrigin then
					-- Use stored grid-aligned position, RELATIVE to terrain origin
					relGridX = math.round((storedX - terrainOrigin.x) / BLOCK_SIZE)
					relGridY = math.round((storedY - terrainOrigin.y) / BLOCK_SIZE)
					relGridZ = math.round((storedZ - terrainOrigin.z) / BLOCK_SIZE)
					usedStoredPos = true
				elseif terrainOrigin then
					-- Fallback: calculate from actual position, RELATIVE to terrain origin
					-- WARNING: For Models, actual position is offset from grid center!
					relGridX = math.round((blockPos.X - terrainOrigin.x) / BLOCK_SIZE)
					relGridY = math.round((blockPos.Y - terrainOrigin.y) / BLOCK_SIZE)
					relGridZ = math.round((blockPos.Z - terrainOrigin.z) / BLOCK_SIZE)
					missingBlockPosCount = missingBlockPosCount + 1
					
					-- Log first few missing BlockPos blocks for debugging
					if missingBlockPosCount <= 3 then
						print(string.format("[PlotSerializer] WARNING: Terrain block missing BlockPosX/Y/Z! actualPos=(%.2f,%.2f,%.2f) -> relGrid=(%d,%d,%d)",
							blockPos.X, blockPos.Y, blockPos.Z, relGridX, relGridY, relGridZ))
					end
				else
					-- No terrain origin, use absolute coords (fallback)
					relGridX = math.round(blockPos.X / BLOCK_SIZE)
					relGridY = math.round(blockPos.Y / BLOCK_SIZE)
					relGridZ = math.round(blockPos.Z / BLOCK_SIZE)
				end
				
				local key = relGridX .. "," .. relGridY .. "," .. relGridZ
				existingTerrainPositions[key] = true
				terrainBlockCount = terrainBlockCount + 1
				
				-- Log sample terrain positions (first 3 blocks)
				if terrainBlockCount <= 3 then
					print(string.format("[PlotSerializer] Sample terrain: relKey=%s storedPos=(%.2f,%.2f,%.2f) usedStored=%s",
						key, storedX or blockPos.X, storedY or blockPos.Y, storedZ or blockPos.Z, tostring(usedStoredPos)))
				end
			end
			
			local serialized = serializeBlock(block, blockPos, BLOCK_SIZE, terrainOrigin)
			if serialized then
				-- Summary logging at level 1+
				if isGlass and DEBUG_GLASS_LEVEL >= 1 then
					local connType = block:GetAttribute("GlassConnectionType") or "unknown"
					print(string.format("[Glass SAVE] type=%s pivotPos=(%.2f,%.2f,%.2f) -> grid=(%d,%d,%d)",
						connType, blockPos.X, blockPos.Y, blockPos.Z,
						(serialized :: {any})[1], (serialized :: {any})[2], (serialized :: {any})[3]))
				end
				table.insert(blocks, serialized)
				totalBlocks = totalBlocks + 1
			else
				if block:GetAttribute("IsTerrainBlock") then
					skippedTerrain = skippedTerrain + 1
				end
			end
		end
		
		-- Yield periodically to prevent timeout (every 100 blocks)
		if not noYield and i % 100 == 0 then
			task.wait()
		end
	end
	
	print(string.format("[PlotSerializer] Found %d terrain blocks (%d missing BlockPos attrs)", terrainBlockCount, missingBlockPosCount))
	
	-- Calculate expected surface blocks for validation
	local expectedSurfaceBlocks = 0
	if sizeX and sizeZ then
		expectedSurfaceBlocks = (math.floor(sizeX / BLOCK_SIZE)) * (math.floor(sizeZ / BLOCK_SIZE))
	end
	
	-- SAFEGUARD 1: Skip dug detection if terrain generation is in progress
	-- This prevents corruption when auto-save triggers during terrain regeneration
	local generationInProgress = buildArea:GetAttribute("TerrainGenerationInProgress") == true
	if generationInProgress then
		warn("[PlotSerializer] SAFEGUARD: Terrain generation in progress - skipping dug detection to prevent corruption!")
	end
	
	-- SAFEGUARD 2: If terrain block count is suspiciously low, skip dug detection entirely
	-- This prevents corruption when saving during terrain regeneration
	local minExpectedTerrain = expectedSurfaceBlocks * 0.5 -- At least 50% of terrain should exist
	local terrainCountTooLow = terrainBlockCount < minExpectedTerrain and expectedSurfaceBlocks > 100
	
	if terrainCountTooLow then
		warn(string.format("[PlotSerializer] SAFEGUARD: Only found %d terrain blocks (expected ~%d). Terrain may be regenerating - skipping dug detection to prevent corruption!",
			terrainBlockCount, expectedSurfaceBlocks))
	end
	
	local skipDugDetection = generationInProgress or terrainCountTooLow
	
	-- Calculate which SURFACE terrain positions are MISSING (dug out)
	-- Underground blocks are now saved as regular blocks (lazy-loaded), so we don't track those
	-- NOTE: Dug positions are saved as RELATIVE grid coords (same as blocks) for plot portability
	local dugPositions = {}
	local terrainStyle = buildArea:GetAttribute("TerrainStyle") or "Flat"
	local isFlatTerrain = (terrainStyle == "Flat")
	
	-- Only detect dug positions if we have enough terrain to be reliable
	if not skipDugDetection and terrainSurfaceY and posX and posZ and sizeX and sizeZ and terrainOrigin then
		-- IMPORTANT: Use stored grid dimensions from TerrainGenerator to prevent floating-point mismatches
		-- This fixes the "missing stripe" bug where recalculating gridSize could yield different results
		local gridSizeX = buildArea:GetAttribute("TerrainGridSizeX") or math.floor(sizeX / BLOCK_SIZE)
		local gridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ") or math.floor(sizeZ / BLOCK_SIZE)
		
		print(string.format("[PlotSerializer] Checking for dug positions: gridSize=%dx%d, flat=%s", 
			gridSizeX, gridSizeZ, tostring(isFlatTerrain)))
		
		-- For Natural terrain, we need the height map to know expected surface Y at each position
		local heightMap = nil
		if not isFlatTerrain then
			local heightMapStr: string? = buildArea:GetAttribute("TerrainHeightMap")
			local storedGridSizeX = buildArea:GetAttribute("TerrainGridSizeX")
			local storedGridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ")
			
			if heightMapStr and storedGridSizeX and storedGridSizeZ then
				-- Parse height map string into 2D array
				local heights = string.split(heightMapStr, ",")
				heightMap = {}
				for gx = 0, storedGridSizeX - 1 do
					heightMap[gx] = {}
					for gz = 0, storedGridSizeZ - 1 do
						local index = gx * storedGridSizeZ + gz + 1
						heightMap[gx][gz] = tonumber(heights[index]) or 0
					end
				end
				print(string.format("[PlotSerializer] Loaded height map for Natural terrain (%dx%d)", storedGridSizeX, storedGridSizeZ))
			end
		end
		
		-- Only check surface layer - underground is handled by lazy-loaded block saves
		-- KEY FIX: Use RELATIVE grid coords consistently (gx, relGridY, gz)
		for gx = 0, gridSizeX - 1 do
			for gz = 0, gridSizeZ - 1 do
				-- Calculate expected surface Y for this position
				local expectedSurfaceY: number = 0
				if isFlatTerrain then
					-- Flat terrain: all surface blocks at terrainSurfaceY
					expectedSurfaceY = terrainSurfaceY
				else
					-- Natural terrain: surface varies based on height map
					if heightMap and heightMap[gx] and heightMap[gx][gz] then
						local heightOffset = heightMap[gx][gz]
						expectedSurfaceY = terrainSurfaceY + (heightOffset * BLOCK_SIZE)
					else
						-- No height map data, skip this position
						continue
					end
				end
				
				-- Calculate RELATIVE grid Y (same coordinate system as terrain lookup)
				local relGridY = math.round((expectedSurfaceY - terrainOrigin.y) / BLOCK_SIZE)
				
				-- Check if surface terrain block is missing at the expected RELATIVE position
				local surfaceKey = gx .. "," .. relGridY .. "," .. gz
				if not existingTerrainPositions[surfaceKey] then
					-- Surface is dug - record as RELATIVE grid coords
					table.insert(dugPositions, {gx, relGridY, gz})
					
					-- Log first few dug positions for debugging
					if #dugPositions <= 5 then
						print(string.format("[PlotSerializer] Dug detected: relKey=%s NOT FOUND (expectedSurfaceY=%.2f)", 
							surfaceKey, expectedSurfaceY))
					end
				end
			end
			
			-- Yield periodically for large plots
			if not noYield and gx % 10 == 0 then
				task.wait()
			end
		end
	end
	
	-- Build type registry for save data
	local typeRegistry = {}
	for typeName, id in pairs(TypeToId) do
		typeRegistry[id] = typeName
	end
	
	local saveData = {
		version = PlotSerializer.VERSION,
		biome = buildArea:GetAttribute("CurrentBiome") or "Plains",
		season = buildArea:GetAttribute("CurrentSeason") or "Summer",  -- Save season for grass/leaf coloring
		terrainStyle = buildArea:GetAttribute("TerrainStyle") or "Flat",
		terrainSeed = buildArea:GetAttribute("TerrainSeed"),  -- Save terrain seed for consistent regeneration
		terrainHeightMap = buildArea:GetAttribute("TerrainHeightMap"),  -- Save height map for exact Natural terrain restoration
		terrainGridSizeX = buildArea:GetAttribute("TerrainGridSizeX"),
		terrainGridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ"),
		terrainMinHeight = buildArea:GetAttribute("TerrainMinHeight"),
		terrainMaxHeight = buildArea:GetAttribute("TerrainMaxHeight"),
		terrainStartX = buildArea:GetAttribute("TerrainStartX"),
		terrainStartZ = buildArea:GetAttribute("TerrainStartZ"),
		weather = buildArea:GetAttribute("CurrentWeather") or "Clear",  -- Save weather type
		weatherIntensity = buildArea:GetAttribute("WeatherIntensity") or "Normal",  -- Save weather intensity
		lifetimeBlocksPlaced = buildArea:GetAttribute("LifetimeBlocksPlaced") or 0,  -- Total blocks ever placed (for beta qualification)
		types = typeRegistry,
		blocks = blocks,
		dug = dugPositions,
		origin = terrainOrigin,  -- Save terrain origin for accurate position reconstruction
	}
	
	-- Calculate expected surface blocks
	local expectedSurfaceBlocks = (math.floor(sizeX / BLOCK_SIZE)) * (math.floor(sizeZ / BLOCK_SIZE))
	
	print(string.format("[PlotSerializer] Serialized %d blocks, %d dug positions (skipped %d terrain, found %d terrain blocks)", 
		totalBlocks, #dugPositions, skippedTerrain, terrainBlockCount))
	
	-- STRIP PATTERN DETECTION: Check if an entire row or column is falsely marked as dug
	-- This catches the edge strip bug at save time to prevent corrupting save data
	if #dugPositions > 0 then
		local gridSizeX = buildArea:GetAttribute("TerrainGridSizeX") or math.floor(sizeX / BLOCK_SIZE)
		local gridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ") or math.floor(sizeZ / BLOCK_SIZE)
		
		-- Count dug positions per row (gx) and per column (gz)
		local rowCounts = {}  -- gx -> count
		local colCounts = {}  -- gz -> count
		for _, pos in ipairs(dugPositions) do
			local gx, gz = pos[1], pos[3]
			rowCounts[gx] = (rowCounts[gx] or 0) + 1
			colCounts[gz] = (colCounts[gz] or 0) + 1
		end
		
		-- Detect strips: if an entire row or column is "dug", it's almost certainly a bug
		local stripRows = {}
		local stripCols = {}
		for gx, count in pairs(rowCounts) do
			if count >= gridSizeZ then
				table.insert(stripRows, gx)
			end
		end
		for gz, count in pairs(colCounts) do
			if count >= gridSizeX then
				table.insert(stripCols, gz)
			end
		end
		
		if #stripRows > 0 or #stripCols > 0 then
			warn(string.format("[PlotSerializer] STRIP PATTERN DETECTED: %d full rows, %d full columns falsely marked as dug!",
				#stripRows, #stripCols))
			if #stripRows > 0 then
				warn(string.format("[PlotSerializer] Strip rows (gx): %s", table.concat(stripRows, ", ")))
			end
			if #stripCols > 0 then
				warn(string.format("[PlotSerializer] Strip columns (gz): %s", table.concat(stripCols, ", ")))
			end
			
			-- Remove strip positions from dug list to prevent corruption
			local stripRowSet = {}
			local stripColSet = {}
			for _, gx in ipairs(stripRows) do stripRowSet[gx] = true end
			for _, gz in ipairs(stripCols) do stripColSet[gz] = true end
			
			local filteredDug = {}
			for _, pos in ipairs(dugPositions) do
				if not stripRowSet[pos[1]] and not stripColSet[pos[3]] then
					table.insert(filteredDug, pos)
				end
			end
			
			local removed = #dugPositions - #filteredDug
			warn(string.format("[PlotSerializer] Removed %d false dug positions from strip pattern", removed))
			dugPositions = filteredDug
			saveData.dug = dugPositions
		end
	end
	
	-- Warning if lots of dug positions detected
	if #dugPositions > expectedSurfaceBlocks * 0.5 then
		warn(string.format("[PlotSerializer] WARNING: Detected %d dug positions out of %d expected surface blocks (%.1f%%) - this seems too high!",
			#dugPositions, expectedSurfaceBlocks, (#dugPositions / expectedSurfaceBlocks) * 100))
		warn(string.format("[PlotSerializer] This likely indicates a coordinate system mismatch - check debug output above"))
	end
	
	return saveData, nil
end

-- Deserialize save data back to block list
function PlotSerializer.DeserializePlot(saveData)
	if not saveData then
		return nil, "No save data"
	end
	
	-- Check version compatibility
	if saveData.version > PlotSerializer.VERSION then
		return nil, "Save data version too new: " .. saveData.version
	end
	
	local typeRegistry = saveData.types or {}
	local blocks = {}
	
	for _, blockData in ipairs(saveData.blocks or {}) do
		local gridX = blockData[1]
		local gridY = blockData[2]
		local gridZ = blockData[3]
		local typeId = blockData[4]
		local rotation = blockData[5] or 0
		local extra = blockData[6]
		
		local blockType = typeRegistry[typeId]
		if not blockType then
			warn("[PlotSerializer] Unknown type ID: " .. tostring(typeId))
			continue
		end
		
		local attributes = deserializeExtraData(extra)
		attributes.Rotation = rotation
		
		table.insert(blocks, {
			gridX = gridX,
			gridY = gridY,
			gridZ = gridZ,
			blockType = blockType,
			attributes = attributes,
		})
	end
	
	-- Parse dug positions (now includes all depths)
	local dugPositions = {}
	for _, pos in ipairs(saveData.dug or {}) do
		table.insert(dugPositions, {
			gridX = pos[1],
			gridY = pos[2],
			gridZ = pos[3],
		})
	end
	
	print(string.format("[PlotSerializer] Deserialized %d blocks, %d dug positions", #blocks, #dugPositions))
	
	return {
		biome = saveData.biome or "Plains",
		season = saveData.season or "Summer",  -- Pass season for grass/leaf coloring
		terrainStyle = saveData.terrainStyle or "Flat",
		terrainSeed = saveData.terrainSeed,  -- Pass seed for consistent terrain regeneration
		terrainHeightMap = saveData.terrainHeightMap,  -- Height map for exact Natural terrain restoration
		terrainGridSizeX = saveData.terrainGridSizeX,
		terrainGridSizeZ = saveData.terrainGridSizeZ,
		terrainMinHeight = saveData.terrainMinHeight,
		terrainMaxHeight = saveData.terrainMaxHeight,
		terrainStartX = saveData.terrainStartX,
		terrainStartZ = saveData.terrainStartZ,
		weather = saveData.weather or "Clear",  -- Pass weather type
		weatherIntensity = saveData.weatherIntensity or "Normal",  -- Pass weather intensity
		lifetimeBlocksPlaced = saveData.lifetimeBlocksPlaced or 0,  -- Total blocks ever placed
		blocks = blocks,
		dugPositions = dugPositions,
		origin = saveData.origin,  -- Pass origin to loader for accurate position reconstruction
	}, nil
end

-- Estimate save data size
function PlotSerializer.EstimateSize(saveData)
	local json = game:GetService("HttpService"):JSONEncode(saveData)
	return #json
end

-- Maximum DataStore value size (4MB, but use 3.5MB to be safe)
PlotSerializer.MAX_SIZE = 3500000

return PlotSerializer
