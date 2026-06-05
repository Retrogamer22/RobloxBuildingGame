--[[
	ChunkWorldLoadingScreen.client.luau  — RETIRED / NO-OP STUB

	This script is the OLD chunk-world loading screen. It waited for the buildArea
	attribute "ChunkRingComplete", which used to be set at the end of
	ChunkTerrainManager.GenerateRing. The streaming refactor replaced GenerateRing
	with ChunkStreamManager.StartStreaming, so that attribute is never set anymore
	and this screen would sit until its 30s safety timeout EVERY join
	([ChunkWorldLoadingScreen] "Timeout after 30 s - hiding anyway").

	Its replacement is ChunkLoadingScreen.client.luau, which waits on
	"ChunkCenterReady" (still set by ChunkTerrainManager.GenerateCenterChunk) and
	dismisses the instant the player's ground exists.

	This file is intentionally emptied to a no-op so a stale synced copy can't
	show a phantom loading screen / fire the 30s timeout. It is safe to delete the
	instance from the Studio place entirely; this stub just guarantees correct
	behaviour until then. DO NOT re-add logic here -- use ChunkLoadingScreen.
]]

return
