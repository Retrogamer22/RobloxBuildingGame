--[[
	ClientPrediction
	Handles optimistic/predictive block placement and breaking.
	Shows instant visual feedback while waiting for server confirmation.
	
	BREAKING: Hides blocks INSTANTLY (fully invisible) when broken client-side.
	PLACING: Creates ghost blocks for instant placement feedback.
	TERRAIN: Predicts adjacent terrain blocks when digging underground.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local TerrainLogic = require(ReplicatedStorage:WaitForChild("TerrainLogic", 10))

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
-- Free-build (second) place gate. There, the world is one continuous space with
-- no bounded plots, so prediction resolves any position to the player's owned
-- center build area instead of a footprint test. Mirrors BlockHandler +
-- BuildingController. Single source of truth: BetaConfig.
local BetaConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("BetaConfig", 10))

local ClientPrediction = {}

-- Configuration
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Remote for receiving dug positions from server (cleans up phantom predictions in saved holes)
-- Only connect on client (this module is in Shared but only used client-side)
local TerrainDugPositions = nil
if RunService:IsClient() then
	local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	TerrainDugPositions = Remotes and Remotes:WaitForChild("TerrainDugPositions", 5)
end
local PREDICTION_TIMEOUT = 3 -- Seconds before cleaning up stale predictions
local TERRAIN_PREDICTION_TIMEOUT = 1.5 -- Short timeout: real blocks arrive in ~100ms, dug cleanup in ~200ms. Fallback if both miss.
local GHOST_TRANSPARENCY = 1 -- Fully transparent - no visible ghost blocks
local DEBUG = false

-- ============================================
-- STATE TRACKING
-- ============================================

-- Blocks hidden by client prediction (being destroyed, waiting for server)
-- Key: block instance, Value: { timestamp, originalTransparencies }
local hiddenBlocks = {}

-- Terrain prediction blocks (temporary blocks spawned to fill underground gaps)
-- Key: position string "X,Y,Z", Value: { block, timestamp }
local terrainPredictions = {}

-- Placement prediction blocks (ghost blocks for instant placement feedback)
-- Key: position string "X,Y,Z", Value: { block, timestamp }
local placementPredictions = {}

-- Track positions the client has dug out (prevents re-spawning temp blocks)
local dugPositions = {}

-- Predictions folder in workspace (for raycast exclusion)
local predictionsFolder = nil

-- ============================================
-- UTILITY
-- ============================================

local function posKey(pos)
	-- Use rounded coordinates directly instead of re-snapping to BLOCK_SIZE grid.
	-- Server terrain grid may not be aligned to multiples of BLOCK_SIZE from origin
	-- (e.g., surfaceY = plateTop - 1.5 can produce Y values like 10.5, 7.5, etc.)
	-- Re-snapping via round(Y/BLOCK_SIZE)*BLOCK_SIZE would misalign these positions.
	-- Rounding to 1 decimal place handles floating-point drift while preserving the
	-- server's actual grid positions.
	return string.format("%.1f,%.1f,%.1f",
		math.round(pos.X * 10) / 10,
		math.round(pos.Y * 10) / 10,
		math.round(pos.Z * 10) / 10)
end

local function getPredictionsFolder()
	if predictionsFolder and predictionsFolder.Parent then
		return predictionsFolder
	end
	predictionsFolder = workspace:FindFirstChild("ClientPredictions")
	if not predictionsFolder then
		predictionsFolder = Instance.new("Folder")
		predictionsFolder.Name = "ClientPredictions"
		predictionsFolder.Parent = workspace
	end
	return predictionsFolder
end

local function getBlockPosition(block)
	-- Prefer stored grid position attributes
	local bpx = block:GetAttribute("BlockPosX")
	local bpy = block:GetAttribute("BlockPosY")
	local bpz = block:GetAttribute("BlockPosZ")
	if bpx and bpy and bpz then
		return Vector3.new(bpx, bpy, bpz)
	end

	local gpx = block:GetAttribute("GridPosX")
	local gpy = block:GetAttribute("GridPosY")
	local gpz = block:GetAttribute("GridPosZ")
	if gpx and gpy and gpz then
		return Vector3.new(gpx, gpy, gpz)
	end

	-- Fallback to pivot
	if block:IsA("Model") then
		return block:GetPivot().Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
	elseif block:IsA("BasePart") then
		return block:GetPivot().Position
	end
	return nil
end

-- ============================================
-- BLOCK HIDING (for breaking)
-- Makes blocks FULLY INVISIBLE so there's no "ghost" appearance
-- ============================================

local function hideBlockCompletely(block)
	if hiddenBlocks[block] then return end -- Already hidden

	local originalData = {}

	if block:IsA("BasePart") then
		originalData.transparency = block.Transparency
		originalData.canCollide = block.CanCollide
		originalData.canQuery = block.CanQuery
		block.Transparency = 1
		block.CanCollide = false
		block.CanQuery = false -- CRITICAL: Let raycasts pass through hidden blocks
		-- Single-part blocks (e.g. leaves) carry their look on child Texture/Decal
		-- objects, which keep rendering even when the part is fully transparent. Hide
		-- them too, or the texture lingers on screen until the server destroys the block.
		for _, child in ipairs(block:GetDescendants()) do
			if child:IsA("Decal") or child:IsA("Texture") then
				if not originalData.decals then originalData.decals = {} end
				table.insert(originalData.decals, { decal = child, transparency = child.Transparency })
				child.Transparency = 1
			elseif child:IsA("SurfaceGui") then
				if not originalData.surfaceGuis then originalData.surfaceGuis = {} end
				table.insert(originalData.surfaceGuis, { gui = child, enabled = child.Enabled })
				child.Enabled = false
			end
		end
	elseif block:IsA("Model") then
		originalData.parts = {}
		for _, part in ipairs(block:GetDescendants()) do
			if part:IsA("BasePart") then
				table.insert(originalData.parts, {
					part = part,
					transparency = part.Transparency,
					canCollide = part.CanCollide,
					canQuery = part.CanQuery,
				})
				part.Transparency = 1
				part.CanCollide = false
				part.CanQuery = false -- CRITICAL: Let raycasts pass through hidden blocks
			elseif part:IsA("Decal") or part:IsA("Texture") then
				-- Hide decals/textures too
				if not originalData.decals then originalData.decals = {} end
				table.insert(originalData.decals, {
					decal = part,
					transparency = part.Transparency,
				})
				part.Transparency = 1
			elseif part:IsA("SurfaceGui") then
				if not originalData.surfaceGuis then originalData.surfaceGuis = {} end
				table.insert(originalData.surfaceGuis, {
					gui = part,
					enabled = part.Enabled,
				})
				part.Enabled = false
			end
		end
	end

	hiddenBlocks[block] = {
		timestamp = os.clock(),
		original = originalData,
	}

	if DEBUG then
		print(string.format("[ClientPrediction] Hidden block: %s", block.Name))
	end
end

-- ============================================
-- TERRAIN PREDICTION
-- When digging underground, instantly spawn predicted dirt/stone blocks
-- so the player doesn't see sky flash through gaps
-- ============================================

-- Track known real block positions for O(1) lookups (no physics queries needed)
local realBlockPositions = {} -- Key: posKey string, Value: count of blocks at that position

local function trackRealBlock(block)
	if block:GetAttribute("IsPrediction") then return end
	local pos = getBlockPosition(block)
	if not pos then return end
	local key = posKey(pos)
	realBlockPositions[key] = (realBlockPositions[key] or 0) + 1
end

local function untrackRealBlock(block)
	if block:GetAttribute("IsPrediction") then return end
	local pos = getBlockPosition(block)
	if not pos then return end
	local key = posKey(pos)
	if realBlockPositions[key] then
		realBlockPositions[key] = realBlockPositions[key] - 1
		if realBlockPositions[key] <= 0 then
			realBlockPositions[key] = nil
		end
	end
end

local function blockExistsAt(pos, blocksFolder)
	local key = posKey(pos)
	-- Check if we already have a prediction there
	if terrainPredictions[key] then return true end
	-- Check tracked real block positions (O(1) lookup, no physics queries)
	if realBlockPositions[key] and not dugPositions[key] then return true end
	return false
end

local function spawnTerrainPrediction(pos, blockType, blocksFolder)
	local key = posKey(pos)

	-- Skip if already dug out this session
	if dugPositions[key] then
		if DEBUG then print("[ClientPrediction] Skipping dug position: " .. key) end
		return
	end

	-- Skip if already predicted or a visible real block already exists
	if terrainPredictions[key] then return end
	if realBlockPositions[key] then return end

	-- Create a simple temporary block
	local folder = getPredictionsFolder()
	local template = ReplicatedStorage:FindFirstChild("Blocks") and ReplicatedStorage.Blocks:FindFirstChild(blockType)
	local tempBlock

	if template then
		tempBlock = template:Clone()
	else
		-- Fallback: create a simple Part
		tempBlock = Instance.new("Part")
		tempBlock.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
		tempBlock.Anchored = true
		tempBlock.CanCollide = false
		tempBlock.Material = Enum.Material.Slate
		tempBlock.Color = if blockType == "Stone" then Color3.fromRGB(128, 128, 128) else Color3.fromRGB(139, 90, 43)
	end

	if tempBlock:IsA("BasePart") then
		tempBlock.CFrame = CFrame.new(pos)
		tempBlock.Anchored = true
		tempBlock.CanCollide = true -- Allow player to stand on predicted terrain
		tempBlock.CanQuery = true -- CRITICAL: Allow raycasts to hit for continuous digging
		-- Fully opaque so predictions look identical to real blocks
	elseif tempBlock:IsA("Model") then
		tempBlock:PivotTo(CFrame.new(pos - Vector3.new(0, BLOCK_SIZE / 2, 0)))
		for _, part in ipairs(tempBlock:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = true -- Allow player to stand on predicted terrain
				part.CanQuery = true -- CRITICAL: Allow raycasts to hit for continuous digging
			end
		end
	end

	tempBlock.Name = "TerrainPrediction_" .. blockType
	tempBlock:SetAttribute("IsPrediction", true)
	tempBlock:SetAttribute("BlockType", blockType) -- So getBlockTarget() recognizes it
	tempBlock:SetAttribute("IsTerrainBlock", true)
	-- Store the actual grid position (already aligned by the server's terrain grid).
	-- Do NOT re-snap via round(Y/BLOCK_SIZE)*BLOCK_SIZE — the terrain grid origin
	-- may not be at a multiple of BLOCK_SIZE.
	tempBlock:SetAttribute("BlockPosX", pos.X)
	tempBlock:SetAttribute("BlockPosY", pos.Y)
	tempBlock:SetAttribute("BlockPosZ", pos.Z)
	tempBlock.Parent = folder

	terrainPredictions[key] = {
		block = tempBlock,
		timestamp = os.clock(),
	}

	if DEBUG then
		print(string.format("[ClientPrediction] Spawned terrain prediction: %s at %s", blockType, key))
	end
end

-- ============================================
-- SHARED PREDICTION SPAWNING
-- Spawns predictions 2 blocks deep in ALL 6 directions.
-- This ensures that when the player breaks the next block, there's always
-- another prediction behind it — no see-through-the-world flash.
-- ============================================

local PREDICTION_DEPTH = 2 -- How many blocks out to predict in each direction

-- Try to spawn a single prediction at pos if terrain should exist there
local function trySpawnPrediction(pos, buildArea, blocksFolder)
	local key = posKey(pos)
	if dugPositions[key] then return end
	local shouldHave, blockType = TerrainLogic.ShouldHaveTerrainAt(pos, buildArea)
	if shouldHave and blockType then
		-- spawnTerrainPrediction will skip if a real block already exists
		-- (prevents visual doubling) or if this spot was already dug out
		spawnTerrainPrediction(pos, blockType, blocksFolder)
	end
end

local function spawnAdjacentPredictions(snapped, buildArea, blocksFolder)
	if not buildArea or not blocksFolder then return end

	-- Predict 2 deep in all 6 cardinal directions
	-- Depth 1: the 6 immediate neighbors (what you see when this block is removed)
	-- Depth 2: the next layer behind those (so when you break depth-1, depth-2 is already there)
	for _, offset in ipairs(TerrainLogic.ADJACENT_OFFSETS) do
		for depth = 1, PREDICTION_DEPTH do
			local pos = snapped + offset * depth
			trySpawnPrediction(pos, buildArea, blocksFolder)
		end
	end

	-- Wall fill: when adjacent horizontal terrain is higher, fill the column
	-- so there's no vertical gap visible when digging into a hillside
	local snappedY = snapped.Y
	for _, hOffset in ipairs(TerrainLogic.HORIZONTAL_OFFSETS) do
		local adjPos = snapped + hOffset
		local adjSurfaceY = TerrainLogic.GetSurfaceYAtPosition(adjPos, buildArea)
		if adjSurfaceY and adjSurfaceY > snappedY then
			local fillY = snappedY
			while fillY < adjSurfaceY do
				local fillPos = Vector3.new(adjPos.X, fillY, adjPos.Z)
				trySpawnPrediction(fillPos, buildArea, blocksFolder)
				fillY = fillY + BLOCK_SIZE
			end
		end
	end
end

-- ============================================
-- PUBLIC API
-- ============================================

function ClientPrediction.OnBlockBreak(block, blocksFolder, buildArea)
	if not block then return end

	-- Get position before hiding
	local blockPos = getBlockPosition(block)

	-- INSTANTLY make block fully invisible (no transparency, no ghost appearance)
	hideBlockCompletely(block)

	-- Track this position as dug
	if blockPos then
		local key = posKey(blockPos)
		dugPositions[key] = true
	end

	-- If this is a terrain block, predict adjacent terrain
	local isTerrainBlock = block:GetAttribute("IsTerrainBlock")
	if isTerrainBlock and blockPos and buildArea and blocksFolder then
		-- Use blockPos directly — it's already grid-aligned from server attributes.
		-- Do NOT re-snap via round(Y/BLOCK_SIZE)*BLOCK_SIZE, as the terrain grid
		-- origin may not be at a multiple of BLOCK_SIZE (e.g., surfaceY=10.5).
		spawnAdjacentPredictions(blockPos, buildArea, blocksFolder)
	end
end

function ClientPrediction.OnBlockPlace(blockId, gridPos, placementData, blocksFolder)
	-- Placement prediction: create a ghost block for instant feedback
	-- The server will create the real block which replaces this
	-- For now, we skip complex placement prediction (logs, doors, etc.)
	-- since those have special positioning logic
	if not gridPos or not blocksFolder then return end

	-- Leaf blocks receive a randomized biome/season tint server-side. A ghost would
	-- render the untinted template colour first and visibly flash to the real tint
	-- once the server block replicates. Skip prediction for leaves so the only colour
	-- the client ever sees is the final, server-tinted block. [BB-LEAF-TINT]
	if string.find(blockId, "Leaves") then return end

	local key = posKey(gridPos)
	if placementPredictions[key] then return end -- Already predicted

	-- Only predict simple blocks (not logs, doors, fences, etc.)
	local template = ReplicatedStorage:FindFirstChild("Blocks") and ReplicatedStorage.Blocks:FindFirstChild(blockId)
	if not template then return end

	-- Skip complex block types that need special server handling
	if placementData and (placementData.LogData or placementData.DoorData or placementData.FenceData or placementData.StairData) then
		return
	end

	local ghost = template:Clone()
	local folder = getPredictionsFolder()

	if ghost:IsA("BasePart") then
		ghost.CFrame = CFrame.new(gridPos)
		ghost.Anchored = true
		ghost.CanCollide = false
		ghost.CanQuery = false -- Placement ghosts should NOT be targetable by raycasts
		ghost.Transparency = GHOST_TRANSPARENCY
	elseif ghost:IsA("Model") then
		-- Simple full-block Models - check if pivot is at center or bottom
		-- Only offset if pivot is at the bottom (like GrassBlock), not center (like GlassBlock)
		local bbCFrame = ghost:GetBoundingBox()
		local pivotOffsetY = ghost.WorldPivot.Position.Y - bbCFrame.Position.Y
		local pivotIsCenter = math.abs(pivotOffsetY) < 0.1
		if pivotIsCenter then
			ghost:PivotTo(CFrame.new(gridPos))
		else
			ghost:PivotTo(CFrame.new(gridPos) * CFrame.new(0, -BLOCK_SIZE / 2, 0))
		end
		for _, part in ipairs(ghost:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false -- Placement ghosts should NOT be targetable by raycasts
				part.Transparency = math.max(part.Transparency, GHOST_TRANSPARENCY)
			end
		end
	end

	ghost.Name = "PlacePrediction_" .. blockId
	ghost:SetAttribute("IsPrediction", true)
	ghost.Parent = folder

	placementPredictions[key] = {
		block = ghost,
		timestamp = os.clock(),
	}
end

function ClientPrediction.OnPredictionBreak(predictionBlock, buildArea)
	-- Called when the player breaks a client-side prediction block
	-- Returns the grid position so BuildingController can tell the server
	if not predictionBlock then return nil end

	local blockPos = getBlockPosition(predictionBlock)
	if not blockPos then return nil end

	local key = posKey(blockPos)

	-- Mark as dug FIRST (before spawning new predictions, so we don't re-predict this pos)
	dugPositions[key] = true

	-- Remove from prediction tracking
	if terrainPredictions[key] then
		terrainPredictions[key] = nil
	end

	-- CRITICAL: Spawn new predictions BEFORE destroying the old block.
	-- This ensures there's never a frame with no collision below the player.
	if buildArea then
		-- Use blockPos directly — already grid-aligned from BlockPosX/Y/Z attributes.
		-- Do NOT re-snap, as terrain grid origin may not be at multiples of BLOCK_SIZE.

		-- Find the blocks folder for existence checks
		-- For individual plots: BuildAreaN.Blocks
		-- For MegaPlot: MegaPlotBuildArea.Blocks (GetBuildAreaAtPosition returns MegaPlotBuildArea)
		local blocksFolder = buildArea:FindFirstChild("Blocks")

		if blocksFolder then
			spawnAdjacentPredictions(blockPos, buildArea, blocksFolder)
		end
	end

	-- NOW destroy the old prediction block (after new predictions are in place)
	predictionBlock:Destroy()

	if DEBUG then
		print(string.format("[ClientPrediction] Broke prediction block at %s", key))
	end

	return blockPos
end

-- ============================================
-- UNDO / RESTORE (for server-rejected actions)
-- ============================================

-- Restore a hidden block back to its original visual state
function ClientPrediction.RestoreHiddenBlock(block)
	local data = hiddenBlocks[block]
	if not data then return false end

	local original = data.original
	if not original then
		hiddenBlocks[block] = nil
		return false
	end

	if block:IsA("BasePart") then
		if block.Parent then
			block.Transparency = original.transparency or 0
			block.CanCollide = original.canCollide ~= nil and original.canCollide or true
			block.CanQuery = original.canQuery ~= nil and original.canQuery or true
		end
	elseif block:IsA("Model") then
		if original.parts then
			for _, partData in ipairs(original.parts) do
				if partData.part and partData.part.Parent then
					partData.part.Transparency = partData.transparency or 0
					partData.part.CanCollide = partData.canCollide ~= nil and partData.canCollide or true
					partData.part.CanQuery = partData.canQuery ~= nil and partData.canQuery or true
				end
			end
		end
	end

	-- Restore any hidden Texture/Decal/SurfaceGui. Applies to both single-part blocks
	-- (e.g. leaves, whose textures are hidden in the BasePart branch above) and models.
	if original.decals then
		for _, decalData in ipairs(original.decals) do
			if decalData.decal and decalData.decal.Parent then
				decalData.decal.Transparency = decalData.transparency or 0
			end
		end
	end
	if original.surfaceGuis then
		for _, guiData in ipairs(original.surfaceGuis) do
			if guiData.gui and guiData.gui.Parent then
				guiData.gui.Enabled = guiData.enabled ~= nil and guiData.enabled or true
			end
		end
	end

	hiddenBlocks[block] = nil

	if DEBUG then
		print(string.format("[ClientPrediction] Restored hidden block: %s", block.Name))
	end
	return true
end

-- Undo a break prediction at a specific position (restore hidden block)
function ClientPrediction.UndoBreakAtPosition(position)
	if not position then return false end

	for block, data in pairs(hiddenBlocks) do
		if block and block.Parent then
			local blockPos = getBlockPosition(block)
			if blockPos and (blockPos - position).Magnitude < 1.5 then
				ClientPrediction.RestoreHiddenBlock(block)
				-- Also remove from dugPositions so terrain predictions get cleaned
				local key = posKey(blockPos)
				dugPositions[key] = nil
				print(string.format("[ClientPrediction] Undid break prediction at (%.1f, %.1f, %.1f)", position.X, position.Y, position.Z))
				return true
			end
		end
	end
	return false
end

-- Undo a place prediction at a specific position (remove ghost block)
function ClientPrediction.UndoPlaceAtPosition(position)
	if not position then return false end

	local key = posKey(position)
	local data = placementPredictions[key]
	if data and data.block and data.block.Parent then
		data.block:Destroy()
		placementPredictions[key] = nil
		print(string.format("[ClientPrediction] Undid place prediction at (%.1f, %.1f, %.1f)", position.X, position.Y, position.Z))
		return true
	end
	return false
end

function ClientPrediction.IsPredictionBlock(block)
	return block and block:GetAttribute("IsPrediction") == true
end

function ClientPrediction.IsBlockHidden(block)
	return hiddenBlocks[block] ~= nil
end

function ClientPrediction.GetBuildAreaAtPosition(pos)
	-- FREE-BUILD PLACE: continuous world, no per-plot footprint. Resolve ANY
	-- position to the local player's owned center build area (the chunk (0,0)
	-- model that owns the shared grid + terrain attributes prediction reads).
	if BetaConfig.IsFreeBuildPlace() then
		local lp = Players.LocalPlayer
		for i = 1, 20 do
			local area = workspace:FindFirstChild("BuildArea" .. i)
			if area and lp and area:GetAttribute("OwnerUserId") == lp.UserId then
				return area
			end
		end
		return nil -- not assigned yet
	end

	-- Search build areas in workspace to find which one contains this position
	for i = 1, 20 do -- Check up to 20 build areas
		local area = workspace:FindFirstChild("BuildArea" .. i)
		if area then
			local areaPos = area:GetAttribute("BasePlatePositionX")
			local areaZ = area:GetAttribute("BasePlatePositionZ")
			local sizeX = area:GetAttribute("BasePlateSizeX")
			local sizeZ = area:GetAttribute("BasePlateSizeZ")

			if areaPos and areaZ and sizeX and sizeZ then
				local halfX = sizeX / 2 + BLOCK_SIZE
				local halfZ = sizeZ / 2 + BLOCK_SIZE
				if pos.X >= areaPos - halfX and pos.X <= areaPos + halfX
					and pos.Z >= areaZ - halfZ and pos.Z <= areaZ + halfZ then
					return area
				end
			end
		end
	end

	-- Also check MegaPlotRoom — return MegaPlotBuildArea (NOT MegaPlotRoom!)
	-- MegaPlotBuildArea has the terrain attributes (TerrainSurfaceY, BasePlatePositionX, etc.)
	-- that TerrainLogic reads directly from the buildArea parameter.
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			local areaPos = megaBuildArea:GetAttribute("BasePlatePositionX")
			local areaZ = megaBuildArea:GetAttribute("BasePlatePositionZ")
			local sizeX = megaBuildArea:GetAttribute("BasePlateSizeX")
			local sizeZ = megaBuildArea:GetAttribute("BasePlateSizeZ")

			if areaPos and areaZ and sizeX and sizeZ then
				local halfX = sizeX / 2 + BLOCK_SIZE
				local halfZ = sizeZ / 2 + BLOCK_SIZE
				if pos.X >= areaPos - halfX and pos.X <= areaPos + halfX
					and pos.Z >= areaZ - halfZ and pos.Z <= areaZ + halfZ then
					return megaBuildArea
				end
			end
		end
	end

	return nil
end

function ClientPrediction.CleanupTimedOut()
	local now = os.clock()

	-- Clean up hidden blocks that the server should have destroyed by now
	for block, data in pairs(hiddenBlocks) do
		if now - data.timestamp > PREDICTION_TIMEOUT then
			if block and block.Parent then
				-- Server didn't destroy it in time — it was probably rejected.
				-- Restore the block's original visual state so it doesn't stay invisible.
				ClientPrediction.RestoreHiddenBlock(block)
				if DEBUG then
					print("[ClientPrediction] Timed out — restored hidden block: " .. tostring(block))
				end
			else
				-- Block was destroyed by server (normal case) — just clean up tracking
				hiddenBlocks[block] = nil
			end
		end
	end

	-- Clean up terrain predictions that were replaced by real blocks or timed out
	for key, data in pairs(terrainPredictions) do
		local shouldRemove = false

		if not data.block or not data.block.Parent then
			shouldRemove = true
		elseif now - data.timestamp > TERRAIN_PREDICTION_TIMEOUT then
			shouldRemove = true
		end

		if shouldRemove then
			if data.block and data.block.Parent then
				data.block:Destroy()
			end
			terrainPredictions[key] = nil
		end
	end

	-- Clean up placement predictions replaced by real blocks or timed out
	for key, data in pairs(placementPredictions) do
		local shouldRemove = false

		if not data.block or not data.block.Parent then
			shouldRemove = true
		elseif now - data.timestamp > PREDICTION_TIMEOUT then
			shouldRemove = true
		end

		if shouldRemove then
			if data.block and data.block.Parent then
				data.block:Destroy()
			end
			placementPredictions[key] = nil
		end
	end
end

-- ============================================
-- AUTO-CLEANUP: Remove prediction blocks when real blocks appear nearby
-- ============================================

local function onRealBlockAdded(block)
	if block:GetAttribute("IsPrediction") then return end

	-- Track the real block position
	trackRealBlock(block)

	local pos = getBlockPosition(block)
	if not pos then return end

	local key = posKey(pos)

	-- Remove terrain prediction at this position (real block replaces it)
	if terrainPredictions[key] then
		local pred = terrainPredictions[key]
		if pred.block and pred.block.Parent then
			-- Don't destroy immediately — make invisible so break targets aren't yanked mid-break.
			-- The block is now redundant (real block exists), so just hide it and let cleanup handle it.
			if pred.block:IsA("BasePart") then
				pred.block.Transparency = 1
				pred.block.CanCollide = false
				pred.block.CanQuery = false
			elseif pred.block:IsA("Model") then
				for _, p in ipairs(pred.block:GetDescendants()) do
					if p:IsA("BasePart") then
						p.Transparency = 1
						p.CanCollide = false
						p.CanQuery = false
					end
				end
			end
			-- Mark for deferred cleanup (destroyed on next CleanupTimedOut cycle)
			pred.timestamp = 0
		end
		-- Don't remove from terrainPredictions yet — let CleanupTimedOut handle it
		-- This prevents the break target from becoming nil mid-break
	end

	-- Remove placement prediction at this position
	if placementPredictions[key] then
		local pred = placementPredictions[key]
		if pred.block and pred.block.Parent then
			pred.block:Destroy()
		end
		placementPredictions[key] = nil
	end
end

-- Monitor build areas for real blocks appearing (to remove predictions)
local function monitorBlocksFolder(blocksFolder)
	blocksFolder.ChildAdded:Connect(onRealBlockAdded)

	-- Track existing blocks for position lookups
	for _, block in ipairs(blocksFolder:GetChildren()) do
		trackRealBlock(block)
	end
end

-- Clean up hidden blocks when the server destroys them (ChildRemoved)
local function onBlockRemoved(block)
	if hiddenBlocks[block] then
		hiddenBlocks[block] = nil
	end
	-- Track removed terrain positions as dug so predictions don't respawn there
	if block:GetAttribute("IsTerrainBlock") then
		local pos = getBlockPosition(block)
		if pos then
			local key = posKey(pos)
			dugPositions[key] = true
		end
	end
	-- Untrack the real block position
	untrackRealBlock(block)
end

-- Connect both ChildAdded (monitoring) and ChildRemoved (cleanup) for a blocks folder
local monitoredFolders = {} -- Prevent double-connecting
local function connectBlocksFolder(blocksFolder)
	if monitoredFolders[blocksFolder] then return end
	monitoredFolders[blocksFolder] = true
	monitorBlocksFolder(blocksFolder) -- ChildAdded + track existing
	blocksFolder.ChildRemoved:Connect(onBlockRemoved)
	if DEBUG then
		print("[ClientPrediction] Connected monitoring for: " .. blocksFolder:GetFullName())
	end
end

-- Watch a build area for its Blocks folder (may not exist yet)
local function watchBuildArea(buildArea)
	local blocks = buildArea:FindFirstChild("Blocks")
	if blocks and blocks:IsA("Folder") then
		connectBlocksFolder(blocks)
	end
	-- Also connect for late creation
	buildArea.ChildAdded:Connect(function(child)
		if child.Name == "Blocks" and child:IsA("Folder") then
			connectBlocksFolder(child)
		end
	end)
end

-- Monitor MegaPlotBuildArea (may be created late in private servers)
local function setupMegaPlotMonitoring()
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			watchBuildArea(megaBuildArea)
		else
			-- MegaPlotBuildArea may be added later
			megaPlotRoom.ChildAdded:Connect(function(child)
				if child.Name == "MegaPlotBuildArea" then
					watchBuildArea(child)
				end
			end)
		end
	end
end

-- Set up monitoring for all build areas
task.defer(function()
	for i = 1, 20 do
		local area = workspace:FindFirstChild("BuildArea" .. i)
		if area then
			watchBuildArea(area)
		end
	end

	-- Monitor MegaPlot (handles both existing and late-created)
	setupMegaPlotMonitoring()

	-- If MegaPlotRoom itself is created later (private server spin-up)
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "MegaPlotRoom" then
			task.wait(0.1) -- Let children replicate
			setupMegaPlotMonitoring()
		end
	end)
end)

-- ============================================
-- SERVER DUG POSITIONS: Clean up phantom predictions in saved holes
-- When the server skips spawning terrain (because positions are dug from a
-- previous save), it sends those positions here so we can remove any
-- client predictions that were optimistically spawned into those holes.
-- ============================================

if TerrainDugPositions then
	TerrainDugPositions.OnClientEvent:Connect(function(positions)
		if not positions or type(positions) ~= "table" then return end
		
		for _, pos in ipairs(positions) do
			if typeof(pos) == "Vector3" then
				local key = posKey(pos)
				-- Mark as dug so future predictions won't spawn here
				dugPositions[key] = true
				
				-- Destroy any existing prediction at this position
				if terrainPredictions[key] then
					local pred = terrainPredictions[key]
					if pred.block and pred.block.Parent then
						pred.block:Destroy()
					end
					terrainPredictions[key] = nil
				end
				
				if DEBUG then
					print(string.format("[ClientPrediction] Server dug position: %s", key))
				end
			end
		end
	end)
end

return ClientPrediction
