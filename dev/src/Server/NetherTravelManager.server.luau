--[[
	NetherTravelManager.server
	Phase 1: portal-to-portal travel plumbing.

	When a player dwells in a lit portal on their overworld plot (BuildArea{N}),
	the client fires RequestNetherTravel. This script:
	  1. Resolves the player's plot number N and its origin.
	  2. Finds the lit portal the player is standing in, and computes that
	     portal's offset RELATIVE to the plot origin.
	  3. Finds NetherPlot{N}, resolves its origin, and builds a return portal at
	     the SAME relative offset (frame + lit blocks) via PortalHandler.
	  4. Teleports the player to that portal using the protected-teleport pattern
	     (anchor + ForceField + PivotTo + release).
	The reverse trip (NetherPlot{N} portal -> BuildArea{N}) maps back the same way.

	No cave generation here — the bare NetherPlot baseplate is the floor for now.

	Conventions matched from the codebase:
	  - Plot lookup by OwnerUserId across BuildArea1..9 (like ToolHandler).
	  - Origin/extent from BasePlatePositionX/Y/Z attributes, with a fallback
	    that derives them from a baseplate part (like GenerateDefaultTerrain).
	  - Portal building delegated to PortalHandler.BuildPortalBlock.
	  - Protected teleport mirrors MegaPlotVisibility (anchor, hidden ForceField,
	    PivotTo, release after a short delay).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local NetherConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("NetherConfig"))

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local LOG = NetherConfig.LOG_PREFIX

-- PortalHandler (loaded defensively, same as ToolHandler does).
local PortalHandler = nil
pcall(function()
	PortalHandler = require(ServerScriptService:WaitForChild("Modules", 10):WaitForChild("PortalHandler", 10))
end)

-- TerrainGenerator (loaded defensively). Used to carve an air pocket around a
-- freshly-built return portal so the player doesn't spawn embedded in the cave.
local TerrainGenerator = nil
pcall(function()
	TerrainGenerator = require(ServerScriptService:WaitForChild("Modules", 10):WaitForChild("TerrainGenerator", 10))
end)

-- Map a NetherPlot{N} name to the nether terrain key (100+N) used by
-- TerrainGenerator's nether functions (matches generation + dig-reveal).
local function netherTerrainKey(destArea)
	local n = destArea.Name:match("%d+")
	return n and (tonumber(n) + 100) or nil
end

-- ============================================
-- REMOTES
-- ============================================

local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end

local RequestTravel = Remotes:FindFirstChild(NetherConfig.REMOTE_REQUEST_TRAVEL)
if not RequestTravel then
	RequestTravel = Instance.new("RemoteEvent")
	RequestTravel.Name = NetherConfig.REMOTE_REQUEST_TRAVEL
	RequestTravel.Parent = Remotes
end

local TravelResult = Remotes:FindFirstChild(NetherConfig.REMOTE_TRAVEL_RESULT)
if not TravelResult then
	TravelResult = Instance.new("RemoteEvent")
	TravelResult.Name = NetherConfig.REMOTE_TRAVEL_RESULT
	TravelResult.Parent = Remotes
end

-- ============================================
-- ORIGIN / EXTENT RESOLUTION
-- ============================================

-- Resolve a build area's grid origin + extents from attributes, falling back to
-- a baseplate part's Position/Size (and caching the attributes) the same way
-- GenerateDefaultTerrain does. Returns {posX,posY,posZ,sizeX,sizeY,sizeZ} or nil.
local function resolveExtents(area, baseplatePartName)
	local posX = area:GetAttribute("BasePlatePositionX")
	local posY = area:GetAttribute("BasePlatePositionY")
	local posZ = area:GetAttribute("BasePlatePositionZ")
	local sizeX = area:GetAttribute("BasePlateSizeX")
	local sizeY = area:GetAttribute("BasePlateSizeY")
	local sizeZ = area:GetAttribute("BasePlateSizeZ")

	if not (posX and posY and posZ and sizeX and sizeZ) then
		-- Find a baseplate part to derive from. Prefer a child named like the
		-- area itself or a known baseplate name; else first BasePart child.
		local plate = (baseplatePartName and area:FindFirstChild(baseplatePartName))
			or area:FindFirstChild("BasePlate")
		if not plate then
			if area:IsA("BasePart") then
				plate = area
			else
				for _, c in ipairs(area:GetChildren()) do
					if c:IsA("BasePart") then plate = c break end
				end
			end
		end
		if not plate or not plate:IsA("BasePart") then
			return nil
		end
		posX, posY, posZ = plate.Position.X, plate.Position.Y, plate.Position.Z
		sizeX, sizeY, sizeZ = plate.Size.X, plate.Size.Y, plate.Size.Z
		area:SetAttribute("BasePlatePositionX", posX)
		area:SetAttribute("BasePlatePositionY", posY)
		area:SetAttribute("BasePlatePositionZ", posZ)
		area:SetAttribute("BasePlateSizeX", sizeX)
		area:SetAttribute("BasePlateSizeY", sizeY)
		area:SetAttribute("BasePlateSizeZ", sizeZ)
		area:SetAttribute("BasePlateTop", posY + sizeY / 2)
	end

	return {
		posX = posX, posY = posY, posZ = posZ,
		sizeX = sizeX, sizeY = sizeY or 0.4, sizeZ = sizeZ,
	}
end

-- Ensure a build area has a Blocks folder (NetherPlots may be bare baseplates).
local function ensureBlocksFolder(area)
	local f = area:FindFirstChild("Blocks")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Blocks"
		f.Parent = area
	end
	return f
end

-- ============================================
-- PLOT PAIRING
-- ============================================

-- Returns plotNumber, overworldBuildArea for the player (nil if unassigned).
local function getPlayerPlot(player)
	for i = 1, GridConfig.TOTAL_PLOTS do
		local area = Workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if area and area:GetAttribute("OwnerUserId") == player.UserId then
			return i, area
		end
	end
	return nil, nil
end

local function getNetherPlot(plotNumber)
	return Workspace:FindFirstChild(NetherConfig.NETHER_PLOT_PREFIX .. plotNumber)
end

-- ============================================
-- PORTAL LOCATION
-- ============================================

-- Find the lit portal block the player is standing nearest to within `area`'s
-- Blocks folder. We pick the closest IsPortal part to the player's torso.
-- Returns the portal block, or nil.
local function findPortalPlayerIsIn(player, area)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	local blocksFolder = area:FindFirstChild("Blocks")
	if not blocksFolder then return nil end

	local pos = root.Position
	local best, bestDist = nil, math.huge
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if child:GetAttribute("IsPortal") then
			local cx = child:GetAttribute("BlockPosX")
			local cy = child:GetAttribute("BlockPosY")
			local cz = child:GetAttribute("BlockPosZ")
			local cpos = (cx and cy and cz) and Vector3.new(cx, cy, cz)
				or (child:IsA("BasePart") and child.Position)
			if cpos then
				local d = (cpos - pos).Magnitude
				if d < bestDist then
					bestDist = d
					best = child
				end
			end
		end
	end
	-- Only accept if reasonably close (within ~2.5 blocks) so we don't grab a far
	-- portal on the same plot.
	if best and bestDist <= BLOCK_SIZE * 2.5 then
		return best
	end
	return nil
end

-- Find the existing lit portal in `area` nearest to `worldPoint`, within
-- `radiusBlocks` blocks. Returns the bottom-centre interior position to teleport
-- to (so the player lands standing in it), or nil if none is close enough.
-- This is the Minecraft "link to the nearest existing portal" behaviour: on
-- arrival we reuse a portal that's already there instead of building a new one.
local function findNearestExistingPortal(area, worldPoint, radiusBlocks)
	local blocksFolder = area:FindFirstChild("Blocks")
	if not blocksFolder then return nil end
	local maxDist = (radiusBlocks or 16) * BLOCK_SIZE

	-- Find the single closest portal block to the target point.
	local closest, closestDist = nil, math.huge
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if child:GetAttribute("IsPortal") then
			local cx = child:GetAttribute("BlockPosX")
			local cy = child:GetAttribute("BlockPosY")
			local cz = child:GetAttribute("BlockPosZ")
			local cpos = (cx and cy and cz) and Vector3.new(cx, cy, cz)
				or (child:IsA("BasePart") and child.Position)
			if cpos then
				local d = (cpos - worldPoint).Magnitude
				if d < closestDist then
					closestDist = d
					closest = cpos
				end
			end
		end
	end

	if not closest or closestDist > maxDist then
		return nil
	end

	-- Drop the player at the LOWEST portal cell sharing this column (the base of
	-- the portal) so they spawn on the frame floor, not partway up the swirl.
	local lowestY = closest.Y
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if child:GetAttribute("IsPortal") then
			local cx = child:GetAttribute("BlockPosX")
			local cy = child:GetAttribute("BlockPosY")
			local cz = child:GetAttribute("BlockPosZ")
			if cx and cy and cz
				and math.abs(cx - closest.X) < BLOCK_SIZE * 0.5
				and math.abs(cz - closest.Z) < BLOCK_SIZE * 0.5
				and cy < lowestY then
				lowestY = cy
			end
		end
	end

	return Vector3.new(closest.X, lowestY, closest.Z)
end

-- Grid centre of a portal block (BlockPos attrs preferred).
local function portalCentre(block)
	local cx = block:GetAttribute("BlockPosX")
	local cy = block:GetAttribute("BlockPosY")
	local cz = block:GetAttribute("BlockPosZ")
	if cx and cy and cz then return Vector3.new(cx, cy, cz) end
	if block:IsA("BasePart") then return block.Position end
	return block:GetPivot().Position
end

-- Read the portal's orientation (wide axis) from the part's rotation. The
-- NetherPortal template is thin along Z at 0deg; a Z-aligned frame is rotated
-- +90 about Y at build time. We infer the wide axis from the part's RightVector.
local function portalWideAxis(block)
	local part = block
	if block:IsA("Model") then
		part = block:FindFirstChildWhichIsA("BasePart", true)
	end
	if not part then return Vector3.new(BLOCK_SIZE, 0, 0) end
	local right = part.CFrame.RightVector
	if math.abs(right.X) >= math.abs(right.Z) then
		return Vector3.new(BLOCK_SIZE, 0, 0)  -- wide along X
	else
		return Vector3.new(0, 0, BLOCK_SIZE)  -- wide along Z
	end
end

-- ============================================
-- RETURN PORTAL CONSTRUCTION
-- ============================================

-- Build a 2x3 obsidian frame + lit portal at `interiorBottomLeft` (grid centre
-- of the bottom-left interior cell) with the given wide axis, inside
-- destBlocksFolder. Mirrors the vanilla frame the portal handler validates so
-- the player can walk back through. Returns the bottom-centre interior position
-- (good teleport target) or nil.
local function buildReturnPortal(destArea, interiorBottomLeft, wideAxis)
	if not PortalHandler then
		warn(LOG .. " PortalHandler not loaded; cannot build return portal")
		return nil
	end
	local destBlocksFolder = ensureBlocksFolder(destArea)
	local UP = Vector3.new(0, BLOCK_SIZE, 0)

	-- Don't duplicate if a portal already exists at this interior cell.
	local existing = false
	for _, c in ipairs(destBlocksFolder:GetChildren()) do
		if c:GetAttribute("IsPortal") then
			local cc = portalCentre(c)
			if (cc - interiorBottomLeft).Magnitude < BLOCK_SIZE * 0.5 then
				existing = true
				break
			end
		end
	end

	if not existing then
		-- If we're building into the NETHER, the target cells are very likely buried
		-- in solid cave rock (the noise filled them). Carve an air pocket FIRST so
		-- the frame + portal sit in open space and the player doesn't spawn embedded.
		-- Skip in the overworld (no cave there). Centre the pocket on the middle of
		-- the 2-wide x 3-tall interior; half-extents clear the obsidian ring + a
		-- little standing room.
		if TerrainGenerator and TerrainGenerator.CarveNetherPocket
			and destArea.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX) then
			local key = netherTerrainKey(destArea)
			if key then
				local pocketCentre = interiorBottomLeft + wideAxis * 0.5 + UP * 1
				pcall(function()
					TerrainGenerator.CarveNetherPocket(destArea, key, pocketCentre, 2, 3, 2)
				end)
			end
		end

		-- Obsidian frame: ring around a 2-wide x 3-tall interior.
		local INTERIOR_W, INTERIOR_H = 2, 3
		local function obsidianAt(p)
			local templates = ReplicatedStorage:FindFirstChild("Blocks")
			local tmpl = templates and templates:FindFirstChild("Obsidian")
			if not tmpl then return end
			local b = tmpl:Clone()
			b.Name = "Obsidian"
			if b:IsA("BasePart") then
				b.CFrame = CFrame.new(p)
				b.Anchored = true
				b.CanCollide = true
			elseif b:IsA("Model") then
				b:PivotTo(CFrame.new(p - Vector3.new(0, BLOCK_SIZE / 2, 0)))
				for _, d in ipairs(b:GetDescendants()) do
					if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = true end
				end
			end
			b:SetAttribute("BlockType", "Obsidian")
			b:SetAttribute("BlockPosX", p.X)
			b:SetAttribute("BlockPosY", p.Y)
			b:SetAttribute("BlockPosZ", p.Z)
			b.Parent = destBlocksFolder
		end

		-- Left/right columns (one per interior row).
		for h = 0, INTERIOR_H - 1 do
			obsidianAt(interiorBottomLeft - wideAxis + UP * h)
			obsidianAt(interiorBottomLeft + wideAxis * INTERIOR_W + UP * h)
		end
		-- Bottom/top rows (one per interior column).
		for w = 0, INTERIOR_W - 1 do
			obsidianAt(interiorBottomLeft + wideAxis * w - UP)
			obsidianAt(interiorBottomLeft + wideAxis * w + UP * INTERIOR_H)
		end

		-- Four corners (cosmetic — vanilla leaves these optional, but we fill them
		-- so the return portal reads as a complete rectangle).
		obsidianAt(interiorBottomLeft - wideAxis - UP)                              -- bottom-left
		obsidianAt(interiorBottomLeft + wideAxis * INTERIOR_W - UP)                 -- bottom-right
		obsidianAt(interiorBottomLeft - wideAxis + UP * INTERIOR_H)                 -- top-left
		obsidianAt(interiorBottomLeft + wideAxis * INTERIOR_W + UP * INTERIOR_H)    -- top-right

		-- Light it: place portal blocks across the interior.
		for w = 0, INTERIOR_W - 1 do
			for h = 0, INTERIOR_H - 1 do
				local cell = interiorBottomLeft + wideAxis * w + UP * h
				PortalHandler.BuildPortalBlock(destBlocksFolder, cell, wideAxis, "Nether")
			end
		end

		-- Whole-portal glow panel (one invisible SurfaceLight pane per face, sized to
		-- the frame) so the swirl lights both sides without per-cell "balls of light".
		-- This portal is built directly here (not via LightFrame), so we call it
		-- ourselves. gridOffset is zero -- cells are placed at absolute grid centres.
		if PortalHandler.BuildPortalGlow then
			local tint = PortalHandler.GetTintForType("Nether")
			PortalHandler.BuildPortalGlow(destBlocksFolder, interiorBottomLeft, wideAxis, INTERIOR_W, INTERIOR_H, Vector3.new(0, 0, 0), tint)
		end

		-- Ground the portal: the carve above dug out the cells under the frame, so
		-- the bottom obsidian would float over air. Re-add a netherrack floor directly
		-- beneath the bottom interior cells so the portal base rests on solid ground.
		-- Only in the nether (the overworld portal sits on real terrain already).
		if TerrainGenerator and TerrainGenerator.GroundNetherPortalFloor
			and destArea.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX) then
			local key = netherTerrainKey(destArea)
			if key then
				pcall(function()
					TerrainGenerator.GroundNetherPortalFloor(destArea, key, interiorBottomLeft, wideAxis, INTERIOR_W)
				end)
			end
		end

		-- Seed the visible cave AROUND the portal. We no longer build the whole bubble
		-- up-front (that spawned the entire 128-tall shell -- the "walls"). Instead we
		-- build only a bounded pocket of exposed cave centred on the arrival point, so
		-- the player lands somewhere that looks like a cave; digging outward streams
		-- the rest via OnNetherBlockBroken. Half-extents are in BLOCKS (a 12-radius box
		-- = ~25 cells per side). Only in the nether; runs once per portal build.
		--
		-- NOTE: This call is ALSO made unconditionally from handleTravel below (every
		-- arrival, not just new portal builds) so a visitor arriving through someone
		-- else's portal still gets a bubble around them. GenerateNetherBubble is
		-- idempotent (skips existing blocks), so calling it twice on a fresh portal is
		-- harmless — the second call sees the blocks from the first and does nothing.
		-- The reason it's STILL here is so a freshly-built portal lands with terrain
		-- in the same code path, even if the handleTravel post-call ever changes.
		if TerrainGenerator and TerrainGenerator.GenerateNetherBubble
			and destArea.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX) then
			local key = netherTerrainKey(destArea)
			if key then
				local seed = destArea:GetAttribute("NetherSeed")
				local regionCentre = interiorBottomLeft + wideAxis * 0.5 + UP * 1
				pcall(function()
					TerrainGenerator.GenerateNetherBubble(destArea, key, seed, {
						centre = regionCentre, hx = 12, hy = 12, hz = 12,
					})
				end)
			end
		end

		print(string.format("%s Built return portal at (%.1f,%.1f,%.1f) on %s",
			LOG, interiorBottomLeft.X, interiorBottomLeft.Y, interiorBottomLeft.Z, destArea.Name))
	end

	-- Teleport target: bottom-centre of the interior, standing on the frame base.
	local centreBottom = interiorBottomLeft + wideAxis * 0.5
	return centreBottom
end

-- ============================================
-- PROTECTED TELEPORT (mirrors MegaPlotVisibility)
-- ============================================

local function protectedTeleport(player, targetPos)
	local character = player.Character
	if not character then return false end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	local humanoid = character:FindFirstChild("Humanoid")
	if humanoid and humanoid.Sit then
		humanoid.Sit = false
		task.wait(0.1)
	end

	hrp.Anchored = true
	local ff = character:FindFirstChild("NetherTeleportProtection")
	if not ff then
		ff = Instance.new("ForceField")
		ff.Name = "NetherTeleportProtection"
		ff.Visible = false
		ff.Parent = character
	end

	character:PivotTo(CFrame.new(targetPos + Vector3.new(0, NetherConfig.SPAWN_Y_OFFSET, 0)))

	task.delay(0.3, function()
		if hrp and hrp.Parent then hrp.Anchored = false end
		task.delay(0.5, function()
			if ff and ff.Parent then ff:Destroy() end
		end)
	end)
	return true
end

-- ============================================
-- TRAVEL DIRECTION RESOLUTION
-- ============================================

-- Given the area the player is currently in, figure out the destination area
-- and the relative offset of the source portal. Works both directions:
--   overworld BuildArea{N}  -> NetherPlot{N}
--   NetherPlot{N}           -> overworld BuildArea{N}
-- Returns srcArea, destArea, srcPortalBlock, or nil + reason.
local function resolveTravel(player)
	-- Are they currently in a nether plot? Check all NetherPlots for one whose
	-- Blocks folder contains a portal near the player.
	for i = 1, GridConfig.TOTAL_PLOTS do
		local nether = getNetherPlot(i)
		if nether then
			local portal = findPortalPlayerIsIn(player, nether)
			if portal then
				local overworld = Workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
				if not overworld then return nil, nil, nil, "No overworld plot " .. i end
				return nether, overworld, portal, nil
			end
		end
	end

	-- Otherwise they should be in SOME overworld plot — their own or someone
	-- else's. Public-portal behaviour: any player can use any lit portal regardless
	-- of who owns the plot it sits in. Iterate every BuildArea (same way the nether
	-- branch above iterates every NetherPlot) and find the one whose Blocks folder
	-- has a portal the player is currently standing in. The destination is the
	-- NETHER plot matching whichever overworld plot they entered from — going
	-- through plot 3's portal takes you to plot 3's nether, regardless of owner.
	-- The return trip naturally lands them back in that same overworld plot.
	for i = 1, GridConfig.TOTAL_PLOTS do
		local overworld = Workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if overworld then
			local portal = findPortalPlayerIsIn(player, overworld)
			if portal then
				local nether = getNetherPlot(i)
				if not nether then return nil, nil, nil, "NetherPlot" .. i .. " missing" end
				return overworld, nether, portal, nil
			end
		end
	end
	return nil, nil, nil, "Not standing in a lit portal"
end

-- ============================================
-- MAIN HANDLER
-- ============================================

local function handleTravel(player)
	local srcArea, destArea, srcPortal, reason = resolveTravel(player)
	if not srcArea then
		print(LOG .. " Travel denied for " .. player.Name .. ": " .. tostring(reason))
		return
	end

	local srcExt = resolveExtents(srcArea)
	local destExt = resolveExtents(destArea, destArea.Name) -- NetherPlot may itself be the baseplate
	if not srcExt or not destExt then
		warn(LOG .. " Could not resolve extents for travel")
		return
	end

	-- Source portal centre, as an offset from the source plot origin (X/Z), and
	-- relative to the source baseplate TOP for Y (so the portal sits the same
	-- height above the floor on both sides).
	local pc = portalCentre(srcPortal)
	local wideAxis = portalWideAxis(srcPortal)

	local srcTopY = srcExt.posY + srcExt.sizeY / 2
	local relX = pc.X - srcExt.posX
	local relZ = pc.Z - srcExt.posZ
	local relY = pc.Y - srcTopY  -- height above the source floor

	-- Apply the same relative offset to the destination origin.
	local destTopY = destExt.posY + destExt.sizeY / 2
	local destInteriorBottomLeft = Vector3.new(
		destExt.posX + relX,
		destTopY + relY,
		destExt.posZ + relZ
	)

	-- Minecraft behaviour: prefer linking to an EXISTING portal near the
	-- destination point rather than building a fresh one. The round-trip
	-- relative-offset math can drift by a cell or two, so we search a radius
	-- around the computed point; if a portal is already there (e.g. the one the
	-- player originally came through), reuse it. Only build if none is found.
	local targetPos = findNearestExistingPortal(destArea, destInteriorBottomLeft, 16)
	if targetPos then
		print(string.format("%s Linking to existing portal on %s", LOG, destArea.Name))
	else
		targetPos = buildReturnPortal(destArea, destInteriorBottomLeft, wideAxis)
	end
	if not targetPos then
		warn(LOG .. " Failed to find or build return portal")
		return
	end
	
	-- Ensure terrain exists AROUND the arrival point, regardless of whether the
	-- portal was newly built or reused. Without this, a visitor walking through
	-- someone else's portal can arrive in a sparse area: the owner's first trip
	-- generated a 12-block bubble around their portal, but the visitor's arrival
	-- doesn't trigger any new generation, so they only see what the owner had
	-- already revealed (which might be only the small initial pocket). With this
	-- call, every arrival grows/refreshes the bubble around the player. The
	-- function is idempotent (skips cells that already have a block), so this is
	-- cheap when terrain is already there. Only runs for nether destinations.
	if destArea.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX)
		and TerrainGenerator and TerrainGenerator.GenerateNetherBubble then
		local key = netherTerrainKey(destArea)
		if key then
			local seed = destArea:GetAttribute("NetherSeed")
			pcall(function()
				TerrainGenerator.GenerateNetherBubble(destArea, key, seed, {
					centre = targetPos, hx = 12, hy = 12, hz = 12,
				})
			end)
		end
	end

	-- Tag the dest area as nether (for later systems) and pair it.
	if destArea.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX) then
		destArea:SetAttribute(NetherConfig.ATTR_IS_NETHER, true)
	end

	local ok = protectedTeleport(player, targetPos)
	if ok then
		print(string.format("%s Teleported %s : %s -> %s", LOG, player.Name, srcArea.Name, destArea.Name))
		-- Tell the client to start its arrival grace so it doesn't instantly
		-- re-trigger on the portal it lands in. Also tell it which dimension it
		-- landed in so per-client lighting (e.g. GlobalShadows) can switch:
		-- nether wants shadows ON (kills the specular hotspot on reflective
		-- netherrack), overworld wants them back OFF.
		local destIsNether = destArea.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX) ~= nil
		TravelResult:FireClient(player, {
			grace = NetherConfig.ARRIVAL_GRACE_SECONDS,
			dimension = destIsNether and "nether" or "overworld",
		})
	end
end

-- Debounce per player so a held dwell doesn't fire repeatedly.
local lastTravel = {}
RequestTravel.OnServerEvent:Connect(function(player)
	local now = os.clock()
	if lastTravel[player] and now - lastTravel[player] < NetherConfig.ARRIVAL_GRACE_SECONDS then
		return
	end
	lastTravel[player] = now
	handleTravel(player)
end)

Players.PlayerRemoving:Connect(function(player)
	lastTravel[player] = nil
end)

print(LOG .. " NetherTravelManager initialized")
