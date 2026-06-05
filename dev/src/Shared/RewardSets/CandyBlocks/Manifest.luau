-- ReplicatedStorage/RewardSets/CandyBlocks/Manifest
-- Candy reward set. Rare-tier daily reward set.
--
-- Build order (see chat plan):
--   Step 1 (DONE): Manifest + 3 plain blocks below.
--   Step 2 (DONE): CandyCaneLog registered ΓÇö log rotation is automatic because
--                  the name contains "Log" (see LogPlacement.IsLog).
--   Step 3 (DONE): ChocolateBlock + CandyCaneLog + CandyCaneFull expanded into
--                  per-color variants via PaletteSubset (see field docs below).
--   Step 4: CandyLattice as a glass-style pane (needs corner geometry first).
--   Step 5 (DONE): CandyCaneSapling ΓÇö placed like a regular sapling, grows after
--                  10s into a J-shape candy cane with random height/curl/color.

-- Bright candy-flavor colors. These intentionally override the shared
-- ColorPalette (whose reds/greens are muted) so placed + inventory candy blocks
-- match the vivid colors used by grown candy canes. MUST stay in sync with
-- CANDY_PALETTE in Server/SaplingHandler.server.luau.
local candyColors = {
	White  = Color3.fromRGB(255, 255, 255),
	Red    = Color3.fromRGB(240, 30, 50),
	Green  = Color3.fromRGB(50, 200, 70),
	Pink   = Color3.fromRGB(255, 110, 185),
	Purple = Color3.fromRGB(165, 70, 230),
	Orange = Color3.fromRGB(255, 130, 25),
	Yellow = Color3.fromRGB(255, 220, 40),
}

-- Richer, warmer chocolate tones. The shared ColorPalette's browns read as
-- washed-out grey-browns; these are more saturated cocoa colors so the
-- chocolate blocks actually look like chocolate. Keyed by the palette color
-- name each variant uses (see ChocolateBlock.PaletteSubset below).
local chocolateColors = {
	White    = Color3.fromRGB(245, 224, 180), -- creamy white chocolate (warmer than pure white)
	Tan      = Color3.fromRGB(165, 100, 52),  -- milk chocolate
	Brown    = Color3.fromRGB(96, 52, 26),    -- dark chocolate
	DarkGrey = Color3.fromRGB(54, 30, 18),    -- extra dark chocolate
	Pink     = Color3.fromRGB(225, 120, 120), -- strawberry chocolate
}

return {
	-- Set-wide rarity. Drives the weighted random pick in RewardSetPicker.
	-- Common = weight 10, Uncommon = 5, Rare = 2.
	Rarity = "Rare",

	-- This set gets its own dedicated tab in the inventory (themed-pack tab),
	-- rendered on the right side under Tools. The tab is HIDDEN until the player
	-- has unlocked at least one block from this set (or owns the pack, once shop
	-- packs exist). The owner sees it always. Toggle with /preview to test as a
	-- fresh player.
	Tab = "Candy",
	TabIcon = "CandyBricks",  -- block model name shown in the tab's viewport

	-- Defaults merged into every block below unless that block overrides the key.
	Defaults = {
		-- NOTE: Category is NOT defaulted here because the Tab field above routes
		-- all blocks to the "Candy" tab automatically. If we later want a single
		-- candy block to live in a built-in tab (e.g. Decoration), give that
		-- block an explicit Category and it'll override the Tab.
		ApplyColor = false,     -- plain blocks keep their authored textures (no tint)
		-- Material intentionally NOT defaulted: each template keeps the Material /
		-- MaterialVariant it was authored with in Studio.
	},

	Blocks = {
		-- PaletteSubset (optional, set per-block below): expands one block template
		-- into multiple inventory entries, one per color, the way Concrete works.
		-- Three forms:
		--   "all"                                  -> all 17 palette colors
		--   { "Red", "Blue", ... }                 -> just those colors
		--   { { Color="Red", Name="Cherry" }, ... } -> custom display name per color
		-- The original (uncolored) preset is suppressed from the inventory when a
		-- PaletteSubset is set ΓÇö only the variants appear, matching how concrete works.
		-- StripeColorMode (optional):
		--   "Part"    -> tint the block's BasePart Color3 (default; works for solid blocks)
		--   "Texture" -> tint every Texture descendant's Color3 (for blocks whose
		--                pattern lives in grayscale Texture images, like candy canes)

		ChocolateBlock = {
			DisplayName = "Chocolate Block",
			SortPriority = 60,
			BaseBlock = "ChocolateBlock",
			ApplyColor = true,  -- override the set-wide false (variants need coloring)
			StripeColorMode = "Part",  -- explicit for clarity (this is the default)
			PaletteSubset = {
				{ Color = "White",    Name = "White Chocolate" },
				{ Color = "Tan",      Name = "Milk Chocolate" },
				{ Color = "Brown",    Name = "Dark Chocolate" },
				{ Color = "DarkGrey", Name = "Extra Dark Chocolate" },
				{ Color = "Pink",     Name = "Strawberry Chocolate" },
			},
			-- Use richer cocoa tones instead of the muted shared-palette browns.
			ColorOverrides = chocolateColors,
		},

		CandyBricks = {
			DisplayName = "Candy Bricks",
			-- 6100 is between chocolate variants (60xx) and candy cane variants (62xx, 63xx)
			-- because variant blocks get SortPriority = base * 100 + paletteIndex.
			SortPriority = 6100,
			BaseBlock = "CandyBricks",
			-- No PaletteSubset: stays a single fixed-multicolor block.
		},

		-- Solid candy-cane cube. Player-placeable, and ALSO reused as the corner
		-- piece when the sapling grows (its faces have no log seam, unlike the log).
		-- 17 color variants ΓÇö the stripe texture is grayscale, so tinting it produces
		-- a candy cane in whatever flavor color the player picks.
		CandyCaneFull = {
			DisplayName = "Candy Cane Block",
			SortPriority = 62,
			BaseBlock = "CandyCaneFull",
			ApplyColor = true,
			StripeColorMode = "Texture",  -- tint Texture descendants, not the Part
			-- Curated to colors that actually look like real candy canes. Skips
			-- things like Cyan/Magenta/Lime which read more arts-and-crafts than candy.
			PaletteSubset = { "White", "Red", "Green", "Pink", "Purple", "Orange", "Yellow" },
			-- Use the bright candy colors instead of the muted shared palette so these
			-- match grown candy canes.
			ColorOverrides = candyColors,
		},

		-- Candy-cane log (Step 2). The name contains "Log", so LogPlacement.IsLog
		-- auto-detects it and the building code rotates it like Oak/Birch/etc.:
		-- vertical when placed on top/bottom, horizontal when placed on a side.
		-- Used as the straight segments of the sapling's grown structure (Step 5);
		-- CandyCaneFull fills in at the two bends so there's no log seam at corners.
		-- 17 color variants, same tint mechanism as CandyCaneFull.
		CandyCaneLog = {
			DisplayName = "Candy Cane Log",
			SortPriority = 63,
			BaseBlock = "CandyCaneLog",
			ApplyColor = true,
			StripeColorMode = "Texture",
			-- Same curated set as CandyCaneFull ΓÇö they're meant to pair.
			PaletteSubset = { "White", "Red", "Green", "Pink", "Purple", "Orange", "Yellow" },
			ColorOverrides = candyColors,
		},

		-- Sapling (Step 5). Placed like any sapling ΓÇö grows into a J-shaped candy
		-- cane after the standard growth delay (10s). Random height (3ΓÇô8), random
		-- curl direction (L/R), random color from the 7 candy-cane flavors. All
		-- saplings look identical (all-white) regardless of what they grow into.
		-- The block is a Decoration shape, so placement-wise it behaves like
		-- OakSapling etc. (top-of-grass/dirt placement, decoration billboard).
		-- Template lives in RewardSets/CandyBlocks/CandyCaneSapling ΓÇö BlockHandler's
		-- decoration path honors the preset's BlockModelFolder so it'll find it
		-- there instead of the usual Decorations folder.
		CandyCaneSapling = {
			DisplayName = "Candy Cane Sapling",
			SortPriority = 64,
			BaseBlock = "CandyCaneSapling",
			Shape = "Decoration",
			IsDecoration = true,
			IsSaplingItem = true,
			TreeType = "CandyCane",
			-- DecorationName + BlockModelFolder (set by RewardBlockPresets) route the
			-- placement template lookup to RewardSets/CandyBlocks/CandyCaneSapling
			-- rather than the hardcoded Decorations folder.
			DecorationName = "CandyCaneSapling",
		},

		-- Glass-style lattice pane (Step 4). Routed through the glass placement system
		-- via IsGlass = true: it auto-connects into corner/tee/cross pieces exactly like
		-- glass panes do, pulling its four models (CandyLattice / CandyLatticeCorner /
		-- CandyLatticeT / CandyLatticeCross) from this RewardSets/CandyBlocks folder.
		-- GlassPlacement.GLASS_TYPE_CONFIG maps the type -> folder + model names; the
		-- BlockHandler/SaveManager glass paths read preset.BlockModelFolder (set
		-- automatically to "RewardSets/CandyBlocks") instead of the hardcoded glass folder.
		-- Center pivot, fixed (non-tintable) brown-in-texture look, so no ApplyColor.
		CandyLattice = {
			DisplayName = "Candy Lattice",
			SortPriority = 61,
			BaseBlock = "CandyLattice",
			IsGlass = true,
		},
	},
}
