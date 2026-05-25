--[[
	PortalHandler
	Detects a valid Nether-style portal frame and lights / extinguishes it.

	Frame spec (vanilla minimum):
	  - Interior: 2 wide x 3 tall (the air gap that becomes portal blocks)
	  - Border: Obsidian around that interior
	  - Corners: OPTIONAL (like real Minecraft) -- never required for validity,
	    but a clicked corner block still resolves to its frame.
	  - Orientation: the frame is a flat vertical plane, lying in either the
	    X-axis ("wide" runs along X) or the Z-axis ("wide" runs along Z).
	    Y is always the "tall" axis.

	Lit interior = NetherPortal blocks (the animated obsidian-portal block),
	non-solid, walk-through, excluded from saves.

	Conventions matched from the rest of the codebase:
	  - Blocks identified by the "BlockType" attribute
	  - Grid step = GridConfig.BLOCK_SIZE (3 studs)
	  - O(1) neighbour lookups via BlockSpatialIndex (GetOrCreate / GetBlockAt /
	    HasBlockAt / GetBlocksAt) -- the index keys blocks by their grid centre,
	    preferring the BlockPosX/Y/Z attributes.
	  - Blocks live in buildArea.Blocks; templates in ReplicatedStorage.Blocks

	Block CREATION is delegated to a closure supplied by the caller (ToolHandler)
	so this module never duplicates the clone/attribute recipe -- it stays pure
	logic. The closure receives (cellPos: Vector3, wideAxis: Vector3) and returns
	the created block (or nil).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))

local PortalHandler = {}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Extra Y rotation (degrees) applied to every portal block. The NetherPortal
-- template is 3x3x0.4 (thin along Z) with the swirl on its +/-Z faces, so 0 is
-- correct for an X-aligned frame; Z-aligned frames get an automatic +90.
local PORTAL_BASE_YROT = 0

-- Block type names
local OBSIDIAN_TYPE = "Obsidian"
local PORTAL_TYPE   = "NetherPortal"

-- ===== PORTAL TYPES / TINT CONFIG =====
-- The swirl texture is greyscale, so ImageColor3 multiplies cleanly against it.
-- A portal's COLOR is decided by the material of its frame: a frame built from
-- one block type lights one dimension's colour, another block type a different
-- one. To add a future dimension (e.g. an ice portal): add a colour row to
-- PORTAL_TYPES, then map its frame block in FRAME_BLOCK_TO_PORTAL_TYPE. Nothing
-- else changes -- build, animation, save/load all read the type generically.
local DEFAULT_PORTAL_TYPE = "Nether"

local PORTAL_TYPES = {
	Nether = { tint = Color3.fromRGB(140, 70, 220) },   -- purple
	-- Ice    = { tint = Color3.fromRGB(90, 200, 235) },  -- example future dimension
}

-- Which frame block type lights which portal type. Frame detection requires the
-- whole border to be ONE block type, so a single lookup on that type decides the
-- colour. Keys are BlockType strings; unmapped frames fall back to the default.
local FRAME_BLOCK_TO_PORTAL_TYPE = {
	[OBSIDIAN_TYPE] = "Nether",
	-- ["PackedIce"] = "Ice",  -- example future dimension
}

-- Resolve a portal type from the frame's border block type. Returns a valid key
-- into PORTAL_TYPES (never nil) so callers always get a usable colour.
local function resolvePortalType(frameBlockType: string?): string
	local t = frameBlockType and FRAME_BLOCK_TO_PORTAL_TYPE[frameBlockType]
	if t and PORTAL_TYPES[t] then return t end
	return DEFAULT_PORTAL_TYPE
end

-- Look up the tint colour for a portal type (default-safe).
local function tintForPortalType(portalType: string?): Color3
	local entry = portalType and PORTAL_TYPES[portalType]
	if entry and entry.tint then return entry.tint end
	return PORTAL_TYPES[DEFAULT_PORTAL_TYPE].tint
end

-- Public accessors (clients/UI may want the colour without the block).
function PortalHandler.GetTintForType(portalType: string?): Color3
	return tintForPortalType(portalType)
end
function PortalHandler.GetDefaultType(): string
	return DEFAULT_PORTAL_TYPE
end

-- Interior dimensions (in blocks)
local INTERIOR_W = 2  -- wide
local INTERIOR_H = 3  -- tall

-- ===== helpers =====

-- Snap a world position to the grid (same rounding the spatial index uses).
local function snap(pos: Vector3): Vector3
	return Vector3.new(
		math.round(pos.X / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(pos.Y / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(pos.Z / BLOCK_SIZE) * BLOCK_SIZE
	)
end

-- Mirror BlockSpatialIndex.getBlockCenter so click positions resolve to the
-- same grid keys the index stores blocks under.
local function blockCenter(block: Instance?): Vector3?
	if not block then return nil end
	local sx = block:GetAttribute("BlockPosX")
	local sy = block:GetAttribute("BlockPosY")
	local sz = block:GetAttribute("BlockPosZ")
	if sx and sy and sz then
		return Vector3.new(sx, sy, sz)
	end
	if block:IsA("BasePart") then
		return block.Position
	elseif block:IsA("Model") then
		local pivot = block:GetPivot().Position
		if block:GetAttribute("IsFence") or block:GetAttribute("IsGlass") then
			return pivot
		else
			return pivot + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
	end
	return nil
end

local function isObsidian(block: Instance?): boolean
	if not block then return false end
	return (block:GetAttribute("BlockType") or block.Name) == OBSIDIAN_TYPE
end

local function isPortal(block: Instance?): boolean
	if not block then return false end
	if block:GetAttribute("IsPortal") then return true end
	return (block:GetAttribute("BlockType") or block.Name) == PORTAL_TYPE
end

-- ===== world fallback =====
-- The spatial index can miss blocks that streamed/loaded in without firing the
-- ChildAdded it listens for (deferred terrain, StreamingEnabled). For frame
-- detection we can't trust "index says EMPTY", so when the index has nothing at
-- a cell we physically probe the world at that grid centre and walk up to the
-- owning block (the part, or its model ancestor carrying BlockType).
local _overlapParams = OverlapParams.new()
_overlapParams.FilterType = Enum.RaycastFilterType.Include

local PROBE_SIZE = Vector3.new(BLOCK_SIZE * 0.6, BLOCK_SIZE * 0.6, BLOCK_SIZE * 0.6)

local function resolveOwningBlock(part: BasePart, blocksFolder: Instance): Instance?
	local node: Instance? = part
	while node and node ~= blocksFolder do
		if node:GetAttribute("BlockType") then return node end
		node = node.Parent
	end
	return part
end

-- Returns the block instance occupying `cell` in the world (searching only
-- inside blocksFolder), or nil. `cell` is a snapped grid centre; we offset by
-- the frame's sub-grid offset so the probe lands on the real block.
local function worldBlockAt(blocksFolder: Instance, cell: Vector3, gridOffset: Vector3): Instance?
	if not blocksFolder then return nil end
	_overlapParams.FilterDescendantsInstances = { blocksFolder }
	local parts = Workspace:GetPartBoundsInBox(CFrame.new(cell + gridOffset), PROBE_SIZE, _overlapParams)
	for _, part in ipairs(parts) do
		local owner = resolveOwningBlock(part, blocksFolder)
		if owner then return owner end
	end
	return nil
end

-- Terrain/ground blocks that a frame can be sunk into. When lighting, any of
-- these sitting in the interior get cleared (like the air gap being burned
-- open). Player builds and other blocks are NOT cleared -- those still block.
local CLEARABLE_INTERIOR = {
	Dirt = true, GrassBlock = true, Stone = true, Sand = true, Sandstone = true,
	Gravel = true, SnowBlock = true, SnowyGrassBlock = true, SnowLayer = true,
	PathBlock = true,
}

local function isClearableTerrain(block: Instance?): boolean
	if not block then return false end
	local t = block:GetAttribute("BlockType") or block.Name
	if CLEARABLE_INTERIOR[t] then return true end
	-- Terrain-generated blocks without a PlacedBy owner are ground, not builds.
	if block:GetAttribute("IsTerrainBlock") and not block:GetAttribute("PlacedBy") then
		return true
	end
	return false
end

-- A cell counts as "open" for the interior if it's empty or just clearable
-- terrain the frame is sunk into.
local function isInteriorOpen(index, cell: Vector3): boolean
	if not index:HasBlockAt(cell) then return true end
	return isClearableTerrain(index:GetBlockAt(cell))
end

-- Unified cell accessor used by frame detection: returns the block at `cell`,
-- preferring the index but falling back to a world probe when the index is
-- empty (handles streamed/unindexed obsidian). `ctx` carries blocksFolder +
-- gridOffset for the world probe.
local function cellBlock(ctx, cell: Vector3): Instance?
	local b = ctx.index:GetBlockAt(cell)
	if b then return b end
	return worldBlockAt(ctx.blocksFolder, cell, ctx.gridOffset)
end

local function cellIsObsidian(ctx, cell: Vector3): boolean
	return isObsidian(cellBlock(ctx, cell))
end

-- Open for interior = empty, or clearable terrain. Uses the world fallback so a
-- buried/streamed interior reads correctly too.
local function cellIsOpen(ctx, cell: Vector3): boolean
	local b = cellBlock(ctx, cell)
	if not b then return true end
	return isClearableTerrain(b)
end

-- ===== debug logging =====
-- Toggle verbose [BB-PORTAL] positioning logs. Flip to false to silence once the
-- offset is sorted.
local DEBUG_PORTAL = false

local function posStr(p: Vector3?): string
	if not p then return "nil" end
	return string.format("(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
end

-- Dumps a block's *visual* position (CFrame/pivot) alongside its *stored* grid
-- position (BlockPosX/Y/Z) and the center the index keys it under. If visualPos
-- and center disagree, that mismatch is the offset.
local function describeBlock(block: Instance?): string
	if not block then return "nil" end
	local pivot
	if block:IsA("BasePart") then
		pivot = block.Position
	elseif block:IsA("Model") then
		pivot = block:GetPivot().Position
	end
	local bx = block:GetAttribute("BlockPosX")
	local by = block:GetAttribute("BlockPosY")
	local bz = block:GetAttribute("BlockPosZ")
	return string.format("%s<%s> visualPos=%s bpos=(%s, %s, %s) center=%s",
		block.Name, block.ClassName, posStr(pivot),
		tostring(bx), tostring(by), tostring(bz), posStr(blockCenter(block)))
end

-- The two possible "wide" axes for a vertical frame.
local AXES = {
	Vector3.new(BLOCK_SIZE, 0, 0),  -- wide runs along X
	Vector3.new(0, 0, BLOCK_SIZE),  -- wide runs along Z
}
local UP = Vector3.new(0, BLOCK_SIZE, 0)

-- 6-neighbour offsets (used by the extinguish flood fill).
local NEIGHBORS6 = {
	Vector3.new(BLOCK_SIZE, 0, 0), Vector3.new(-BLOCK_SIZE, 0, 0),
	Vector3.new(0, BLOCK_SIZE, 0), Vector3.new(0, -BLOCK_SIZE, 0),
	Vector3.new(0, 0, BLOCK_SIZE), Vector3.new(0, 0, -BLOCK_SIZE),
}

local function gridKey(p: Vector3): string
	return ("%d,%d,%d"):format(
		math.round(p.X / BLOCK_SIZE),
		math.round(p.Y / BLOCK_SIZE),
		math.round(p.Z / BLOCK_SIZE)
	)
end

-- Interior cell positions for an (origin, wideAxis). `origin` is the bottom cell
-- on the "left" of the interior along the wide axis.
local function interiorCellPositions(origin: Vector3, wideAxis: Vector3): {Vector3}
	local cells = {}
	for w = 0, INTERIOR_W - 1 do
		for h = 0, INTERIOR_H - 1 do
			table.insert(cells, origin + wideAxis * w + UP * h)
		end
	end
	return cells
end

-- Required border positions for an interior, EXCLUDING the 4 corners.
-- Border = the ring of cells immediately outside the interior rectangle.
local function requiredBorderPositions(origin: Vector3, wideAxis: Vector3): {Vector3}
	local border = {}
	-- Left and right sides (one cell per interior row).
	for h = 0, INTERIOR_H - 1 do
		table.insert(border, origin - wideAxis + UP * h)               -- left of interior
		table.insert(border, origin + wideAxis * INTERIOR_W + UP * h)  -- right of interior
	end
	-- Bottom and top (one cell per interior column).
	for w = 0, INTERIOR_W - 1 do
		table.insert(border, origin + wideAxis * w - UP)               -- below interior
		table.insert(border, origin + wideAxis * w + UP * INTERIOR_H)  -- above interior
	end
	return border
end

-- All border deltas relative to origin INCLUDING corners. Used only to enumerate
-- where a click could be -- corners are valid click targets even though they are
-- not required to exist for the frame to validate.
local function clickableBorderDeltas(wideAxis: Vector3): {Vector3}
	local deltas = requiredBorderPositions(Vector3.new(0, 0, 0), wideAxis)
	table.insert(deltas, -wideAxis - UP)                            -- bottom-left corner
	table.insert(deltas, wideAxis * INTERIOR_W - UP)                -- bottom-right corner
	table.insert(deltas, -wideAxis + UP * INTERIOR_H)               -- top-left corner
	table.insert(deltas, wideAxis * INTERIOR_W + UP * INTERIOR_H)   -- top-right corner
	return deltas
end

-- Is (origin, wideAxis) a valid, currently-unlit frame?
local function isValidFrameAt(index, origin: Vector3, wideAxis: Vector3): boolean
	-- 1) Interior must be entirely empty (no blocks).
	for _, cell in ipairs(interiorCellPositions(origin, wideAxis)) do
		if index:HasBlockAt(cell) then
			return false
		end
	end
	-- 2) All required (non-corner) border cells must be obsidian.
	for _, bpos in ipairs(requiredBorderPositions(origin, wideAxis)) do
		if not isObsidian(index:GetBlockAt(bpos)) then
			return false
		end
	end
	return true
end

-- When a click doesn't resolve to a valid frame, find the closest candidate
-- (most empty interior + most obsidian border) per axis and report exactly what
-- blocked it: terrain sitting in the interior, a non-obsidian / buried / missing
-- border cell, or a frame whose interior simply isn't 2 wide x 3 tall (in which
-- case an interior cell shows up occupied by Obsidian).
local function diagnoseNoFrame(index, clickedCenter: Vector3)
	for _, wideAxis in ipairs(AXES) do
		local axisName = (math.abs(wideAxis.X) > 0) and "X" or "Z"
		local bestOrigin, bestScore = nil, -1
		for _, delta in ipairs(clickableBorderDeltas(wideAxis)) do
			local origin = clickedCenter - delta
			local score = 0
			for _, cell in ipairs(interiorCellPositions(origin, wideAxis)) do
				if not index:HasBlockAt(cell) then score += 1 end
			end
			for _, bpos in ipairs(requiredBorderPositions(origin, wideAxis)) do
				if isObsidian(index:GetBlockAt(bpos)) then score += 1 end
			end
			if score > bestScore then
				bestScore = score
				bestOrigin = origin
			end
		end
		if bestOrigin then
			print(string.format("[BB-PORTAL] [diagnose %s-axis] closest frame origin=%s score=%d/16", axisName, posStr(bestOrigin), bestScore))
			for _, cell in ipairs(interiorCellPositions(bestOrigin, wideAxis)) do
				local occ = index:GetBlockAt(cell)
				if occ then
					print(string.format("[BB-PORTAL]    interior %s should be EMPTY but has %s", posStr(cell), occ.Name))
				end
			end
			for _, bpos in ipairs(requiredBorderPositions(bestOrigin, wideAxis)) do
				local b = index:GetBlockAt(bpos)
				if not isObsidian(b) then
					print(string.format("[BB-PORTAL]    border   %s should be Obsidian but is %s", posStr(bpos), b and b.Name or "EMPTY"))
				end
			end
		end
	end
end

-- Max interior size we'll scan for (Minecraft caps at 21x21; this is plenty and
-- bounds the search).
local MAX_SPAN = 21

-- Walk from `from` in `dir` until we leave obsidian. Returns the number of
-- consecutive open (candidate interior) cells, then whether the cell right
-- after them is obsidian (the closing wall). Uses ctx so unindexed obsidian
-- still reads as a wall.
local function measureGap(ctx, from: Vector3, dir: Vector3): (number, boolean)
	local gap = 0
	for step = 1, MAX_SPAN + 1 do
		local cell = from + dir * step
		if cellIsObsidian(ctx, cell) then
			return gap, true   -- hit the closing obsidian wall
		end
		if not cellIsOpen(ctx, cell) then
			return gap, false  -- ran into a non-clearable block; not a clean wall
		end
		gap += 1
	end
	return gap, false      -- never closed within range
end

-- Given the clicked obsidian and a `wideAxis`, try to resolve the closed
-- obsidian rectangle it belongs to. The clicked block can be anywhere on the
-- ring. Returns { origin, wideAxis, w, h } (interior dims) or nil.
--   origin = bottom-left INTERIOR cell
--   `ctx.c` is the clicked block's snapped grid centre.
local function resolveRectangle(ctx, wideAxis: Vector3)
	local c = ctx.c
	local right = wideAxis            -- along the wide axis (+)
	local left  = -wideAxis
	local up    = UP
	local down  = -UP

	-- Step inward one cell in each of the 4 directions; the first that lands on
	-- an open (interior/air/clearable) cell tells us which wall the clicked block
	-- is on. We then measure the interior in both perpendicular directions.
	local function tryWall(inwardWide: number, inwardUp: number)
		local inwardDir = right * inwardWide + up * inwardUp
		local firstInterior = c + inwardDir
		if cellIsObsidian(ctx, firstInterior) then return nil end
		if not cellIsOpen(ctx, firstInterior) then return nil end -- must be air or clearable ground

		local leftGap, leftClosed   = measureGap(ctx, firstInterior, left)
		local rightGap, rightClosed = measureGap(ctx, firstInterior, right)
		local downGap, downClosed   = measureGap(ctx, firstInterior, down)
		local upGap, upClosed       = measureGap(ctx, firstInterior, up)
		if not (leftClosed and rightClosed and downClosed and upClosed) then
			return nil
		end

		local w = leftGap + 1 + rightGap   -- interior width (cells) along wide axis
		local h = downGap + 1 + upGap       -- interior height (cells) along Y
		if w < INTERIOR_W or h < INTERIOR_H or w > MAX_SPAN or h > MAX_SPAN then
			return nil
		end

		local origin = firstInterior + left * leftGap + down * downGap -- bottom-left interior cell
		return { origin = origin, wideAxis = wideAxis, w = w, h = h }
	end

	-- Clicked block could be on left wall (interior to the right), right wall
	-- (interior left), bottom wall (interior up), or top wall (interior down).
	return tryWall(1, 0) or tryWall(-1, 0) or tryWall(0, 1) or tryWall(0, -1)
end

-- Verify a resolved rectangle is a fully closed obsidian ring (every interior
-- cell empty, every border cell -- excluding the 4 corners -- obsidian) and
-- return its interior cell list. Sizes are read from the rectangle, so this is
-- no longer locked to 2x3.
local function rectInteriorCells(rect): {Vector3}
	local cells = {}
	for wi = 0, rect.w - 1 do
		for hi = 0, rect.h - 1 do
			table.insert(cells, rect.origin + rect.wideAxis * wi + UP * hi)
		end
	end
	return cells
end

local function rectBorderCells(rect): {Vector3}
	local border = {}
	for hi = 0, rect.h - 1 do
		table.insert(border, rect.origin - rect.wideAxis + UP * hi)
		table.insert(border, rect.origin + rect.wideAxis * rect.w + UP * hi)
	end
	for wi = 0, rect.w - 1 do
		table.insert(border, rect.origin + rect.wideAxis * wi - UP)
		table.insert(border, rect.origin + rect.wideAxis * wi + UP * rect.h)
	end
	return border
end

local function rectIsValid(ctx, rect): boolean
	for _, cell in ipairs(rectInteriorCells(rect)) do
		if not cellIsOpen(ctx, cell) then return false end
	end
	for _, bpos in ipairs(rectBorderCells(rect)) do
		if not cellIsObsidian(ctx, bpos) then return false end
	end
	return true
end

--[[
	From a clicked obsidian block, find the closed obsidian rectangle it belongs
	to. Works for any interior size from 2x3 up to 21x21, in either the X or Z
	vertical plane, regardless of where on the ring you click. Everything runs on
	the plot's actual grid (the clicked block's snapped centre + sub-grid offset),
	not world coords.

	Returns { origin, wideAxis, w, h, gridOffset } or nil.
]]
function PortalHandler.FindFrameFromClick(blocksFolder: Folder, clickedBlock: Instance)
	if not blocksFolder or not clickedBlock then return nil end
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return nil end

	local rawC = blockCenter(clickedBlock)
	if DEBUG_PORTAL then
		print("[BB-PORTAL] ===== FindFrameFromClick =====")
		print("[BB-PORTAL] clicked obsidian: " .. describeBlock(clickedBlock))
		print(string.format("[BB-PORTAL] clicked center=%s -> snapped=%s", posStr(rawC), posStr(rawC and snap(rawC))))
	end
	if not rawC then return nil end
	local c = snap(rawC)
	-- The frame sits on the plot's grid, which can be offset from world multiples
	-- of BLOCK_SIZE. Logic runs on the snapped grid (what the index keys on); this
	-- offset is re-applied so portal blocks land exactly where the obsidian is.
	local gridOffset = rawC - c
	if DEBUG_PORTAL then
		print(string.format("[BB-PORTAL] gridOffset=%s", posStr(gridOffset)))
	end

	for _, wideAxis in ipairs(AXES) do
		local ctx = { index = index, blocksFolder = blocksFolder, c = c, gridOffset = gridOffset }
		local rect = resolveRectangle(ctx, wideAxis)
		if rect and rectIsValid(ctx, rect) then
			rect.gridOffset = gridOffset
			-- Record the frame's border block type so the caller can resolve the
			-- portal type/colour from it. The border is validated as a single block
			-- type, so the clicked block's type is representative of the whole frame.
			local clickedType = clickedBlock:GetAttribute("BlockType") or clickedBlock.Name
			rect.frameBlockType = clickedType
			rect.portalType = resolvePortalType(clickedType)
			if DEBUG_PORTAL then
				local axisName = (math.abs(wideAxis.X) > 0) and "X" or "Z"
				print(string.format("[BB-PORTAL] VALID FRAME: origin=%s wideAxis=%s interior=%dx%d frameBlock=%s portalType=%s",
					posStr(rect.origin), axisName, rect.w, rect.h, tostring(clickedType), rect.portalType))
			end
			return rect
		end
	end

	if DEBUG_PORTAL then
		print("[BB-PORTAL] no valid frame found from this click")
		diagnoseNoFrame(index, c)
	end
	return nil
end

--[[
	Light a validated frame. `createPortalBlock(cellPos, wideAxis)` is supplied by
	the caller and is responsible for cloning / orienting / parenting one portal
	block at the given cell. Returns the number of portal blocks created.
]]
function PortalHandler.LightFrame(blocksFolder: Folder, frame, createPortalBlock): number
	if not (blocksFolder and frame and frame.origin and frame.wideAxis and createPortalBlock) then
		return 0
	end
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	local offset = frame.gridOffset or Vector3.new(0, 0, 0)
	-- Interior cells: use the resolved rectangle size if present (variable size),
	-- otherwise fall back to the fixed INTERIOR_W x INTERIOR_H.
	local cells
	if frame.w and frame.h then
		cells = {}
		for wi = 0, frame.w - 1 do
			for hi = 0, frame.h - 1 do
				table.insert(cells, frame.origin + frame.wideAxis * wi + UP * hi)
			end
		end
	else
		cells = interiorCellPositions(frame.origin, frame.wideAxis)
	end
	local count = 0
	for _, cellPos in ipairs(cells) do
		-- Clear any ground the frame is sunk into before placing the portal.
		for _, existing in ipairs(index:GetBlocksAt(cellPos)) do
			if isClearableTerrain(existing) and existing.Parent then
				existing:Destroy()
			end
		end
		-- Add the frame's sub-grid offset so the portal sits exactly on the
		-- obsidian's grid, not the abstract world grid. The frame's resolved
		-- portalType is passed so the builder tints the swirl correctly.
		local block = createPortalBlock(cellPos + offset, frame.wideAxis, frame.portalType)
		if block then
			count += 1
		end
	end

	-- Whole-portal glow: one invisible SurfaceLight panel sized to the full frame
	-- (replaces the old per-cell lights that looked like balls of light). Built
	-- AFTER the cells so it spans the whole interior. Uses the resolved rectangle
	-- size if present, else the fixed 2x3.
	if count > 0 then
		local gw = frame.w or INTERIOR_W
		local gh = frame.h or INTERIOR_H
		local tint = tintForPortalType(frame.portalType)
		PortalHandler.BuildPortalGlow(blocksFolder, frame.origin, frame.wideAxis, gw, gh, offset, tint)
	end

	return count
end

--[[
	Extinguish the portal connected to `centerPos` (the grid position of the block
	that was just broken). Flood-fills outward through contiguous portal cells
	(starting from the broken cell's neighbours) and destroys them. O(portal size)
	via the spatial index -- cheap enough to call on any block break. The broken
	block itself can already be gone; we only read the surviving portal cells.
	Returns the number of portal blocks removed.
]]
function PortalHandler.ExtinguishAround(blocksFolder: Folder, centerPos: Vector3): number
	if not blocksFolder or not centerPos then return 0 end
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return 0 end

	local start = snap(centerPos)
	local toVisit = { start }
	for _, off in ipairs(NEIGHBORS6) do
		table.insert(toVisit, start + off)
	end

	local seen = {}
	local found = {}
	while #toVisit > 0 do
		local pos = table.remove(toVisit)
		local k = gridKey(pos)
		if not seen[k] then
			seen[k] = true
			local hasPortalHere = false
			for _, b in ipairs(index:GetBlocksAt(pos)) do
				if isPortal(b) then
					hasPortalHere = true
					table.insert(found, b)
				end
			end
			-- Only expand through cells that actually contain a portal block, so
			-- the fill stays confined to one contiguous portal sheet.
			if hasPortalHere then
				for _, off in ipairs(NEIGHBORS6) do
					table.insert(toVisit, pos + off)
				end
			end
		end
	end

	for _, b in ipairs(found) do
		if b and b.Parent then
			b:Destroy()
		end
	end
	return #found
end

-- Convenience predicate (used for save-exclusion / filters).
function PortalHandler.IsPortalBlock(block: Instance): boolean
	return isPortal(block)
end

--[[
	Build ONE whole-portal glow instead of a light per cell (which looked like a
	grid of point-source "balls"). Creates a single invisible, non-collidable part
	spanning the entire interior, with a SurfaceLight on its FRONT and BACK faces so
	light washes out both sides evenly. Size scales with the portal: a 2x3 frame
	lights modestly, a big frame floods the room.

	Parented to blocksFolder and tagged IsPortalGlow + IsPortal so it's cleaned up
	with the portal (ExtinguishAround treats it as part of the sheet) and excluded
	from saves like the portal cells.

	Args mirror a resolved frame:
	  origin    - bottom-left INTERIOR cell grid centre (pre-offset)
	  wideAxis  - BLOCK_SIZE vector along the wide axis
	  w, h      - interior size in cells
	  gridOffset- frame sub-grid offset (added so the panel sits on the real grid)
	  tint      - portal Color3
]]
function PortalHandler.BuildPortalGlow(blocksFolder: Folder, origin: Vector3, wideAxis: Vector3, w: number, h: number, gridOffset: Vector3, tint: Color3): Instance?
	if not (blocksFolder and origin and wideAxis) then return nil end
	w = w or INTERIOR_W
	h = h or INTERIOR_H
	gridOffset = gridOffset or Vector3.new(0, 0, 0)
	tint = tint or PORTAL_TYPES[DEFAULT_PORTAL_TYPE].tint

	-- Centre of the interior rectangle, in world space.
	local centre = origin + wideAxis * ((w - 1) / 2) + UP * ((h - 1) / 2) + gridOffset

	-- Interior span in studs along wide and up; the thin axis is the frame normal.
	local wideStuds = w * BLOCK_SIZE
	local tallStuds = h * BLOCK_SIZE
	local THIN = 0.2

	-- Orient the panel in the frame's plane:
	--   wide along X -> plane XY, normal Z (Front/Back faces already face +/-Z)
	--   wide along Z -> plane ZY, normal X -> rotate 90 about Y
	local sizeVec, yRot
	if math.abs(wideAxis.Z) > 0 then
		-- Wide runs along Z; after a 90 Y-rotation the part's local X maps to world Z.
		sizeVec = Vector3.new(THIN, tallStuds, wideStuds)
		yRot = 90
	else
		sizeVec = Vector3.new(wideStuds, tallStuds, THIN)
		yRot = 0
	end

	-- Reuse an existing glow panel for this portal if one is already here.
	local panel = nil
	for _, c in ipairs(blocksFolder:GetChildren()) do
		if c:GetAttribute("IsPortalGlow") and c:IsA("BasePart") then
			if (c.Position - centre).Magnitude < BLOCK_SIZE * 0.5 then
				panel = c
				break
			end
		end
	end

	if not panel then
		panel = Instance.new("Part")
		panel.Name = "PortalGlow"
		panel.Anchored = true
		panel.CanCollide = false
		panel.CanQuery = false
		panel.CanTouch = false
		panel.CastShadow = false
		panel.Transparency = 1
		panel:SetAttribute("IsPortalGlow", true)
		panel:SetAttribute("IsPortal", true)        -- folded into the portal sheet for cleanup/save-exclusion
		panel:SetAttribute("BlockType", PORTAL_TYPE)
	end

	panel.Size = sizeVec
	panel.CFrame = CFrame.new(centre) * CFrame.Angles(0, math.rad(yRot), 0)
	panel:SetAttribute("BlockPosX", centre.X)
	panel:SetAttribute("BlockPosY", centre.Y)
	panel:SetAttribute("BlockPosZ", centre.Z)

	-- Saturate the tint a touch for emitted light (more vivid than the surface).
	local hh, ss, vv = tint:ToHSV()
	local lightColor = Color3.fromHSV(hh, math.clamp(ss * 1.2, 0, 1), math.clamp(vv * 1.1, 0, 1))

	-- Brightness/range scale a little with portal area so bigger portals reach
	-- further, but clamp so a giant frame doesn't blow out.
	local area = w * h
	local brightness = math.clamp(5.0 + area * 0.06, 5.0, 8.0)
	local range = math.clamp(16 + area * 0.4, 16, 32)

	-- OUTWARD lights on the main panel: Front = +normal, Back = -normal. These
	-- light the room/caverns on both sides.
	for _, faceName in ipairs({ "Front", "Back" }) do
		local sl = panel:FindFirstChild("Glow_" .. faceName)
		if not sl then
			sl = Instance.new("SurfaceLight")
			sl.Name = "Glow_" .. faceName
			sl.Parent = panel
		end
		sl.Face = (faceName == "Front") and Enum.NormalId.Front or Enum.NormalId.Back
		sl.Color = lightColor
		sl.Brightness = brightness
		sl.Range = range
		sl.Angle = 180        -- wide spread so it reads as a flat wash, not a beam
		sl.Shadows = true
		sl:SetAttribute("OriginalBrightness", brightness)
	end

	panel.Parent = blocksFolder

	-- INWARD backlights: two more invisible panels offset just outside each face,
	-- with their SurfaceLight aimed BACK at the portal plane, so the swirl blocks
	-- themselves are lit up (not just the room). The normal direction (the thin
	-- axis) is +Z for an X-wide frame, +X for a Z-wide frame.
	local normalDir
	if math.abs(wideAxis.Z) > 0 then
		normalDir = Vector3.new(1, 0, 0)   -- Z-wide frame: normal runs along X
	else
		normalDir = Vector3.new(0, 0, 1)   -- X-wide frame: normal runs along Z
	end
	local backlightGap = BLOCK_SIZE * 0.6    -- how far outside the swirl each backlight sits
	local backBright = math.clamp(brightness * 1.1, 5.0, 9.0)
	local backRange = math.clamp(backlightGap + BLOCK_SIZE * 2, 8, 16)

	-- side = +1 sits on the +normal side and faces back (-normal); side = -1 mirrors.
	for _, side in ipairs({ 1, -1 }) do
		local name = "PortalBacklight_" .. (side == 1 and "Pos" or "Neg")
		local bl = nil
		for _, c in ipairs(blocksFolder:GetChildren()) do
			if c:GetAttribute("IsPortalGlow") and c.Name == name then
				local want = centre + normalDir * (backlightGap * side)
				if (c.Position - want).Magnitude < BLOCK_SIZE * 0.5 then bl = c break end
			end
		end
		if not bl then
			bl = Instance.new("Part")
			bl.Name = name
			bl.Anchored = true
			bl.CanCollide = false
			bl.CanQuery = false
			bl.CanTouch = false
			bl.CastShadow = false
			bl.Transparency = 1
			bl:SetAttribute("IsPortalGlow", true)
			bl:SetAttribute("IsPortal", true)
			bl:SetAttribute("BlockType", PORTAL_TYPE)
		end
		bl.Size = sizeVec
		bl.CFrame = CFrame.new(centre + normalDir * (backlightGap * side)) * CFrame.Angles(0, math.rad(yRot), 0)
		local blPos = centre + normalDir * (backlightGap * side)
		bl:SetAttribute("BlockPosX", blPos.X)
		bl:SetAttribute("BlockPosY", blPos.Y)
		bl:SetAttribute("BlockPosZ", blPos.Z)
		-- The face pointing back at the portal: a +side panel faces Back (-normal),
		-- a -side panel faces Front (+normal).
		local inwardFace = (side == 1) and Enum.NormalId.Back or Enum.NormalId.Front
		local sl = bl:FindFirstChild("Backlight")
		if not sl then
			sl = Instance.new("SurfaceLight")
			sl.Name = "Backlight"
			sl.Parent = bl
		end
		sl.Face = inwardFace
		sl.Color = lightColor
		sl.Brightness = backBright
		sl.Range = backRange
		sl.Angle = 180         -- wide so the whole swirl is lit, not just the centre
		sl.Shadows = true
		sl:SetAttribute("OriginalBrightness", backBright)
		bl.Parent = blocksFolder
	end

	return panel
end

--[[
	The single source of truth for building one lit portal block. Clones the
	NetherPortal template, orients it in the frame's plane, tags it (IsPortal +
	BlockType + BlockPosX/Y/Z), makes it walk-through-but-queryable, and parents
	it into blocksFolder. Returns the created block (or nil).

	Used by BOTH the flint-and-steel tool (fresh lighting) and the save managers
	(relight on load), so the recipe lives in exactly one place. Pass it directly
	as the `createPortalBlock` argument to LightFrame / RelightFromInteriorCell:
	   LightFrame(folder, frame, function(cell, wide)
	       return PortalHandler.BuildPortalBlock(folder, cell, wide)
	   end)
]]
function PortalHandler.BuildPortalBlock(blocksFolder: Folder, cellPos: Vector3, wideAxis: Vector3, portalType: string?): Instance?
	local templatesFolder = ReplicatedStorage:FindFirstChild("Blocks")
	local template = templatesFolder and templatesFolder:FindFirstChild(PORTAL_TYPE)
	if not template then
		warn("[BB-PORTAL] NetherPortal template missing from ReplicatedStorage.Blocks")
		return nil
	end

	portalType = (portalType and PORTAL_TYPES[portalType]) and portalType or DEFAULT_PORTAL_TYPE
	local tint = tintForPortalType(portalType)

	local block = template:Clone()
	block.Name = PORTAL_TYPE

	-- Face the swirl along the frame's normal:
	--   wide along X -> plane is XY, normal Z -> no extra rotation
	--   wide along Z -> plane is ZY, normal X -> rotate 90 about Y
	local yRot = PORTAL_BASE_YROT
	if math.abs(wideAxis.Z) > 0 then
		yRot += 90
	end
	local cf = CFrame.new(cellPos) * CFrame.Angles(0, math.rad(yRot), 0)

	if block:IsA("BasePart") then
		block.Anchored = true
		block.CanCollide = false
		-- Walk-through, but MUST stay query-able so the client's vision-effect
		-- probe can detect it.
		block.CanQuery = true
		block.CFrame = cf
	elseif block:IsA("Model") then
		-- Position by the inner part's CENTRE (not the model pivot) so the 3x3
		-- face fills the cell exactly regardless of the template's PivotOffset.
		local portalPart = block:FindFirstChild("Portal") or block:FindFirstChildWhichIsA("BasePart", true)
		if portalPart then
			portalPart.CFrame = cf
		else
			block:PivotTo(cf)
		end
		for _, d in ipairs(block:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = true
			end
		end
	end

	block:SetAttribute("BlockType", PORTAL_TYPE)
	block:SetAttribute("IsPortal", true)
	-- Portal type + tint drive the swirl colour. The animation script reads
	-- PortalTint and applies it as ImageColor3 (greyscale texture * tint = colour).
	-- We also apply it here so the colour is correct on the very first frame,
	-- before the client animation script has run.
	block:SetAttribute("PortalType", portalType)
	block:SetAttribute("PortalTint", tint)
	for _, d in ipairs(block:GetDescendants()) do
		if d:IsA("ImageLabel") then
			d.ImageColor3 = tint
		end
	end
	-- NOTE: per-cell lighting was removed -- it produced visible point-source
	-- "balls" of light. The whole-portal glow is now ONE invisible panel per face
	-- (see BuildPortalGlow), created after all cells are placed so it can be sized
	-- to the full frame.
	-- Pin the grid position so BlockSpatialIndex keys it at the cell centre.
	block:SetAttribute("BlockPosX", cellPos.X)
	block:SetAttribute("BlockPosY", cellPos.Y)
	block:SetAttribute("BlockPosZ", cellPos.Z)

	block.Parent = blocksFolder
	return block
end

--[[
	Collect one interior-cell grid position per lit portal in this plot, for the
	save system to persist. Returns an array of { x, y, z } tables (plain numbers,
	DataStore-friendly). On load, each entry is fed back to RelightFromInteriorCell.

	We flood-fill contiguous portal sheets (reusing the ExtinguishAround walk) so
	multiple separate portals each contribute exactly ONE representative cell,
	and a single multi-cell portal contributes one cell total -- not one per block.
]]
function PortalHandler.CollectLitPortalCells(blocksFolder: Folder): {any}
	local result = {}
	if not blocksFolder then return result end
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return result end

	-- Gather every portal block's grid centre + its portal type.
	local portalCells = {}   -- gridKey -> Vector3
	local portalTypes = {}   -- gridKey -> string
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if isPortal(child) then
			local centre = blockCenter(child)
			if centre then
				local k = gridKey(centre)
				portalCells[k] = centre
				portalTypes[k] = child:GetAttribute("PortalType") or DEFAULT_PORTAL_TYPE
			end
		end
	end

	-- Cluster contiguous portal cells; emit one representative per cluster.
	local visited = {}
	for key, centre in pairs(portalCells) do
		if not visited[key] then
			-- Flood this cluster.
			local stack = { centre }
			visited[key] = true
			while #stack > 0 do
				local pos = table.remove(stack)
				for _, off in ipairs(NEIGHBORS6) do
					local np = pos + off
					local nk = gridKey(np)
					if portalCells[nk] and not visited[nk] then
						visited[nk] = true
						table.insert(stack, portalCells[nk])
					end
				end
			end
			-- One representative cell for this whole portal, tagged with its type.
			table.insert(result, { x = centre.X, y = centre.Y, z = centre.Z, t = portalTypes[key] })
		end
	end
	return result
end

--[[
	Relight a portal on load from a single saved INTERIOR cell position.

	The save system stores only the grid centre of one interior cell per lit
	portal (not the portal blocks themselves -- those are transient). On load,
	the obsidian frame is back as normal saved blocks, so we:
	  1. Snap the saved cell to the grid and find an adjacent OBSIDIAN block
	     (checking the 4 in-plane neighbours in both candidate planes, then the
	     diagonals as a fallback for corner-adjacent interiors).
	  2. Hand that obsidian to FindFrameFromClick, which resolves + validates the
	     whole frame exactly like the flint-and-steel path.
	  3. LightFrame it with the caller's createPortalBlock closure.

	Returns the number of portal blocks created (0 if no intact frame was found,
	which is the correct outcome if the player broke the frame before saving).
]]
function PortalHandler.RelightFromInteriorCell(blocksFolder: Folder, cellPos: Vector3, createPortalBlock, savedType: string?): number
	if not (blocksFolder and cellPos and createPortalBlock) then return 0 end
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return 0 end

	local c = snap(cellPos)
	local gridOffset = cellPos - c
	local ctx = { index = index, blocksFolder = blocksFolder, c = c, gridOffset = gridOffset }

	-- Search outward for an obsidian block bordering this interior cell. The 6
	-- axis neighbours cover side/top/bottom walls; diagonals cover the case where
	-- the saved cell sits in a corner of the interior next to a corner obsidian.
	local SEARCH_OFFSETS = {
		Vector3.new(BLOCK_SIZE, 0, 0), Vector3.new(-BLOCK_SIZE, 0, 0),
		Vector3.new(0, BLOCK_SIZE, 0), Vector3.new(0, -BLOCK_SIZE, 0),
		Vector3.new(0, 0, BLOCK_SIZE), Vector3.new(0, 0, -BLOCK_SIZE),
		Vector3.new(BLOCK_SIZE, 0, BLOCK_SIZE), Vector3.new(-BLOCK_SIZE, 0, BLOCK_SIZE),
		Vector3.new(BLOCK_SIZE, 0, -BLOCK_SIZE), Vector3.new(-BLOCK_SIZE, 0, -BLOCK_SIZE),
	}

	local obsidian
	for _, off in ipairs(SEARCH_OFFSETS) do
		local candidate = cellBlock(ctx, c + off)
		if isObsidian(candidate) then
			obsidian = candidate
			break
		end
	end
	if not obsidian then
		if DEBUG_PORTAL then
			print(string.format("[BB-PORTAL] relight: no obsidian neighbouring saved cell %s", posStr(c)))
		end
		return 0
	end

	local frame = PortalHandler.FindFrameFromClick(blocksFolder, obsidian)
	if not frame then
		if DEBUG_PORTAL then
			print(string.format("[BB-PORTAL] relight: obsidian at %s did not resolve to a valid frame", posStr(blockCenter(obsidian))))
		end
		return 0
	end

	-- FindFrameFromClick resolves portalType from the frame's current material,
	-- which is authoritative. Fall back to the saved type only if the frame's
	-- material doesn't map to a known type (e.g. config changed since the save).
	if (not frame.portalType or frame.portalType == DEFAULT_PORTAL_TYPE)
		and savedType and PORTAL_TYPES[savedType] then
		if not FRAME_BLOCK_TO_PORTAL_TYPE[frame.frameBlockType or ""] then
			frame.portalType = savedType
		end
	end

	return PortalHandler.LightFrame(blocksFolder, frame, createPortalBlock)
end

return PortalHandler
