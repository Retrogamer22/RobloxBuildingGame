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

-- Valid inventory tabs (must match Categories list in BlockPresets.luau).
-- THEMED-PACK tabs (Tab field in Manifest) are added dynamically and live
-- alongside these — they don't need to be listed here.
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

-- Resolve a manifest PaletteSubset spec into a list of { color3, colorName, displayName, index }.
-- Three accepted forms:
--   "all"                              -> every palette color (in ColorPalette.ColorOrder)
--   { "Red", "Blue", ... }             -> just those colors (names from ColorPalette)
--   { { Color="Red", Name="..." }, .. } -> custom display name per color
-- `index` is each variant's position in the canonical palette order, used for
-- in-tab sorting so colors group together visually instead of alphabetically.
local function resolvePaletteSubset(spec, ColorPalette, setName, blockName, colorOverrides)
	local entries = {}
	local orderedNames = ColorPalette.ColorOrder
	local nameToIndex = {}
	for i, n in ipairs(orderedNames) do nameToIndex[n] = i end
	-- colorOverrides (optional): { [colorName] = Color3 } from the manifest. When a
	-- color is listed here, use that exact Color3 instead of ColorPalette's version.
	-- Lets a set use punchier colors than the shared palette (e.g. candy canes).
	colorOverrides = colorOverrides or {}
	local function colorFor(name)
		return colorOverrides[name] or ColorPalette.Colors[name] or ColorPalette.getColor(name)
	end
	
	-- Form 1: "all"
	if spec == "all" then
		for i, n in ipairs(orderedNames) do
			table.insert(entries, { colorName = n, color3 = colorFor(n), displayName = nil, index = i })
		end
		return entries
	end
	
	if type(spec) ~= "table" then
		warn(string.format("[RewardBlockPresets] %s.%s: PaletteSubset must be 'all' or a table - skipping variants", setName, blockName))
		return {}
	end
	
	for _, item in ipairs(spec) do
		local colorName, displayName
		if type(item) == "string" then
			-- Form 2: list of names
			colorName = item
		elseif type(item) == "table" and type(item.Color) == "string" then
			-- Form 3: { Color, Name } table
			colorName = item.Color
			displayName = item.Name
		else
			warn(string.format("[RewardBlockPresets] %s.%s: PaletteSubset entry has unexpected shape - skipping", setName, blockName))
			continue
		end
		local color3 = colorFor(colorName)
		if not color3 then
			warn(string.format("[RewardBlockPresets] %s.%s: PaletteSubset references unknown color '%s' - skipping",
				setName, blockName, tostring(colorName)))
			continue
		end
		table.insert(entries, {
			colorName = colorName,
			color3 = color3,
			displayName = displayName,
			index = nameToIndex[colorName] or 999,
		})
	end
	return entries
end

-- Shallow-merge defaults into a config table without overwriting per-block keys
local function applyDefaults(blockCfg, defaults)
	if not defaults then return blockCfg end
	local merged = {}
	for k, v in pairs(defaults) do merged[k] = v end
	for k, v in pairs(blockCfg) do merged[k] = v end -- per-block keys win
	return merged
end

-- Build a single preset table from a set name, block name, and merged config.
-- manifestTab: the set-level Tab field (themed-pack tab name), if any. Used as
-- the fallback Category when no per-block Category is set.
local function buildPreset(setName, blockName, cfg, manifestTab)
	-- Resolve category: per-block Category wins; otherwise fall back to the
	-- set-level Tab field; otherwise we have no destination and must skip.
	local category = cfg.Category or manifestTab
	local isThemedPackBlock = (cfg.Category == nil and manifestTab ~= nil)
	if not category then
		warn(string.format("[RewardBlockPresets] %s.%s: no Category and no set-level Tab - skipping",
			setName, blockName))
		return nil
	end
	-- Built-in categories must be in the allow-list. Themed-pack categories
	-- (where Category == manifestTab) bypass this check since they're declared
	-- by the manifest itself.
	if not isThemedPackBlock and not VALID_CATEGORIES[category] then
		warn(string.format("[RewardBlockPresets] %s.%s: invalid Category '%s' (valid: Nature/Building/Decoration/Colors/Lights/Frames/Wiring/Items) - skipping",
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
		-- True when this block lives in a themed-pack tab (set-level Tab field).
		-- Used by the inventory to gate tab visibility per-player.
		IsThemedPackBlock = isThemedPackBlock or nil,
		-- Behavior config (drives ColorCycleController, placement quirks, etc.)
		Behavior = cfg.Behavior,
		-- Decoration support (saplings, flowers, etc. living in reward sets).
		-- BlockHandler's decoration placement path uses BlockModelFolder to look
		-- up the template, instead of the hardcoded Decorations folder.
		IsDecoration = cfg.IsDecoration or nil,
		DecorationName = cfg.DecorationName or nil,
		-- Sapling support: IsSaplingItem flags the preset as a sapling for the
		-- inventory UI; TreeType identifies what tree it grows into (consumed by
		-- SaplingHandler via its SAPLING_TO_TREE map).
		IsSaplingItem = cfg.IsSaplingItem or nil,
		TreeType = cfg.TreeType or nil,
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
		-- Set-level fields that shouldn't pass through to per-block presets:
		Tab = true, TabIcon = true,
		-- Variant-expansion fields (handled by the caller, not the per-preset row):
		PaletteSubset = true, NamePattern = true, ColorOverrides = true,
		-- Decoration / sapling fields (handled inline above; don't pass through
		-- as random extra preset keys):
		IsDecoration = true, DecorationName = true,
		IsSaplingItem = true, TreeType = true,
		-- StripeColorMode + BaseBlock DO pass through; the block-creation pipeline
		-- reads StripeColorMode to know how to tint, and BaseBlock identifies the
		-- unlock group for variant presets.
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

-- Walk RewardSets and return an array of preset tables for every block.
-- Also returns themed-pack tab info as a second return value:
--   { { Name = "Candy", IconBlockName = "CandyBricks", SetName = "CandyBlocks" }, ... }
function RewardBlockPresets.Generate()
	local results = {}
	local themedTabs = {}     -- list of { Name, IconBlockName, SetName }
	local seenThemedTabs = {} -- dedupe by tab name in case two sets share one
	
	local setsFolder = ReplicatedStorage:FindFirstChild("RewardSets")
	if not setsFolder then
		return results, themedTabs
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
		local manifestTab = manifest.Tab  -- set-level themed-pack tab name (or nil)
		
		-- Record themed-pack tab if this set declares one
		if manifestTab and not seenThemedTabs[manifestTab] then
			seenThemedTabs[manifestTab] = true
			table.insert(themedTabs, {
				Name = manifestTab,
				IconBlockName = manifest.TabIcon,  -- may be nil; consumer should fall back
				SetName = setName,
			})
		end
		
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
			
			-- PaletteSubset: expand into N variant presets, one per color, the way
			-- Concrete works. The original (uncolored) preset is suppressed; only
			-- the variants appear in the inventory.
			if merged.PaletteSubset then
				local ColorPalette = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ColorPalette"))
				local entries = resolvePaletteSubset(merged.PaletteSubset, ColorPalette, setName, blockName, merged.ColorOverrides)
				local namePattern = merged.NamePattern or "{color} {base}"
				local baseDisplayName = merged.DisplayName or autoSpace(blockName)
				local basePriority = merged.SortPriority or 500
				
				for _, entry in ipairs(entries) do
					-- Build a per-variant config: variant Id, name, color, and a
					-- SortPriority that interleaves variants alongside the base sort
					-- order (base*100 + paletteIndex) so all colors of a block group
					-- together AND respect the palette's display order.
					local variantCfg = {}
					for k, v in pairs(merged) do variantCfg[k] = v end
					variantCfg.PaletteSubset = nil
					variantCfg.NamePattern = nil
					variantCfg.DefaultColor = entry.color3
					variantCfg.SortPriority = basePriority * 100 + entry.index
					variantCfg.BaseBlock = blockName  -- unlock check looks at base, not variant
					-- Per-color display name: custom > pattern > derived
					if entry.displayName then
						variantCfg.DisplayName = entry.displayName
					else
						local humanColor = (entry.colorName:gsub("(%l)(%u)", "%1 %2"))
						local name = namePattern:gsub("{color}", humanColor):gsub("{base}", baseDisplayName)
						variantCfg.DisplayName = name
					end
					
					local variantId = blockName .. "_" .. entry.colorName
					local preset = buildPreset(setName, variantId, variantCfg, manifestTab)
					if preset then
						-- Override BlockModelName: variants share the SAME template, only
						-- the preset Id and color differ. buildPreset defaulted this to
						-- variantId (which doesn't exist on disk) — fix that.
						preset.BlockModelName = blockName
						preset.IsVariant = true
						preset.VariantColorName = entry.colorName
						table.insert(results, preset)
					end
				end
			else
				-- Single preset, no expansion
				local preset = buildPreset(setName, blockName, merged, manifestTab)
				if preset then
					table.insert(results, preset)
				end
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
	
	return results, themedTabs
end

return RewardBlockPresets
