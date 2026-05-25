--[[
	ColumnPlacement
	Handles dynamic column stacking: single, top, middle, bottom
	
	When columns are stacked vertically:
	- 1 block alone = ColumnSingle
	- Top of stack  = ColumnTop
	- Middle pieces = Column
	- Bottom piece  = ColumnBottom
	
	On place/remove, only the affected block and its immediate
	vertical neighbors (+Y, -Y) need updating.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ColumnPlacement = {}

local BLOCK_SIZE = 3

-- All 4 model names (must exist in Blocks folder)
ColumnPlacement.MODEL_NAMES = {
	Single = "ColumnSingle",
	Top    = "ColumnTop",
	Middle = "Column",
	Bottom = "ColumnBottom",
}

-- Spatial index for O(1) lookups
local BlockSpatialIndex = nil
local function getSpatialIndex(blocksFolder)
	if not BlockSpatialIndex then
		local mod = ReplicatedStorage:FindFirstChild("BlockSpatialIndex")
		if mod then
			BlockSpatialIndex = require(mod)
		end
	end
	if BlockSpatialIndex then
		return BlockSpatialIndex.GetOrCreate(blocksFolder)
	end
	return nil
end

-- ============================================
-- DETECTION
-- ============================================

function ColumnPlacement.IsColumn(blockType)
	if not blockType then return false end
	return blockType == "Column"
end

function ColumnPlacement.IsColumnInstance(block)
	if not block then return false end
	if block:GetAttribute("IsColumn") then return true end
	return ColumnPlacement.IsColumn(block:GetAttribute("BlockType"))
end

-- Blocks that act as a column cap (column below them should become Middle instead of Top)
function ColumnPlacement.IsColumnCap(block)
	if not block then return false end
	local blockType = block:GetAttribute("BlockType")
	return blockType == "ColumnTorch"
end

-- ============================================
-- NEIGHBOR LOOKUPS
-- ============================================

local function getColumnsAt(position, blocksFolder)
	local index = getSpatialIndex(blocksFolder)
	local candidates = index and index:GetBlocksAt(position) or blocksFolder:GetChildren()
	for _, block in ipairs(candidates) do
		if ColumnPlacement.IsColumnInstance(block) then
			local bx = block:GetAttribute("BlockPosX") or 0
			local by = block:GetAttribute("BlockPosY") or 0
			local bz = block:GetAttribute("BlockPosZ") or 0
			if math.abs(bx - position.X) < 1 and math.abs(by - position.Y) < 1 and math.abs(bz - position.Z) < 1 then
				return block
			end
		end
	end
	return nil
end

-- Check if a column cap (e.g. ColumnTorch) exists at position
local function getColumnCapAt(position, blocksFolder)
	local index = getSpatialIndex(blocksFolder)
	local candidates = index and index:GetBlocksAt(position) or blocksFolder:GetChildren()
	for _, block in ipairs(candidates) do
		if ColumnPlacement.IsColumnCap(block) then
			local bx = block:GetAttribute("BlockPosX") or 0
			local by = block:GetAttribute("BlockPosY") or 0
			local bz = block:GetAttribute("BlockPosZ") or 0
			if math.abs(bx - position.X) < 1 and math.abs(by - position.Y) < 1 and math.abs(bz - position.Z) < 1 then
				return block
			end
		end
	end
	return nil
end

-- Check for column at an offset, optionally ignoring a specific position
local function hasColumnAtOffset(position, offsetY, blocksFolder, excludePos)
	local checkPos = position + Vector3.new(0, offsetY, 0)
	if excludePos then
		if math.abs(checkPos.X - excludePos.X) < 1
			and math.abs(checkPos.Y - excludePos.Y) < 1
			and math.abs(checkPos.Z - excludePos.Z) < 1 then
			return false
		end
	end
	-- Check for actual column
	if getColumnsAt(checkPos, blocksFolder) ~= nil then
		return true
	end
	-- When looking upward, also check for column caps (e.g. ColumnTorch)
	if offsetY > 0 and getColumnCapAt(checkPos, blocksFolder) ~= nil then
		return true
	end
	return false
end

function ColumnPlacement.HasColumnAbove(position, blocksFolder)
	local abovePos = position + Vector3.new(0, BLOCK_SIZE, 0)
	return getColumnsAt(abovePos, blocksFolder) ~= nil or getColumnCapAt(abovePos, blocksFolder) ~= nil
end

function ColumnPlacement.HasColumnBelow(position, blocksFolder)
	return getColumnsAt(position - Vector3.new(0, BLOCK_SIZE, 0), blocksFolder) ~= nil
end

-- ============================================
-- MODEL DETERMINATION
-- ============================================

-- Determine which model a column should use, optionally pretending excludePos is empty
function ColumnPlacement.DetermineModelName(position, blocksFolder, excludePos)
	local hasAbove = hasColumnAtOffset(position, BLOCK_SIZE, blocksFolder, excludePos)
	local hasBelow = hasColumnAtOffset(position, -BLOCK_SIZE, blocksFolder, excludePos)

	if hasAbove and hasBelow then
		return ColumnPlacement.MODEL_NAMES.Middle    -- "Column"
	elseif hasAbove and not hasBelow then
		return ColumnPlacement.MODEL_NAMES.Bottom    -- "ColumnBottom"
	elseif not hasAbove and hasBelow then
		return ColumnPlacement.MODEL_NAMES.Top       -- "ColumnTop"
	else
		return ColumnPlacement.MODEL_NAMES.Single    -- "ColumnSingle"
	end
end

-- ============================================
-- STACK UPDATE (called after place/remove)
-- ============================================

-- Returns list of {block, oldModelName, newModelName} for neighbors that need updating
-- Does NOT update the block at `position` itself (caller handles that for new placements)
-- `replaceCallback(block, newModelName, neighborPos)` is called for each neighbor that needs a swap
-- `excludePos` (optional) - pretend this position is empty (for pre-destroy removal updates)
function ColumnPlacement.UpdateNeighborColumns(position, blocksFolder, replaceCallback, excludePos)
	local updated = {}
	
	for _, offsetY in ipairs({BLOCK_SIZE, -BLOCK_SIZE}) do
		local neighborPos = position + Vector3.new(0, offsetY, 0)
		local neighbor = getColumnsAt(neighborPos, blocksFolder)
		if neighbor then
			local oldModel = neighbor:GetAttribute("ColumnModelName") or "ColumnSingle"
			local newModel = ColumnPlacement.DetermineModelName(neighborPos, blocksFolder, excludePos)
			if oldModel ~= newModel then
				if replaceCallback then
					replaceCallback(neighbor, newModel, neighborPos)
				end
				table.insert(updated, {block = neighbor, oldModel = oldModel, newModel = newModel})
			end
		end
	end
	
	return updated
end

return ColumnPlacement
