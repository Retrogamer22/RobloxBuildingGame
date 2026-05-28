--[[
	SaplingHandler
	Tracks planted saplings and grows them into trees after a delay
	
	Saplings grow into their corresponding tree type:
	- OakSapling -> Oak tree
	- SpruceSapling -> Spruce tree
	- BirchSapling -> Birch tree
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Wait for TreeGenerator module
local TreeGenerator = nil
local LeafDecayManager = nil

task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local treeModule = modulesFolder:WaitForChild("TreeGenerator", 10)
		if treeModule then
			TreeGenerator = require(treeModule)
			print("[SaplingHandler] TreeGenerator loaded")
		else
			warn("[SaplingHandler] TreeGenerator module not found!")
		end

		-- Also load LeafDecayManager for tree decay support
		local leafDecayModule = modulesFolder:WaitForChild("LeafDecayManager", 10)
		if leafDecayModule then
			LeafDecayManager = require(leafDecayModule)
			print("[SaplingHandler] LeafDecayManager loaded")
		else
			warn("[SaplingHandler] LeafDecayManager module not found!")
		end
	end
end)

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Configuration
local GROWTH_TIME = 10 -- Seconds until sapling grows into tree (reduced from 60 for testing)
local GROWTH_CHECK_INTERVAL = 1 -- How often to check for growth (seconds)

-- Map sapling types to tree types
local SAPLING_TO_TREE = {
	["OakSapling"] = "Oak",
	["SpruceSapling"] = "Spruce",
	["BirchSapling"] = "Birch",
	["AcaciaSapling"] = "Acacia",
	["DarkOakSapling"] = "DarkOak",
	["EbonySapling"] = "Ebony",
	["RedwoodSapling"] = "Redwood",
	-- Candy reward sapling (Step 5). Grows into a J-shape candy cane structure
	-- via a custom path — NOT through TreeGenerator/TreeStructures, since candy
	-- canes are programmatically generated (random height/curl) and use different
	-- block types (CandyCaneLog + CandyCaneFull) than normal trees.
	["CandyCaneSapling"] = "CandyCane",
}

-- Candy cane growth config. All saplings grow into a J-shape with random:
--   * Height (pole length, 3-8 blocks)
--   * Curl direction (left or right of the pole, on a random axis)
--   * Color (one of these 7 candy-flavor colors, same for every block in the cane).
-- The flavor is rolled at PLACEMENT time and stored on the sapling as the
-- "CandyCaneFlavor" attribute, so the sapling itself shows the color it'll
-- grow into. growCandyCane reads the attribute back to ensure the grown cane
-- matches the sapling's color.
local CANDY_PALETTE = {
	{ name = "White",  color = Color3.fromRGB(255, 255, 255) },
	{ name = "Red",    color = Color3.fromRGB(240, 30, 50) },
	{ name = "Green",  color = Color3.fromRGB(50, 200, 70) },
	{ name = "Pink",   color = Color3.fromRGB(255, 110, 185) },
	{ name = "Purple", color = Color3.fromRGB(165, 70, 230) },
	{ name = "Orange", color = Color3.fromRGB(255, 130, 25) },
	{ name = "Yellow", color = Color3.fromRGB(255, 220, 40) },
}

-- Find a palette entry by flavor name. Returns nil if not found.
local function getCandyFlavor(name)
	for _, f in ipairs(CANDY_PALETTE) do
		if f.name == name then return f end
	end
	return nil
end

-- Apply a candy color to a sapling. If the sapling already has a saved
-- CandyCaneFlavor attribute (from a previous placement or a save reload),
-- re-applies that color; otherwise rolls a fresh random flavor, saves it,
-- and applies. Either way the sapling ends up tinted to its grow-color.
local function tintCandyCaneSapling(sapling)
	if not sapling then return end
	local flavor = getCandyFlavor(sapling:GetAttribute("CandyCaneFlavor"))
	if not flavor then
		flavor = CANDY_PALETTE[math.random(1, #CANDY_PALETTE)]
		sapling:SetAttribute("CandyCaneFlavor", flavor.name)
	end
	local color = flavor.color
	-- The sapling is built like the canes: white "Stripes" over colored
	-- "Background" geometry. Only tint the Background parts (and any Texture/
	-- Decal/SurfaceAppearance on them) so the stripes stay white, matching how
	-- the grown cane will look.
	local function paint(inst)
		if inst:IsA("BasePart") then
			if inst.Name == "Background" then
				inst.Color = color
			end
		elseif inst:IsA("Texture") or inst:IsA("Decal") then
			if inst.Parent and inst.Parent.Name == "Background" then
				inst.Color3 = color
			end
		elseif inst:IsA("SurfaceAppearance") then
			if inst.Parent and inst.Parent.Name == "Background" then
				inst.Color = color
			end
		end
	end
	paint(sapling)
	for _, desc in ipairs(sapling:GetDescendants()) do
		paint(desc)
	end
end

-- Saplings that require 2x2 formation to grow (large trees)
local REQUIRES_2X2 = {
	["RedwoodSapling"] = true,
	["DarkOakSapling"] = true,
}

-- Track all planted saplings: { [sapling] = { plantedTime = tick(), treeType = "Oak", ... } }
local plantedSaplings = {}

-- Debug flag
local DEBUG_SAPLINGS = false

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getSaplingPosition(sapling)
	if sapling:IsA("BasePart") then
		return sapling.Position
	elseif sapling:IsA("Model") then
		local pivot = sapling:GetPivot()
		return pivot.Position
	end
	return nil
end

-- Find a sapling of the same type at a specific world position
local function findSaplingAt(blocksFolder, saplingType, worldX, worldZ, baseY)
	local tolerance = BLOCK_SIZE * 0.7 -- Generous tolerance for position matching

	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")
		if blockType == saplingType then
			local pos = getSaplingPosition(block)
			if pos then
				if math.abs(pos.X - worldX) < tolerance and 
					math.abs(pos.Z - worldZ) < tolerance and
					math.abs(pos.Y - baseY) < BLOCK_SIZE then
					return block
				end
			end
		end
	end
	return nil
end

-- Check if this sapling is part of a complete 2x2 formation
-- Returns: isComplete, allSaplings (array of 4 saplings if complete), centerPosition
local function check2x2Formation(sapling, blocksFolder, buildArea)
	local saplingType = sapling:GetAttribute("BlockType")

	-- Use ParentBlock position for accurate grid alignment
	local parentX = sapling:GetAttribute("ParentBlockX")
	local parentY = sapling:GetAttribute("ParentBlockY")
	local parentZ = sapling:GetAttribute("ParentBlockZ")

	if not (parentX and parentY and parentZ) then
		-- Fallback to sapling position if no parent block data
		local pos = getSaplingPosition(sapling)
		if not pos then return false, nil, nil end
		parentX, parentY, parentZ = pos.X, pos.Y - BLOCK_SIZE, pos.Z
	end

	-- Calculate terrain origin for proper grid snapping
	local originX, originZ = 0, 0
	if buildArea then
		local posX = buildArea:GetAttribute("BasePlatePositionX")
		local posZ = buildArea:GetAttribute("BasePlatePositionZ")
		local sizeX = buildArea:GetAttribute("BasePlateSizeX")
		local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")

		if posX and posZ and sizeX and sizeZ then
			originX = posX - sizeX / 2 + BLOCK_SIZE / 2
			originZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2
		end
	end

	-- Convert parent block position to grid coordinates relative to terrain origin
	local gridX = math.round((parentX - originX) / BLOCK_SIZE)
	local gridZ = math.round((parentZ - originZ) / BLOCK_SIZE)

	print(string.format("[SaplingHandler] 2x2 check: sapling parent at grid (%d, %d), origin (%.1f, %.1f)", 
		gridX, gridZ, originX, originZ))

	-- Check all 4 possible 2x2 arrangements this sapling could be part of
	-- (this sapling could be in any corner of the 2x2)
	local offsets = {
		{{0, 0}, {1, 0}, {0, 1}, {1, 1}},   -- This sapling is bottom-left
		{{-1, 0}, {0, 0}, {-1, 1}, {0, 1}}, -- This sapling is bottom-right
		{{0, -1}, {1, -1}, {0, 0}, {1, 0}}, -- This sapling is top-left
		{{-1, -1}, {0, -1}, {-1, 0}, {0, 0}}, -- This sapling is top-right
	}

	for arrangementIndex, arrangement in ipairs(offsets) do
		local allFound = true
		local saplings = {}
		local minGridX, minGridZ = math.huge, math.huge

		for _, offset in ipairs(arrangement) do
			local checkGridX = gridX + offset[1]
			local checkGridZ = gridZ + offset[2]

			-- Track min position for center calculation
			minGridX = math.min(minGridX, checkGridX)
			minGridZ = math.min(minGridZ, checkGridZ)

			-- Convert grid position back to world position
			local worldX = originX + checkGridX * BLOCK_SIZE
			local worldZ = originZ + checkGridZ * BLOCK_SIZE

			-- Check if this is the original sapling
			if offset[1] == 0 and offset[2] == 0 then
				table.insert(saplings, sapling)
			else
				local foundSapling = findSaplingAt(blocksFolder, saplingType, worldX, worldZ, parentY + BLOCK_SIZE)
				if foundSapling then
					table.insert(saplings, foundSapling)
				else
					allFound = false
					break
				end
			end
		end

		if allFound and #saplings == 4 then
			-- Use bottom-left corner position (grid-aligned) as tree base
			-- BUT: The tree structure has its 2x2 trunk at offsets (-3,-3), (0,-3), (-3,0), (0,0)
			-- So we need to offset by +BLOCK_SIZE to align the trunk with the sapling positions
			local cornerX = originX + (minGridX + 1) * BLOCK_SIZE  -- +1 block offset to compensate for structure
			local cornerZ = originZ + (minGridZ + 1) * BLOCK_SIZE  -- +1 block offset to compensate for structure
			-- Y: tree base goes half a block above parent block center (tested value)
			local cornerY = parentY + BLOCK_SIZE / 2
			local cornerPos = Vector3.new(cornerX, cornerY, cornerZ)

			print(string.format("[SaplingHandler] 2x2 COMPLETE with arrangement %d! Base: (%.1f, %.1f, %.1f) for grid (%d,%d)",
				arrangementIndex, cornerX, cornerY, cornerZ, minGridX, minGridZ))

			return true, saplings, cornerPos
		end
	end

	print("[SaplingHandler] 2x2 formation NOT complete")
	return false, nil, nil
end

local function getBlocksFolder(sapling)
	-- Saplings are placed in BuildArea/Blocks folder
	local parent = sapling.Parent
	if parent and parent.Name == "Blocks" then
		return parent
	end
	return nil
end

local function getBuildArea(sapling)
	local blocksFolder = getBlocksFolder(sapling)
	if blocksFolder then
		return blocksFolder.Parent
	end
	return nil
end

-- Build a fast spatial lookup set from all existing blocks in a folder
-- Returns a table where keys are snapped position strings for O(1) lookups
local function buildBlockPositionSet(blocksFolder)
	local posSet = {}
	local snapSize = BLOCK_SIZE * 0.5 -- Snap to half-block grid for reliable matching

	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockPos
		if block:IsA("BasePart") then
			blockPos = block.Position
		elseif block:IsA("Model") then
			local storedX = block:GetAttribute("BlockPosX")
			local storedY = block:GetAttribute("BlockPosY")
			local storedZ = block:GetAttribute("BlockPosZ")

			if storedX and storedY and storedZ then
				blockPos = Vector3.new(storedX, storedY, storedZ)
			else
				local primary = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
				if primary then
					blockPos = primary.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
				end
			end
		end

		if blockPos then
			-- Snap to grid for consistent key generation
			local key = string.format("%d,%d,%d",
				math.round(blockPos.X / snapSize),
				math.round(blockPos.Y / snapSize),
				math.round(blockPos.Z / snapSize))
			posSet[key] = true
		end
	end

	return posSet
end

-- Check if there's already a block at the given position using a pre-built position set
local function hasBlockAtPositionFast(position, posSet)
	local snapSize = BLOCK_SIZE * 0.5
	local key = string.format("%d,%d,%d",
		math.round(position.X / snapSize),
		math.round(position.Y / snapSize),
		math.round(position.Z / snapSize))
	return posSet[key] == true
end

-- ============================================
-- CANDY CANE GROWTH (Step 5)
-- ============================================
-- Bespoke path for candy cane saplings. We DON'T go through TreeGenerator/
-- TreeStructures because:
--   * Candy canes are programmatically generated (random height + curl), not
--     authored as fixed structures.
--   * They use two block types (CandyCaneLog + CandyCaneFull) that aren't in
--     the normal Blocks folder — they're variant presets in the Candy reward
--     set, with stripe colors tinted via Texture-mode.
--   * The pole's horizontal-curl piece needs a non-Y log axis, which would
--     require special structure character support.

-- Locate the Candy reward set folder once, cached for reuse.
local CandyBlocksFolder = nil
local function getCandyBlocksFolder()
	if CandyBlocksFolder and CandyBlocksFolder.Parent then return CandyBlocksFolder end
	local rewardSets = ReplicatedStorage:FindFirstChild("RewardSets")
	CandyBlocksFolder = rewardSets and rewardSets:FindFirstChild("CandyBlocks") or nil
	return CandyBlocksFolder
end

-- Clone the given template (CandyCaneLog or CandyCaneFull) from the Candy set,
-- tint its Texture descendants and any Part named "Core" to the variant color,
-- and return the new block. Mirrors BlockHandler's Texture-mode tinting branch.
local function buildCandyBlock(templateName, color)
	local folder = getCandyBlocksFolder()
	if not folder then
		warn("[SaplingHandler] CandyBlocks folder not found in ReplicatedStorage.RewardSets")
		return nil
	end
	local template = folder:FindFirstChild(templateName)
	if not template then
		warn("[SaplingHandler] Template missing in CandyBlocks: " .. templateName)
		return nil
	end
	
	local block = template:Clone()
	
	-- Anchor everything and tint stripes + Core to the chosen color.
	local function tintAndAnchor(part)
		if part:IsA("BasePart") then
			part.Anchored = true
			if part.Name == "Core" then
				part.Color = color
			end
		end
	end
	if block:IsA("BasePart") then
		tintAndAnchor(block)
		for _, child in ipairs(block:GetChildren()) do
			if child:IsA("Texture") or child:IsA("Decal") then
				child.Color3 = color
			end
		end
	elseif block:IsA("Model") then
		for _, desc in ipairs(block:GetDescendants()) do
			tintAndAnchor(desc)
			if desc:IsA("Texture") or desc:IsA("Decal") then
				desc.Color3 = color
			end
		end
	end
	
	return block
end

-- Compute the offset from a model's pivot to its visual bounding-box center,
-- in the model's LOCAL frame. We use this so we can place bottom-pivoted (or
-- otherwise off-center-pivoted) models such that their visual center ends up
-- exactly at the desired world position — even if the model author put the
-- pivot somewhere weird relative to the geometry. Rotates correctly with the
-- model too, since it's a local-space offset.
local function computeModelCenterOffset(model)
	if not model or not model:IsA("Model") then
		return Vector3.new(0, BLOCK_SIZE / 2, 0) -- fallback: assume bottom-pivot
	end
	local pivot = model:GetPivot()
	local bbCframe = model:GetBoundingBox()
	-- bbCframe.Position is the bb center in world space (with model in its
	-- natural pose). PointToObjectSpace converts it to the pivot's local frame.
	return pivot:PointToObjectSpace(bbCframe.Position)
end

-- One-time cache for the candy log's center-vs-pivot offset. Resolved on first
-- candy growth (templates aren't guaranteed to exist at script load).
local candyLogCenterOffsetCache = nil
local function getCandyLogCenterOffset()
	if candyLogCenterOffsetCache then return candyLogCenterOffsetCache end
	local folder = getCandyBlocksFolder()
	local template = folder and folder:FindFirstChild("CandyCaneLog")
	candyLogCenterOffsetCache = computeModelCenterOffset(template)
	print(string.format("[SaplingHandler] CandyCaneLog center-vs-pivot offset: (%.2f, %.2f, %.2f)",
		candyLogCenterOffsetCache.X, candyLogCenterOffsetCache.Y, candyLogCenterOffsetCache.Z))
	return candyLogCenterOffsetCache
end

-- Place a candy block at the given world position with optional log axis.
-- logAxis: "X", "Y", or "Z" — only meaningful for CandyCaneLog. Horizontal logs
-- in the curl get "X" or "Z"; the vertical pole gets "Y" (default).
local function placeCandyBlock(templateName, variantId, color, position, logAxis, blocksFolder, placedBy)
	local block = buildCandyBlock(templateName, color)
	if not block then return nil end
	
	block.Name = variantId .. "_" .. math.random(100000, 999999)
	
	-- Candy templates use TWO different pivot conventions, and we have to
	-- account for both to get the J-shape's pieces flush with each other:
	--
	--   * CandyCaneLog (Model) is BOTTOM-PIVOTED. Its pivot sits at the bottom
	--     face of the visual cylinder. For vertical placement we drop the pivot
	--     half a block below the target so the model extends UP to be centered.
	--     For HORIZONTAL placement the rotation re-orients which way "up" points
	--     in world space, so the half-block offset must align with the rotated
	--     extend direction (±X or ±Z) instead of –Y.
	--
	--   * CandyCaneFull (BasePart Union) is CENTER-PIVOTED. Its CFrame sits at
	--     the visual center of the cube, so no offset is needed at all—just
	--     place the CFrame directly at the target position.
	local rotation = CFrame.new()
	if logAxis == "X" then
		rotation = CFrame.Angles(0, 0, math.rad(90))
	elseif logAxis == "Z" then
		rotation = CFrame.Angles(math.rad(90), 0, 0)
	end
	
	if block:IsA("BasePart") then
		-- Center-pivoted: CFrame = position centers the block on `position`.
		block.CFrame = CFrame.new(position) * rotation
	elseif block:IsA("Model") then
		-- Compute pivot position such that the model's visual bounding-box
		-- center ends up at world `position` after rotation. The local-space
		-- offset between pivot and visual center is constant for the template,
		-- so we cache it once and rotate it into world space here for each
		-- placement. This auto-adapts to whatever pivot the model was authored
		-- with — no hardcoded BLOCK_SIZE/2 assumptions, no magic floating fudge.
		local localCenterOffset = getCandyLogCenterOffset()
		local worldCenterOffset = rotation:VectorToWorldSpace(localCenterOffset)
		block:PivotTo(CFrame.new(position - worldCenterOffset) * rotation)
	end
	
	-- Attributes that the save/load + spatial-index systems expect.
	block:SetAttribute("BlockType", variantId)
	block:SetAttribute("BlockPosX", position.X)
	block:SetAttribute("BlockPosY", position.Y)
	block:SetAttribute("BlockPosZ", position.Z)
	block:SetAttribute("PlacedBy", placedBy)
	block:SetAttribute("GrownFromSapling", true)
	block:SetAttribute("IsTreeBlock", true)
	if logAxis and templateName == "CandyCaneLog" then
		block:SetAttribute("LogAxis", logAxis)
	end
	
	block.Parent = blocksFolder
	return block
end

-- Grow a candy cane from the sapling's position. Returns true on success.
-- The structure (Option B from chat plan): a J-shape made of N+4 blocks.
--   * Vertical pole: N CandyCaneLog blocks (N = random 3-8), all CandyCaneLog
--     (including the base, which sits on the ground so its swirl is hidden).
--   * Top corner (pole-top + 1 in Y): CandyCaneFull — the bend where the pole
--     meets the curl. Full because the chain changes axis here.
--   * Horizontal middle: CandyCaneLog, oriented on the curl axis, placed 1
--     block in the curl direction. Log because both its ends are covered
--     (top corner on one side, right corner on the other).
--   * Right corner: CandyCaneFull, placed 1 block further in the curl direction
--     (= 2 blocks from the top corner). Covers the horizontal log's far end
--     AND the stub's top — without this, the log's swirl shows through and
--     the cane looks janky.
--   * Stub: CandyCaneFull, 1 block DOWN from the right corner. The tip of the
--     J: its bottom face is exposed (nothing below), so Full for stripes
--     on all faces.
-- Plan view of the curl (looking down at the top two layers, curl going +X):
--   Y=N:   F L F      <- top corner, horizontal log, right corner
--   Y=N-1: P . F      <- pole top, gap, stub
local function growCandyCane(sapling, treeBasePos, blocksFolder)
	local placedBy = sapling:GetAttribute("PlacedBy")
	
	-- The CandyCaneLog model's pivot is ~0.1 studs below its visual bottom face,
	-- so the cane sat half a block too low. Net offset: -1.6 + 1.5 = -0.1 keeps
	-- the pole base flush on grass.
	treeBasePos = treeBasePos - Vector3.new(0, 0.1, 0)
	
	-- Roll randomness
	local height = math.random(3, 8)
	-- Color: prefer the flavor that was already chosen when the sapling was
	-- planted (stored on the sapling so it visually matched the grow-color).
	-- Fall back to a fresh random roll if the attribute is missing.
	local flavor = getCandyFlavor(sapling:GetAttribute("CandyCaneFlavor"))
		 or CANDY_PALETTE[math.random(1, #CANDY_PALETTE)]
	local color = flavor.color
	local variantSuffix = "_" .. flavor.name
	-- Curl direction: random +X, -X, +Z, or -Z. The chosen axis is the curl axis;
	-- the horizontal-log gets LogAxis = that axis.
	local directions = {
		{ axis = "X", offset = Vector3.new(BLOCK_SIZE, 0, 0) },
		{ axis = "X", offset = Vector3.new(-BLOCK_SIZE, 0, 0) },
		{ axis = "Z", offset = Vector3.new(0, 0, BLOCK_SIZE) },
		{ axis = "Z", offset = Vector3.new(0, 0, -BLOCK_SIZE) },
	}
	local dir = directions[math.random(1, #directions)]
	
	print(string.format("[SaplingHandler] Growing candy cane: %s, height=%d, curlAxis=%s, curlDir=(%.0f,%.0f,%.0f)",
		flavor.name, height, dir.axis, dir.offset.X, dir.offset.Y, dir.offset.Z))
	
	local placedAny = false
	
	-- 1. Pole — N vertical CandyCaneLog blocks
	for i = 0, height - 1 do
		local pos = treeBasePos + Vector3.new(0, i * BLOCK_SIZE, 0)
		local blk = placeCandyBlock(
			"CandyCaneLog",
			"CandyCaneLog" .. variantSuffix,
			color, pos, "Y", blocksFolder, placedBy)
		if blk then placedAny = true end
	end
	
	-- 2. Top corner — CandyCaneFull at pole-top + 1 in Y
	local topCornerPos = treeBasePos + Vector3.new(0, height * BLOCK_SIZE, 0)
	placeCandyBlock(
		"CandyCaneFull",
		"CandyCaneFull" .. variantSuffix,
		color, topCornerPos, nil, blocksFolder, placedBy)
	
	-- 3. Horizontal middle — CandyCaneLog, oriented on curl axis, 1 block in
	--    the curl direction from the top corner. Both ends covered (by top
	--    corner and right corner) so the log's swirl stays hidden.
	local curlMidPos = topCornerPos + dir.offset
	placeCandyBlock(
		"CandyCaneLog",
		"CandyCaneLog" .. variantSuffix,
		color, curlMidPos, dir.axis, blocksFolder, placedBy)
	
	-- 4. Right corner — CandyCaneFull, 1 block further in the curl direction
	--    from the horizontal log. Covers the log's far end and sits above
	--    the stub.
	local rightCornerPos = curlMidPos + dir.offset
	placeCandyBlock(
		"CandyCaneFull",
		"CandyCaneFull" .. variantSuffix,
		color, rightCornerPos, nil, blocksFolder, placedBy)
	
	-- 5. Stub — CandyCaneFull, 1 block down from the right corner. This is
	--    the tip of the J: bottom face exposed, so Full for stripes-everywhere.
	local stubPos = rightCornerPos - Vector3.new(0, BLOCK_SIZE, 0)
	placeCandyBlock(
		"CandyCaneFull",
		"CandyCaneFull" .. variantSuffix,
		color, stubPos, nil, blocksFolder, placedBy)
	
	print("[SaplingHandler] Candy cane grown successfully")
	return placedAny
end

-- Grow a sapling into a tree
local function growSapling(sapling, data)
	print("[SaplingHandler] ========== GROW SAPLING CALLED ==========")

	if not TreeGenerator then
		warn("[SaplingHandler] Cannot grow sapling - TreeGenerator not loaded!")
		warn("[SaplingHandler] Check that ServerScriptService.Modules.TreeGenerator exists")
		return false
	end
	print("[SaplingHandler] TreeGenerator is loaded ✓")

	local blocksFolder = getBlocksFolder(sapling)
	if not blocksFolder then
		warn("[SaplingHandler] Cannot find blocks folder for sapling")
		warn("[SaplingHandler] Sapling parent: " .. tostring(sapling.Parent))
		return false
	end
	print("[SaplingHandler] Blocks folder found: " .. blocksFolder:GetFullName())

	local buildArea = getBuildArea(sapling)
	local saplingPos = getSaplingPosition(sapling)
	if not saplingPos then
		warn("[SaplingHandler] Could not get sapling position")
		return false
	end
	print(string.format("[SaplingHandler] Sapling position: (%.1f, %.1f, %.1f)", saplingPos.X, saplingPos.Y, saplingPos.Z))

	-- Get tree type from sapling
	local treeType = data.treeType
	if not treeType then
		warn("[SaplingHandler] No tree type for sapling")
		return false
	end
	print("[SaplingHandler] Tree type: " .. treeType)

	-- Check if this sapling requires 2x2 formation
	local blockType = sapling:GetAttribute("BlockType")
	local saplingsToRemove = {sapling}

	-- Get grid-aligned position for tree base
	-- Saplings are decorations - use ParentBlock attributes for accurate grid position
	local parentX = sapling:GetAttribute("ParentBlockX")
	local parentY = sapling:GetAttribute("ParentBlockY")
	local parentZ = sapling:GetAttribute("ParentBlockZ")

	local treeBasePos

	if parentX and parentY and parentZ then
		-- ParentBlock attributes record where the sapling was placed in WORLD
		-- coordinates, but that's not always the parent block's grid center —
		-- decorations can land at offset positions on top of a block, and the
		-- parent block itself may not be perfectly grid-aligned. Snap X/Z to
		-- the build area's grid so trees always grow centered on the cell they
		-- were planted on, regardless of where the sapling visually sits.
		local snappedX, snappedZ = parentX, parentZ
		if buildArea then
			local posX = buildArea:GetAttribute("BasePlatePositionX")
			local posZ = buildArea:GetAttribute("BasePlatePositionZ")
			local sizeX = buildArea:GetAttribute("BasePlateSizeX")
			local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
			if posX and posZ and sizeX and sizeZ then
				local originX = posX - sizeX / 2 + BLOCK_SIZE / 2
				local originZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2
				snappedX = originX + math.round((parentX - originX) / BLOCK_SIZE) * BLOCK_SIZE
				snappedZ = originZ + math.round((parentZ - originZ) / BLOCK_SIZE) * BLOCK_SIZE
			end
		end
		-- ParentBlock Y is the block CENTER; tree base Y goes one full block above.
		treeBasePos = Vector3.new(snappedX, parentY + BLOCK_SIZE, snappedZ)
		print(string.format("[SaplingHandler] ParentBlock (%.1f, %.1f, %.1f) snapped to (%.1f, _, %.1f) -> tree base: (%.1f, %.1f, %.1f)", 
			parentX, parentY, parentZ, snappedX, snappedZ, treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
	elseif buildArea then
		-- Fallback: snap current position to terrain grid
		local posX = buildArea:GetAttribute("BasePlatePositionX")
		local posZ = buildArea:GetAttribute("BasePlatePositionZ")
		local sizeX = buildArea:GetAttribute("BasePlateSizeX")
		local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")

		if posX and posZ and sizeX and sizeZ then
			-- Calculate terrain origin (same as TerrainGenerator/PlotSerializer)
			local originX = posX - sizeX / 2 + BLOCK_SIZE / 2
			local originZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2

			-- Snap to nearest grid position relative to terrain origin
			local gridIndexX = math.round((saplingPos.X - originX) / BLOCK_SIZE)
			local gridIndexZ = math.round((saplingPos.Z - originZ) / BLOCK_SIZE)

			local snappedX = originX + gridIndexX * BLOCK_SIZE
			local snappedZ = originZ + gridIndexZ * BLOCK_SIZE

			treeBasePos = Vector3.new(snappedX, saplingPos.Y, snappedZ)
			print(string.format("[SaplingHandler] Snapped to terrain grid: (%.1f, %.1f, %.1f) from origin (%.1f, %.1f)", 
				treeBasePos.X, treeBasePos.Y, treeBasePos.Z, originX, originZ))
		else
			-- Fallback if no build area attributes
			treeBasePos = Vector3.new(
				math.round(saplingPos.X / BLOCK_SIZE) * BLOCK_SIZE,
				saplingPos.Y,
				math.round(saplingPos.Z / BLOCK_SIZE) * BLOCK_SIZE
			)
			print(string.format("[SaplingHandler] Fallback snap: (%.1f, %.1f, %.1f)", treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
		end
	else
		-- No build area, basic snap
		treeBasePos = Vector3.new(
			math.round(saplingPos.X / BLOCK_SIZE) * BLOCK_SIZE,
			saplingPos.Y,
			math.round(saplingPos.Z / BLOCK_SIZE) * BLOCK_SIZE
		)
		print(string.format("[SaplingHandler] Basic snap (no buildArea): (%.1f, %.1f, %.1f)", treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
	end

	if REQUIRES_2X2[blockType] then
		print("[SaplingHandler] This sapling requires 2x2 formation...")
		local isComplete, allSaplings, centerPos = check2x2Formation(sapling, blocksFolder, buildArea)

		if not isComplete then
			print("[SaplingHandler] 2x2 formation not complete - need 4 saplings in a square")
			return false -- Will retry later
		end

		print(string.format("[SaplingHandler] 2x2 formation complete! Center at (%.1f, %.1f, %.1f)", 
			centerPos.X, centerPos.Y, centerPos.Z))

		saplingsToRemove = allSaplings
		treeBasePos = centerPos
	end

	print(string.format("[SaplingHandler] Tree base position: (%.1f, %.1f, %.1f)", treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
	
	-- CANDY CANE: bespoke path — doesn't go through TreeGenerator at all.
	if treeType == "CandyCane" then
		local placedBy = sapling:GetAttribute("PlacedBy")
		local ok = growCandyCane(sapling, treeBasePos, blocksFolder)
		if ok then
			-- Destroy the sapling on success.
			for _, sap in ipairs(saplingsToRemove) do
				plantedSaplings[sap] = nil
				sap:Destroy()
			end
			return true
		else
			warn("[SaplingHandler] Candy cane growth failed")
			return false
		end
	end

	-- Get biome and season from build area for leaf coloring
	local biomeName = buildArea and buildArea:GetAttribute("CurrentBiome") or nil
	local seasonName = buildArea and buildArea:GetAttribute("CurrentSeason") or nil
	print(string.format("[SaplingHandler] Biome: %s, Season: %s", tostring(biomeName), tostring(seasonName)))

	-- Get tree blocks using TreeGenerator
	-- Pass true for skipDistanceCheck since player saplings can grow near other trees
	print("[SaplingHandler] Calling TreeGenerator.GetTreeBlocks...")
	local treeBlocks = TreeGenerator.GetTreeBlocks(treeBasePos, treeType, blocksFolder, biomeName, seasonName, true)

	if not treeBlocks then
		warn(string.format("[SaplingHandler] TreeGenerator.GetTreeBlocks RETURNED NIL for %s at (%.1f, %.1f, %.1f)", 
			treeType, treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
		warn("[SaplingHandler] This usually means CanPlaceTree failed (out of plot bounds?)")
		return false
	end
	print(string.format("[SaplingHandler] TreeGenerator returned %d blocks", #treeBlocks))

	-- Store who planted the sapling for attribution
	local placedBy = sapling:GetAttribute("PlacedBy")

	-- Destroy all saplings (handles both single and 2x2)
	print(string.format("[SaplingHandler] Destroying %d sapling(s)...", #saplingsToRemove))
	for _, sap in ipairs(saplingsToRemove) do
		-- Remove from tracking
		plantedSaplings[sap] = nil
		sap:Destroy()
	end

	-- Build a fast spatial lookup of existing blocks ONCE (O(n) instead of O(n) per leaf)
	local existingBlockSet = buildBlockPositionSet(blocksFolder)

	-- Build a set of log positions from THIS tree for fast overlap checks
	local logPosSet = {}
	local snapSize = BLOCK_SIZE * 0.5
	for _, blockData in ipairs(treeBlocks) do
		if blockData.blockType == "L" then
			local key = string.format("%d,%d,%d",
				math.round(blockData.position.X / snapSize),
				math.round(blockData.position.Y / snapSize),
				math.round(blockData.position.Z / snapSize))
			logPosSet[key] = true
		end
	end

	-- Spawn the tree blocks (logs first, then leaves)
	local blocksCreated = 0
	local YIELD_EVERY = 10 -- Yield every N blocks to prevent frame freezes

	-- Create logs
	for _, blockData in ipairs(treeBlocks) do
		if blockData.blockType == "L" then
			local log = TreeGenerator.CreateLog(blockData.position, blocksFolder, blockData.treeType)
			if log then
				log:SetAttribute("PlacedBy", placedBy)
				log:SetAttribute("GrownFromSapling", true)
				blocksCreated = blocksCreated + 1
				if blocksCreated % YIELD_EVERY == 0 then
					task.wait()
				end
			end
		end
	end

	-- Create leaves
	for _, blockData in ipairs(treeBlocks) do
		if blockData.blockType == "l" then
			-- Skip if overlaps with logs from this tree (O(1) lookup)
			local key = string.format("%d,%d,%d",
				math.round(blockData.position.X / snapSize),
				math.round(blockData.position.Y / snapSize),
				math.round(blockData.position.Z / snapSize))
			if logPosSet[key] then
				continue
			end

			-- Skip if there's already a block at this position (O(1) lookup)
			if hasBlockAtPositionFast(blockData.position, existingBlockSet) then
				continue
			end

			local leaves = TreeGenerator.CreateLeaves(
				blockData.position, 
				blocksFolder, 
				blockData.treeType, 
				true, -- isGenerated = true, allows decay
				blockData.biomeName,
				blockData.seasonName
			)
			if leaves then
				leaves:SetAttribute("PlacedBy", placedBy)
				leaves:SetAttribute("GrownFromSapling", true)
				blocksCreated = blocksCreated + 1
				if blocksCreated % YIELD_EVERY == 0 then
					task.wait()
				end
			end
		end
	end

	print(string.format("[SaplingHandler] SUCCESS! Grew %s tree with %d blocks at (%.1f, %.1f, %.1f)", 
		treeType, blocksCreated, treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
	print("[SaplingHandler] ========================================")

	-- Initialize leaf decay for this build area so leaves can decay when logs are broken
	if LeafDecayManager and buildArea then
		LeafDecayManager.Initialize(buildArea)
	end

	return true
end

-- ============================================
-- PUBLIC API
-- ============================================

local SaplingHandler = {}

-- Scan a build area for existing saplings and register them
-- Called after plot is loaded from save
function SaplingHandler.ScanBuildAreaForSaplings(buildArea, restartTimers)
	if not buildArea then 
		warn("[SaplingHandler] ScanBuildAreaForSaplings: buildArea is nil")
		return 0 
	end

	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then 
		print("[SaplingHandler] ScanBuildAreaForSaplings: No Blocks folder in " .. buildArea.Name)
		return 0 
	end

	local registered = 0
	local totalBlocks = #blocksFolder:GetChildren()

	print(string.format("[SaplingHandler] Scanning %s for saplings (%d total blocks)...", buildArea.Name, totalBlocks))

	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")

		-- Check if it's a sapling by BlockType (primary method)
		local treeType = SAPLING_TO_TREE[blockType]

		-- Also check IsSapling attribute as fallback
		if not treeType and block:GetAttribute("IsSapling") then
			treeType = block:GetAttribute("TreeType")
		end

		if treeType then
			-- Skip if already tracked
			if plantedSaplings[block] then 
				print(string.format("[SaplingHandler] Skipping already-tracked sapling: %s", blockType or "unknown"))
				continue 
			end

			-- Mark as sapling if not already
			block:SetAttribute("IsSapling", true)
			block:SetAttribute("TreeType", treeType)
			
			-- Candy cane saplings: re-apply the visual color from their saved
			-- CandyCaneFlavor attribute. If no saved flavor (legacy save), rolls
			-- a new one and stores it.
			if blockType == "CandyCaneSapling" then
				tintCandyCaneSapling(block)
			end

			local startTime

			if restartTimers then
				-- Restart timer from scratch
				block:SetAttribute("PlantedTime", os.time())
				startTime = tick()

				print(string.format("[SaplingHandler] Registered loaded %s sapling, timer restarted (grows in %d seconds)", 
					blockType or "unknown", GROWTH_TIME))
			else
				-- Try to restore remaining time
				local plantedTime = block:GetAttribute("PlantedTime")
				if plantedTime then
					local age = os.time() - plantedTime
					local remainingTime = math.max(0, GROWTH_TIME - age)
					startTime = tick() - (GROWTH_TIME - remainingTime)

					print(string.format("[SaplingHandler] Restored sapling timer (grows in %.1f seconds)", remainingTime))
				else
					-- No planted time saved, restart timer
					block:SetAttribute("PlantedTime", os.time())
					startTime = tick()

					print(string.format("[SaplingHandler] Registered loaded sapling, no saved time (grows in %d seconds)", GROWTH_TIME))
				end
			end

			plantedSaplings[block] = {
				plantedTime = startTime,
				treeType = treeType,
			}

			registered = registered + 1
		end
	end

	if registered > 0 then
		print(string.format("[SaplingHandler] Scanned %s - found and registered %d saplings", buildArea.Name, registered))
	else
		print(string.format("[SaplingHandler] Scanned %s - no saplings found", buildArea.Name))
	end

	return registered
end

-- Register a newly planted sapling
function SaplingHandler.RegisterSapling(sapling)
	if not sapling then
		warn("[SaplingHandler] RegisterSapling called with nil sapling!")
		return
	end

	-- Check if already tracked
	if plantedSaplings[sapling] then
		if DEBUG_SAPLINGS then
			print("[SaplingHandler] Sapling already registered, skipping")
		end
		return
	end

	local blockType = sapling:GetAttribute("BlockType")
	local treeType = SAPLING_TO_TREE[blockType]

	if DEBUG_SAPLINGS then
		print(string.format("[SaplingHandler] RegisterSapling called - BlockType: %s, TreeType: %s", 
			tostring(blockType), tostring(treeType)))
	end

	if not treeType then
		if DEBUG_SAPLINGS then
			print("[SaplingHandler] Unknown sapling type: " .. tostring(blockType))
			print("[SaplingHandler] Valid types are: OakSapling, SpruceSapling, BirchSapling, AcaciaSapling, DarkOakSapling, EbonySapling, RedwoodSapling")
		end
		return
	end

	-- Mark as sapling
	sapling:SetAttribute("IsSapling", true)
	sapling:SetAttribute("TreeType", treeType)
	sapling:SetAttribute("PlantedTime", os.time())
	
	-- Candy cane saplings: roll a random flavor color and apply it visually.
	-- The flavor is stored on the sapling, so growCandyCane will pick the same
	-- color when growth happens — the visual sapling matches the grown cane.
	if blockType == "CandyCaneSapling" then
		tintCandyCaneSapling(sapling)
	end

	-- Track the sapling
	plantedSaplings[sapling] = {
		plantedTime = tick(),
		treeType = treeType,
	}

	-- Count total tracked
	local count = 0
	for _ in pairs(plantedSaplings) do
		count = count + 1
	end

	if DEBUG_SAPLINGS then
		local pos = getSaplingPosition(sapling)
		print(string.format("[SaplingHandler] SUCCESS! Registered %s sapling (grows %s tree) at (%.1f, %.1f, %.1f)", 
			blockType, treeType, pos and pos.X or 0, pos and pos.Y or 0, pos and pos.Z or 0))
		print(string.format("[SaplingHandler] Now tracking %d saplings total. Will grow in %d seconds.", 
			count, GROWTH_TIME))
	end
end

-- Unregister a sapling (when broken)
function SaplingHandler.UnregisterSapling(sapling)
	if plantedSaplings[sapling] then
		plantedSaplings[sapling] = nil
		if DEBUG_SAPLINGS then
			print("[SaplingHandler] Unregistered sapling")
		end
	end
end

-- Check if a block type is a sapling
function SaplingHandler.IsSapling(blockType)
	return SAPLING_TO_TREE[blockType] ~= nil
end

-- Get tree type for a sapling type
function SaplingHandler.GetTreeType(saplingType)
	return SAPLING_TO_TREE[saplingType]
end

-- ============================================
-- GROWTH LOOP
-- ============================================

local lastCheckTime = tick()
local lastDebugTime = tick()

RunService.Heartbeat:Connect(function()
	local currentTime = tick()

	-- Only check every GROWTH_CHECK_INTERVAL seconds
	if currentTime - lastCheckTime < GROWTH_CHECK_INTERVAL then
		return
	end
	lastCheckTime = currentTime

	-- Count tracked saplings for debug
	local saplingCount = 0
	for _ in pairs(plantedSaplings) do
		saplingCount = saplingCount + 1
	end

	-- Print debug status every 5 seconds (reduced for debugging)
	if DEBUG_SAPLINGS and currentTime - lastDebugTime >= 5 then
		lastDebugTime = currentTime
		print(string.format("[SaplingHandler] Tracking %d saplings", saplingCount))
		-- Also print details about tracked saplings
		for sap, sapData in pairs(plantedSaplings) do
			local age = currentTime - sapData.plantedTime
			local parentName = sap.Parent and sap.Parent.Name or "nil"
			print(string.format("[SaplingHandler]   - %s: age=%.1f/%d, parent=%s", sapData.treeType, age, GROWTH_TIME, parentName))
		end
	end

	-- Check each sapling for growth
	for sapling, data in pairs(plantedSaplings) do
		-- Check if sapling still exists
		if not sapling or not sapling.Parent then
			if DEBUG_SAPLINGS then
				print("[SaplingHandler] Removing destroyed sapling from tracking")
			end
			plantedSaplings[sapling] = nil
			continue
		end

		-- Check if enough time has passed
		local age = currentTime - data.plantedTime

		if DEBUG_SAPLINGS and saplingCount > 0 then
			-- Only print once per sapling per 10 seconds
			if currentTime - lastDebugTime < 1 then
				local pos = getSaplingPosition(sapling)
				print(string.format("[SaplingHandler] Sapling %s age: %.1f / %d seconds", 
					data.treeType, age, GROWTH_TIME))
			end
		end

		if age >= GROWTH_TIME then
			if DEBUG_SAPLINGS then
				print(string.format("[SaplingHandler] Sapling ready to grow! Type: %s, Age: %.1f", 
					data.treeType, age))
			end

			-- Try to grow the sapling
			local success = growSapling(sapling, data)

			if success then
				-- Remove from tracking (sapling was destroyed)
				plantedSaplings[sapling] = nil
			else
				-- Couldn't grow (no space?), reset timer to try again later
				if DEBUG_SAPLINGS then
					print("[SaplingHandler] Growth failed, will retry in 10 seconds")
				end
				data.plantedTime = currentTime - (GROWTH_TIME - 10) -- Try again in 10 seconds
			end
		end
	end
end)

-- ============================================
-- LISTEN FOR EXISTING SAPLINGS (on server restart)
-- ============================================

-- Scan all build areas for existing saplings
-- This runs on server restart to pick up any saplings that weren't tracked
-- NOTE: We wait longer to ensure saves have fully loaded
task.spawn(function()
	task.wait(10) -- Wait 10 seconds for game and saves to fully load

	local totalFound = 0

	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				local blockCount = #blocksFolder:GetChildren()

				for _, block in ipairs(blocksFolder:GetChildren()) do
					local blockType = block:GetAttribute("BlockType")
					local treeType = SAPLING_TO_TREE[blockType]

					-- Also check IsSapling attribute
					if not treeType and block:GetAttribute("IsSapling") then
						treeType = block:GetAttribute("TreeType")
					end

					if treeType then
						-- Skip if already tracked
						if plantedSaplings[block] then continue end

						local plantedTime = block:GetAttribute("PlantedTime")

						-- Calculate how much time has passed since planted
						local age = plantedTime and (os.time() - plantedTime) or 0
						local remainingTime = math.max(0, GROWTH_TIME - age)

						-- Mark attributes
						block:SetAttribute("IsSapling", true)
						block:SetAttribute("TreeType", treeType)
						if not plantedTime then
							block:SetAttribute("PlantedTime", os.time())
							remainingTime = GROWTH_TIME
						end
						
						-- Candy cane saplings: re-apply visual color from saved flavor.
						if blockType == "CandyCaneSapling" then
							tintCandyCaneSapling(block)
						end

						plantedSaplings[block] = {
							plantedTime = tick() - (GROWTH_TIME - remainingTime),
							treeType = treeType,
						}

						totalFound = totalFound + 1
					end
				end
			end
		end
	end

	-- Also scan MegaPlot build area (for private server MegaPlot mode)
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			local blocksFolder = megaBuildArea:FindFirstChild("Blocks")
			if blocksFolder then
				for _, block in ipairs(blocksFolder:GetChildren()) do
					local blockType = block:GetAttribute("BlockType")
					local treeType = SAPLING_TO_TREE[blockType]
					if not treeType and block:GetAttribute("IsSapling") then
						treeType = block:GetAttribute("TreeType")
					end
					if treeType and not plantedSaplings[block] then
						local plantedTime = block:GetAttribute("PlantedTime")
						local age = plantedTime and (os.time() - plantedTime) or 0
						local remainingTime = math.max(0, GROWTH_TIME - age)
						block:SetAttribute("IsSapling", true)
						block:SetAttribute("TreeType", treeType)
						if not plantedTime then
							block:SetAttribute("PlantedTime", os.time())
							remainingTime = GROWTH_TIME
						end
						if blockType == "CandyCaneSapling" then
							tintCandyCaneSapling(block)
						end
						plantedSaplings[block] = {
							plantedTime = tick() - (GROWTH_TIME - remainingTime),
							treeType = treeType,
						}
						totalFound = totalFound + 1
					end
				end
			end
		end
	end

end)

-- Make module accessible via _G and BindableFunction
_G.SaplingHandler = SaplingHandler

-- Create BindableFunction for reliable registration from other scripts
local RegisterSaplingBindable = Instance.new("BindableFunction")
RegisterSaplingBindable.Name = "RegisterSapling"
RegisterSaplingBindable.Parent = ReplicatedStorage
RegisterSaplingBindable.OnInvoke = function(sapling)
	if DEBUG_SAPLINGS then
		print("[SaplingHandler] RegisterSapling called via BindableFunction")
	end
	SaplingHandler.RegisterSapling(sapling)
	return true
end

return SaplingHandler
