--[[
	RewardSetPicker.luau
	Picks a random reward set from ReplicatedStorage.RewardSets, weighted by rarity.
	
	A "set" is defined by a folder under ReplicatedStorage.RewardSets:
	  RewardSets/<SetName>/
	    Manifest      -- ModuleScript with { Rarity, Defaults, Blocks = {...} }
	    <Model 1>
	    <Model 2>
	    ...
	
	The matching visual Model lives in ReplicatedStorage.RewardModels/<SetName>
	and is used for the chest-burst animation.
	
	Usage:
	  local RewardSetPicker = require(ReplicatedStorage:WaitForChild("RewardSetPicker"))
	  local set = RewardSetPicker.PickRandom(rng, ownedSetNames)
	  -- set = { name, model, grants = {"BlockA", "BlockB"}, rarity = "Rare" } or nil
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RewardSetPicker = {}

-- ============================================
-- CONFIG
-- ============================================

-- Rarity weights (higher = more common)
RewardSetPicker.RarityWeights = {
	Common = 10,
	Uncommon = 5,
	Rare = 2,
}

local SETS_FOLDER_NAME = "RewardSets"
local MODELS_FOLDER_NAME = "RewardModels"

-- ============================================
-- INTERNAL HELPERS
-- ============================================

local function getSetsFolder()
	return ReplicatedStorage:FindFirstChild(SETS_FOLDER_NAME)
end

local function getModelsFolder()
	return ReplicatedStorage:FindFirstChild(MODELS_FOLDER_NAME)
end

-- Load and require a set's Manifest module. Returns the manifest table or nil.
local function loadManifest(setFolder)
	local manifestScript = setFolder:FindFirstChild("Manifest")
	if not manifestScript or not manifestScript:IsA("ModuleScript") then return nil end
	
	local ok, result = pcall(require, manifestScript)
	if not ok or type(result) ~= "table" then return nil end
	return result
end

-- Build a set info table for the public API
local function buildSetInfo(setFolder, manifest)
	-- Derive grants list from the manifest's Blocks keys
	local grants = {}
	if type(manifest.Blocks) == "table" then
		for blockId, _ in pairs(manifest.Blocks) do
			table.insert(grants, blockId)
		end
	end
	
	local modelsFolder = getModelsFolder()
	local visualModel = modelsFolder and modelsFolder:FindFirstChild(setFolder.Name) or nil
	
	return {
		name = setFolder.Name,
		model = visualModel, -- may be nil if no matching visual exists
		grants = grants,
		rarity = manifest.Rarity or "Common",
	}
end

-- ============================================
-- PUBLIC API
-- ============================================

-- Get a specific set by name (returns nil if not found or no manifest)
function RewardSetPicker.GetSet(name)
	local setsFolder = getSetsFolder()
	if not setsFolder then return nil end
	
	local setFolder = setsFolder:FindFirstChild(name)
	if not setFolder or not setFolder:IsA("Folder") then return nil end
	
	local manifest = loadManifest(setFolder)
	if not manifest then return nil end
	
	return buildSetInfo(setFolder, manifest)
end

-- Get all valid sets (those with a loadable manifest)
function RewardSetPicker.GetAllSets()
	local results = {}
	local setsFolder = getSetsFolder()
	if not setsFolder then return results end
	
	for _, child in ipairs(setsFolder:GetChildren()) do
		if child:IsA("Folder") then
			local manifest = loadManifest(child)
			if manifest then
				table.insert(results, buildSetInfo(child, manifest))
			end
		end
	end
	
	return results
end

-- Pick a random set using rarity weights, excluding any names in excludeNames.
-- excludeNames: table of { [setName] = true } for sets the player already owns
-- Returns set info table or nil if no eligible sets available.
function RewardSetPicker.PickRandom(rng, excludeNames)
	excludeNames = excludeNames or {}
	rng = rng or Random.new()
	
	local setsFolder = getSetsFolder()
	if not setsFolder then
		warn("[RewardSetPicker] ReplicatedStorage." .. SETS_FOLDER_NAME .. " folder does not exist")
		return nil
	end
	
	-- Collect eligible sets and total weight
	local eligible = {}
	local totalWeight = 0
	
	for _, child in ipairs(setsFolder:GetChildren()) do
		if child:IsA("Folder") and not excludeNames[child.Name] then
			local manifest = loadManifest(child)
			if manifest then
				local rarity = manifest.Rarity or "Common"
				local weight = RewardSetPicker.RarityWeights[rarity] or RewardSetPicker.RarityWeights.Common
				
				table.insert(eligible, { folder = child, manifest = manifest, weight = weight })
				totalWeight = totalWeight + weight
			end
		end
	end
	
	if #eligible == 0 or totalWeight <= 0 then
		return nil
	end
	
	-- Weighted random pick
	local roll = rng:NextNumber(0, totalWeight)
	local cumulative = 0
	
	for _, entry in ipairs(eligible) do
		cumulative = cumulative + entry.weight
		if roll <= cumulative then
			return buildSetInfo(entry.folder, entry.manifest)
		end
	end
	
	-- Fallback (shouldn't hit)
	return buildSetInfo(eligible[1].folder, eligible[1].manifest)
end

-- Count how many valid sets exist total (useful for "all unlocked" detection)
function RewardSetPicker.GetTotalSetCount()
	local setsFolder = getSetsFolder()
	if not setsFolder then return 0 end
	
	local count = 0
	for _, child in ipairs(setsFolder:GetChildren()) do
		if child:IsA("Folder") and loadManifest(child) then
			count = count + 1
		end
	end
	return count
end

return RewardSetPicker
