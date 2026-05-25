--[[
	GridConfig
	Configuration for the building grid system
]]

return {
	BLOCK_SIZE = 3,
	PLOT_HEIGHT = 400,
	TOTAL_PLOTS = 9,
	BUILD_AREA_PREFIX = "BuildArea",
	
	-- Terrain generation settings (LAZY LOADING)
	-- Only grass surface generates on startup
	-- Underground blocks spawn as you dig
	TERRAIN = {
		ENABLED = true,
		MAX_DEPTH = 40,      -- Max dig depth in blocks (can be deep now with lazy loading!)
		GRASS_LAYERS = 1,    -- Grass on top
		DIRT_LAYERS = 4,     -- Dirt below grass (depth 1-4)
		-- Stone fills the rest (depth 5+)
		
		-- Block types (must match ReplicatedStorage.Blocks folder)
		GRASS_BLOCK = "GrassBlock",
		DIRT_BLOCK = "Dirt",
		STONE_BLOCK = "Stone",
	},
}
