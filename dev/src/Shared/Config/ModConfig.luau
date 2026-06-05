--[[
	ModConfig.luau
	Configuration for purchasable MODS (coin-bought content bundles).

	A "mod" is a named bundle the player buys ONCE with Build Coins. Buying it
	marks the mod owned and unlocks every block Id in its `grants` list — reusing
	the same per-player unlock machinery as reward sets:
	  - CoinManager grants each grant Id into the player's `unlockedBlocks`
	  - sets an `Unlocked_<BlockId>` attribute on the player
	  - the inventory un-gates any preset whose Id is unlocked (IsRewardBlock path)

	HOW TO SHIP A MOD (e.g. when the Paint Mod is ready):
	  1. Fill the mod's `grants` list with the block Ids it should unlock.
	  2. On each of those presets in BlockPresets, replace `HideFromInventory = true`
	     with `IsRewardBlock = true` so it stays hidden until unlocked (instead of
	     hidden forever). Use the BaseBlock convention if variants share an unlock.
	  3. Flip `available = true`.
	  4. (Optional) set a real `image` asset id.
	That's it — the shop card becomes purchasable and the grant flow works.

	A mod with `available = false` shows in the shop as "Coming Soon" and cannot
	be purchased. A `coinPrice` of 0 is treated as free (still requires available).
]]

local ModConfig = {}

-- ============================================
-- MODS
-- LayoutOrder controls left-to-right order in the shop's Mods row.
-- ============================================
ModConfig.Mods = {
	{
		id = "paint",
		name = "Paint Mod",
		description = "Mix custom colors and paint your blocks.",
		coinPrice = 2000,            -- per economy plan (mods ~2,000-2,500)
		image = "rbxassetid://82797790981860", -- PaintCanImage (Assets/Icons/PaintCanImage.png)
		available = false,           -- Coming Soon — flip to true when the mod ships
		layoutOrder = 1,
		-- TODO: when the paint item set is finalized, list the block Ids to unlock
		-- on purchase here (e.g. "PaintBrush", "Sponge", "EmptyPaintCan",
		-- "PaintSwatch", and the per-color paint cans). Empty = nothing to grant yet.
		grants = {},

		-- ----------------------------------------------------------------
		-- "MORE INFO" CARD CONTENT
		-- Shown when the player clicks the mod card (not the Buy button).
		-- Purely cosmetic/marketing copy — safe to edit anytime.
		--
		-- IMAGES: the icon PNGs live in Assets/Icons. Roblox can't load a
		-- local PNG by path, so upload each one to Roblox (Studio > Asset
		-- Manager, or create.roblox.com > Decals) and paste its rbxassetid
		-- below. Until then they show as empty boxes — text still works.
		-- ----------------------------------------------------------------
		info = {
			tagline = "A full painting toolkit for your builds.",
			overview = "Buy the Paint Mod once and a complete painting kit is added to "
				.. "your inventory: a brush, paint cans, primer, a sponge, color swatches "
				.. "and the Paint Mixer station. Mix any color you want, paint your blocks, "
				.. "and the colors save with your build.",

			-- Filename -> uploaded Roblox asset id. Replace each rbxassetid://0.
			images = {
				PaintBrushImage      = "rbxassetid://96458817687331", -- Assets/Icons/PaintBrushImage.png
				PaintBrushPaintLayer = "rbxassetid://79038148113281", -- Assets/Icons/PaintBrushPaintLayer.png
				PaintCanImage        = "rbxassetid://82797790981860", -- Assets/Icons/PaintCanImage.png
				PaintCanPaintLayer   = "rbxassetid://82160577410104", -- Assets/Icons/PaintCanPaintLayer.png
				PaintCanPrimerImage  = "rbxassetid://98621510100794", -- Assets/Icons/PaintCanPrimerImage.png
				SpongeImage          = "rbxassetid://92656632140980", -- Assets/Icons/SpongeImage.png
				SwatchImage          = "rbxassetid://95615966551669", -- Assets/Icons/SwatchImage.png
			},

			-- Each feature row: image is a KEY into `images` above (not a raw id).
			features = {
				{
					name = "Paint Brush",
					image = "PaintBrushImage",
					text = "Right-click a placed paint can to load its color onto the brush, "
						.. "then right-click any block to paint it. Painted colors are saved "
						.. "with your build.",
				},
				{
					name = "Paint Can",
					image = "PaintCanImage",
					text = "Fill cans with custom colors at the Paint Mixer. Place a can down "
						.. "and it becomes a color source your brush can load from.",
				},
				{
					name = "Primer",
					image = "PaintCanPrimerImage",
					text = "Mix a primer can for a flat, solid base coat. Switch between Regular "
						.. "and Primer in the mixer to change how the paint sits on a block.",
				},
				{
					name = "Sponge",
					image = "SpongeImage",
					text = "Made a mistake? The sponge steps a block back one stage at a time "
						.. "— painted back to plain — so you can undo paint without rebuilding.",
				},
				{
					name = "Paint Swatch",
					image = "SwatchImage",
					text = "Capture a color you like onto a swatch, then drop it into the mixer's "
						.. "swatch slot to instantly reload that exact color later.",
				},
				{
					name = "Paint Mixer",
					image = "PaintCanPaintLayer",
					text = "Place and interact with the Paint Mixer station. Drop in an empty "
						.. "can, dial a color with the RGB sliders or a hex code, then pull out "
						.. "a filled can. The empty can isn't used up, so keep mixing.",
				},
			},
		},
	},
}

-- ============================================
-- HELPERS
-- ============================================
-- Return the mod definition with this id, or nil.
function ModConfig.GetById(modId: string)
	if type(modId) ~= "string" then return nil end
	for _, mod in ipairs(ModConfig.Mods) do
		if mod.id == modId then
			return mod
		end
	end
	return nil
end

-- Return all mods (in config order). Caller should treat as read-only.
function ModConfig.GetAll()
	return ModConfig.Mods
end

return ModConfig
