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
	-- Add colored glass variants here later if needed
	-- ["RedGlass"] = "Glass",
	-- ["BlueGlass"] = "Glass",
}

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
		print(string.format("[Glass] PlacementInfo: template=Glass_0, orientation=%s", orientation))
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
		print(string.format("[Glass] GetGlassCFrame: inputPos=(%.2f,%.2f,%.2f) finalPos=(%.2f,%.2f,%.2f)",
			position.X, position.Y, position.Z,
			finalPosition.X, finalPosition.Y, finalPosition.Z))
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
	return fixupGlassAtPosition(existing, blocksFolder, createGlassFunc, true)
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
