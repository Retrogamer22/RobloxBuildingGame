--[[
	ChunkStreamManager.luau
	FREE-BUILD (SECOND) PLACE ONLY.  Server module.

	Ashborne-style streaming terrain for the free-build world: small chunks load
	around each player as they move and unload when far away, so the world feels
	endless and flying around stays smooth, with a fast first join (only nearby
	chunks generate up front).

	WHY THIS EXISTS (vs ChunkTerrainManager):
	ChunkTerrainManager generates a fixed grid of large 32-block chunks once and
	keeps them forever -- fine for a small static world, but it does not stream and
	the big chunks cause hitches. This manager matches Ashborne's proven approach:
	small 10-block chunks (30 studs, since BLOCK_SIZE = 3 in both) with a load
	radius around the player. Small chunks = granular, cheap load/unload = smooth.

	STAGE 1 (this file): streaming only. Generation reuses the existing, tuned
	TerrainGenerator.GenerateDefaultTerrain (so biomes/height/snow/culling all carry
	over) by pointing the buildArea's BasePlate* window at each 30-stud chunk.
	PLAYER BUILDS ARE NEVER LOST: a chunk that contains ANY player modification
	(placed or broken block) is pinned and never unloaded. Only pristine generated
	terrain streams out. (Stage 2 will add a DataStore diff so touched chunks can
	unload and restore -- deliberately not here yet.)

	GATING: PlotManager decides whether to start this, based on PlaceId. This
	module never runs itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Same handler-suppression flags generation uses. Destroying a chunk's worth of
-- terrain fires ChildRemoved on the Blocks folder, which would otherwise trigger
-- the per-block handlers (GrassSpread, LeafDecay, FallingBlock, neighbor updates,
-- spatial index) hundreds of times synchronously and freeze/crash the server.
-- We suppress that cascade during the unload destroy. NOTE: this flag is a simple
-- per-buildArea on/off (NOT ref-counted), and a concurrent chunk GENERATION may
-- already hold it -- so the unload only Start/Ends the flag if no bulk op is
-- currently active, and otherwise leaves the generation's flag untouched (handlers
-- are already suppressed). This avoids an unload prematurely re-enabling handlers
-- in the middle of a still-yielding generation on the same buildArea.
local BulkOperationFlags = nil
pcall(function()
	BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))
end)

local ChunkStreamManager = {}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE -- 3

-- ============================================
-- STREAMING SETTINGS  (mirrors Ashborne)
-- ============================================
-- Chunk side in blocks. Ashborne uses 10 (=30 studs at BLOCK_SIZE 3). Small
-- chunks are the whole point: they make load/unload granular and lag-free.
local CHUNK_BLOCKS = 10
local CHUNK_STUDS = CHUNK_BLOCKS * BLOCK_SIZE -- 30

-- How many chunks out from the player to keep loaded. Each chunk runs the FULL
-- TerrainGenerator (not a cheap array fill like Ashborne), so the loaded set has
-- to stay small enough to actually finish generating. 2 => a 5x5 window of
-- 30-stud chunks (~the visual extent of the old static grid, but streaming).
-- Ashborne's 5 works there only because its chunks are array-backed and cheap;
-- here 5 (=121 chunks) can never catch up and the loader thrashes forever.
local LOAD_DISTANCE = 2

-- Seconds a chunk must be out of range before it actually unloads. Prevents
-- thrash when a player hovers near a chunk border.
local UNLOAD_DELAY = 8

-- How often (seconds) we re-evaluate each player's chunk and adjust loaded set.
local UPDATE_INTERVAL = 0.5

-- Max chunk GENERATIONS started per update tick. Must be high enough that the
-- whole loaded window (with LOAD_DISTANCE 2 => 25 chunks) fills within a few
-- ticks, otherwise the loader never catches up to a moving player and churns.
-- 25 chunks at 5/tick fills in ~5 ticks (~2.5s), then only the leading edge
-- generates as the player moves.
local MAX_LOADS_PER_TICK = 5

-- Single shared world seed (must match what the center chunk used so the field
-- is continuous). Mirrors ChunkTerrainManager.WORLD_SEED.
local WORLD_SEED = 1337

local DEBUG = true

local function log(...)
	if DEBUG then print("[BB-STREAM]", ...) end
end

-- TerrainGenerator is injected by the caller (PlotManager), same as
-- ChunkTerrainManager, to avoid a second require chain.
local TerrainGenerator = nil

-- ============================================
-- STATE
-- ============================================
-- Per-buildArea streaming state. Keyed weakly so a removed buildArea's state is
-- collected. Each entry:
--   loaded      = { [chunkKey] = true }            chunks currently generated
--   pinned      = { [chunkKey] = true }            chunks with player edits (never unload in Stage 1)
--   pendingUnload = { [chunkKey] = os.clock() }     chunks waiting out UNLOAD_DELAY
--   centerCX/CZ = the chunk coords of the spawn/center chunk (never unloads)
--   originX/Z   = world studs of chunk (0,0) center (the buildArea's plot center)
--   plotNumber  = the real plot number for this buildArea
--   running     = whether the update loop is active
local StreamState = setmetatable({}, { __mode = "k" })

-- ============================================
-- INIT
-- ============================================
function ChunkStreamManager.Init(terrainGenerator)
	TerrainGenerator = terrainGenerator
end

-- ============================================
-- CHUNK MATH
-- ============================================
local function chunkKey(cx, cz)
	return cx .. "_" .. cz
end

-- Stable pseudo plot number per chunk so TerrainGenerator's per-plot guards
-- (GeneratedPlots, dug tracking, RNG) treat each chunk independently. Center
-- chunk keeps the real plot number so existing plot wiring stays intact.
local function chunkPlotNumber(realPlotNumber, cx, cz)
	if cx == 0 and cz == 0 then
		return realPlotNumber
	end
	-- High band unlikely to collide with real plots; encodes cx,cz uniquely.
	return 200000 + (cx + 500) * 1000 + (cz + 500)
end

-- World studs (center) of chunk (cx,cz), relative to the origin chunk center.
local function chunkCenterStuds(state, cx, cz)
	return state.originX + cx * CHUNK_STUDS, state.originZ + cz * CHUNK_STUDS
end

-- Which chunk a world-stud position falls in (relative to origin chunk).
local function worldToChunk(state, wx, wz)
	local cx = math.floor((wx - state.originX) / CHUNK_STUDS + 0.5)
	local cz = math.floor((wz - state.originZ) / CHUNK_STUDS + 0.5)
	return cx, cz
end

-- ============================================
-- STATE SETUP
-- ============================================
-- Reads the buildArea's plot center from its BasePlate* attributes and pins
-- chunk (0,0) there. The center chunk is whatever the join sequence already
-- generated (PlotManager calls ChunkTerrainManager.GenerateCenterChunk first),
-- so we do NOT regenerate (0,0); we just register it as loaded + pinned.
local function ensureState(buildArea, plotNumber)
	local state = StreamState[buildArea]
	if state then return state end

	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	if not (posX and posZ) then
		local basePlate = buildArea:FindFirstChild("BasePlate")
		if basePlate then
			posX, posZ = basePlate.Position.X, basePlate.Position.Z
		else
			warn("[BB-STREAM] buildArea has no BasePlate position; cannot anchor stream")
			return nil
		end
	end

	state = {
		loaded = {},
		pinned = {},
		pendingUnload = {},
		originX = posX,
		originZ = posZ,
		centerCX = 0,
		centerCZ = 0,
		plotNumber = plotNumber,
		running = false,
	}
	StreamState[buildArea] = state
	return state
end

-- ============================================
-- GENERATION (reuse existing tuned terrain)
-- ============================================
-- Generate one 30-stud chunk by pointing the buildArea's BasePlate* window at it,
-- calling GenerateDefaultTerrain, then restoring the window. This is the same
-- attribute-shift pattern ChunkTerrainManager uses; it's required because the
-- spawn teleport reads those SAME attributes, so we must always leave them
-- describing the center chunk when we're done.
local function generateChunk(buildArea, state, cx, cz)
	if not TerrainGenerator then
		warn("[BB-STREAM] not initialized (TerrainGenerator missing)")
		return false
	end

	local key = chunkKey(cx, cz)
	if state.loaded[key] then return true end

	-- Center chunk is generated by the join sequence; never re-generate it here.
	if cx == state.centerCX and cz == state.centerCZ then
		state.loaded[key] = true
		return true
	end

	local savedPosX = buildArea:GetAttribute("BasePlatePositionX")
	local savedPosZ = buildArea:GetAttribute("BasePlatePositionZ")
	local savedSizeX = buildArea:GetAttribute("BasePlateSizeX")
	local savedSizeZ = buildArea:GetAttribute("BasePlateSizeZ")

	local centerX, centerZ = chunkCenterStuds(state, cx, cz)

	buildArea:SetAttribute("BasePlatePositionX", centerX)
	buildArea:SetAttribute("BasePlatePositionZ", centerZ)
	buildArea:SetAttribute("BasePlateSizeX", CHUNK_STUDS)
	buildArea:SetAttribute("BasePlateSizeZ", CHUNK_STUDS)

	local pseudoPlot = chunkPlotNumber(state.plotNumber, cx, cz)

	-- Snapshot the Blocks folder children BEFORE generation so we can record
	-- exactly what this chunk adds (terrain + trees + decorations alike). Lua is
	-- single-threaded and generateChunk is called sequentially (not task.spawn'd),
	-- so even though generation yields, no other chunk generates concurrently --
	-- the after-minus-before difference is precisely this chunk's instances.
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	local before = {}
	if blocksFolder then
		for _, child in ipairs(blocksFolder:GetChildren()) do
			before[child] = true
		end
	end

	local ok, err = pcall(function()
		TerrainGenerator.GenerateDefaultTerrain(buildArea, pseudoPlot, WORLD_SEED, nil, true)
	end)

	-- Always restore the center window so the buildArea never describes a
	-- surrounding chunk (the spawn teleport depends on this).
	buildArea:SetAttribute("BasePlatePositionX", savedPosX)
	buildArea:SetAttribute("BasePlatePositionZ", savedPosZ)
	buildArea:SetAttribute("BasePlateSizeX", savedSizeX)
	buildArea:SetAttribute("BasePlateSizeZ", savedSizeZ)

	if not ok then
		warn("[BB-STREAM] chunk gen failed", key, err)
		return false
	end

	-- Record everything that appeared during generation as this chunk's instances,
	-- so unload can destroy exactly them (O(chunk), and complete -- no leftovers).
	if not state.chunkInstances then state.chunkInstances = {} end
	if blocksFolder then
		local added = {}
		for _, child in ipairs(blocksFolder:GetChildren()) do
			if not before[child] then
				table.insert(added, child)
			end
		end
		state.chunkInstances[key] = added
	end

	state.loaded[key] = true
	log("generated chunk", key, "at", centerX, centerZ, "(" .. tostring(state.chunkInstances[key] and #state.chunkInstances[key] or 0) .. " blocks)")
	return true
end

-- ============================================
-- UNLOAD (bounds-scoped, build-safe)
-- ============================================
-- Destroy ONLY pristine generated terrain inside this chunk's world bounds.
-- A block is removed only if it is IsTerrainBlock AND NOT IsLazyLoaded (pure
-- generated terrain). Player-placed blocks (no IsTerrainBlock) and dug-modified /
-- lazy blocks are left untouched -- though in Stage 1 a chunk with ANY edit is
-- pinned upstream and never reaches here. Edges treated inclusively so we don't
-- shave a neighbor's blocks.
local function unloadChunk(buildArea, state, cx, cz)
	local key = chunkKey(cx, cz)
	if not state.loaded[key] then return true end

	-- Never unload the center / spawn chunk.
	if cx == state.centerCX and cz == state.centerCZ then
		return false
	end

	-- Safety: never unload a chunk a player has modified (Stage 1 guarantee).
	if state.pinned[key] then
		return false
	end

	-- Destroy exactly the instances this chunk generated (tracked at gen time).
	-- This is O(chunk) -- no full Blocks-folder scan -- so unloading many chunks at
	-- once no longer lags, and it catches trees + decorations that don't carry
	-- position attributes, so nothing is left floating. Player-placed and lazy/dug
	-- blocks were never in this list (a touched chunk is pinned and never reaches
	-- here), but we still skip them defensively.
	if not state.chunkInstances then state.chunkInstances = {} end
	local instances = state.chunkInstances[key]
	if instances and #instances > 0 then
		local blocksFolder = buildArea:FindFirstChild("Blocks")

		-- Suppress the per-block handlers that fire on block removal. There are TWO
		-- separate suppression mechanisms in this codebase and the unload must set
		-- BOTH or the O(n) ChildRemoved handlers (decoration cleanup, leaf decay,
		-- falling block, pressure plate, water, chest, lighting, spatial index) each
		-- run per destroyed block and time out the server:
		--   1. BulkOperationFlags  (buildArea-level, checked by ChildAdded-style handlers)
		--   2. the Blocks folder's "BulkRemoving" attribute (checked by the ChildRemoved
		--      cleanup handlers in TerrainGenerator and friends -- this is the one the
		--      timeout stack pointed at).
		local weStartedBulk = false
		if BulkOperationFlags then
			local active = false
			pcall(function() active = BulkOperationFlags.IsBulkOperation(buildArea) end)
			if not active then
				pcall(function() BulkOperationFlags.StartBulkOperation(buildArea, "chunk_unload") end)
				weStartedBulk = true
			end
		end

		-- Set BulkRemoving only if not already set (a concurrent op may own it).
		local weSetBulkRemoving = false
		if blocksFolder and not blocksFolder:GetAttribute("BulkRemoving") then
			blocksFolder:SetAttribute("BulkRemoving", true)
			weSetBulkRemoving = true
		end

		for _, block in ipairs(instances) do
			if block and block.Parent then
				-- Defensive: never destroy a player build or lazy/dug block.
				if block:GetAttribute("IsLazyLoaded") then
					-- skip
				else
					block:Destroy()
				end
			end
		end

		if weSetBulkRemoving and blocksFolder then
			blocksFolder:SetAttribute("BulkRemoving", false)
		end
		if weStartedBulk then
			pcall(function() BulkOperationFlags.EndBulkOperation(buildArea) end)
		end
	end
	state.chunkInstances[key] = nil

	-- Clear the per-chunk generation guard so this chunk can regenerate later.
	local pseudoPlot = chunkPlotNumber(state.plotNumber, cx, cz)
	if TerrainGenerator and TerrainGenerator.ResetPlot then
		pcall(function() TerrainGenerator.ResetPlot(pseudoPlot) end)
	end

	state.loaded[key] = nil
	log("unloaded chunk", key)
	return true
end

-- ============================================
-- PLAYER -> CHUNK
-- ============================================
local function getPlayerChunk(state, player)
	local char = player.Character
	if not char then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
		or char:FindFirstChild("Torso")
		or char:FindFirstChild("UpperTorso")
	if not root then return nil end
	local pos = root.Position
	local cx, cz = worldToChunk(state, pos.X, pos.Z)
	return cx, cz
end

-- ============================================
-- PUBLIC: mark a chunk as modified (pin it)
-- ============================================
-- Called by the build/break hooks (gated to free-build) so we never unload a
-- chunk a player has changed. worldX/worldZ are studs.
function ChunkStreamManager.MarkModified(buildArea, worldX, worldZ)
	local state = StreamState[buildArea]
	if not state then return end
	local cx, cz = worldToChunk(state, worldX, worldZ)
	local key = chunkKey(cx, cz)
	state.pinned[key] = true
	state.pendingUnload[key] = nil
	log("pinned modified chunk", key)
end

-- ============================================
-- UPDATE TICK
-- ============================================
local function updateOnce(buildArea, state)
	if not buildArea.Parent then return false end -- buildArea gone; stop loop

	-- The owner is whoever this buildArea belongs to. Stream around them.
	-- (Free-build: one owner per buildArea, same as the plots game.)
	local ownerId = buildArea:GetAttribute("OwnerUserId")
	if not ownerId then return true end
	local owner = Players:GetPlayerByUserId(ownerId)
	if not owner then return true end -- owner not in yet; try next tick

	local pcx, pcz = getPlayerChunk(state, owner)
	if not pcx then return true end

	-- Build the needed set within LOAD_DISTANCE (square ring, like Ashborne).
	local needed = {}
	for dx = -LOAD_DISTANCE, LOAD_DISTANCE do
		for dz = -LOAD_DISTANCE, LOAD_DISTANCE do
			needed[chunkKey(pcx + dx, pcz + dz)] = { cx = pcx + dx, cz = pcz + dz }
		end
	end
	-- Center chunk is always needed.
	needed[chunkKey(state.centerCX, state.centerCZ)] = { cx = state.centerCX, cz = state.centerCZ }

	-- Load needed-but-missing chunks, nearest first, capped per tick.
	local toLoad = {}
	for key, c in pairs(needed) do
		if not state.loaded[key] then
			local ddx = c.cx - pcx
			local ddz = c.cz - pcz
			c.dist2 = ddx * ddx + ddz * ddz
			table.insert(toLoad, c)
		end
		-- Anything needed cancels a pending unload.
		state.pendingUnload[key] = nil
	end
	table.sort(toLoad, function(a, b) return a.dist2 < b.dist2 end)
	local loads = 0
	for _, c in ipairs(toLoad) do
		if loads >= MAX_LOADS_PER_TICK then break end
		if generateChunk(buildArea, state, c.cx, c.cz) then
			loads = loads + 1
		end
	end

	-- Mark loaded-but-no-longer-needed chunks for delayed unload.
	local now = os.clock()
	for key in pairs(state.loaded) do
		if not needed[key] and not state.pinned[key] then
			if not state.pendingUnload[key] then
				state.pendingUnload[key] = now
			end
		end
	end

	-- Process pending unloads past the delay.
	for key, ts in pairs(state.pendingUnload) do
		if now - ts >= UNLOAD_DELAY then
			-- Re-derive cx,cz from the key.
			local sx, sz = key:match("^(-?%d+)_(-?%d+)$")
			if sx then
				unloadChunk(buildArea, state, tonumber(sx), tonumber(sz))
			end
			state.pendingUnload[key] = nil
		end
	end

	return true
end

-- ============================================
-- ENTRY POINT
-- ============================================
-- Start streaming for a buildArea. Call AFTER the center chunk has generated and
-- the player has been teleported onto it (same ordering rule as GenerateRing:
-- the generation borrows the BasePlate* window, so it must not run until the
-- spawn teleport has read the center bounds). Idempotent: a second call is a
-- no-op while the loop is running.
function ChunkStreamManager.StartStreaming(buildArea, plotNumber)
	local state = ensureState(buildArea, plotNumber)
	if not state then return end
	if state.running then return end
	state.running = true

	-- Register the center chunk as already loaded + pinned (it's the real plot;
	-- it must never unload).
	local ck = chunkKey(state.centerCX, state.centerCZ)
	state.loaded[ck] = true
	state.pinned[ck] = true

	log("streaming started for plot", plotNumber, "chunkStuds", CHUNK_STUDS, "loadDist", LOAD_DISTANCE)

	task.spawn(function()
		while state.running do
			if not buildArea.Parent then
				state.running = false
				StreamState[buildArea] = nil
				log("buildArea gone; streaming stopped")
				return
			end
			local ok, err = pcall(updateOnce, buildArea, state)
			if not ok then
				warn("[BB-STREAM] update error:", err)
			end
			task.wait(UPDATE_INTERVAL)
		end
	end)
end

-- Stop streaming for a buildArea (e.g. owner left). Loaded chunks are left as-is.
function ChunkStreamManager.StopStreaming(buildArea)
	local state = StreamState[buildArea]
	if state then state.running = false end
end

return ChunkStreamManager
