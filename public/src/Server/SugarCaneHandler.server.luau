--[[
	SugarCaneHandler
	Server-side natural growth for sugar cane (Minecraft-style).

	Rules:
	- Sugar cane grows UPWARD one block at a time on a tick interval with randomness.
	- A column grows until it reaches MAX_HEIGHT total blocks (placed + grown).
	- Growth only happens from the TOP cane of a column, into an empty cell above.
	- Grown segments are normal SugarCane decorations: they carry IsDecoration +
	  ParentBlock + PlacedBy attributes, so the existing decoration save/load path
	  persists them automatically (no special save handling needed).

	Manual stacking (placing cane on cane) is handled in BlockHandler's decoration
	placement path; this handler only adds the time-based growth.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local BulkOperationFlags = nil
pcall(function()
	BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 5))
end)

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- ============================================
-- CONFIGURATION
-- ============================================

local CONFIG = {
	-- How often a growth tick runs (seconds).
	TICK_INTERVAL = 20.0,

	-- Chance per top-cane per tick to grow one block (0-1). With TICK_INTERVAL=20
	-- and chance 0.12 a cane grows roughly every ~2.8 minutes on average. Tune freely.
	GROWTH_CHANCE = 0.12,

	-- Max blocks grown per plot per tick (performance limit).
	MAX_GROWS_PER_TICK = 5,

	-- Max total column height (placed + grown).
	-- KEEP IN SYNC with STACKABLE_DECORATIONS["SugarCane"] in BlockHandler.server.luau.
	MAX_HEIGHT = 9,
}

-- ============================================
-- STATE
-- ============================================

local ActivePlots = {}
local IsRunning = false
local LastTickTime = 0

-- ============================================
-- HELPERS
-- ============================================

local function getSugarCaneTemplate()
	local decorations = ReplicatedStorage:FindFirstChild("Decorations")
	if decorations then
		return decorations:FindFirstChild("SugarCane")
	end
	return nil
end

-- Resolve a cane's parent-block grid position (the cell directly below it).
local function getCaneParent(cane)
	local px = cane:GetAttribute("ParentBlockX")
	local py = cane:GetAttribute("ParentBlockY")
	local pz = cane:GetAttribute("ParentBlockZ")
	if px and py and pz then
		return Vector3.new(px, py, pz)
	end
	-- Fallback: derive from pivot (pivot sits BLOCK_SIZE/2 above the parent cell).
	local pos
	if cane:IsA("Model") then
		pos = cane:GetPivot().Position
	elseif cane:IsA("BasePart") then
		pos = cane.Position
	end
	if pos then
		return pos - Vector3.new(0, BLOCK_SIZE / 2, 0)
	end
	return nil
end

-- The grid cell a cane occupies in the spatial index. A bottom-pivot decoration
-- with parent P is keyed one block above P.
local function caneCell(parent)
	return parent + Vector3.new(0, BLOCK_SIZE, 0)
end

-- Count contiguous sugar cane blocks in this column, from the given top cell down.
-- Counts BOTH SugarCane and SugarCaneTrimmed so a sheared segment still counts
-- toward the height cap (a trimmed cane in the middle must not reset the column).
local function isSugarCaneType(blockType)
	return blockType == "SugarCane" or blockType == "SugarCaneTrimmed"
end

local function columnHeight(index, topCell)
	local count = 0
	local p = topCell
	while true do
		local d = index:GetDecorationAt(p)
		if d and isSugarCaneType(d:GetAttribute("BlockType")) then
			count = count + 1
			p = p - Vector3.new(0, BLOCK_SIZE, 0)
		else
			break
		end
	end
	return count
end

-- Create a grown sugar cane segment on top of `sourceCane`. The new segment's parent
-- cell is `parent` (sourceCane's own cell). We pivot using sourceCane's ACTUAL XZ
-- (not the rounded `parent` attributes) so the grown cane lines up exactly with the
-- visible column below it — hand-placed canes sit at their raw sub-grid click XZ,
-- which can differ from the rounded ParentBlock by the rounding remainder. (On reload
-- the whole column snaps to grid XZ together via the serializer, staying consistent.)
local function createSugarCane(parent, sourceCane, blocksFolder, placedBy)
	local template = getSugarCaneTemplate()
	if not template then
		warn("[SugarCaneHandler] SugarCane template not found in Decorations folder!")
		return nil
	end

	local cane = template:Clone()
	cane.Name = "SugarCane"

	if cane:IsA("BasePart") then
		cane.Anchored = true
		cane.CanCollide = false
	elseif cane:IsA("Model") then
		for _, part in ipairs(cane:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
	end

	-- Seat the grown segment off the source cane's ACTUAL pivot, not the rounded grid.
	-- Sugar cane parts are BLOCK_SIZE tall but stack at BLOCK_SIZE/2 (half-block) steps,
	-- so each segment sits BLOCK_SIZE/2 above the one below. Anchoring to srcPos (instead
	-- of parent.Y) also carries the terrain-origin fractional offset that the rounded
	-- ParentBlock attributes drop — that offset was the old ~0.1-stud drift. XZ likewise
	-- comes from srcPos so the column stays aligned. Fixed 45-degree Y turn matches placement.
	local srcPos
	if sourceCane:IsA("Model") then
		srcPos = sourceCane:GetPivot().Position
	elseif sourceCane:IsA("BasePart") then
		srcPos = sourceCane.Position
	end
	local newPos
	if srcPos then
		newPos = Vector3.new(srcPos.X, srcPos.Y + BLOCK_SIZE / 2, srcPos.Z)
	else
		newPos = Vector3.new(parent.X, parent.Y + BLOCK_SIZE / 2, parent.Z)
	end
	cane:PivotTo(CFrame.new(newPos) * CFrame.Angles(0, math.rad(45), 0))

	cane:SetAttribute("BlockType", "SugarCane")
	cane:SetAttribute("IsDecoration", true)
	cane:SetAttribute("ParentBlockX", parent.X)
	cane:SetAttribute("ParentBlockY", parent.Y)
	cane:SetAttribute("ParentBlockZ", parent.Z)
	cane:SetAttribute("IsNaturalSugarCane", true) -- marks naturally grown (vs placed)
	-- PlacedBy MUST be set or PlotSerializer treats this as a terrain decoration and
	-- skips saving it. Inherit the column's placer; fall back to 0 (shared/unknown).
	cane:SetAttribute("PlacedBy", placedBy or 0)

	cane.Parent = blocksFolder
	return cane
end

-- ============================================
-- GROWTH TICK
-- ============================================

local function processPlot(blocksFolder)
	if not blocksFolder then return end
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return end

	-- Collect all sugar cane decorations.
	local canes = {}
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsDecoration") and block:GetAttribute("BlockType") == "SugarCane" then
			table.insert(canes, block)
		end
	end
	if #canes == 0 then return end

	-- Shuffle for fairness when capped by MAX_GROWS_PER_TICK.
	for i = #canes, 2, -1 do
		local j = math.random(1, i)
		canes[i], canes[j] = canes[j], canes[i]
	end

	local grows = 0
	for _, cane in ipairs(canes) do
		if grows >= CONFIG.MAX_GROWS_PER_TICK then break end

		local parent = getCaneParent(cane)
		if not parent then continue end

		local cell = caneCell(parent)
		local aboveCell = cell + Vector3.new(0, BLOCK_SIZE, 0)

		-- Only grow from the TOP of a column (nothing sugar-cane above this one).
		local above = index:GetDecorationAt(aboveCell)
		if above and above:GetAttribute("BlockType") == "SugarCane" then
			continue
		end

		-- Don't grow into an occupied cell (any block, including non-cane decorations).
		if index:GetAnyBlockAt(aboveCell) ~= nil then
			continue
		end

		-- Height cap: count the existing column from this top cell down.
		if columnHeight(index, cell) >= CONFIG.MAX_HEIGHT then
			continue
		end

		-- Random chance gate.
		if math.random() > CONFIG.GROWTH_CHANCE then
			continue
		end

		-- Grow: new segment sits on top, its parent cell is THIS cane's cell.
		local newCane = createSugarCane(cell, cane, blocksFolder, cane:GetAttribute("PlacedBy"))
		if newCane then
			grows = grows + 1
		end
	end
end

-- ============================================
-- PLOT TRACKING
-- ============================================

local function RegisterPlot(blocksFolder)
	if not blocksFolder then return end
	ActivePlots[blocksFolder] = true
	if not IsRunning then
		IsRunning = true
		LastTickTime = tick()
	end
end

local function UnregisterPlot(blocksFolder)
	ActivePlots[blocksFolder] = nil
	local hasAny = false
	for _ in pairs(ActivePlots) do
		hasAny = true
		break
	end
	if not hasAny then
		IsRunning = false
	end
end

-- ============================================
-- MAIN LOOP
-- ============================================

RunService.Heartbeat:Connect(function()
	if BulkOperationFlags and BulkOperationFlags.IsShuttingDown() then return end
	if not IsRunning then return end

	local now = tick()
	if now - LastTickTime < CONFIG.TICK_INTERVAL then return end
	LastTickTime = now

	-- Per-plot bulk check: skip only the plot that's mid-generation/load so a stuck
	-- flag on one plot can't freeze growth everywhere (mirrors VineHandler).
	for blocksFolder in pairs(ActivePlots) do
		if blocksFolder and blocksFolder.Parent then
			local buildArea = blocksFolder.Parent
			local busy = BulkOperationFlags and BulkOperationFlags.IsBulkOperation(buildArea)
			if not busy then
				processPlot(blocksFolder)
			end
		else
			ActivePlots[blocksFolder] = nil
		end
	end
end)

-- ============================================
-- AUTO-REGISTER EXISTING PLOTS
-- ============================================

task.spawn(function()
	task.wait(5) -- wait for plots to initialize

	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				RegisterPlot(blocksFolder)
			end
		end
	end

	-- Also track the MegaPlot build area (private-server MegaPlot mode).
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			local blocksFolder = megaBuildArea:FindFirstChild("Blocks")
			if blocksFolder then
				RegisterPlot(blocksFolder)
			end
		end
	end
end)

-- Listen for new plots created at runtime.
workspace.ChildAdded:Connect(function(child)
	task.wait(1)
	if child.Name:find(GridConfig.BUILD_AREA_PREFIX) then
		local blocksFolder = child:FindFirstChild("Blocks")
		if blocksFolder then
			RegisterPlot(blocksFolder)
		end
	end
end)

print("[SugarCaneHandler] Sugar cane growth system loaded")
