--[[
	ChunkStreamManager.luau
	FREE-BUILD (SECOND) PLACE ONLY.  Server module.

	ONE SHARED WORLD PER SERVER. The free-build place is a single continuous world
	that every player in the server occupies together -- there are NO per-player
	build plates. The server streams terrain around the UNION of all players: a
	chunk loads when ANY player is near it and unloads only when NO player is near
	it. Everyone sees the same blocks in the same place (chunk coords are absolute
	to world origin), so two players standing together see identical terrain.

	Per-player "you don't see someone else's distant chunks pop" is handled
	CLIENT-side (a separate visibility script fades chunks not near the local
	player). This module's job is just to keep the shared set of nearby chunks
	generated on the server.

	WHY THIS EXISTS (vs ChunkTerrainManager):
	ChunkTerrainManager generates a fixed grid of large 32-block chunks once and
	keeps them forever. This manager streams small 10-block chunks (30 studs, since
	BLOCK_SIZE = 3) around the players so the world feels endless and stays smooth.

	GENERATION reuses the existing tuned TerrainGenerator.GenerateDefaultTerrain (so
	biomes/height/snow/culling all carry over) by pointing the world container's
	BasePlate* window at each 30-stud chunk.

	GATING: PlotManager decides whether to start this, based on PlaceId. This module
	never runs itself.

	=====================================================================
	PER-CHUNK FOLDERS (the real Ashborne structure)
	=====================================================================
	Each chunk's parts live in their OWN folder so tearing one down is a single
	isolated Destroy that fires no events on any shared folder and cannot leave a
	stray. Generated terrain does NOT live in the shared Blocks folder (where player
	builds, the spatial index, the save managers, and every per-block handler
	operate). Instead each chunk gets its own folder:

	    worldContainer.StreamTerrain.Chunk_<key>

	GenerateDefaultTerrain still parents into Blocks (shared code we don't touch), so
	generateChunk SNAPSHOTS what the call added and REPARENTS that batch into the
	chunk's StreamTerrain sub-folder. From then on:
	  * Unload = StreamTerrain.Chunk_<key>:Destroy() -- one isolated destroy, zero
	    orphans, and NO ChildRemoved cascade on Blocks (no handler watches
	    StreamTerrain), which kills the timeout cascade by construction.
	  * Player builds still go in Blocks exactly as before -- the flat-Blocks
	    systems are completely untouched, and builds are shared by everyone.
	  * Breaking streamed terrain: BlockHandler (free-build branch) accepts a block
	    parented under StreamTerrain and pins its chunk via MarkModified so the
	    chunk's folder never unloads out from under the edit.

	Consequence (accepted): grass-spread / decoration growth do NOT run on streamed
	terrain (those handlers only watch Blocks). Fine for scenery.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Handler-suppression flags, used ONLY while reparenting a freshly generated batch
-- OUT of the shared Blocks folder into the chunk's StreamTerrain sub-folder (that
-- move fires ChildRemoved on Blocks). The unload itself needs no suppression at all.
local BulkOperationFlags = nil
pcall(function()
	BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))
end)

local ChunkStreamManager = {}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE -- 3

-- Sibling folder (under the world container) holding all per-chunk terrain folders.
local STREAM_FOLDER_NAME = "StreamTerrain"

-- ============================================
-- STREAMING SETTINGS  (mirrors Ashborne)
-- ============================================
local CHUNK_BLOCKS = 10
local CHUNK_STUDS = CHUNK_BLOCKS * BLOCK_SIZE -- 30

-- How many chunks out from EACH player to keep loaded. 2 => a 5x5 window per
-- player; the loaded set is the union across all players.
local LOAD_DISTANCE = 2

-- Seconds a chunk must be needed by NO player before it actually unloads.
local UNLOAD_DELAY = 8

-- Max chunk UNLOADS / GENERATIONS performed per update tick (spread work out).
local MAX_UNLOADS_PER_TICK = 2
local MAX_LOADS_PER_TICK = 5

-- Batch size for reparenting a freshly generated chunk into its folder.
local REPARENT_BATCH_SIZE = 50

-- How often (seconds) we re-evaluate the union and adjust the loaded set.
local UPDATE_INTERVAL = 0.5

-- Single shared world seed (the continuous field every chunk samples).
local WORLD_SEED = 1337

local DEBUG = true

local function log(...)
	if DEBUG then print("[BB-STREAM]", ...) end
end

-- TerrainGenerator is injected by the caller (PlotManager).
local TerrainGenerator = nil

-- ============================================
-- SHARED-WORLD STATE  (one per server, not per player)
-- ============================================
-- There is exactly ONE shared world container. We hold a single module-level
-- state for it. Fields:
--   container     = the world Model/Folder (holds Blocks + StreamTerrain)
--   loaded        = { [chunkKey] = true }       chunks currently generated
--   pinned        = { [chunkKey] = true }       chunks with player edits (never unload)
--   pendingUnload = { [chunkKey] = os.clock() }  chunks needed by nobody, waiting out the delay
--   originX/Z     = world studs that chunk (0,0) is centered on (0,0 -> shared)
--   running       = whether the update loop is active
local state = nil

-- ============================================
-- INIT
-- ============================================
function ChunkStreamManager.Init(terrainGenerator)
	TerrainGenerator = terrainGenerator
end

-- ============================================
-- CHUNK MATH  (absolute to world origin -> shared by everyone)
-- ============================================
local function chunkKey(cx, cz)
	return cx .. "_" .. cz
end

-- Stable pseudo plot number per chunk so TerrainGenerator's per-plot guards
-- (GeneratedPlots, dug tracking, RNG) treat each chunk independently.
local function chunkPlotNumber(cx, cz)
	if cx == 0 and cz == 0 then
		return 1
	end
	return 200000 + (cx + 500) * 1000 + (cz + 500)
end

local function chunkCenterStuds(cx, cz)
	return state.originX + cx * CHUNK_STUDS, state.originZ + cz * CHUNK_STUDS
end

local function worldToChunk(wx, wz)
	local cx = math.floor((wx - state.originX) / CHUNK_STUDS + 0.5)
	local cz = math.floor((wz - state.originZ) / CHUNK_STUDS + 0.5)
	return cx, cz
end

-- ============================================
-- STREAM FOLDER HELPERS
-- ============================================
local function getStreamFolder(createIfMissing)
	local container = state.container
	if not container then return nil end
	local f = container:FindFirstChild(STREAM_FOLDER_NAME)
	if not f and createIfMissing then
		f = Instance.new("Folder")
		f.Name = STREAM_FOLDER_NAME
		f.Parent = container
	end
	return f
end

local function chunkFolderName(key)
	return "Chunk_" .. key
end

-- ============================================
-- GENERATION (reuse existing tuned terrain, then move into the chunk folder)
-- ============================================
local function generateChunk(cx, cz)
	if not TerrainGenerator then
		warn("[BB-STREAM] not initialized (TerrainGenerator missing)")
		return false
	end
	local container = state.container
	if not container then return false end

	local key = chunkKey(cx, cz)
	if state.loaded[key] then return true end

	local savedPosX = container:GetAttribute("BasePlatePositionX")
	local savedPosZ = container:GetAttribute("BasePlatePositionZ")
	local savedSizeX = container:GetAttribute("BasePlateSizeX")
	local savedSizeZ = container:GetAttribute("BasePlateSizeZ")

	local centerX, centerZ = chunkCenterStuds(cx, cz)

	container:SetAttribute("BasePlatePositionX", centerX)
	container:SetAttribute("BasePlatePositionZ", centerZ)
	container:SetAttribute("BasePlateSizeX", CHUNK_STUDS)
	container:SetAttribute("BasePlateSizeZ", CHUNK_STUDS)

	local pseudoPlot = chunkPlotNumber(cx, cz)

	-- Snapshot Blocks children BEFORE generation; the after-minus-before diff is
	-- precisely this chunk's blocks, which we then relocate into its own folder.
	local blocksFolder = container:FindFirstChild("Blocks")
	local before = {}
	if blocksFolder then
		for _, child in ipairs(blocksFolder:GetChildren()) do
			before[child] = true
		end
	end

	local ok, err = pcall(function()
		TerrainGenerator.GenerateDefaultTerrain(container, pseudoPlot, WORLD_SEED, nil, true)
	end)

	-- Always restore the window so the container never describes a surrounding chunk.
	container:SetAttribute("BasePlatePositionX", savedPosX)
	container:SetAttribute("BasePlatePositionZ", savedPosZ)
	container:SetAttribute("BasePlateSizeX", savedSizeX)
	container:SetAttribute("BasePlateSizeZ", savedSizeZ)

	if not ok then
		warn("[BB-STREAM] chunk gen failed", key, err)
		return false
	end

	local added = {}
	if blocksFolder then
		for _, child in ipairs(blocksFolder:GetChildren()) do
			if not before[child] then
				table.insert(added, child)
			end
		end
	end

	-- Relocate the batch into this chunk's own folder (suppress Blocks handlers for
	-- the brief move, same flags generation uses; only manage the flag if free).
	local streamFolder = getStreamFolder(true)
	local chunkFolder = Instance.new("Folder")
	chunkFolder.Name = chunkFolderName(key)
	chunkFolder:SetAttribute("ChunkX", cx)
	chunkFolder:SetAttribute("ChunkZ", cz)

	local weStartedBulk = false
	if BulkOperationFlags then
		local active = false
		pcall(function() active = BulkOperationFlags.IsBulkOperation(container) end)
		if not active then
			pcall(function() BulkOperationFlags.StartBulkOperation(container, "chunk_relocate") end)
			weStartedBulk = true
		end
	end
	local weSetBulkRemoving = false
	if blocksFolder and not blocksFolder:GetAttribute("BulkRemoving") then
		blocksFolder:SetAttribute("BulkRemoving", true)
		weSetBulkRemoving = true
	end

	local moved = 0
	for _, child in ipairs(added) do
		if child and child.Parent then
			child.Parent = chunkFolder
			moved = moved + 1
			if moved % REPARENT_BATCH_SIZE == 0 then
				task.wait()
			end
		end
	end

	if weSetBulkRemoving and blocksFolder then
		blocksFolder:SetAttribute("BulkRemoving", false)
	end
	if weStartedBulk then
		pcall(function() BulkOperationFlags.EndBulkOperation(container) end)
	end

	-- Parent the populated chunk folder into the world in one shot (atomic pop-in).
	chunkFolder.Parent = streamFolder

	state.loaded[key] = true
	log("generated chunk", key, "at", centerX, centerZ, "(" .. moved .. " blocks)")
	return true
end

-- ============================================
-- UNLOAD (per-chunk folder destroy -- isolated, complete, lag-free)
-- ============================================
local function unloadChunk(cx, cz)
	local key = chunkKey(cx, cz)
	if not state.loaded[key] then return true end

	-- Never unload the spawn chunk (always-needed so spawn ground exists).
	if cx == 0 and cz == 0 then
		return false
	end

	-- Never unload a chunk a player has modified.
	if state.pinned[key] then
		return false
	end

	state.loaded[key] = nil

	local streamFolder = getStreamFolder(false)
	if streamFolder then
		local chunkFolder = streamFolder:FindFirstChild(chunkFolderName(key))
		if chunkFolder then
			-- One isolated destroy. StreamTerrain is watched by NO handler, so this
			-- fires no cascade. Reparent to nil first (stops replication immediately)
			-- and Destroy off the main path so a big folder never blocks this tick.
			chunkFolder.Parent = nil
			task.defer(function()
				chunkFolder:Destroy()
			end)
		end
	end

	local pseudoPlot = chunkPlotNumber(cx, cz)
	if TerrainGenerator and TerrainGenerator.ResetPlot then
		pcall(function() TerrainGenerator.ResetPlot(pseudoPlot) end)
	end

	log("unloaded chunk", key)
	return true
end

-- ============================================
-- PLAYER -> CHUNK
-- ============================================
local function getPlayerChunk(player)
	local char = player.Character
	if not char then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
		or char:FindFirstChild("Torso")
		or char:FindFirstChild("UpperTorso")
	if not root then return nil end
	local pos = root.Position
	return worldToChunk(pos.X, pos.Z)
end

-- ============================================
-- PUBLIC: mark a chunk as modified (pin it)
-- ============================================
-- Called by the build/break hooks (gated to free-build) so we never unload a
-- chunk a player has changed. worldX/worldZ are studs. (buildArea arg kept for
-- call-site compatibility; the shared world has a single state.)
function ChunkStreamManager.MarkModified(_buildArea, worldX, worldZ)
	if not state then return end
	local cx, cz = worldToChunk(worldX, worldZ)
	local key = chunkKey(cx, cz)
	state.pinned[key] = true
	state.pendingUnload[key] = nil
	log("pinned modified chunk", key)
end

-- Public: which chunk a world position falls in. (buildArea arg kept for
-- call-site compatibility.)
function ChunkStreamManager.GetChunkInfo(_buildArea, worldX, worldZ)
	if not state then return nil end
	local cx, cz = worldToChunk(worldX, worldZ)
	return { cx = cx, cz = cz, key = chunkKey(cx, cz) }
end

-- ============================================
-- UPDATE TICK  (union of all players)
-- ============================================
local function updateOnce()
	local container = state.container
	if not container or not container.Parent then return false end

	-- Build the UNION of every player's load window. Track the closest-player
	-- distance per chunk for load prioritization (Ashborne pattern).
	local needed = {}
	local anyPlayer = false
	for _, player in ipairs(Players:GetPlayers()) do
		local pcx, pcz = getPlayerChunk(player)
		if pcx then
			anyPlayer = true
			for dx = -LOAD_DISTANCE, LOAD_DISTANCE do
				for dz = -LOAD_DISTANCE, LOAD_DISTANCE do
					local cx, cz = pcx + dx, pcz + dz
					local d2 = dx * dx + dz * dz
					local key = chunkKey(cx, cz)
					local cur = needed[key]
					if not cur or d2 < cur.dist2 then
						needed[key] = { cx = cx, cz = cz, dist2 = d2 }
					end
				end
			end
		end
	end

	-- Spawn chunk is always needed so there's ground at the origin to land on.
	if not needed[chunkKey(0, 0)] then
		needed[chunkKey(0, 0)] = { cx = 0, cz = 0, dist2 = 0 }
	end

	-- If nobody has a character yet, do nothing (keep what's loaded).
	if not anyPlayer then return true end

	-- Load needed-but-missing chunks, closest-to-any-player first, capped per tick.
	local toLoad = {}
	for key, c in pairs(needed) do
		if not state.loaded[key] then
			table.insert(toLoad, c)
		end
		-- Anything needed cancels a pending unload.
		state.pendingUnload[key] = nil
	end
	table.sort(toLoad, function(a, b) return a.dist2 < b.dist2 end)
	local loads = 0
	for _, c in ipairs(toLoad) do
		if loads >= MAX_LOADS_PER_TICK then break end
		if generateChunk(c.cx, c.cz) then
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

	-- Process overdue unloads, capped per tick. Final re-check against `needed`
	-- in case a player moved back into range during the delay.
	local overdue = {}
	for key, ts in pairs(state.pendingUnload) do
		if now - ts >= UNLOAD_DELAY then
			table.insert(overdue, key)
		end
	end
	local unloads = 0
	for _, key in ipairs(overdue) do
		if unloads >= MAX_UNLOADS_PER_TICK then break end
		if needed[key] then
			state.pendingUnload[key] = nil
		else
			local sx, sz = key:match("^(-?%d+)_(-?%d+)$")
			if sx then
				unloadChunk(tonumber(sx), tonumber(sz))
				unloads = unloads + 1
			end
			state.pendingUnload[key] = nil
		end
	end

	return true
end

-- ============================================
-- ENTRY POINT
-- ============================================
-- Start the single shared-world streaming loop. `container` is the one world
-- Model/Folder that holds Blocks + StreamTerrain. Idempotent.
function ChunkStreamManager.StartStreaming(container)
	if state and state.running then return end

	-- Anchor the shared world at the container's plate center (normally world
	-- origin 0,0 for the free-build world).
	local posX = container:GetAttribute("BasePlatePositionX")
	local posZ = container:GetAttribute("BasePlatePositionZ")
	if not (posX and posZ) then
		local basePlate = container:FindFirstChild("BasePlate")
		if basePlate then
			posX, posZ = basePlate.Position.X, basePlate.Position.Z
		else
			posX, posZ = 0, 0
		end
	end

	state = {
		container = container,
		loaded = {},
		pinned = {},
		pendingUnload = {},
		originX = posX,
		originZ = posZ,
		running = true,
	}

	-- Spawn chunk is loaded + pinned from the start (generated by the join flow).
	local ck = chunkKey(0, 0)
	state.loaded[ck] = true
	state.pinned[ck] = true

	log("shared-world streaming started", "chunkStuds", CHUNK_STUDS, "loadDist", LOAD_DISTANCE, "origin", posX, posZ)

	task.spawn(function()
		while state and state.running do
			if not container.Parent then
				state.running = false
				log("world container gone; streaming stopped")
				return
			end
			local ok, err = pcall(updateOnce)
			if not ok then
				warn("[BB-STREAM] update error:", err)
			end
			task.wait(UPDATE_INTERVAL)
		end
	end)
end

function ChunkStreamManager.StopStreaming()
	if state then state.running = false end
end

return ChunkStreamManager
