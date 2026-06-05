--[[
	BlockSpatialIndex
	Provides O(1) block lookups by grid position instead of scanning all children.
	Critical for MegaPlot performance where thousands of blocks exist.
	
	Usage:
		local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
		local block = index:GetBlockAt(position)
		local blocks = index:GetBlocksNear(position, radius)
]]

local BLOCK_SIZE = 3
local TOLERANCE = 1.5  -- Half a block for snapping

-- Skip per-block index updates once the server is tearing down. On the free-build
-- terrain world (tens of thousands of blocks) the ChildRemoved cascade at shutdown
-- would otherwise blow Studio's shutdown deadline. Nil-safe; always false on client.
local BulkOperationFlags = nil
pcall(function()
	BulkOperationFlags = require(game:GetService("ReplicatedStorage"):WaitForChild("BulkOperationFlags", 5))
end)

local BlockSpatialIndex = {}
BlockSpatialIndex.__index = BlockSpatialIndex

-- Cache of indexes per Blocks folder
local IndexCache = {}

-- Generate a key from a position (snapped to grid)
local function posKey(x, y, z)
	local gx = math.round(x / BLOCK_SIZE)
	local gy = math.round(y / BLOCK_SIZE)
	local gz = math.round(z / BLOCK_SIZE)
	return gx .. "," .. gy .. "," .. gz
end

local function posKeyFromVector(pos)
	return posKey(pos.X, pos.Y, pos.Z)
end

-- Get the center position of a block (handles BaseParts, Models, etc.)
local function getBlockCenter(block)
	if block:IsA("BasePart") then
		-- Check stored position attributes first (for offset blocks like SnowLayer)
		local storedX = block:GetAttribute("BlockPosX")
		local storedY = block:GetAttribute("BlockPosY")
		local storedZ = block:GetAttribute("BlockPosZ")
		if storedX and storedY and storedZ then
			return Vector3.new(storedX, storedY, storedZ)
		end
		return block.Position
	elseif block:IsA("Model") then
		-- Check stored position attributes first (most reliable)
		local storedX = block:GetAttribute("BlockPosX")
		local storedY = block:GetAttribute("BlockPosY")
		local storedZ = block:GetAttribute("BlockPosZ")
		if storedX and storedY and storedZ then
			return Vector3.new(storedX, storedY, storedZ)
		end
		-- Fallback: use pivot + offset for bottom-center pivot models
		local pivot = block:GetPivot().Position
		if block:GetAttribute("IsFence") or block:GetAttribute("IsGlass") then
			return pivot
		else
			return pivot + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
	end
	return nil
end

function BlockSpatialIndex.new(blocksFolder)
	local self = setmetatable({}, BlockSpatialIndex)
	self._folder = blocksFolder
	self._map = {}        -- posKey -> {block, block, ...} (multiple for decorations on same pos)
	self._blockKeys = {}  -- block -> posKey (reverse lookup for fast removal)
	self._connections = {}
	
	-- Index all existing blocks
	for _, block in ipairs(blocksFolder:GetChildren()) do
		self:_addBlock(block)
	end
	
	-- Listen for changes
	table.insert(self._connections, blocksFolder.ChildAdded:Connect(function(block)
		if BulkOperationFlags and BulkOperationFlags.IsShuttingDown() then return end
		self:_addBlock(block)
	end))
	
	table.insert(self._connections, blocksFolder.ChildRemoved:Connect(function(block)
		if BulkOperationFlags and BulkOperationFlags.IsShuttingDown() then return end
		self:_removeBlock(block)
	end))
	
	return self
end

function BlockSpatialIndex:_addBlock(block)
	local pos = getBlockCenter(block)
	if not pos then return end
	
	local key = posKeyFromVector(pos)
	self._blockKeys[block] = key
	
	if not self._map[key] then
		self._map[key] = {}
	end
	table.insert(self._map[key], block)
end

-- Register a block at an additional position (for multi-cell blocks like beds)
function BlockSpatialIndex:RegisterSecondaryPosition(block, position)
	local key = posKeyFromVector(position)
	if not self._map[key] then
		self._map[key] = {}
	end
	table.insert(self._map[key], block)
	-- Store secondary key for cleanup
	if not self._secondaryKeys then self._secondaryKeys = {} end
	if not self._secondaryKeys[block] then self._secondaryKeys[block] = {} end
	table.insert(self._secondaryKeys[block], key)
end

function BlockSpatialIndex:_removeBlock(block)
	local key = self._blockKeys[block]
	if not key then return end
	
	self._blockKeys[block] = nil
	
	local list = self._map[key]
	if list then
		for i = #list, 1, -1 do
			if list[i] == block then
				table.remove(list, i)
				break
			end
		end
		if #list == 0 then
			self._map[key] = nil
		end
	end
	
	-- Clean up secondary positions (beds, etc.)
	if self._secondaryKeys and self._secondaryKeys[block] then
		for _, secKey in ipairs(self._secondaryKeys[block]) do
			local secList = self._map[secKey]
			if secList then
				for i = #secList, 1, -1 do
					if secList[i] == block then
						table.remove(secList, i)
						break
					end
				end
				if #secList == 0 then
					self._map[secKey] = nil
				end
			end
		end
		self._secondaryKeys[block] = nil
	end
end

-- Get all blocks at a grid position
function BlockSpatialIndex:GetBlocksAt(position)
	local key = posKeyFromVector(position)
	return self._map[key] or {}
end

-- Get the first non-decoration block at a position
function BlockSpatialIndex:GetBlockAt(position)
	local blocks = self:GetBlocksAt(position)
	for _, block in ipairs(blocks) do
		if not block:GetAttribute("IsDecoration") then
			return block
		end
	end
	return nil
end

-- Get any block at position (including decorations)
function BlockSpatialIndex:GetAnyBlockAt(position)
	local blocks = self:GetBlocksAt(position)
	return blocks[1]
end

-- Get decoration at a position
function BlockSpatialIndex:GetDecorationAt(position)
	local blocks = self:GetBlocksAt(position)
	for _, block in ipairs(blocks) do
		if block:GetAttribute("IsDecoration") then
			return block
		end
	end
	return nil
end

-- Check if any non-decoration block exists at position
function BlockSpatialIndex:HasBlockAt(position)
	return self:GetBlockAt(position) ~= nil
end

-- Get blocks at neighboring positions (6 directions)
function BlockSpatialIndex:GetNeighbors(position)
	local offsets = {
		Vector3.new(BLOCK_SIZE, 0, 0),
		Vector3.new(-BLOCK_SIZE, 0, 0),
		Vector3.new(0, BLOCK_SIZE, 0),
		Vector3.new(0, -BLOCK_SIZE, 0),
		Vector3.new(0, 0, BLOCK_SIZE),
		Vector3.new(0, 0, -BLOCK_SIZE),
	}
	
	local neighbors = {}
	for _, offset in ipairs(offsets) do
		local block = self:GetBlockAt(position + offset)
		if block then
			table.insert(neighbors, block)
		end
	end
	return neighbors
end

-- Get all blocks with a specific attribute at a position
function BlockSpatialIndex:GetBlockWithAttributeAt(position, attribute)
	local blocks = self:GetBlocksAt(position)
	for _, block in ipairs(blocks) do
		if block:GetAttribute(attribute) then
			return block
		end
	end
	return nil
end

-- Find block matching a predicate near a position (checks the position + 6 neighbors)
function BlockSpatialIndex:FindNearby(position, predicate)
	-- Check at position first
	for _, block in ipairs(self:GetBlocksAt(position)) do
		if predicate(block) then return block end
	end
	return nil
end

-- Clean up connections
function BlockSpatialIndex:Destroy()
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	self._connections = {}
	self._map = {}
	self._blockKeys = {}
	IndexCache[self._folder] = nil
end

-- Get block count (for debugging)
function BlockSpatialIndex:GetBlockCount()
	local count = 0
	for _ in pairs(self._blockKeys) do
		count = count + 1
	end
	return count
end

-- Static method: Get or create index for a blocks folder
function BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not blocksFolder then return nil end
	
	if IndexCache[blocksFolder] then
		return IndexCache[blocksFolder]
	end
	
	local index = BlockSpatialIndex.new(blocksFolder)
	IndexCache[blocksFolder] = index
	return index
end

-- Static helper: Find block at position using the index (drop-in replacement for GetChildren loops)
function BlockSpatialIndex.FindBlockAtPosition(blocksFolder, position)
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return nil end
	return index:GetBlockAt(position)
end

return BlockSpatialIndex
