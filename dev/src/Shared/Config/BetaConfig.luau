--[[
	BetaConfig
	Configuration for beta testing phase
	
	During beta:
	- All players get premium features free
	- All players are tracked as beta testers
	
	After beta:
	- Set IS_BETA to false
	- Beta testers keep premium permanently
	- New players must purchase the gamepass
]]

local BetaConfig = {}

-- ============================================
-- MAIN TOGGLE - Set to false when beta ends!
-- ============================================
BetaConfig.IS_BETA = true

-- ============================================
-- OWNER CONFIG
-- ============================================
-- Your UserId (won't be tracked as beta player, gets admin panel, etc.)
-- Set this when game ownership is transferred to a group, since game.CreatorId
-- then returns the group's ID instead of your personal UserId. Setting this to
-- your personal UserId restores all owner-gated features for your account.
-- Set to 0 to fall back to game.CreatorId (only works when you own the game personally).
BetaConfig.OWNER_USER_ID = 9629033464  -- JoseTwinkleToe

-- ============================================
-- DATASTORE CONFIG
-- ============================================
BetaConfig.BETA_PLAYERS_DATASTORE = "BetaPlayers_v1"
BetaConfig.BETA_PLAYERS_KEY = "all_beta_players"  -- For storing the full list
BetaConfig.PLAYER_STATUS_PREFIX = "status_"  -- For individual player status

-- ============================================
-- BETA QUALIFICATION THRESHOLD
-- ============================================
-- Players must place at least this many blocks to be registered as a beta tester
-- This prevents people who join for 5 seconds and leave from being counted
BetaConfig.MINIMUM_BLOCKS_FOR_BETA = 3000

-- ============================================
-- PREMIUM GAMEPASS ID (same as in PlotSignHandler)
-- ============================================
BetaConfig.PREMIUM_GAMEPASS_ID = 1676832631

-- ============================================
-- FREE BUILD PLACE (second place — shares public source)
-- ============================================
-- The free-build sandbox runs off the SAME source as the main plots game, just
-- on a different place in the same universe. Plot persistence (load/save/autosave)
-- must NOT run there, or it would read/write the player's real plot save in the
-- shared-universe DataStore. This is the single source of truth for that gate,
-- referenced by PlotManager (terrain) and SaveManager (persistence).
-- Add any additional free-build place IDs here.
BetaConfig.FREE_BUILD_PLACE_IDS = {
	[117001994964531] = true,  -- BuildBlox Free Build (public universe)
}

function BetaConfig.IsFreeBuildPlace()
	return BetaConfig.FREE_BUILD_PLACE_IDS[game.PlaceId] == true
end

return BetaConfig
