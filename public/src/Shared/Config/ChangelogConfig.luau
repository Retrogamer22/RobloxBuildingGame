--[[
	ChangelogConfig
	Stores the current version and changelog entries.
	Update this file when you publish new versions!
]]

local ChangelogConfig = {
	-- Current version (increment this with each update)
	VERSION = 25,
	
	-- Version display name (shown to players)
	VERSION_NAME = "v1.7.6",
	
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
		{ imageId = "rbxaspsetid://72629514451612", caption = "Added vines and an arch frame variant" },
	},
	
	-- Changelog entries for the current version
	-- Each entry is a table with: { picon = "emoji", text = "description" }
	CHANGES = {
		{ icon = "", text = "Updated the block breaking and placing system" },
		{ icon = "", text = "Sugar cane now grows naturally and can be sheared" },
		{ icon = "", text = "Added new particle effects" },
	},
	
	-- Title shown at the top of the changelog
	TITLE = "What's New",
	
	-- Subtitle shown below the title
	SUBTITLE = "Join the Community for updates and feedback",
	
	-- Footer text at the bottom
	FOOTER = "More to come soon!",
}

return ChangelogConfig