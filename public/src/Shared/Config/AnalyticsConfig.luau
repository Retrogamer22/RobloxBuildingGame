--[[
	AnalyticsConfig
	
	Configuration for the BuildBlox analytics ingest pipeline (Cloudflare Worker).
	
	SECURITY NOTE: This file contains the INGEST_TOKEN which authenticates
	Roblox->Worker writes. If you publish this code publicly, rotate the token
	first (regenerate in Cloudflare, then update here).
	
	The token's blast radius is limited:
	- Can write join/leave events to the analytics database
	- Can post live-stats responses
	- CANNOT trigger admin commands (those use a separate ADMIN_TOKEN)
	- CANNOT read analytics data
]]

return {
	-- Cloudflare Worker base URL (no trailing slash)
	WorkerUrl = "https://buildblox.gardinert4.workers.dev",
	
	-- INGEST_TOKEN secret from the Cloudflare Worker.
	-- Must match env.INGEST_TOKEN exactly. Rotate periodically.
	IngestToken = "380287946df1212432c4876228da1d4907c441b1d48527c4ffed321237271860",
	
	-- Target identifier sent with every event. Must match a key in the Worker's
	-- UNIVERSES map ("prod" or "dev").
	-- This is auto-detected from game.GameId in AnalyticsReporter, with this
	-- value as the fallback if detection fails.
	DefaultTarget = "prod",
	
	-- Map of game.GameId -> target name. Used to auto-detect prod/dev so the
	-- same code can ship to both experiences.
	UniverseTargets = {
		[9590764351] = "prod",
		[9675756310] = "dev",
	},
	
	-- If true, log every event POST. Useful for debugging; noisy in production.
	Debug = true,
}
