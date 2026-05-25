--[[
	RewardBlockPresets.luau
	Auto-generates block presets from the ReplicatedStorage.RewardSets folder.
	
	Folder layout expected:
	  ReplicatedStorage/
	    RewardModels/<SetName>             -- the burst-animation visual (Model)
	    RewardSets/<SetName>/              -- a Folder
	      Manifest                          -- a ModuleScript returning the set's config
	      <BlockName1>                      -- a Model (the block's template)
	      <BlockName2>
	      ...
	
	Manifest shape:
	  return {
	    Rarity = "Common" | "Uncommon" | "Rare",  -- set-wide rarity
	    Defaults = {                              -- (optional) merged into every block
	      Material = "Wood",
	      Category = "Decoration",
	      ...
	    },
	    Blocks = {
	      [BlockName] = {
	        Category = "Building",                -- inventory tab; required (unless in Defaults)
	        DisplayName = "Cherry Blossom Log",   -- optional, auto-derived from name otherwise
	        Material = "Wood",                    -- optional, string name of Enum.Material
	        MaterialVariant = "",                 -- optional
	        Color = Color3.fromRGB(...),          -- optional
	        Shape = "Block",                      -- optional, default "Block"
	        SortPriority = 50,                    -- optional
	        Behavior = {                          -- optional; drives runtime behavior
	          ColorCycle = {                      -- block hue-cycles every frame (rainbow-style)
	            Duration = 6.0,                   --   seconds per full hue cycle
	            Saturation = 0.85,                --   HSV saturation (lower for glass)
	            Value = 1.0,                      --   HSV value/brightness
	            SyncWithNeighbors = true,         --   adjacent same-type blocks share phase
	            Light = {                         --   optional; if present, also animate child PointLights
	              Saturation = 1.0,
	              Value = 1.0,
	            },
	          },
	          RandomRotation = true,              -- random 90 degree XYZ rotation on placement
	        },
	        -- any other flags pass through (IsGlass, IsDecoration, etc.)
	      },
	      ...
	    },
	  }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RewardBlockPresets = {}

-- Valid inventory tabs (must match Categories list in BlockPresets.luau)
local VALID_CATEGORIES = {
	Nature = true,
	Building = true,
	Decoration = true,
	Colors = true,
	Lights = true,
	Frames = true,
	Wiring = true,
	Items = true,
}

-- ============================================
-- HELPERS
-- ============================================

-- Auto-space a CamelCase name: "CherryBlossomLog" -> "Cherry Blossom Log"
local function autoSpace(name)
	return (name:gsub("(%l)(%u)", "%1 %2"))
end

-- Coerce a material value (string name or Enum.Material) into Enum.Material.
-- Returns nil if value is nil/missing so the caller can decide to preserve the
-- template's authored material (Material = nil means "don't override").
local function coerceMaterial(value)
	if value == nil then return nil end
	if typeof(value) == "EnumItem" then return value end
	if type(value) == "string" then
		local ok, mat = pcall(function() return Enum.Material[value] end)
		if ok and mat then return mat end
		warn("[RewardBlockPresets] Unknown Material name '" .. value .. "', leaving template material untouched")
		return nil
	end
	return nil
end

-- Coerce a color value (Color3 or {r,g,b} 0-255 table) into Color3
local function coerceColor(value)
	if typeof(value) == "Color3" then return value end
	if type(value) == "table" and #value >= 3 then
		return Color3.fromRGB(value[1], value[2], value[3])
	end
	return nil
end

-- Shallow-merge defaults into a config table without overwriting per-block keys
local function applyDefaults(blockCfg, defaults)
	if not defaults then return blockCfg end
	local merged = {}
	for k, v in pairs(defaults) do merged[k] = v end
	for k, v in pairs(blockCfg) do merged[k] = v end -- per-block keys win
	return merged
end

-- Build a single preset table from a set name, block name, and merged config
local function buildPreset(setName, blockName, cfg)
	-- Validate category
	local category = cfg.Category
	if not category or not VALID_CATEGORIES[category] then
		warn(string.format("[RewardBlockPresets] %s.%s: invalid or missing Category '%s' (valid: Nature/Building/Decoration/Colors/Lights/Frames/Wiring/Items) - skipping",
			setName, blockName, tostring(category)))
		return nil
	end
	
	local preset = {
		Id = blockName,
		Name = cfg.DisplayName or autoSpace(blockName),
		Category = category,
		Shape = cfg.Shape or "Block",
		Material = coerceMaterial(cfg.Material), -- may be nil = preserve template's material
		MaterialVariant = cfg.MaterialVariant, -- nil = preserve template's variant; "" = clear it
		DefaultColor = coerceColor(cfg.Color) or coerceColor(cfg.DefaultColor) or Color3.fromRGB(255, 255, 255),
		UseBlockModel = true,
		BlockModelFolder = "RewardSets/" .. setName,
		BlockModelName = blockName,
		ApplyColor = cfg.ApplyColor ~= false, -- default true
		SortPriority = cfg.SortPriority or 500,
		-- Tagging for the unlock-gating system
		IsRewardBlock = true,
		BelongsToSet = setName,
		-- Behavior config (drives ColorCycleController, placement quirks, etc.)
		Behavior = cfg.Behavior,
	}
	
	-- Back-compat shim: if the manifest declares ColorCycle behavior, also set
	-- the legacy IsRainbow flag so existing code paths that key off it keep working.
	if cfg.Behavior and cfg.Behavior.ColorCycle then
		preset.IsRainbow = true
		if cfg.Behavior.ColorCycle.Light then
			preset.HasPointLight = true
		end
	end
	
	-- Pass-through flags (IsGlass, IsDecoration, CanRotate, HasPointLight, etc.)
	local KNOWN_FIELDS = {
		Category = true, DisplayName = true, Material = true, MaterialVariant = true,
		Color = true, DefaultColor = true, Shape = true, SortPriority = true, ApplyColor = true,
		Behavior = true,
	}
	for k, v in pairs(cfg) do
		if not KNOWN_FIELDS[k] and preset[k] == nil then
			preset[k] = v
		end
	end
	
	return preset
end

-- ============================================
-- PUBLIC API
-- ============================================

-- Walk RewardSets and return an array of preset tables for every block
function RewardBlockPresets.Generate()
	local results = {}
	
	local setsFolder = ReplicatedStorage:FindFirstChild("RewardSets")
	if not setsFolder then
		-- Not an error - folder doesn't exist yet
		return results
	end
	
	local modelsFolder = ReplicatedStorage:FindFirstChild("RewardModels")
	
	for _, setFolder in ipairs(setsFolder:GetChildren()) do
		if not setFolder:IsA("Folder") then continue end
		
		local setName = setFolder.Name
		
		-- Validate: a matching visual model exists
		if modelsFolder and not modelsFolder:FindFirstChild(setName) then
			warn(string.format("[RewardBlockPresets] RewardSets.%s has no matching model in RewardModels - the chest burst will fall back gracefully but you should add one", setName))
		end
		
		-- Find the manifest
		local manifestScript = setFolder:FindFirstChild("Manifest")
		if not manifestScript or not manifestScript:IsA("ModuleScript") then
			warn(string.format("[RewardBlockPresets] RewardSets.%s has no Manifest ModuleScript - skipping set", setName))
			continue
		end
		
		local ok, manifest = pcall(require, manifestScript)
		if not ok or type(manifest) ~= "table" then
			warn(string.format("[RewardBlockPresets] RewardSets.%s.Manifest failed to load: %s", setName, tostring(manifest)))
			continue
		end
		
		if type(manifest.Blocks) ~= "table" then
			warn(string.format("[RewardBlockPresets] RewardSets.%s.Manifest has no Blocks table - skipping set", setName))
			continue
		end
		
		local defaults = manifest.Defaults
		
		-- Generate one preset per block listed in the manifest
		for blockName, blockCfg in pairs(manifest.Blocks) do
			-- Validate: matching model exists in the set folder
			local model = setFolder:FindFirstChild(blockName)
			local isValidTemplate = model and (model:IsA("Model") or model:IsA("BasePart"))
			if not isValidTemplate then
				warn(string.format("[RewardBlockPresets] %s.%s listed in Manifest but no matching Model or Part in the folder - skipping",
					setName, blockName))
				continue
			end
			
			local merged = applyDefaults(blockCfg, defaults)
			local preset = buildPreset(setName, blockName, merged)
			if preset then
				table.insert(results, preset)
			end
		end
		
		-- Sanity check: warn about template instances in the folder NOT in the manifest
		for _, child in ipairs(setFolder:GetChildren()) do
			if (child:IsA("Model") or child:IsA("BasePart")) and not manifest.Blocks[child.Name] then
				warn(string.format("[RewardBlockPresets] %s.%s is a template instance but not listed in Manifest.Blocks - skipping",
					setName, child.Name))
			end
		end
	end
	
	return results
end

return RewardBlockPresets
