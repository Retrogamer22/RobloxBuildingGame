-- SmokeManager.server.luau
-- DEPRECATED: Server-side smoke simulation has been moved to the client.
-- See: src/Client/SmokeController.client.luau
--
-- WHY: Server-side particle simulation replicated every position update over the
-- network at ~30 Hz, which felt choppy and ate bandwidth. The client-side version
-- runs at full framerate per player with zero replication cost, and the block-
-- above detection still works because workspace:Raycast() behaves identically on
-- both sides.
--
-- The per-campfire tagging script (Decorations/Campfire/Smoke Particles.server.luau)
-- still runs and adds the "Campfire" CollectionService tag to placed campfires.
-- Tags replicate automatically, so the client controller sees them.
--
-- This file is kept (as a no-op) only to make the migration easy to revert if
-- needed. Once the client version is confirmed working in production, this file
-- can be deleted entirely without consequence.

print("[SmokeManager] No-op: smoke simulation moved to client (SmokeController.client.luau)")
