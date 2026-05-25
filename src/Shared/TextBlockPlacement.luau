--[[
	TextBlockPlacement
	------------------------------------------------------------------
	Pure logic module (creates no Instances) for the TextBlock mod.

	A TextBlock is a plain solid cube — placed, coloured, broken, saved and
	loaded exactly like any normal block — with one extra power: each of its
	6 faces is an independent text canvas you can type on, like a sign.

	CURRENT SCOPE (per-block): one block = one canvas per face. Text is
	centered and auto-scaled to fit that single face.

	MERGE-READY SEAM: every geometry call is expressed in terms of a "group"
	(a list of member blocks) rather than a single block. Today the group is
	always {block}. When the merge feature is added later, GetFaceGroup can
	return multiple coplanar neighbours and GetCanvasGeometry will span them
	with NO change to the server/client callers — they already pass a group.

	Identity:
	  - BlockType == "TextBlock"
	  - IsTextBlock attribute == true (set by BlockHandler on placement)
	  - Standard solid Block template, center pivot, BLOCK_SIZE cube.

	Both server (authoritative canvas) and client (live-typing preview) call
	GetCanvasGeometry so the two always line up exactly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

local TextBlockPlacement = {}

-- Push the canvas this far past the face plane so it never z-fights the cube.
local CANVAS_OFFSET = 0.03

TextBlockPlacement.AllFaces = { "Top", "Bottom", "North", "South", "East", "West" }

-- Outward normal for each face (world space). Matches SignPlacement's
-- GetFaceFromNormal convention so face naming is consistent across the game.
TextBlockPlacement.FaceNormals = {
	Top    = Vector3.new(0, 1, 0),
	Bottom = Vector3.new(0, -1, 0),
	North  = Vector3.new(0, 0, -1),
	South  = Vector3.new(0, 0, 1),
	East   = Vector3.new(1, 0, 0),
	West   = Vector3.new(-1, 0, 0),
}

-- The "up" vector used when orienting each face's canvas. Side faces use
-- world up; Top/Bottom can't (parallel to their normal) so they get a
-- stable arbitrary up that reads naturally from a player standing south.
local FaceUp = {
	Top    = Vector3.new(0, 0, 1),
	Bottom = Vector3.new(0, 0, 1),
	North  = Vector3.new(0, 1, 0),
	South  = Vector3.new(0, 1, 0),
	East   = Vector3.new(0, 1, 0),
	West   = Vector3.new(0, 1, 0),
}

-- Map our face names to Roblox's Enum.NormalId (for parenting Texture objects
-- onto the correct face of the cube part).
TextBlockPlacement.FaceNormalId = {
	Top    = Enum.NormalId.Top,
	Bottom = Enum.NormalId.Bottom,
	North  = Enum.NormalId.Front,  -- -Z = Front in Roblox
	South  = Enum.NormalId.Back,   -- +Z = Back
	East   = Enum.NormalId.Right,  -- +X = Right
	West   = Enum.NormalId.Left,   -- -X = Left
}

-- In-plane axes for each face, expressed as world-space unit vectors:
--   right = +column direction (texture's left->right)
--   up    = +row direction    (texture's bottom->top)
-- These are derived from the same normal/FaceUp convention as GetCanvasGeometry
-- so slice grid coordinates and canvas orientation always agree.
local function getPlaneAxes(face)
	local normal = TextBlockPlacement.FaceNormals[face]
	local up = FaceUp[face]
	if not normal or not up then return nil, nil end
	local right = up:Cross(normal)
	if right.Magnitude < 1e-4 then
		right = Vector3.new(1, 0, 0)
	end
	right = right.Unit
	local realUp = normal:Cross(right).Unit
	return right, realUp
end
TextBlockPlacement.GetPlaneAxes = getPlaneAxes

-- ============================================
-- CANVAS SLICE SELECTION (9-slice merge)
-- ============================================

-- Given a block's (col, row) within a group and the group's col/row extents,
-- return the slice texture name. Pure function of grid coordinates.
local function sliceName(col, row, minCol, maxCol, minRow, maxRow)
	local lone = (minCol == maxCol) and (minRow == maxRow)
	if lone then return "CanvasSingle" end

	local isLeft   = (col == minCol)
	local isRight  = (col == maxCol)
	local isBottom = (row == minRow)
	local isTop    = (row == maxRow)

	if isTop and isLeft then return "CanvasTopLeft" end
	if isTop and isRight then return "CanvasTopRight" end
	if isBottom and isLeft then return "CanvasBottomLeft" end
	if isBottom and isRight then return "CanvasBottomRight" end
	if isTop then return "CanvasTopMiddle" end
	if isBottom then return "CanvasBottomMiddle" end
	if isLeft then return "CanvasMiddleLeft" end
	if isRight then return "CanvasMiddleRight" end
	return "CanvasMiddle"
end

-- Compute integer (col, row) grid coordinates of a block within a face plane,
-- relative to an origin block, using the plane's right/up axes.
local function planeCoord(block, originCenter, right, up)
	local c = TextBlockPlacement.GetBlockCenter(block)
	local d = c - originCenter
	local col = math.round(d:Dot(right) / BLOCK_SIZE)
	local row = math.round(d:Dot(up) / BLOCK_SIZE)
	return col, row
end

-- Returns the slice texture NAME to use on a given face of a block, based on
-- its same-face neighbours within the merged group. Requires a spatialIndex
-- (BlockSpatialIndex) to find neighbours O(1); if absent, falls back to Single.
function TextBlockPlacement.GetSliceForFace(block, face, blocksFolder, spatialIndex)
	local members = TextBlockPlacement.GetFaceGroup(block, face, blocksFolder, spatialIndex)
	if #members <= 1 then return "CanvasSingle" end

	local right, up = getPlaneAxes(face)
	if not right then return "CanvasSingle" end

	local anchor = TextBlockPlacement.GetAnchor(members)
	local originCenter = TextBlockPlacement.GetBlockCenter(anchor)

	local minCol, maxCol, minRow, maxRow = math.huge, -math.huge, math.huge, -math.huge
	for _, m in ipairs(members) do
		local col, row = planeCoord(m, originCenter, right, up)
		if col < minCol then minCol = col end
		if col > maxCol then maxCol = col end
		if row < minRow then minRow = row end
		if row > maxRow then maxRow = row end
	end

	local col, row = planeCoord(block, originCenter, right, up)
	return sliceName(col, row, minCol, maxCol, minRow, maxRow)
end


-- ============================================
-- IDENTITY
-- ============================================

-- Is this blockId a text block? (string-based, like BlockPresets.IsSign)
function TextBlockPlacement.IsTextBlockId(blockId)
	if not blockId then return false end
	return blockId == "TextBlock"
end

-- Is this placed Instance a text block? (attribute-based, like IsSignBlock)
function TextBlockPlacement.IsTextBlock(block)
	if not block then return false end
	if block:GetAttribute("IsTextBlock") then return true end
	local blockType = block:GetAttribute("BlockType")
	return TextBlockPlacement.IsTextBlockId(blockType)
end

-- ============================================
-- FACE DETECTION (mirrors SignPlacement.GetFaceFromNormal)
-- ============================================

function TextBlockPlacement.GetFaceFromNormal(normal)
	local absX = math.abs(normal.X)
	local absY = math.abs(normal.Y)
	local absZ = math.abs(normal.Z)

	if absY > absX and absY > absZ then
		return normal.Y > 0 and "Top" or "Bottom"
	elseif absX > absZ then
		return normal.X > 0 and "East" or "West"
	else
		return normal.Z > 0 and "South" or "North"
	end
end

-- ============================================
-- BLOCK POSITION (grid center)
-- ============================================

-- A text block is a plain solid cube. BlockHandler stores its grid center in
-- BlockPosX/Y/Z; fall back to the part position / model pivot if absent.
function TextBlockPlacement.GetBlockCenter(block)
	local bx = block:GetAttribute("BlockPosX")
	local by = block:GetAttribute("BlockPosY")
	local bz = block:GetAttribute("BlockPosZ")
	if bx and by and bz then
		return Vector3.new(bx, by, bz)
	end
	if block:IsA("BasePart") then
		return block.Position
	elseif block:IsA("Model") then
		return block:GetPivot().Position
	end
	return Vector3.new(0, 0, 0)
end

-- ============================================
-- FACE GROUP (flood-fill via spatial index)
-- ============================================

-- The two in-plane neighbour offsets for a face (world-space), each one
-- BLOCK_SIZE along the plane's right and up axes.
local function getInPlaneOffsets(face)
	local right, up = getPlaneAxes(face)
	if not right then return nil end
	return {
		right * BLOCK_SIZE,
		-right * BLOCK_SIZE,
		up * BLOCK_SIZE,
		-up * BLOCK_SIZE,
	}
end

-- Returns the list of text blocks that share this face's canvas: a flood-fill
-- across coplanar, same-face, edge-adjacent text-block neighbours.
--
-- Two blocks merge on face F when they are adjacent along one of F's in-plane
-- axes AND both are text blocks. Uses BlockSpatialIndex for O(1) neighbour
-- lookups (never iterates the Blocks folder). Without an index, returns just
-- { block } (per-block fallback).
function TextBlockPlacement.GetFaceGroup(block, face, blocksFolder, spatialIndex)
	if not spatialIndex then
		return { block }
	end
	local offsets = getInPlaneOffsets(face)
	if not offsets then return { block } end

	local members = {}
	local seen = {}
	local stack = { block }
	seen[block] = true

	while #stack > 0 do
		local current = table.remove(stack)
		table.insert(members, current)
		local center = TextBlockPlacement.GetBlockCenter(current)
		for _, off in ipairs(offsets) do
			local neighborPos = center + off
			-- Find a text block exactly at that grid cell.
			local candidates = spatialIndex:GetBlocksAt(neighborPos)
			for _, cand in ipairs(candidates) do
				if not seen[cand] and TextBlockPlacement.IsTextBlock(cand) then
					seen[cand] = true
					table.insert(stack, cand)
				end
			end
		end
	end

	return members
end

-- Deterministic owner of a group's text (lowest grid coords). For a single
-- block this is just that block; kept so the merge version "just works".
function TextBlockPlacement.GetAnchor(members)
	if not members or #members == 0 then return nil end
	local anchor = members[1]
	local ax = TextBlockPlacement.GetBlockCenter(anchor)
	for i = 2, #members do
		local c = TextBlockPlacement.GetBlockCenter(members[i])
		if c.X < ax.X
			or (c.X == ax.X and c.Y < ax.Y)
			or (c.X == ax.X and c.Y == ax.Y and c.Z < ax.Z) then
			anchor = members[i]
			ax = c
		end
	end
	return anchor
end

-- ============================================
-- CANVAS GEOMETRY
-- ============================================

-- Returns { cframe = CFrame, width = number, height = number } describing the
-- flat canvas plane for a face of a group. The CFrame's LookVector points
-- OUTWARD along the face normal so a SurfaceGui (Front face) reads correctly
-- from outside the block. width/height are the in-plane stud dimensions.
--
-- PER-BLOCK: width == height == BLOCK_SIZE. The math already derives the span
-- from the members' min/max centers, so a multi-block group widens the canvas
-- with no caller change.
function TextBlockPlacement.GetCanvasGeometry(members, face)
	if not members or #members == 0 then return nil end

	local normal = TextBlockPlacement.FaceNormals[face]
	local up = FaceUp[face]
	if not normal or not up then return nil end

	-- Bounding box of member centers.
	local first = TextBlockPlacement.GetBlockCenter(members[1])
	local minV, maxV = first, first
	for i = 2, #members do
		local c = TextBlockPlacement.GetBlockCenter(members[i])
		minV = Vector3.new(math.min(minV.X, c.X), math.min(minV.Y, c.Y), math.min(minV.Z, c.Z))
		maxV = Vector3.new(math.max(maxV.X, c.X), math.max(maxV.Y, c.Y), math.max(maxV.Z, c.Z))
	end
	local center = (minV + maxV) / 2

	-- In-plane axes: right = up x normal, then re-derive a clean up.
	local right = up:Cross(normal)
	if right.Magnitude < 1e-4 then
		-- Degenerate (shouldn't happen with the FaceUp table), pick any.
		right = Vector3.new(1, 0, 0)
	end
	right = right.Unit
	local realUp = normal:Cross(right).Unit

	-- Span of the group along right/up (block centers + one block of footprint).
	local spanV = maxV - minV
	local width = math.abs(spanV:Dot(right)) + BLOCK_SIZE
	local height = math.abs(spanV:Dot(realUp)) + BLOCK_SIZE

	-- Place the canvas just outside the face plane, centered on the group.
	local outDist = BLOCK_SIZE / 2 + CANVAS_OFFSET
	local canvasPos = center + normal * outDist

	-- Build a CFrame whose -Z (Front) faces outward (+normal), with realUp as up.
	local cframe = CFrame.fromMatrix(canvasPos, right, realUp, -normal)

	return {
		cframe = cframe,
		width = width,
		height = height,
	}
end

-- Convenience: resolve everything for a block+face in one call.
-- Returns members, anchor, geometry.
function TextBlockPlacement.Resolve(block, face, blocksFolder, spatialIndex)
	local members = TextBlockPlacement.GetFaceGroup(block, face, blocksFolder, spatialIndex)
	local anchor = TextBlockPlacement.GetAnchor(members)
	local geometry = TextBlockPlacement.GetCanvasGeometry(members, face)
	return members, anchor, geometry
end

return TextBlockPlacement
