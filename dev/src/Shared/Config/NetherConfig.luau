--[[
	NetherConfig
	Shared constants for the Nether dimension travel system.

	Phase 1 (current): portal-to-portal travel plumbing.
	  - A lit portal on BuildArea{N} maps to the SAME relative offset on
	    NetherPlot{N}. A return portal is built there and the player is
	    teleported in. Stepping back through maps the reverse way.
	  - No cave generation yet — the bare NetherPlot baseplate is the floor.

	Cave generation (GenerateNetherBubble etc.) is deferred to a later phase
	and intentionally not referenced here.
]]

local NetherConfig = {}

-- Baseplate naming. Overworld plots are GridConfig.BUILD_AREA_PREFIX .. N
-- ("BuildArea1".."BuildArea9"); the matching nether baseplates are these:
NetherConfig.NETHER_PLOT_PREFIX = "NetherPlot"   -- NetherPlot1 .. NetherPlot9

-- How long (seconds) the player must stand inside a lit portal before travel
-- triggers. Minecraft is ~4s; the PortalVisionEffect swirl ramps over ~1.7s.
-- 3s feels deliberate without dragging. Pure feel — safe to tune.
NetherConfig.DWELL_SECONDS = 3.0

-- After a teleport, ignore portal dwell for this long so the player doesn't
-- instantly re-trigger on the return portal they arrive standing in
-- (prevents ping-ponging between dimensions).
NetherConfig.ARRIVAL_GRACE_SECONDS = 2.5

-- Studs above the destination baseplate/portal to drop the player so they
-- don't spawn embedded in the floor.
NetherConfig.SPAWN_Y_OFFSET = 5

-- Remote names (created at runtime by NetherTravelManager under
-- ReplicatedStorage.Remotes, same as the rest of the codebase).
NetherConfig.REMOTE_REQUEST_TRAVEL = "RequestNetherTravel"   -- client -> server
NetherConfig.REMOTE_TRAVEL_RESULT  = "NetherTravelResult"    -- server -> client (arrival grace, etc.)

-- Attribute set on a build area to record which dimension it is and its pair.
NetherConfig.ATTR_IS_NETHER   = "IsNether"      -- true on NetherPlot{N}
NetherConfig.ATTR_PLOT_NUMBER = "PlotNumber"    -- N, set on both sides for pairing

-- Log prefix for output filtering (matches the [BB-XXX] convention).
NetherConfig.LOG_PREFIX = "[BB-NETHER]"

return NetherConfig
