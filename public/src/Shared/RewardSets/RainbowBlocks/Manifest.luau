-- ReplicatedStorage/RewardSets/RainbowBlocks/Manifest
return {
	-- Set-wide rarity. Drives the weighted random pick in RewardSetPicker.
	-- Common = weight 10, Uncommon = 5, Rare = 2.
	Rarity = "Rare",

	-- Defaults merged into every block below unless that block overrides the key.
	Defaults = {
		Category = "Colors",
		DefaultColor = Color3.fromRGB(255, 255, 255),
		ApplyColor = true,
		-- Note: Material is intentionally NOT defaulted. If a block omits Material,
		-- the cloned template's authored material (and MaterialVariant) is preserved.
	},

	Blocks = {
		-- 1. Plain Rainbow Block: solid cube with Grass + PixelRainbow MaterialVariant.
		--    Author the Part in Studio with whatever Material/Variant you want and
		--    leave Material/MaterialVariant out of the manifest to keep them as-is.
		RainbowBlock = {
			DisplayName = "Rainbow Block",
			SortPriority = 1,
			BaseBlock = "RainbowBlock",
			Behavior = {
				ColorCycle = {
					Duration = 6.0,             -- seconds per full hue cycle
					Saturation = 0.85,
					Value = 1.0,
					SyncWithNeighbors = true,
				},
				RandomRotation = true,          -- random 90 deg XYZ rotation on placement
			},
		},

		-- 2. Rainbow Glass Block: full glass cube; force Glass material so it's transparent
		--    even if the source Model was authored with something else.
		RainbowGlassBlock = {
			DisplayName = "Rainbow Glass",
			Material = "Glass",
			IsGlass = true,
			SortPriority = 2,
			BaseBlock = "RainbowGlassBlock",
			Behavior = {
				ColorCycle = {
					Duration = 6.0,
					Saturation = 0.65,
					Value = 0.95,
					SyncWithNeighbors = true,
				},
			},
		},

		-- 3. Rainbow Glass Pane: thin pane, auto-orients via GlassPlacement.
		--    Model must be named "RainbowGlass" in Studio (not "RainbowGlassPane").
		RainbowGlass = {
			DisplayName = "Rainbow Glass Pane",
			Material = "Glass",
			IsGlass = true,
			SortPriority = 3,
			BaseBlock = "RainbowGlass",
			Behavior = {
				ColorCycle = {
					Duration = 6.0,
					Saturation = 0.65,
					Value = 0.95,
					SyncWithNeighbors = true,
				},
			},
		},

		-- 4. Rainbow Glowstone: keep the template's Material/MaterialVariant
		--    (the authored Part likely has Rock + PixelGlowStone, like the original).
		--    Just omit Material here so the override doesn't wipe it out.
		RainbowGlowstone = {
			DisplayName = "Rainbow Glow",
			SortPriority = 4,
			BaseBlock = "RainbowGlowstone",
			Behavior = {
				ColorCycle = {
					Duration = 6.0,
					Saturation = 0.85,
					Value = 1.0,
					SyncWithNeighbors = true,
					Light = {           -- presence of Light table = also animate child PointLights
						Saturation = 1.0,
						Value = 1.0,
					},
				},
			},
		},
	},
}
