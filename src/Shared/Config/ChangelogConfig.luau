--[[
	ChangelogConfig
	Stores the current version and changelog entries.
	Update this file when you publish new versions!
]]

local ChangelogConfig = {
	-- Current version (increment this with each update)
	VERSION = 22,
	
	-- Version display name (shown to players)
	VERSION_NAME = "v1.7.2",
	
	-- Developer Notes (optional) - shown in a highlighted box above changes
	-- Set to nil or empty string to hide the notes section
	-- Use this for bug awareness, upcoming features, warnings, etc.
	NOTES = "",
	
	-- Notes style: "warning" (yellow), "info" (blue), "success" (green), "error" (red)
	NOTES_STYLE = "warning",
	
	-- Optional carousel images (shown below header if present)
	-- Each entry: { imageId = "rbxassetid://...", caption = "optional caption" }
	-- Set to nil or empty table to hide the carousel
	IMAGES = {
		-- Example:
		{ imageId = "rbxassetid://139684623132536", caption = "Added more parity blocks!" },
		{ imageId = "rbxassetid://72629514451612", caption = "Added vines and an arch frame variant" },
	},
	
	-- Changelog entries for the current version
	-- Each entry is a table with: { picon = "emoji", text = "description" }
	CHANGES = {
		{ icon = "", text = "Added in a new coin system for future features and gameplay" },
		{ icon = "", text = "Added in, beds, crafting tables, furnace, and chests with different variants!" },
		{ icon = "", text = "Created community button to join from the main menu" },
		{ icon = "", text = "Added Vines and shears to stop the vines from growing!" },
		{ icon = "", text = "Added a new frame block variant, the arch! create more dynamic structures" },
		{ icon = "", text = "Revamped all textures with PBR maps to add more depth and detail to the game" },
		{ icon = "", text = "Tweaked campfire smoke and lighting system" },
		{ icon = "", text = "Tweaked saving/loading system to be more robust" },
		{ icon = "", text = "Fixed more bugs and issues as usual!" },
	},
	
	-- Title shown at the top of the changelog
	TITLE = "What's New",
	
	-- Subtitle shown below the title
	SUBTITLE = "Join the Community for updates and feedback",
	
	-- Footer text at the bottom
	FOOTER = "More to come soon!",
}

return ChangelogConfig