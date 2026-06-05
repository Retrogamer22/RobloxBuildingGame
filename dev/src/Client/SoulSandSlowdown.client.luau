--[[
	SoulSandSlowdown
	Client-side movement modifier for SoulSand (Minecraft parity).

	When the player is standing on a block whose BlockType attribute is "SoulSand"
	(or the equivalent terrain marker), their WalkSpeed is reduced to make the
	block feel "sticky" underfoot -- just like Minecraft's soul sand slowdown.

	Detection: every Heartbeat, raycast a short distance straight down from the
	HumanoidRootPart's feet. If we hit a SoulSand block AND the humanoid is
	actually touching the ground (FloorMaterial set), drop WalkSpeed. Otherwise
	smoothly restore it. The lerp keeps the transition from feeling jarring.

	Design notes:
	- Pure client-side. WalkSpeed control is a client responsibility (matches
	  WaterPlayerPhysics). No server round-trip needed for a cosmetic feel.
	- We never write WalkSpeed unconditionally on Heartbeat -- we only set it
	  when our target differs, so other systems can still claim WalkSpeed if
	  they want (water/swim, sprint, etc.). When stepping off SoulSand we
	  restore the value we OBSERVED before entering, not a hardcoded 16, so a
	  player whose normal speed has been modified elsewhere keeps that speed.
	- StreamingEnabled-safe: we raycast against the player's plot Blocks folder
	  (the same approach WaterPlayerPhysics uses), so we don't fight terrain.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

local player = Players.LocalPlayer

-- ============================================
-- CONFIG
-- ============================================
local SOUL_SAND_WALK_SPEED = 6      -- Speed while standing on SoulSand
local SPEED_LERP_RATE       = 10    -- Snappier than water: floor-block transitions feel instant
local CHECK_DISTANCE        = 4     -- Studs of downward raycast slack (humanoid hipheight ~2)
local SOUL_SAND_BLOCK_NAME  = "SoulSand"

-- ============================================
-- STATE
-- ============================================
local character = nil
local humanoid = nil
local rootPart = nil
local baselineSpeed = nil   -- WalkSpeed observed before we first slowed the player
local currentSpeed = nil    -- Last value we wrote (so we don't fight other systems)
local heartbeatConn = nil

-- ============================================
-- HELPERS
-- ============================================

-- Collect every plot's Blocks folder for the raycast filter, the same way
-- WaterPlayerPhysics does. SoulSand can be in any plot (individual or MegaPlot).
local function gatherBlocksFolders()
	local list = {}
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocks = buildArea:FindFirstChild("Blocks")
			if blocks then table.insert(list, blocks) end
		end
	end
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaArea then
			local blocks = megaArea:FindFirstChild("Blocks")
			if blocks then table.insert(list, blocks) end
		end
	end
	return list
end

-- True if the part Claude landed on is a SoulSand block (or part of one). Walk
-- up the ancestry up to a couple of levels in case it's a Part inside a Model.
local function isSoulSand(part)
	if not part then return false end
	if part:GetAttribute("BlockType") == SOUL_SAND_BLOCK_NAME then return true end
	if part.Name == SOUL_SAND_BLOCK_NAME then return true end
	local p = part.Parent
	for _ = 1, 2 do
		if not p then break end
		if p:GetAttribute("BlockType") == SOUL_SAND_BLOCK_NAME then return true end
		if p.Name == SOUL_SAND_BLOCK_NAME then return true end
		p = p.Parent
	end
	return false
end

-- True if the player is currently standing on a SoulSand block.
-- Cheap path first: Humanoid.FloorMaterial is non-Air whenever the player is
-- grounded; only then do we raycast to identify what they're standing on.
local function standingOnSoulSand()
	if not humanoid or not rootPart then return false end
	if humanoid.FloorMaterial == Enum.Material.Air then return false end

	local origin = rootPart.Position
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = gatherBlocksFolders()
	rayParams.IgnoreWater = true

	local result = workspace:Raycast(origin, Vector3.new(0, -(BLOCK_SIZE + CHECK_DISTANCE), 0), rayParams)
	if not result then return false end
	return isSoulSand(result.Instance)
end

-- ============================================
-- MAIN LOOP
-- ============================================

local function onHeartbeat(dt)
	if not character or not humanoid or not rootPart or not rootPart.Parent then return end
	if humanoid.Health <= 0 then return end

	-- Capture the player's "real" speed the first time, then keep tracking it
	-- whenever we're NOT the one driving it (so other systems can change it).
	if baselineSpeed == nil then
		baselineSpeed = humanoid.WalkSpeed
	elseif currentSpeed and math.abs(humanoid.WalkSpeed - currentSpeed) > 0.01 then
		-- Someone else (water, sprint, settings) changed WalkSpeed since our
		-- last write -- treat that as the new baseline so we cooperate instead
		-- of fighting them. If WE wrote it last, this branch is skipped.
		baselineSpeed = humanoid.WalkSpeed
	end

	local target
	if standingOnSoulSand() then
		target = SOUL_SAND_WALK_SPEED
	else
		target = baselineSpeed
	end

	-- Lerp toward the target so the change isn't a jarring snap.
	local newSpeed = humanoid.WalkSpeed + (target - humanoid.WalkSpeed) * math.min(dt * SPEED_LERP_RATE, 1)
	if math.abs(newSpeed - humanoid.WalkSpeed) > 0.01 then
		humanoid.WalkSpeed = newSpeed
		currentSpeed = newSpeed
	end
end

-- ============================================
-- CHARACTER LIFECYCLE
-- ============================================

local function onCharacterAdded(newCharacter)
	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid")
	rootPart = newCharacter:WaitForChild("HumanoidRootPart")
	baselineSpeed = nil
	currentSpeed = nil

	if heartbeatConn then heartbeatConn:Disconnect() end
	heartbeatConn = RunService.Heartbeat:Connect(onHeartbeat)
end

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

Players.PlayerRemoving:Connect(function(leaving)
	if leaving == player and heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
end)

print("[SoulSandSlowdown] Ready - WalkSpeed " .. SOUL_SAND_WALK_SPEED .. " on SoulSand")
