--[[
	PlotPermissionConfig
	Configuration for the plot permission/sharing system
]]

return {
	-- DataStore configuration
	DATASTORE_NAME = "PlotPermissions_v1",
	
	-- Maximum players that can be blocked
	MAX_BLOCKED_PLAYERS = 100,
	
	-- Maximum players that can have build access
	MAX_SHARED_PLAYERS = 20,
	
	-- How far from plot boundary to teleport kicked players (studs)
	KICK_TELEPORT_DISTANCE = 15,
	
	-- Cooldown between kicks (seconds)
	KICK_COOLDOWN = 5,
	
	-- How often to check for blocked players on plots (seconds)
	BLOCK_CHECK_INTERVAL = 1,
	
	-- Distance from plot center to consider "on plot" (fallback if boundaries not set)
	DEFAULT_PLOT_RADIUS = 75,
	
	-- UI Colors
	UI_COLORS = {
		Background = Color3.fromRGB(30, 30, 35),
		BackgroundLight = Color3.fromRGB(45, 45, 50),
		Accent = Color3.fromRGB(88, 166, 255),  -- Blue
		AccentHover = Color3.fromRGB(110, 180, 255),
		Danger = Color3.fromRGB(255, 85, 85),    -- Red
		DangerHover = Color3.fromRGB(255, 110, 110),
		Warning = Color3.fromRGB(255, 170, 50),  -- Orange
		WarningHover = Color3.fromRGB(255, 190, 80),
		Success = Color3.fromRGB(85, 200, 85),   -- Green
		SuccessHover = Color3.fromRGB(110, 220, 110),
		Text = Color3.fromRGB(255, 255, 255),
		TextDim = Color3.fromRGB(180, 180, 180),
	},
}
