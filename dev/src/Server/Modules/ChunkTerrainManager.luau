--[[
	ChunkTerrainManager
	===================================================================
	SECOND-PLACE ONLY. Do not call this on the main game.

	Generates a chunk-based world by reusing the existing
	TerrainGenerator.GenerateDefaultTerrain per chunk. The player's
	assigned buildArea is treated as the CENTER chunk (0,0); a
	(2*RENDER_RADIUS+1) square of chunks is generated around it.
	With RENDER_RADIUS = 1 that is a 3x3 grid.

	Each chunk reuses ALL existing terrain code (heightmap, biomes,
	decorations, trees) by handing GenerateDefaultTerrain a set of
	BasePlate* attributes shifted in world space by the chunk offset.

	Built so dynamic streaming drops in later: loadChunk(cx,cz) and
	unloadChunk(cx,cz) are the only primitives. "Static 3x3" is just a
	double loop over them. Streaming = call the same two functions based
	on player position each step.

	Gating: the CALLER (PlotManager) decides whether to invoke this,
	based on game.PlaceId. This module never runs itself.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

local ChunkTerrainManager = {}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local BUILD_AREA_PREFIX = GridConfig.BUILD_AREA_PREFIX

-- ============================================
-- CHUNK SETTINGS
-- ============================================
-- Size of one chunk, in blocks per side. The center chunk inherits the
-- assigned buildArea's footprint; surrounding chunks are this size.
local CHUNK_BLOCKS = 32

-- 1 => 3x3, 2 => 5x5, 3 => 7x7, etc. (2*RENDER_RADIUS+1) chunks per side.
local RENDER_RADIUS = 2

local DEBUG_CHUNKS = true

-- Single shared seed for the WHOLE chunk world. Every chunk feeds this same
-- seed to GenerateDefaultTerrain so the heightmap noise field is continuous
-- across chunk borders (Minecraft-like). Combined with the world-space biome
-- field (TerrainGenerator's worldContinuous path), adjacent chunks line up
-- seamlessly. Fixed constant => every server renders the same recognizable world.
local WORLD_SEED = 1337

-- TerrainGenerator is injected by the caller so we don't create a second
-- require chain / circular dependency.
local TerrainGenerator = nil

-- Per-buildArea chunk state: [buildArea] = { loaded = { ["cx_cz"] = true }, baseX, baseZ, baseTop, plotNumber }
local ChunkState = setmetatable({}, { __mode = "k" })

local function log(...)
	if DEBUG_CHUNKS then
		print("[BB-CHUNK]", ...)
	end
end

local function chunkKey(cx, cz)
	return cx .. "_" .. cz
end

-- Derive a stable, collision-resistant pseudo "plotNumber" for a chunk so
-- TerrainGenerator's per-plot guards (GeneratedPlots, dug tracking, RNG seed)
-- treat each chunk independently. Center chunk (0,0) keeps the real plot
-- number so existing plot wiring (ownership, grass, saves) stays intact.
local function chunkPlotNumber(realPlotNumber, cx, cz)
	if cx == 0 and cz == 0 then
		return realPlotNumber
	end
	-- Offset into a high numeric band unlikely to collide with real plots
	-- (TOTAL_PLOTS is small). Encodes cx,cz uniquely.
	return 100000 + (cx + 50) * 1000 + (cz + 50)
end

-- ============================================
-- INIT
-- ============================================
function ChunkTerrainManager.Init(terrainGenerator)
	TerrainGenerator = terrainGenerator
end

-- ============================================
-- WORLD CONTAINER (this place has NO pre-placed plots)
-- ============================================
-- The main game ships pre-placed BuildArea{N} models (each with a BasePlate) and
-- PlotManager just looks them up. This place has NONE -- the world is meant to
-- spawn as chunks around an origin. So we fabricate the plot container on demand:
-- a Model named BuildArea{N} plus the BasePlate* ATTRIBUTES the terrain generator
-- and the spawn teleport read. No physical baseplate part is created; the
-- attributes are the anchor and the generated grass surface is the floor.
--
-- Surface top sits at Y=0 (origin). We keep the main game's invariant
-- BasePlateTop == BasePlatePositionY + BasePlateSizeY/2 so teleportToPlot's
-- fallback (posY + sizeY/2) lands the player on the surface.
local CHUNK_PLATE_THICKNESS = 10
function ChunkTerrainManager.EnsureCenterBuildArea(plotNumber)
	local name = BUILD_AREA_PREFIX .. plotNumber
	local existing = workspace:FindFirstChild(name)
	if existing then return existing end

	local footprint = CHUNK_BLOCKS * BLOCK_SIZE

	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("BasePlatePositionX", 0)
	model:SetAttribute("BasePlatePositionY", -CHUNK_PLATE_THICKNESS / 2)
	model:SetAttribute("BasePlatePositionZ", 0)
	model:SetAttribute("BasePlateSizeX", footprint)
	model:SetAttribute("BasePlateSizeY", CHUNK_PLATE_THICKNESS)
	model:SetAttribute("BasePlateSizeZ", footprint)
	model:SetAttribute("BasePlateTop", 0)

	local blocks = Instance.new("Folder")
	blocks.Name = "Blocks"
	blocks.Parent = model

	model.Parent = workspace
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	log("created synthetic build area", name, "at origin (no pre-placed plot)")
	return model
end

-- ============================================
-- CAPTURE CENTER CHUNK ORIGIN
-- ============================================
-- Reads the assigned buildArea's footprint and records it as the anchor
-- for chunk (0,0). Surrounding chunks are placed relative to this.
local function ensureState(buildArea, realPlotNumber)
	local state = ChunkState[buildArea]
	if state then
		return state
	end

	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	local plateTop = buildArea:GetAttribute("BasePlateTop")

	-- Fall back to the BasePlate part if attributes aren't populated yet.
	if not (posX and posZ and sizeX and sizeZ) then
		local basePlate = buildArea:FindFirstChild("BasePlate")
		if not basePlate then
			warn("[BB-CHUNK] buildArea has no BasePlate or attributes; cannot anchor chunks")
			return nil
		end
		posX, posZ = basePlate.Position.X, basePlate.Position.Z
		sizeX, sizeZ = basePlate.Size.X, basePlate.Size.Z
		plateTop = basePlate.Position.Y + basePlate.Size.Y / 2
	end

	state = {
		loaded = {},
		realPlotNumber = realPlotNumber,
		centerPosX = posX,
		centerPosZ = posZ,
		-- Distance between chunk centers in studs. Use the chunk size so
		-- surrounding chunks tile edge-to-edge with the center footprint.
		strideX = CHUNK_BLOCKS * BLOCK_SIZE,
		strideZ = CHUNK_BLOCKS * BLOCK_SIZE,
		chunkSizeX = CHUNK_BLOCKS * BLOCK_SIZE,
		chunkSizeZ = CHUNK_BLOCKS * BLOCK_SIZE,
		plateTop = plateTop or 1.5,
		-- Preserve the center chunk's real footprint so (0,0) regenerates
		-- identically to a normal plot if ever reloaded.
		centerSizeX = sizeX,
		centerSizeZ = sizeZ,
	}
	ChunkState[buildArea] = state
	return state
end

-- ============================================
-- LOAD / UNLOAD PRIMITIVES (streaming-ready)
-- ============================================

-- Generate one chunk into the buildArea. Reuses GenerateDefaultTerrain by
-- temporarily setting the BasePlate* attributes to this chunk's bounds,
-- generating, then restoring the center attributes.
function ChunkTerrainManager.loadChunk(buildArea, realPlotNumber, cx, cz)
	if not TerrainGenerator then
		warn("[BB-CHUNK] not initialized (TerrainGenerator missing)")
		return false
	end

	local state = ensureState(buildArea, realPlotNumber)
	if not state then return false end

	local key = chunkKey(cx, cz)
	if state.loaded[key] then
		log("chunk already loaded", key)
		return true
	end

	-- Center chunk: same shared world seed + world-continuous biome field as
	-- every other chunk, so the origin tile lines up seamlessly with the ring.
	if cx == 0 and cz == 0 then
		TerrainGenerator.GenerateDefaultTerrain(buildArea, realPlotNumber, WORLD_SEED, nil, true)
		state.loaded[key] = true
		log("center chunk generated", key)
		return true
	end

	-- Surrounding chunk: shift bounds, generate, restore.
	local savedPosX = buildArea:GetAttribute("BasePlatePositionX")
	local savedPosZ = buildArea:GetAttribute("BasePlatePositionZ")
	local savedSizeX = buildArea:GetAttribute("BasePlateSizeX")
	local savedSizeZ = buildArea:GetAttribute("BasePlateSizeZ")

	local chunkPosX = state.centerPosX + cx * state.strideX
	local chunkPosZ = state.centerPosZ + cz * state.strideZ

	buildArea:SetAttribute("BasePlatePositionX", chunkPosX)
	buildArea:SetAttribute("BasePlatePositionZ", chunkPosZ)
	buildArea:SetAttribute("BasePlateSizeX", state.chunkSizeX)
	buildArea:SetAttribute("BasePlateSizeZ", state.chunkSizeZ)

	-- Every chunk shares ONE world seed so the noise field is continuous; the
	-- world-space biome field (worldContinuous = true) keeps biomes + height
	-- blending seamless across the shared border. The pseudo plot number only
	-- drives TerrainGenerator's per-chunk guards (GeneratedPlots, dug tracking).
	local pseudoPlot = chunkPlotNumber(realPlotNumber, cx, cz)

	local ok, err = pcall(function()
		TerrainGenerator.GenerateDefaultTerrain(buildArea, pseudoPlot, WORLD_SEED, nil, true)
	end)

	-- Restore center attributes no matter what so the buildArea is never
	-- left describing a surrounding chunk.
	buildArea:SetAttribute("BasePlatePositionX", savedPosX)
	buildArea:SetAttribute("BasePlatePositionZ", savedPosZ)
	buildArea:SetAttribute("BasePlateSizeX", savedSizeX)
	buildArea:SetAttribute("BasePlateSizeZ", savedSizeZ)

	if not ok then
		warn("[BB-CHUNK] chunk gen failed", key, err)
		return false
	end

	state.loaded[key] = true
	log("chunk generated", key, "at", chunkPosX, chunkPosZ)
	return true
end

-- Unload primitive. Today static 3x3 never unloads, but streaming needs this.
-- Clears the chunk's generated blocks via TerrainGenerator's per-plot clear,
-- keyed by the same pseudo plot number used to generate it.
function ChunkTerrainManager.unloadChunk(buildArea, realPlotNumber, cx, cz)
	local state = ChunkState[buildArea]
	if not state then return false end

	local key = chunkKey(cx, cz)
	if not state.loaded[key] then return true end

	-- Center chunk is the real plot; never auto-unload it here.
	if cx == 0 and cz == 0 then
		log("refusing to unload center chunk")
		return false
	end

	local pseudoPlot = chunkPlotNumber(realPlotNumber, cx, cz)
	if TerrainGenerator and TerrainGenerator.ClearTerrain then
		pcall(function()
			TerrainGenerator.ClearTerrain(buildArea, pseudoPlot)
		end)
	end

	state.loaded[key] = nil
	log("chunk unloaded", key)
	return true
end

-- ============================================
-- STATIC 3x3 ENTRY POINTS (split: center now, ring after spawn)
-- ============================================
-- The ring's loadChunk temporarily rewrites the buildArea's BasePlate*
-- attributes while generating each surrounding chunk, then restores them. The
-- spawn teleport (PlotManager.teleportToPlot) reads those SAME attributes to
-- find the plot. So the ring MUST NOT run until the player has been teleported
-- onto the center, or they spawn over a neighbor chunk (often still empty) and
-- fall into the void. Hence the center/ring split below.

-- Center chunk only. SYNCHRONOUS. Safe to call on the join thread
-- (assignPlot): one plot's worth of terrain, returns quickly, and it never
-- borrows the BasePlate* attributes (the center IS the plot), so the spawn
-- teleport reads correct bounds.
function ChunkTerrainManager.GenerateCenterChunk(buildArea, realPlotNumber)
	ensureState(buildArea, realPlotNumber)

	-- Readiness flag the chunk loading screen watches. Cleared here, set true only
	-- AFTER the center chunk's blocks finish spawning. loadChunk -> GenerateDefaultTerrain
	-- runs the block spawn IN THIS THREAD (it yields with task.wait but does not
	-- return until every center block exists), so once loadChunk returns the player
	-- has real ground + immediate surroundings -- exactly the moment to drop the
	-- screen. The outer ring keeps filling in afterward (see ChunkRingComplete).
	if buildArea:GetAttribute("ChunkCenterReady") ~= true then
		buildArea:SetAttribute("ChunkCenterReady", false)
	end

	ChunkTerrainManager.loadChunk(buildArea, realPlotNumber, 0, 0)

	if buildArea.Parent then
		buildArea:SetAttribute("ChunkCenterReady", true)
	end
	log("center chunk generated for plot", realPlotNumber)
end

-- Surrounding ring, in the BACKGROUND. Call ONLY after the player has spawned
-- and been teleported (see attribute note above). loadChunk is idempotent
-- (skips already-loaded chunks), so calling this again on respawn is a no-op,
-- and the ringStarted guard keeps a second concurrent loop from starting.
function ChunkTerrainManager.GenerateRing(buildArea, realPlotNumber)
	local state = ensureState(buildArea, realPlotNumber)
	if not state then return end
	if state.ringStarted then return end
	state.ringStarted = true

	-- Readiness flag the client loading screen watches. Cleared now (ring not
	-- done), set true when the whole 3x3 has generated. The client reads it via
	-- GetAttribute / GetAttributeChangedSignal on its buildArea, so a player who
	-- joins an already-ringed plot (e.g. respawn) sees true immediately and a
	-- player who joins mid-gen waits for the change. No remote/player plumbing.
	if buildArea:GetAttribute("ChunkRingComplete") ~= true then
		buildArea:SetAttribute("ChunkRingComplete", false)
	end

	task.spawn(function()
		for cx = -RENDER_RADIUS, RENDER_RADIUS do
			for cz = -RENDER_RADIUS, RENDER_RADIUS do
				if not (cx == 0 and cz == 0) then
					-- Player may have left (or the plot got reassigned) mid-gen.
					if not buildArea.Parent then
						log("buildArea gone, aborting ring gen")
						state.ringStarted = false
						return
					end
					ChunkTerrainManager.loadChunk(buildArea, realPlotNumber, cx, cz)
					task.wait() -- yield a frame between chunks
				end
			end
		end
		-- Whole ring is in. Tell the client world it's safe to drop the
		-- "Loading World" screen (the floor + surrounding terrain all exist).
		if buildArea.Parent then
			buildArea:SetAttribute("ChunkRingComplete", true)
		end
		log("static grid ring complete")
	end)
end

-- Convenience: center + ring together. Kept for streaming/other callers.
-- PlotManager does NOT use this -- it sequences GenerateCenterChunk (on claim)
-- then GenerateRing (after the spawn teleport) so the spawn can't race the
-- attribute swap.
function ChunkTerrainManager.GenerateStaticGrid(buildArea, realPlotNumber)
	ChunkTerrainManager.GenerateCenterChunk(buildArea, realPlotNumber)
	ChunkTerrainManager.GenerateRing(buildArea, realPlotNumber)
end

return ChunkTerrainManager
