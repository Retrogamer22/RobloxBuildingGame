--[[
	PrivateServerConfig
	Configuration for private server features
]]

return {
	-- Server modes
	MODES = {
		INDIVIDUAL = "Individual",  -- 9 separate plots, anyone can build on any
		MEGAPLOT = "MegaPlot",       -- One giant plot, shared building
	},
	
	-- Default mode for new private servers
	DEFAULT_MODE = "Individual",
	
	-- Mega-plot settings
	MEGAPLOT = {
		-- Size multiplier (3x3 = 9 plots worth of space)
		WIDTH_MULTIPLIER = 3,
		DEPTH_MULTIPLIER = 3,
	},
	
	-- DataStore keys
	DATASTORE_NAME = "PrivateServerData_v1",
	
	-- Schema version for migrations
	SCHEMA_VERSION = 1,
}
