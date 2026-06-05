--[[
	ClientChunkVisibility.client.luau
	FREE-BUILD (SECOND) PLACE ONLY.

	WHY THIS EXISTS:
	The free-build world is ONE shared world per server. The server streams the
	UNION of all players' nearby chunks, so a chunk another player is standing near
	exists as real instances that replicate to EVERYONE -- including players far
	away. Without this script, you would see distant terrain (around other players)
	pop in and out as THEY move. That's the thing we don't want.

	This script makes each client only RENDER the chunks near its own player. It
	does not generate or destroy anything -- it just sets LocalTransparencyModifier
	on each streamed chunk's parts: 0 (visible) for chunks near you, 1 (invisible)
	for chunks that exist only because some other player needs them. So from your
	view, only your own surroundings are visible, and another player's distant
	chunks never appear -- no remote pop-in.

	This mirrors Ashborne's ClientChunkVisibility (front-cone reveal), adapted to
	BuildBlox's shared-world container + per-chunk StreamTerrain folders.

	NOTE: this only affects VISUALS (LocalTransparencyModifier is client-only and
	does not change collision). Terrain you fly over still has server collision even
	while hidden; fine for a fly-around creative world.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- ============================================
-- FREE-BUILD GATE
-- ============================================
local BetaConfig
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("BetaConfig", 10))
	end)
	if not ok or not mod then return end
	BetaConfig = mod
end
if not BetaConfig.IsFreeBuildPlace() then
	return
end

-- ============================================
-- SETTINGS  (must agree with server ChunkStreamManager)
-- ============================================
local BLOCK_SIZE = 3
local CHUNK_STUDS = 30 -- 10 blocks * 3 studs (CHUNK_BLOCKS * BLOCK_SIZE)

-- Distance-based visibility with HYSTERESIS to stop chunks flickering in/out.
-- A chunk becomes visible when it's within SHOW_RADIUS and only goes invisible
-- once it's beyond the larger HIDE_RADIUS. The gap between them means a chunk
-- sitting right at the boundary (as you drift across it) does NOT rapidly toggle
-- -- it has to clearly leave the area before hiding. We do NOT use a facing/cone
-- test: that made whole chunks blink as the camera turned (the glitch). Terrain
-- visibility depends only on distance now.
local SHOW_RADIUS = 2.5  -- chunks within this (in chunks) are revealed
local HIDE_RADIUS = 3.5  -- ...and stay revealed until they pass beyond this

local UPDATE_INTERVAL = 0.15

-- TEMP: set true to log origin/player-chunk/show-hide counts ~once a second.
local DEBUG_VIS = false
local _visDbgT = 0

-- ============================================
-- STATE
-- ============================================
local chunkVisible = {}   -- chunkFolder -> bool (last applied state)
local streamFolder = nil  -- the shared world's StreamTerrain folder

-- ============================================
-- WORLD ANCHOR  (match server: chunk coords absolute to world origin)
-- ============================================
-- The shared world is anchored at world origin: chunk (0,0) is centered on (0,0),
-- chunk (cx,cz) on (cx*30, cz*30). This MUST be a constant, NOT read from the
-- container's BasePlatePosition* attributes -- the server rewrites those every
-- time it generates a chunk (it borrows the window to aim GenerateDefaultTerrain,
-- then restores it). Reading them per-tick caught those transient mid-generation
-- values, so the computed player-chunk lurched around and chunks in front of the
-- player got wrongly hidden. The anchor is fixed; only the StreamTerrain folder
-- lookup is dynamic.
local ORIGIN_X = 0
local ORIGIN_Z = 0

local function findContainer()
	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("Model") and child.Name:match("^BuildArea%d+$")
			and child:FindFirstChild("StreamTerrain") then
			return child
		end
	end
	-- Fall back to any BuildArea Model (StreamTerrain may not exist until the first
	-- surrounding chunk streams in).
	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("Model") and child.Name:match("^BuildArea%d+$") then
			return child
		end
	end
	return nil
end

local function refreshAnchor(container)
	if not container then return end
	-- NOTE: deliberately do NOT read BasePlatePosition* here (it mutates during
	-- generation). We only refresh the StreamTerrain folder reference.
	streamFolder = container:FindFirstChild("StreamTerrain")
end

local function worldToChunk(wx, wz)
	local cx = math.floor((wx - ORIGIN_X) / CHUNK_STUDS + 0.5)
	local cz = math.floor((wz - ORIGIN_Z) / CHUNK_STUDS + 0.5)
	return cx, cz
end

-- ============================================
-- CHUNK COORDS FROM A FOLDER
-- ============================================
local function chunkCoordsOf(chunkFolder)
	local cx = chunkFolder:GetAttribute("ChunkX")
	local cz = chunkFolder:GetAttribute("ChunkZ")
	if cx and cz then return cx, cz end
	-- Fallback: parse "Chunk_<cx>_<cz>".
	local parts = string.split(chunkFolder.Name, "_")
	if #parts >= 3 and parts[1] == "Chunk" then
		return tonumber(parts[2]), tonumber(parts[3])
	end
	return nil, nil
end

-- ============================================
-- VISIBILITY APPLICATION
-- ============================================
local function applyVisibility(chunkFolder, visible)
	if chunkVisible[chunkFolder] == visible then return end
	chunkVisible[chunkFolder] = visible
	local t = visible and 0 or 1
	for _, desc in ipairs(chunkFolder:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.LocalTransparencyModifier = t
		end
	end
end

-- Decide visibility from distance alone, with hysteresis. `wasVisible` is the
-- chunk's current state so we can apply the show/hide gap: already-visible chunks
-- use the larger HIDE_RADIUS, hidden chunks use the smaller SHOW_RADIUS.
local function shouldBeVisible(dx, dz, wasVisible)
	local dist = math.sqrt(dx * dx + dz * dz)
	if wasVisible then
		return dist <= HIDE_RADIUS
	else
		return dist <= SHOW_RADIUS
	end
end

-- ============================================
-- UPDATE
-- ============================================
local function updateVisibility()
	local character = player.Character
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	-- Make sure we have the container + stream folder (they appear after join).
	if not streamFolder or not streamFolder.Parent then
		refreshAnchor(findContainer())
		if not streamFolder then return end
	end

	local pcx, pcz = worldToChunk(root.Position.X, root.Position.Z)

	local total, shown, hidden = 0, 0, 0
	for _, chunkFolder in ipairs(streamFolder:GetChildren()) do
		local cx, cz = chunkCoordsOf(chunkFolder)
		if cx then
			local dx = cx - pcx
			local dz = cz - pcz
			local wasVisible = chunkVisible[chunkFolder] == true
			local vis = shouldBeVisible(dx, dz, wasVisible)
			applyVisibility(chunkFolder, vis)
			total = total + 1
			if vis then shown = shown + 1 else hidden = hidden + 1 end
		end
	end

	-- TEMP diagnostic (throttled): confirm origin + player chunk + show/hide split.
	if DEBUG_VIS then
		_visDbgT = (_visDbgT or 0) + 1
		if _visDbgT % 7 == 0 then
			print(string.format("[BB-VIS] origin=(%.0f,%.0f) pos=(%.0f,%.0f) playerChunk=(%d,%d) chunks=%d shown=%d hidden=%d",
				ORIGIN_X, ORIGIN_Z, root.Position.X, root.Position.Z, pcx, pcz, total, shown, hidden))
		end
	end
end

-- A freshly streamed-in chunk: decide its visibility immediately so it doesn't
-- flash visible for a frame before the next update tick.
local function onChunkAdded(chunkFolder)
	if not (chunkFolder:IsA("Folder") and string.sub(chunkFolder.Name, 1, 6) == "Chunk_") then
		return
	end
	-- Give it a beat for its parts to populate, then apply.
	task.defer(function()
		if not chunkFolder.Parent then return end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			-- No character yet; default hidden so distant chunks never flash.
			applyVisibility(chunkFolder, false)
			return
		end
		local pcx, pcz = worldToChunk(root.Position.X, root.Position.Z)
		local cx, cz = chunkCoordsOf(chunkFolder)
		if cx then
			local dx, dz = cx - pcx, cz - pcz
			-- Fresh chunk: not yet visible, so use the show test (no hysteresis state).
			applyVisibility(chunkFolder, shouldBeVisible(dx, dz, false))
		end
	end)
end

local function hookStreamFolder()
	if not streamFolder then return end
	streamFolder.ChildAdded:Connect(onChunkAdded)
	streamFolder.ChildRemoved:Connect(function(child)
		chunkVisible[child] = nil
	end)
end

-- ============================================
-- INIT
-- ============================================
local function init()
	-- Wait for the shared world container to appear, then hook its StreamTerrain.
	task.spawn(function()
		local container = findContainer()
		local deadline = os.clock() + 30
		while not container and os.clock() < deadline do
			task.wait(0.3)
			container = findContainer()
		end
		if not container then
			warn("[ClientChunkVisibility] no shared world container found; idle")
			return
		end
		refreshAnchor(container)

		-- StreamTerrain may not exist until the first surrounding chunk streams in;
		-- watch for it.
		if streamFolder then
			hookStreamFolder()
		else
			container.ChildAdded:Connect(function(child)
				if child.Name == "StreamTerrain" and not streamFolder then
					streamFolder = child
					hookStreamFolder()
					updateVisibility()
				end
			end)
		end

		-- (No attribute-change watch: the anchor is a fixed constant now, and the
		-- container's BasePlatePosition* mutates constantly during generation, so
		-- watching it would just fire a useless callback per chunk gen.)

		updateVisibility()
	end)

	-- Steady update loop.
	task.spawn(function()
		while true do
			local ok, err = pcall(updateVisibility)
			if not ok then
				-- Never let a transient error kill the loop.
			end
			task.wait(UPDATE_INTERVAL)
		end
	end)

	player.CharacterAdded:Connect(function()
		chunkVisible = {}
		task.wait(0.3)
		updateVisibility()
	end)

	print("[ClientChunkVisibility] active (shared-world per-client reveal)")
end

init()
