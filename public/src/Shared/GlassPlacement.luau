--[[
	GlassPlacement
	Simplified glass pane placement - always uses Glass_0
	Glass panes orient based on player look direction (flat face toward you)
	
	Orientations:
	- "NS" (North/South): Flat face perpendicular to Z axis (looking along Z places this)
	- "EW" (East/West): Flat face perpendicular to X axis (looking along X places this)
	
	No neighbor connections - just simple directional placement
]]

local GlassPlacement = {}

-- ============================================
-- CONFIGURATION
-- ============================================

local BLOCK_SIZE = 3

-- Spatial index for O(1) block lookups (lazy loaded)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BlockSpatialIndex = nil
local function getSpatialIndex(blocksFolder)
	if not BlockSpatialIndex then
		local mod = ReplicatedStorage:FindFirstChild("BlockSpatialIndex")
		if mod then BlockSpatialIndex = require(mod) end
	end
	if BlockSpatialIndex then return BlockSpatialIndex.GetOrCreate(blocksFolder) end
	return nil
end

-- FencePlacement (lazy loaded) - used to identify true solid blocks vs fences/slabs/decor
local FencePlacement = nil
local function getFencePlacement()
	if not FencePlacement then
		local mod = ReplicatedStorage:FindFirstChild("FencePlacement")
		if mod then FencePlacement = require(mod) end
	end
	return FencePlacement
end

-- Debug levels: 0=off, 1=summary only, 2=verbose
local DEBUG_GLASS_LEVEL = 1

-- Always use the basic pane
GlassPlacement.TEMPLATE_NAME = "Glass_0"

-- Map glass block IDs to their base type
GlassPlacement.GLASS_BASE_TYPES = {
	["Glass"] = "Glass",
	["CandyLattice"] = "CandyLattice",
	-- Add colored glass variants here later if needed
	-- ["RedGlass"] = "Glass",
	-- ["BlueGlass"] = "Glass",
}

-- Per-type model source: which folder the pane/corner/tee/cross models live in,
-- and the actual model names for each connection shape. The connection-detection
-- functions below all speak the generic Glass_0 / Glass_Corner / Glass_Tee /
-- Glass_4_Way vocabulary; ResolveTemplate() translates that into the real folder
-- + model name for whatever glass-style block is being placed. This keeps the
-- whole engine generic so new glass-style sets (CandyLattice, future tinted
-- panes) need only an entry here -- no BlockHandler changes.
--
-- folder is relative to ReplicatedStorage (matches preset.BlockModelFolder).
GlassPlacement.GLASS_TYPE_CONFIG = {
	Glass = {
		folder = "Decorations/Glass",
		single  = "GlassPane",
		corner  = "Glass_Corner",
		tee     = "Glass_Tee",
		fourway = "Glass_4_Way",
	},
	CandyLattice = {
		folder = "RewardSets/CandyBlocks",
		single  = "CandyLattice",
		corner  = "CandyLatticeCorner",
		tee     = "CandyLatticeT",
		fourway = "CandyLatticeCross",
	},
}

-- Map a generic template name (as produced by the connection-detection code)
-- to the config key holding the real model name.
local GENERIC_TEMPLATE_TO_KEY = {
	["Glass_0"]     = "single",
	["Glass_Corner"] = "corner",
	["Glass_Tee"]   = "tee",
	["Glass_4_Way"] = "fourway",
}

-- Resolve a glass type + generic template name into the real folder + model name.
-- glassType: the block's BlockType (e.g. "Glass", "CandyLattice").
-- genericName: one of Glass_0 / Glass_Corner / Glass_Tee / Glass_4_Way.
-- Returns folder (string, relative to ReplicatedStorage) and modelName (string).
-- Falls back to the Glass config for unknown types so existing glass is unaffected.
function GlassPlacement.ResolveTemplate(glassType, genericName)
	local baseType = GlassPlacement.GLASS_BASE_TYPES[glassType] or "Glass"
	local cfg = GlassPlacement.GLASS_TYPE_CONFIG[baseType] or GlassPlacement.GLASS_TYPE_CONFIG.Glass
	local key = GENERIC_TEMPLATE_TO_KEY[genericName] or "single"
	return cfg.folder, cfg[key]
end

-- ============================================
-- COLORED GLASS STYLING
-- ============================================
-- A glass model is an invisible Part (Transparency 1, Plastic) whose visible look
-- comes entirely from per-face Texture children (Back / Front / Top / ...). The plain
-- clear "Glass" / "GlassBlock" keep that template look untouched. The tinted variants
-- (RedGlass, BlueGlassBlock, ...) instead get every face Texture recolored to the
-- glass color and the part turned partially transparent IN that color, so the tint
-- reads as colored glass rather than an invisible pane.
GlassPlacement.COLORED_GLASS_TRANSPARENCY = 0.7

-- True only for the tinted glass variants (RedGlass / RedGlassBlock / ...), never for
-- the plain clear "Glass" or "GlassBlock". Colored variants always carry a color-name
-- prefix, so an exact match against the two clear names is enough to exclude them.
function GlassPlacement.IsColoredGlass(blockType)
	if not blockType then return false end
	if blockType == "Glass" or blockType == "GlassBlock" then return false end
	return string.match(blockType, "GlassBlock$") ~= nil or string.match(blockType, "Glass$") ~= nil
end

-- Apply the colored-glass look to a freshly created/cloned glass instance: recolor
-- every face Texture/Decal to `color` and make each pane COLORED_GLASS_TRANSPARENCY
-- transparent in that same color. Accepts either a single Part or a Model. Hitbox /
-- ClimbSensor helper parts are skipped so collision/interaction stays invisible.
function GlassPlacement.StyleColoredGlass(instance, color)
	if not instance or not color then return end
	local function stylePart(part)
		if part.Name == "Hitbox" or part.Name == "ClimbSensor" then return end
		part.Transparency = GlassPlacement.COLORED_GLASS_TRANSPARENCY
		part.Color = color
		-- SmoothPlastic, not Glass: the Glass material's refraction/sheen washes the
		-- tint out and looks wrong on these textured panes.
		part.Material = Enum.Material.SmoothPlastic
	end
	if instance:IsA("BasePart") then stylePart(instance) end
	for _, desc in ipairs(instance:GetDescendants()) do
		if desc:IsA("BasePart") then
			stylePart(desc)
		elseif desc:IsA("Texture") or desc:IsA("Decal") then
			desc.Color3 = color
		end
	end
end

-- True for ANY glass (clear or tinted, pane or full block). Used to force the material.
function GlassPlacement.IsAnyGlass(blockType)
	if not blockType then return false end
	return string.match(blockType, "Glass$") ~= nil or string.match(blockType, "GlassBlock$") ~= nil
end

-- Force every glass part to SmoothPlastic. The refractive Glass material washes the
-- panes out and looks wrong with their textures, so no glass should ever use it -
-- this normalizes both clear and colored glass regardless of what the template/preset
-- left the material as. Hitbox/ClimbSensor helper parts are left alone.
function GlassPlacement.NormalizeGlassMaterial(instance)
	if not instance then return end
	local function fix(part)
		if part.Name == "Hitbox" or part.Name == "ClimbSensor" then return end
		if part.Material == Enum.Material.Glass then
			part.Material = Enum.Material.SmoothPlastic
		end
	end
	if instance:IsA("BasePart") then fix(instance) end
	for _, desc in ipairs(instance:GetDescendants()) do
		if desc:IsA("BasePart") then fix(desc) end
	end
end

-- Valid orientations
GlassPlacement.Orientations = {
	NS = "NS",  -- North/South - flat face perpendicular to Z
	EW = "EW",  -- East/West - flat face perpendicular to X
}

-- ============================================
-- ORIENTATION DETECTION
-- ============================================

-- Get glass orientation from camera look vector
-- Glass pane flat face should be PERPENDICULAR to the camera's horizontal look direction
-- Looking along Z -> NS orientation (flat face perpendicular to Z, thin along Z)
-- Looking along X -> EW orientation (flat face perpendicular to X, thin along X)
function GlassPlacement.GetOrientationFromLookVector(lookVector)
	if not lookVector then return "NS" end
	
	local absX = math.abs(lookVector.X)
	local absZ = math.abs(lookVector.Z)
	
	if absX > absZ then
		-- Looking more along X axis -> EW glass (thin along X, flat face toward you)
		return "EW"
	else
		-- Looking more along Z axis -> NS glass (thin along Z, flat face toward you)
		return "NS"
	end
end

-- Get orientation name for debugging
function GlassPlacement.GetOrientationName(orientation)
	if orientation == "EW" then
		return "East/West (thin on X)"
	end
	return "North/South (thin on Z)"
end

-- ============================================
-- GLASS TYPE DETECTION
-- ============================================

-- Check if a block type is a glass pane
-- Matches "Glass" and any tinted variant like "RedGlass", "BlueGlass", etc.
-- Does NOT match full blocks like "GlassBlock" or "RedGlassBlock"
function GlassPlacement.IsGlass(blockType)
	if not blockType then return false end
	-- Explicit lookup first
	if GlassPlacement.GLASS_BASE_TYPES[blockType] ~= nil then return true end
	-- Pattern match: ends with "Glass" but NOT "GlassBlock"
	if string.match(blockType, "Glass$") and not string.match(blockType, "GlassBlock$") then
		return true
	end
	return false
end

-- Check if a part/model is a glass block
function GlassPlacement.IsGlassBlock(block)
	if not block then return false end
	
	-- Check attribute first
	if block:GetAttribute("IsGlass") then return true end
	
	-- Check BlockType attribute
	local blockType = block:GetAttribute("BlockType")
	if blockType and GlassPlacement.IsGlass(blockType) then return true end
	
	return false
end

-- Get glass at position (kept for potential future use)
function GlassPlacement.GetGlassAtPosition(position, blocksFolder, requiredOrientation)
	if not blocksFolder then return nil end
	
	-- Use spatial index for O(1) lookup
	local index = getSpatialIndex(blocksFolder)
	local candidates = index and index:GetBlocksAt(position) or blocksFolder:GetChildren()
	
	for _, block in ipairs(candidates) do
		-- Defensive: skip blocks that have been destroyed but not yet removed from the spatial
		-- index. Roblox's deferred signal behavior means ChildRemoved can lag a frame behind
		-- Destroy(), and we don't want stale entries to fool our neighbor checks.
		if block.Parent and GlassPlacement.IsGlassBlock(block) then
			local blockPos
			if block:IsA("Model") then
				blockPos = block:GetPivot().Position
			else
				blockPos = block.Position
			end
			
			if blockPos then
				local diff = position - blockPos
				if math.abs(diff.X) < 1.5 and math.abs(diff.Y) < 1.5 and math.abs(diff.Z) < 1.5 then
					local glassOrientation = block:GetAttribute("GlassOrientation") or "NS"
					if requiredOrientation and glassOrientation ~= requiredOrientation then
						continue
					end
					
					return {
						instance = block,
						glassType = block:GetAttribute("BlockType"),
						connectionType = "isolated",
						orientation = glassOrientation,
						position = blockPos,
					}
				end
			end
		end
	end
	
	return nil
end

-- ============================================
-- ROTATION CALCULATION
-- ============================================

-- Get rotation CFrame based on orientation
-- NS: Default orientation (no rotation needed)
-- EW: 90° rotation on Y axis
function GlassPlacement.GetGlassRotation(orientation)
	if orientation == "EW" then
		return CFrame.Angles(0, math.rad(90), 0)
	end
	return CFrame.new() -- NS uses identity rotation
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

-- Get full placement info for glass (simplified - always Glass_0)
function GlassPlacement.GetPlacementInfo(blockType, position, blocksFolder, orientation, debugOutput)
	-- Default orientation if not specified
	orientation = orientation or "NS"
	
	local rotationCFrame = GlassPlacement.GetGlassRotation(orientation)
	
	-- Summary logging at level 1+
	if debugOutput or DEBUG_GLASS_LEVEL >= 1 then
	end
	
	return {
		templateName = "Glass_0",
		connectionType = "isolated",
		rotationCFrame = rotationCFrame,
		orientation = orientation,
		primaryDirection = nil,
		secondaryDirection = nil,
		neighbors = {},
	}
end

-- Get CFrame for glass placement
function GlassPlacement.GetGlassCFrame(position, rotationCFrame, positionOffset, connectionType)
	local finalPosition = position
	if positionOffset then
		finalPosition = position + positionOffset
	end
	
	-- Summary logging at level 1+
	if DEBUG_GLASS_LEVEL >= 1 then
	end
	
	return CFrame.new(finalPosition) * rotationCFrame
end

-- ============================================
-- CORNER DETECTION
-- ============================================

-- Cardinal cell offsets (one block over in each direction)
local NEIGHBOR_OFFSETS = {
	East  = Vector3.new( BLOCK_SIZE, 0,  0),
	West  = Vector3.new(-BLOCK_SIZE, 0,  0),
	South = Vector3.new( 0, 0,  BLOCK_SIZE),
	North = Vector3.new( 0, 0, -BLOCK_SIZE),
}

-- Check if a position contains a solid block (full block - not fence/slab/stair/decor/etc.)
-- Uses FencePlacement.IsSolidBlockInstance which already excludes all partial/non-solid types
local function getSolidBlockAt(position, blocksFolder)
	if not blocksFolder then return nil end
	local Fence = getFencePlacement()
	if not Fence then return nil end

	local index = getSpatialIndex(blocksFolder)
	local candidates = index and index:GetBlocksAt(position) or blocksFolder:GetChildren()

	for _, block in ipairs(candidates) do
		-- Defensive: skip blocks that have been destroyed but not yet removed from the spatial index.
		if block.Parent and Fence.IsSolidBlockInstance(block) then
			local blockPos
			-- Prefer stored grid position attributes for accuracy
			local bpX = block:GetAttribute("BlockPosX")
			local bpY = block:GetAttribute("BlockPosY")
			local bpZ = block:GetAttribute("BlockPosZ")
			if bpX and bpY and bpZ then
				blockPos = Vector3.new(bpX, bpY, bpZ)
			elseif block:IsA("Model") then
				blockPos = block:GetPivot().Position
			elseif block:IsA("BasePart") then
				blockPos = block.Position
			end

			if blockPos then
				local diff = position - blockPos
				if math.abs(diff.X) < 1.5 and math.abs(diff.Y) < 1.5 and math.abs(diff.Z) < 1.5 then
					return block
				end
			end
		end
	end

	return nil
end

-- Check if a position has either a glass pane OR a solid block - both count as L-corner anchors
local function hasCornerAnchorAt(position, blocksFolder)
	if GlassPlacement.GetGlassAtPosition(position, blocksFolder) ~= nil then return true end
	if getSolidBlockAt(position, blocksFolder) ~= nil then return true end
	return false
end

-- Detect what kind of connection this glass position should be.
-- Returns info table with cornerType in {"corner", "tee", "4way"}, or nil for flat panes.
-- Neighbors can be either glass panes or solid blocks (but NOT fences, slabs, etc.).
local function detectGlassConnection(position, blocksFolder, paneOrientation, allowStubTee)
	if not blocksFolder then return nil end

	local hasEast  = hasCornerAnchorAt(position + NEIGHBOR_OFFSETS.East,  blocksFolder)
	local hasWest  = hasCornerAnchorAt(position + NEIGHBOR_OFFSETS.West,  blocksFolder)
	local hasSouth = hasCornerAnchorAt(position + NEIGHBOR_OFFSETS.South, blocksFolder)
	local hasNorth = hasCornerAnchorAt(position + NEIGHBOR_OFFSETS.North, blocksFolder)

	local count = (hasEast and 1 or 0) + (hasWest and 1 or 0) + (hasSouth and 1 or 0) + (hasNorth and 1 or 0)

	-- 4-way intersection: all 4 cardinal neighbors
	if count == 4 then
		return {
			templateName = "Glass_4_Way",
			cornerType = "4way",
			rotationCFrame = CFrame.new(),
			positionOffset = nil,
			rotationDegrees = 0,
		}
	end

	-- T-junction: exactly 3 neighbors (one direction is missing).
	-- Rotation orients the tee so the "closed" back is toward the missing direction.
	-- If your Glass_Tee base model points the wrong way, shift these all by the same
	-- amount (e.g. add 90 to each).
	if count == 3 then
		local rotationDegrees
		if not hasNorth then
			rotationDegrees = 0
		elseif not hasEast then
			rotationDegrees = 270
		elseif not hasSouth then
			rotationDegrees = 180
		else -- not hasWest
			rotationDegrees = 90
		end
		return {
			templateName = "Glass_Tee",
			cornerType = "tee",
			rotationCFrame = CFrame.Angles(0, math.rad(rotationDegrees), 0),
			positionOffset = nil,
			rotationDegrees = rotationDegrees,
		}
	end

	-- L-corner: exactly 2 perpendicular neighbors (1 on each axis)
	if count == 2 then
		local xCount = (hasEast and 1 or 0) + (hasWest and 1 or 0)
		local zCount = (hasSouth and 1 or 0) + (hasNorth and 1 or 0)

		if xCount == 1 and zCount == 1 then
			local rotationDegrees
			if hasEast and hasSouth then
				rotationDegrees = 90
			elseif hasEast and hasNorth then
				rotationDegrees = 180
			elseif hasWest and hasNorth then
				rotationDegrees = 270
			else -- hasWest and hasSouth
				rotationDegrees = 0
			end
			-- The Glass_Corner model faces the opposite way from the old set, so flip
			-- every corner 180° to point its open side back along the wall run.
			rotationDegrees = (rotationDegrees + 180) % 360
			return {
				templateName = "Glass_Corner",
				cornerType = "corner",
				rotationCFrame = CFrame.Angles(0, math.rad(rotationDegrees), 0),
				positionOffset = nil,
				rotationDegrees = rotationDegrees,
			}
		end
	end

	-- count 0, 1, or 2-opposite -> normally flat pane.
	-- BUT: if count==1 and the pane's own orientation is perpendicular to the
	-- single neighbor's axis, it's a tee stub. The pane's own width acts as the
	-- bar of the tee, and the sole real neighbor is the stem. When a real
	-- perpendicular neighbor later gets placed, the count will be 2 and the
	-- L-corner rule takes over naturally.
	-- A pane labeled "NS" is thin on Z (faces north/south) so its width spans X.
	-- Its in-line neighbors are on the X axis (E/W); perpendicular stub neighbors
	-- are on Z (N/S). "EW" is the mirror: thin on X, width spans Z, in-line on Z,
	-- perpendicular on X.
	if count == 1 and paneOrientation and allowStubTee then
		local soleAxisIsX = (hasEast or hasWest)
		local soleAxisIsZ = (hasNorth or hasSouth)
		local perpendicular = false
		local rotationDegrees = 0

		if paneOrientation == "NS" and soleAxisIsZ then
			-- NS pane (bar spans X) with sole N or S neighbor as the stem.
			-- Stem N -> missing S -> 180. Stem S -> missing N -> 0.
			perpendicular = true
			rotationDegrees = hasNorth and 180 or 0
		elseif paneOrientation == "EW" and soleAxisIsX then
			-- EW pane (bar spans Z) with sole E or W neighbor as the stem.
			-- Stem E -> missing W -> 90. Stem W -> missing E -> 270.
			perpendicular = true
			rotationDegrees = hasEast and 90 or 270
		end

		if perpendicular then
			return {
				templateName = "Glass_Tee",
				cornerType = "tee",
				rotationCFrame = CFrame.Angles(0, math.rad(rotationDegrees), 0),
				positionOffset = nil,
				rotationDegrees = rotationDegrees,
			}
		end
	end

	-- Normal flat pane
	return nil
end

-- Alias kept for clarity at older call sites.
local detectCornerAt = detectGlassConnection

-- Returns true if an orientation string represents a special (multi-side) connection.
local function isSpecialOrientation(orient)
	return orient == "corner" or orient == "tee" or orient == "4way"
end

-- Pick the best flat-pane orientation for a position based on its remaining neighbors.
-- More X-axis neighbors -> wall runs E-W -> use NS panes (thin on Z).
local function pickFlatOrientation(position, blocksFolder)
	local hasEast  = hasCornerAnchorAt(position + NEIGHBOR_OFFSETS.East,  blocksFolder)
	local hasWest  = hasCornerAnchorAt(position + NEIGHBOR_OFFSETS.West,  blocksFolder)
	local hasSouth = hasCornerAnchorAt(position + NEIGHBOR_OFFSETS.South, blocksFolder)
	local hasNorth = hasCornerAnchorAt(position + NEIGHBOR_OFFSETS.North, blocksFolder)
	local xCount = (hasEast and 1 or 0) + (hasWest and 1 or 0)
	local zCount = (hasSouth and 1 or 0) + (hasNorth and 1 or 0)
	return (xCount >= zCount) and "NS" or "EW"
end

-- Examine the glass at `existing.position` and, if its current type doesn't match
-- what its neighbors imply, destroy and re-create it as the correct type.
-- Handles all transitions: flat<->corner<->tee<->4way (in either direction).
-- Preserves the old glass's color and per-part material/materialVariant so paint
-- and material choices survive the conversion.
-- Returns table {instance, position, oldOrientation, newOrientation, converted} or nil if no change.
local function fixupGlassAtPosition(existing, blocksFolder, createGlassFunc, allowStubTee)
	if not existing or not createGlassFunc then return nil end

	local instance = existing.instance
	local existingOrient = instance:GetAttribute("GlassOrientation") or "NS"
	local existingRotation = instance:GetAttribute("GlassRotationDegrees")
	local pos = existing.position

	-- Hint detection with the pane's current flat orientation. For specials
	-- (corner/tee/4way), compute what flat orient would be picked, so the
	-- perpendicular-stub rule can still trigger after a revert.
	local hintOrient = existingOrient
	if isSpecialOrientation(existingOrient) then
		hintOrient = pickFlatOrientation(pos, blocksFolder)
	end

	-- A pane that's currently a corner or tee was already on a perpendicular wall
	-- branch, so when its situation collapses back toward count==1 we want it to
	-- stay a tee stub rather than flatten. Allow the stub-tee rule for these.
	local effectiveStubTee = allowStubTee or existingOrient == "corner" or existingOrient == "tee"

	local newInfo = detectGlassConnection(pos, blocksFolder, hintOrient, effectiveStubTee)
	local existingIsSpecial = isSpecialOrientation(existingOrient)

	-- Decide whether to replace.
	local replaceWith = nil

	if newInfo then
		-- Should be a special connection (corner/tee/4way).
		-- Replace if type changed, or if rotation changed within the same type.
		if existingOrient ~= newInfo.cornerType or existingRotation ~= newInfo.rotationDegrees then
			replaceWith = {
				template        = newInfo.templateName,
				rotationCFrame  = newInfo.rotationCFrame,
				connectionType  = newInfo.cornerType,
				orientation     = newInfo.cornerType,
				rotationDegrees = newInfo.rotationDegrees,
			}
		end
	elseif existingIsSpecial then
		-- Was special, should now be flat.
		local newOrient = pickFlatOrientation(pos, blocksFolder)
		replaceWith = {
			template        = "Glass_0",
			rotationCFrame  = GlassPlacement.GetGlassRotation(newOrient),
			connectionType  = "isolated",
			orientation     = newOrient,
			rotationDegrees = 0,
		}
	end
	-- else: flat staying flat, no change needed.

	if not replaceWith then return nil end

	-- Sample appearance from old glass BEFORE destroying.
	-- We capture per-part-by-name so Outer/Inner can retain their distinct materials,
	-- and we keep one sampled color as a fallback for any new parts not in the old.
	local perPartAppearance = {}
	local fallbackColor = nil
	if instance:IsA("BasePart") then
		fallbackColor = instance.Color
		perPartAppearance["__root__"] = {
			color = instance.Color, material = instance.Material, materialVariant = instance.MaterialVariant,
		}
	elseif instance:IsA("Model") then
		for _, part in ipairs(instance:GetDescendants()) do
			if part:IsA("BasePart") then
				perPartAppearance[part.Name] = {
					color = part.Color, material = part.Material, materialVariant = part.MaterialVariant,
				}
				if not fallbackColor then fallbackColor = part.Color end
			end
		end
	end

	local oldBlockType = instance:GetAttribute("BlockType")
	local oldPlacedBy  = instance:GetAttribute("PlacedBy")
	instance:Destroy()

	local newGlass = createGlassFunc(
		replaceWith.template, oldBlockType, pos,
		replaceWith.rotationCFrame, oldPlacedBy, replaceWith.connectionType,
		nil, nil, replaceWith.orientation
	)

	if newGlass then
		-- Reapply appearance: prefer per-part-by-name match, fall back to sampled color.
		local function applyTo(part)
			local app = perPartAppearance[part.Name] or perPartAppearance["__root__"]
			if app then
				part.Color = app.color
				part.Material = app.material
				if app.materialVariant and app.materialVariant ~= "" then
					part.MaterialVariant = app.materialVariant
				end
			elseif fallbackColor then
				part.Color = fallbackColor
			end
		end
		if newGlass:IsA("BasePart") then
			applyTo(newGlass)
		elseif newGlass:IsA("Model") then
			for _, part in ipairs(newGlass:GetDescendants()) do
				if part:IsA("BasePart") then
					applyTo(part)
				end
			end
		end

		-- Colored glass: re-apply the tinted-texture + 70% transparency look so it
		-- survives the flat<->corner<->tee<->4way conversion. Clear glass is skipped.
		if GlassPlacement.IsColoredGlass(oldBlockType) and fallbackColor then
			GlassPlacement.StyleColoredGlass(newGlass, fallbackColor)
		end

		-- Store rotation degrees so future fixups can detect rotation-only changes.
		newGlass:SetAttribute("GlassRotationDegrees", replaceWith.rotationDegrees)
		return {
			instance = newGlass,
			position = pos,
			oldOrientation = existingOrient,
			newOrientation = replaceWith.orientation,
			converted = (existingIsSpecial and not newInfo) and "flatten"
				or (newInfo and replaceWith.connectionType or "isolated"),
		}
	end

	return nil
end

-- ============================================
-- CONNECTED-BLOCK FACE CULLING (glass + leaves)
-- ============================================
-- When a textured see-through block (glass, or leaves) abuts another block of the SAME
-- kind, the textures on the faces where the two cells meet read as doubled clutter seen
-- through them. We hide the texture on any face that points at a neighboring cell of the
-- same kind (restoring it when the neighbor goes away), so a run/volume of connected
-- glass -- or a clump of leaves -- reads as one clean surface; only outward faces keep
-- their texture. Direction comes from each Texture's Face mapped through the part's world
-- CFrame, so it works for any orientation, the corner/tee/4way models, full glass blocks,
-- leaf blocks, and leaf-filled frames.
--
-- Culling is per-kind ("group"): glass only culls against glass, leaves only against
-- leaves -- so a leaf next to glass keeps both textures.

local CULL_NEIGHBOR_DIRS = {
	Vector3.new( BLOCK_SIZE, 0, 0), Vector3.new(-BLOCK_SIZE, 0, 0),
	Vector3.new(0,  BLOCK_SIZE, 0), Vector3.new(0, -BLOCK_SIZE, 0),
	Vector3.new(0, 0,  BLOCK_SIZE), Vector3.new(0, 0, -BLOCK_SIZE),
}

-- Snap a (roughly axis-aligned) world vector to its nearest unit cardinal direction.
local function toCardinal(v)
	local ax, ay, az = math.abs(v.X), math.abs(v.Y), math.abs(v.Z)
	if ax >= ay and ax >= az then
		return Vector3.new(v.X >= 0 and 1 or -1, 0, 0)
	elseif ay >= az then
		return Vector3.new(0, v.Y >= 0 and 1 or -1, 0)
	else
		return Vector3.new(0, 0, v.Z >= 0 and 1 or -1)
	end
end

-- True for leaves that should cull: leaf blocks and leaf-filled frames, but NOT
-- leaf-filled frame doors (and never anything door-like).
function GlassPlacement.IsCullableLeaf(block, blockType)
	blockType = blockType or (block and block:GetAttribute("BlockType"))
	-- Never cull doors, including leaf-filled frame doors.
	if blockType and string.find(blockType, "Door") then return false end
	if block and block:GetAttribute("IsDoor") then return false end
	-- A leaf block (BirchLeaves, OakLeaves, ...).
	if blockType and string.find(blockType, "Leaves") then return true end
	-- A frame filled with leaves.
	local fill = block and block:GetAttribute("FrameFillBlockId")
	if fill and string.find(fill, "Leaves") then return true end
	return false
end

-- Which cull group a block belongs to ("glass" / "leaves"), or nil if it doesn't
-- participate. Faces only cull against neighbors of the SAME group.
local function cullGroupOf(block)
	if not block then return nil end
	local bt = block:GetAttribute("BlockType")
	if block:GetAttribute("IsGlass") or (bt and GlassPlacement.IsAnyGlass(bt)) then
		return "glass"
	end
	if GlassPlacement.IsCullableLeaf(block, bt) then
		return "leaves"
	end
	return nil
end

-- Grid position of a block (prefers stored attributes; falls back to pivot/position).
local function blockGridPos(block)
	local bx = block:GetAttribute("BlockPosX")
	local by = block:GetAttribute("BlockPosY")
	local bz = block:GetAttribute("BlockPosZ")
	if bx and by and bz then return Vector3.new(bx, by, bz) end
	if block:IsA("Model") then return block:GetPivot().Position end
	if block:IsA("BasePart") then return block.Position end
	return nil
end

-- Find a cullable block occupying the given cell. If `wantGroup` is given, only matches
-- that group. Returns (block, gridPos, group) or nil.
local function findCullableAt(position, blocksFolder, wantGroup)
	local index = getSpatialIndex(blocksFolder)
	local candidates = index and index:GetBlocksAt(position) or blocksFolder:GetChildren()
	for _, block in ipairs(candidates) do
		if block.Parent then
			local g = cullGroupOf(block)
			if g and (wantGroup == nil or g == wantGroup) then
				local bpos = blockGridPos(block)
				if bpos then
					local d = position - bpos
					if math.abs(d.X) < 1.5 and math.abs(d.Y) < 1.5 and math.abs(d.Z) < 1.5 then
						return block, bpos, g
					end
				end
			end
		end
	end
	return nil
end

-- Show or hide a single face texture, caching its authored transparency the first time
-- so it can be restored when the neighbor is removed.
local function setTextureHidden(tex, hidden)
	if tex:GetAttribute("BaseTransparency") == nil then
		tex:SetAttribute("BaseTransparency", tex.Transparency)
	end
	tex.Transparency = hidden and 1 or tex:GetAttribute("BaseTransparency")
end

-- Hide `instance`'s face textures on any side abutting another cell of the SAME group,
-- and show the rest. `pos` is the instance's grid cell. (Name kept for existing callers;
-- works for glass and leaves alike.)
function GlassPlacement.CullGlassFaces(instance, pos, blocksFolder)
	if not instance or not pos or not blocksFolder then return end
	local group = cullGroupOf(instance)
	if not group then return end

	-- Probe each of the six neighbor cells at most once, even for multi-part models.
	local neighborCache = {}
	local function sameKindInDirection(dir)
		local key = dir.X .. "," .. dir.Y .. "," .. dir.Z
		local cached = neighborCache[key]
		if cached == nil then
			cached = findCullableAt(pos + dir * BLOCK_SIZE, blocksFolder, group) ~= nil
			neighborCache[key] = cached
		end
		return cached
	end

	-- Collect the instance's own part (if any) AND every BasePart descendant, so blocks
	-- that carry more than one set of face textures -- e.g. leaf blocks with an inner and
	-- outer texture layer on nested parts -- all get culled, not just the top-level part.
	local parts = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, p in ipairs(instance:GetDescendants()) do
		if p:IsA("BasePart") then table.insert(parts, p) end
	end
	if #parts == 0 then return end

	for _, part in ipairs(parts) do
		if part.Name ~= "Hitbox" and part.Name ~= "ClimbSensor" then
			-- Every Texture/Decal on the part (a face may carry several layers; cull each).
			for _, child in ipairs(part:GetChildren()) do
				if child:IsA("Texture") or child:IsA("Decal") then
					local worldDir = toCardinal(part.CFrame:VectorToWorldSpace(Vector3.FromNormalId(child.Face)))
					setTextureHidden(child, sameKindInDirection(worldDir))
				end
			end
		end
	end
end

-- Re-cull the cullable block at `pos` and each of its six neighbors (each against its
-- own group). Call after any glass/leaf block is placed, removed, or converted.
function GlassPlacement.RefreshGlassFaces(pos, blocksFolder)
	if not pos or not blocksFolder then return end
	local function refreshAt(p)
		local inst, ipos = findCullableAt(p, blocksFolder, nil)
		if inst then
			GlassPlacement.CullGlassFaces(inst, ipos, blocksFolder)
		end
	end
	refreshAt(pos)
	for _, dir in ipairs(CULL_NEIGHBOR_DIRS) do
		refreshAt(pos + dir)
	end
end

-- Cull every cullable block (glass + leaves) in the folder. Used once after a plot
-- loads, where blocks are created straight from saved data rather than via placement.
function GlassPlacement.CullAllGlass(blocksFolder)
	if not blocksFolder then return end
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if cullGroupOf(block) then
			local pos = blockGridPos(block)
			if pos then
				GlassPlacement.CullGlassFaces(block, pos, blocksFolder)
			end
		end
	end
end

-- ============================================
-- NEIGHBOR UPDATES
-- ============================================

-- Called after a glass is placed OR removed. Re-evaluates every adjacent glass
-- pane and updates it to the correct connection type if its neighbor situation
-- has changed (handles all flat<->corner<->tee<->4way transitions).
function GlassPlacement.UpdateAdjacentGlass(position, blocksFolder, createGlassFunc, orientation)
	local updated = {}
	if not blocksFolder or not createGlassFunc then return updated end

	for _, offset in pairs(NEIGHBOR_OFFSETS) do
		local existing = GlassPlacement.GetGlassAtPosition(position + offset, blocksFolder)
		if existing then
			local result = fixupGlassAtPosition(existing, blocksFolder, createGlassFunc)
			if result then
				table.insert(updated, result)
			end
		end
	end

	-- Keep connected-glass texture culling in sync (covers place, remove, and
	-- solid-block-near-glass, since they all funnel through here).
	GlassPlacement.RefreshGlassFaces(position, blocksFolder)

	return updated
end

-- Public: re-evaluate a single glass pane at the given position. Useful after a
-- new pane is placed to check if it itself should become a corner/tee/4way
-- (the UpdateAdjacentGlass path only checks neighbors, not self).
-- This path enables the stub-tee rule since the pane is freshly placed by the
-- player and intended to extend a wall perpendicularly.
function GlassPlacement.FixupGlassAtPosition(position, blocksFolder, createGlassFunc)
	if not blocksFolder or not createGlassFunc then return nil end
	local existing = GlassPlacement.GetGlassAtPosition(position, blocksFolder)
	if not existing then return nil end
	local result = fixupGlassAtPosition(existing, blocksFolder, createGlassFunc, true)
	GlassPlacement.RefreshGlassFaces(position, blocksFolder)
	return result
end

-- Called when a SOLID BLOCK is placed or removed near glass panes.
-- Same behavior as UpdateAdjacentGlass: re-evaluates each adjacent glass pane.
function GlassPlacement.UpdateGlassNearSolidBlock(position, blocksFolder, createGlassFunc)
	return GlassPlacement.UpdateAdjacentGlass(position, blocksFolder, createGlassFunc, nil)
end

-- No neighbor checking needed
function GlassPlacement.GetGlassNeighbors(position, blocksFolder, orientation)
	return {
		[0] = false,
		[1] = false,
		[2] = false,
		[3] = false,
	}
end

-- ============================================
-- DEBUG HELPERS
-- ============================================

function GlassPlacement.GetDirectionName(dir, orientation)
	return "N/A"
end

function GlassPlacement.GetConnectionTypeName(connectionType)
	return "isolated"
end

-- ============================================
-- CORNER PUBLIC API
-- ============================================

-- Called BEFORE the new glass is placed. If the placement cell satisfies a
-- corner / tee / 4-way condition, returns template info; otherwise returns nil
-- and standard flat-pane placement is used.
function GlassPlacement.GetCornerPlacementInfo(blockType, position, blocksFolder)
	return detectGlassConnection(position, blocksFolder)
end

-- Called AFTER a new flat glass is placed. Returns existing adjacent panes
-- that should be converted into a special connection (corner/tee/4way) because
-- the new placement changed their neighbor configuration.
-- NOTE: With the unified UpdateAdjacentGlass above, this is mostly redundant
--       (UpdateAdjacentGlass already performs the conversions). It still works
--       correctly: any panes already converted by UpdateAdjacentGlass will be
--       skipped here because their orientation will already match.
function GlassPlacement.GetAdjacentGlassToConvertToCorners(position, orientation, blocksFolder)
	local toConvert = {}
	if not blocksFolder then return toConvert end

	for _, offset in pairs(NEIGHBOR_OFFSETS) do
		local existing = GlassPlacement.GetGlassAtPosition(position + offset, blocksFolder)
		if existing then
			local existingOrient = existing.instance:GetAttribute("GlassOrientation") or "NS"
			local newInfo = detectGlassConnection(existing.position, blocksFolder)

			-- Only return panes that need to become a special type AND aren't already that type.
			if newInfo and existingOrient ~= newInfo.cornerType then
				table.insert(toConvert, {
					existingGlass = existing,
					cornerInfo = newInfo,
					position = existing.position,
				})
			end
		end
	end

	return toConvert
end

-- Legacy connection type determination (returns isolated)
function GlassPlacement.DetermineConnectionType(neighbors)
	return "isolated", nil, nil
end

return GlassPlacement
