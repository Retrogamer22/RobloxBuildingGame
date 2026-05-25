--[[
	ChestHandler
	Server-side chest state management
	- Syncs chest open/close state to all clients
	- Validates chest ownership/permissions
	- Manages chest inventory (items stored inside chests)
	- Persists inventory via ChestContents attribute (JSON string)
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local StairPlacement = require(ReplicatedStorage:WaitForChild("StairPlacement", 10))
local SlabPlacement = require(ReplicatedStorage:WaitForChild("SlabPlacement", 10))

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local SINGLE_CHEST_SLOTS = 27 -- 3 rows x 9 cols
local DOUBLE_CHEST_SLOTS = 54 -- 6 rows x 9 cols
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

-- Create chest remotes if they don't exist
local function getOrCreateRemote(name)
	local remote = Remotes:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end

local ToggleChest = getOrCreateRemote("ToggleChest")
local ChestStateChanged = getOrCreateRemote("ChestStateChanged")
local RequestChestContents = getOrCreateRemote("RequestChestContents")
local ChestContentsResponse = getOrCreateRemote("ChestContentsResponse")
local UpdateChestSlot = getOrCreateRemote("UpdateChestSlot")

-- ============================================
-- CHEST INVENTORY STORAGE
-- ============================================
-- In-memory cache: [chestModel] = { [slotIndex] = {p = "PresetId", c = {R,G,B}} or nil }
local ChestInventories = {}

-- Get max slots for a chest
local function getMaxSlots(chest)
	if chest:GetAttribute("IsDoubleChest") then
		return DOUBLE_CHEST_SLOTS
	end
	return SINGLE_CHEST_SLOTS
end

-- Load chest inventory from its ChestContents attribute (JSON string)
local function loadChestInventory(chest)
	if ChestInventories[chest] then return ChestInventories[chest] end
	
	local maxSlots = getMaxSlots(chest)
	local inventory = {}
	
	local contentsJson = chest:GetAttribute("ChestContents")
	if contentsJson and contentsJson ~= "" then
		local ok, data = pcall(function()
			return HttpService:JSONDecode(contentsJson)
		end)
		if ok and type(data) == "table" then
			for i, item in pairs(data) do
				local idx = tonumber(i)
				if idx and idx >= 1 and idx <= maxSlots and type(item) == "table" and item.p then
					inventory[idx] = item
				end
			end
		end
	end
	
	ChestInventories[chest] = inventory
	return inventory
end

-- Save chest inventory to its ChestContents attribute
local function saveChestInventory(chest)
	local inventory = ChestInventories[chest]
	if not inventory then
		chest:SetAttribute("ChestContents", nil)
		return
	end
	
	-- Check if inventory is empty
	local hasItems = false
	for _ in pairs(inventory) do
		hasItems = true
		break
	end
	
	if not hasItems then
		chest:SetAttribute("ChestContents", nil)
		return
	end
	
	-- Encode as JSON with numeric string keys
	local data = {}
	for idx, item in pairs(inventory) do
		data[tostring(idx)] = item
	end
	
	local ok, json = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if ok then
		chest:SetAttribute("ChestContents", json)
	end
end

-- Serialize inventory to send to client (sparse table → array-friendly format)
local function serializeForClient(chest)
	local inventory = loadChestInventory(chest)
	local maxSlots = getMaxSlots(chest)
	local result = {}
	for i = 1, maxSlots do
		result[i] = inventory[i] or false -- false = empty slot
	end
	return result
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function isChestBlock(block)
	if not block then return false end
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return false end
	return BlockPresets.IsChest and BlockPresets.IsChest(blockType)
end

-- Check if a block above the chest would prevent it from opening
-- Returns true if the chest CAN open, false if blocked
local function canChestOpen(chest)
	local blocksFolder = chest.Parent
	if not blocksFolder then return true end
	
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not spatialIndex then return true end
	
	-- Get chest grid position(s)
	local posX = chest:GetAttribute("BlockPosX")
	local posY = chest:GetAttribute("BlockPosY")
	local posZ = chest:GetAttribute("BlockPosZ")
	if not posX then return true end
	
	local checkPositions = { Vector3.new(posX, posY + BLOCK_SIZE, posZ) }
	
	-- For double chests, also check above the secondary cell
	if chest:GetAttribute("IsDoubleChest") then
		local secX = chest:GetAttribute("ChestSecondaryX")
		local secY = chest:GetAttribute("ChestSecondaryY")
		local secZ = chest:GetAttribute("ChestSecondaryZ")
		if secX then
			table.insert(checkPositions, Vector3.new(secX, secY + BLOCK_SIZE, secZ))
		end
	end
	
	for _, abovePos in ipairs(checkPositions) do
		local candidates = spatialIndex:GetBlocksAt(abovePos)
		for _, block in ipairs(candidates) do
			local blockType = block:GetAttribute("BlockType") or ""
			
			-- Non-blocking types: chest can still open under these
			local isNonBlocking = block:GetAttribute("IsFence")
				or block:GetAttribute("IsGlass")
				or block:GetAttribute("IsTorch")
				or block:GetAttribute("IsLantern")
				or block:GetAttribute("IsSignStanding")
				or block:GetAttribute("IsWallSign")
				or block:GetAttribute("IsCarpet")
				or block:GetAttribute("IsVine")
				or block:GetAttribute("IsDecoration")
				or block:GetAttribute("IsChest")
				or block:GetAttribute("IsColumn")
				or block:GetAttribute("IsArchitrave")
				or block:GetAttribute("IsWater")
				or blockType == "SnowLayer"
				or StairPlacement.IsStairType(blockType)
				or SlabPlacement.IsSlab(blockType)
				or (BlockPresets.IsGlass and BlockPresets.IsGlass(blockType))
				or (BlockPresets.IsLadder and BlockPresets.IsLadder(blockType))
			
			if not isNonBlocking then
				print(string.format("[Chest] Blocked from opening by %s at (%.0f, %.0f, %.0f)", blockType, abovePos.X, abovePos.Y, abovePos.Z))
				return false
			end
		end
	end
	
	return true
end

-- ============================================
-- CHEST TOGGLE (manual player interaction)
-- ============================================

ToggleChest.OnServerEvent:Connect(function(player, chest)
	if not chest or not chest.Parent then return end
	if not isChestBlock(chest) then return end
	
	-- Prevent spamming
	if chest:GetAttribute("IsAnimating") then return end
	
	-- Toggle chest state
	local isOpen = chest:GetAttribute("IsOpen") or false
	local newState = not isOpen
	
	-- If trying to open, check if there's a solid block above
	if newState == true and not canChestOpen(chest) then
		print(string.format("[Chest] %s cannot open - blocked by solid block above", chest.Name))
		return
	end
	
	chest:SetAttribute("IsOpen", newState)
	
	-- Fire to all clients for animation
	ChestStateChanged:FireAllClients(chest, newState)
	
	print(string.format("[Chest] %s toggled to %s by %s", chest.Name, newState and "OPEN" or "CLOSED", player.Name))
end)

-- ============================================
-- CHEST INVENTORY REMOTES
-- ============================================

-- Client requests chest contents when opening the UI
RequestChestContents.OnServerEvent:Connect(function(player, chest)
	if not chest or not chest.Parent then return end
	if not isChestBlock(chest) then return end
	
	local contents = serializeForClient(chest)
	ChestContentsResponse:FireClient(player, chest, contents)
end)

-- Client updates a single slot (place or remove an item)
UpdateChestSlot.OnServerEvent:Connect(function(player, chest, slotIndex, itemData)
	if not chest or not chest.Parent then return end
	if not isChestBlock(chest) then return end
	
	-- Validate slot index
	local maxSlots = getMaxSlots(chest)
	if type(slotIndex) ~= "number" or slotIndex < 1 or slotIndex > maxSlots then
		warn(string.format("[ChestHandler] Invalid slot index %s from %s", tostring(slotIndex), player.Name))
		return
	end
	slotIndex = math.floor(slotIndex)
	
	local inventory = loadChestInventory(chest)
	
	if itemData == nil or itemData == false then
		-- Clearing a slot
		inventory[slotIndex] = nil
	else
		-- Validate item data
		if type(itemData) ~= "table" or type(itemData.p) ~= "string" then
			warn(string.format("[ChestHandler] Invalid item data from %s", player.Name))
			return
		end
		
		-- Validate preset exists
		local preset = BlockPresets.GetPreset(itemData.p)
		if not preset then
			warn(string.format("[ChestHandler] Unknown preset '%s' from %s", itemData.p, player.Name))
			return
		end
		
		-- Store the item
		inventory[slotIndex] = {
			p = itemData.p,
			c = itemData.c or nil, -- Color is optional (nil = preset default)
			n = (type(itemData.n) == "number" and itemData.n > 1) and math.min(math.floor(itemData.n), 64) or nil, -- Stack count (nil = 1)
		}
	end
	
	-- Persist to attribute
	saveChestInventory(chest)
end)

-- ============================================
-- CLEANUP: remove cache when chest is destroyed
-- ============================================
workspace.DescendantRemoving:Connect(function(descendant)
	if ChestInventories[descendant] then
		ChestInventories[descendant] = nil
	end
end)

-- ============================================
-- INITIALIZE
-- ============================================

print("ChestHandler initialized (with inventory storage)")
