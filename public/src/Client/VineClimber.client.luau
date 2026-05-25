--[[
	VineClimber
	Client-side climbing mechanic for vines (and ladders)
	
	When the player touches a vine/ladder:
	- Gravity is cancelled (player floats in place)
	- Jump / W = climb up
	- Shift / S = climb down
	- Releasing all inputs = hover in place
	- Only vertical movement is affected; horizontal movement is normal
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer

-- ============================================
-- CONFIGURATION
-- ============================================

local CLIMB_SPEED = 15       -- Studs per second going up (raised from 12 for snappier climb feel)
local DESCEND_SPEED = 12     -- Studs per second going down
local SENSOR_TAG = "VineClimbSensor"
local CLIMB_GRACE_PERIOD = 0.3 -- Seconds to keep climbing after the last touch ends — covers brief gaps between adjacent vine sensors so transitions don't drop the climb.

-- Walled-vs-free-hanging behavior
local SLOW_WALK_SPEED = 9         -- Player walk speed while passing through free-hanging vines
local WALL_CHECK_DISTANCE = 1.7  -- Tightened from 2.5: just reaches the host block's near face. Tighter means less false-positive (blocks beyond the immediately adjacent cell can never be hit).
local VINE_POLL_INTERVAL = 2      -- Seconds between full re-scans of vine wall states

-- ============================================
-- STATE
-- ============================================

local isClimbing = false
local touchingVines = {}  -- Track all walled vine sensors currently being touched (for climbing)
local slowingVines = {}   -- Track all free-hanging vine sensors currently being touched (for slowdown)
local vineWalled = {}     -- [sensor] = true if walled (climbable), false if free-hanging
local savedWalkSpeed = nil -- Player's walk speed before vine slowdown (for restoration)
local lastClimbTouchTime = 0 -- tick() at last walled-vine touch; used for grace period
local bodyVelocity = nil
local heartbeatConnection = nil
local character = nil
local humanoid = nil
local rootPart = nil

-- Input tracking
local jumpHeld = false
local crouchHeld = false

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getCharacterParts()
	character = LocalPlayer.Character
	if not character then return false end
	humanoid = character:FindFirstChildOfClass("Humanoid")
	rootPart = character:FindFirstChild("HumanoidRootPart")
	return humanoid ~= nil and rootPart ~= nil
end

local function startClimbing()
	if isClimbing then return end
	if not getCharacterParts() then return end
	
	isClimbing = true
	
	-- Create BodyVelocity to control vertical movement and cancel gravity
	if not bodyVelocity then
		bodyVelocity = Instance.new("BodyVelocity")
		bodyVelocity.Name = "VineClimbVelocity"
		bodyVelocity.MaxForce = Vector3.new(0, math.huge, 0) -- Only control Y axis
		bodyVelocity.Velocity = Vector3.new(0, 0, 0)
		bodyVelocity.P = 10000
		bodyVelocity.Parent = rootPart
	end
end

local function stopClimbing()
	if not isClimbing then return end
	
	isClimbing = false
	
	-- Remove BodyVelocity (let gravity take over)
	if bodyVelocity then
		bodyVelocity:Destroy()
		bodyVelocity = nil
	end
end

-- ============================================
-- WALL-DETECTION + COLLISION OVERRIDE
-- ============================================
-- A vine is "walled" (climbable) if there's a solid block adjacent to it on
-- one of the four horizontal sides. "Free-hanging" vines (no wall behind)
-- just slow the player a bit and don't start climbing. The vine itself is
-- already CanCollide=false server-side, so the player can walk through.
local DEBUG_VINES = true -- set to false to silence [BB-VINE] logs

local function getVineModel(sensor)
	-- Walk up the sensor's parents to find the node with IsVine attribute.
	local current = sensor
	for _ = 1, 5 do
		if current:GetAttribute("IsVine") then return current end
		current = current.Parent
		if not current or current == workspace then return nil end
	end
	return nil
end

local function checkVineWalled(sensor)
	if not sensor or not sensor.Parent then return false end
	
	local vineModel = getVineModel(sensor)
	-- Prefer the vine's stored grid position (more reliable than sensor.Position
	-- since the sensor is flush against a wall and can sit at a fractional offset)
	local origin
	if vineModel then
		local gx = vineModel:GetAttribute("BlockPosX")
		local gy = vineModel:GetAttribute("BlockPosY")
		local gz = vineModel:GetAttribute("BlockPosZ")
		if gx and gy and gz then
			origin = Vector3.new(gx, gy, gz)
		end
	end
	origin = origin or sensor.Position
	
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local filterList = {}
	if vineModel then table.insert(filterList, vineModel) end
	if LocalPlayer.Character then table.insert(filterList, LocalPlayer.Character) end
	rayParams.FilterDescendantsInstances = filterList
	
	-- Determine the "back" direction: opposite of the face the vine is on.
	-- The vine model is mounted on a host block's face, so its host (the wall)
	-- is in the OPPOSITE direction of VineFace. Checking only that one direction
	-- avoids false positives from solid blocks beside/in-front of the vine.
	local vineFace = vineModel and vineModel:GetAttribute("VineFace")
	local directions = {}
	if vineFace == "North" then
		table.insert(directions, Vector3.new(0, 0, WALL_CHECK_DISTANCE)) -- back is +Z (south)
	elseif vineFace == "South" then
		table.insert(directions, Vector3.new(0, 0, -WALL_CHECK_DISTANCE)) -- back is -Z (north)
	elseif vineFace == "East" then
		table.insert(directions, Vector3.new(-WALL_CHECK_DISTANCE, 0, 0)) -- back is -X (west)
	elseif vineFace == "West" then
		table.insert(directions, Vector3.new(WALL_CHECK_DISTANCE, 0, 0)) -- back is +X (east)
	else
		-- Fallback for vines with no VineFace attribute (rare; check all 4 directions)
		directions = {
			Vector3.new(WALL_CHECK_DISTANCE, 0, 0),
			Vector3.new(-WALL_CHECK_DISTANCE, 0, 0),
			Vector3.new(0, 0, WALL_CHECK_DISTANCE),
			Vector3.new(0, 0, -WALL_CHECK_DISTANCE),
		}
	end
	
	for _, dir in ipairs(directions) do
		local result = workspace:Raycast(origin, dir, rayParams)
		if result and result.Instance then
			local hit = result.Instance
			-- Walk up to find the BlockType-bearing ancestor (handles Models)
			local hitOwner = hit
			for _ = 1, 4 do
				if hitOwner:GetAttribute("BlockType") then break end
				hitOwner = hitOwner.Parent
				if not hitOwner or hitOwner == workspace then break end
			end
			local hitIsVine = (hitOwner and hitOwner:GetAttribute("IsVine"))
				or hit:GetAttribute("IsVine")
			local hitIsDecoration = (hitOwner and hitOwner:GetAttribute("IsDecoration"))
				or hit:GetAttribute("IsDecoration")
			-- A real wall: solid (CanCollide), not another vine, not a decoration
			-- (ShortGrass/TallGrass/flowers etc. shouldn't count as walls even if
			-- the raycast hits their visual). Decorations are CanCollide=false but
			-- some can have CanQuery=true so the raycast still finds them.
			local isSolidWall = hit.CanCollide and not hitIsVine and not hitIsDecoration
			if isSolidWall then
				if DEBUG_VINES then
					print(string.format("[BB-VINE] Vine at (%.1f,%.1f,%.1f) face=%s WALLED by %s",
						origin.X, origin.Y, origin.Z,
						tostring(vineFace),
						hitOwner and hitOwner.Name or hit.Name))
				end
				return true
			end
		end
	end
	if DEBUG_VINES then
		print(string.format("[BB-VINE] Vine at (%.1f,%.1f,%.1f) face=%s FREE-HANGING",
			origin.X, origin.Y, origin.Z, tostring(vineFace)))
	end
	return false
end

local function updateVineState(sensor)
	if not sensor or not sensor.Parent then return end
	if not sensor:IsA("BasePart") then return end
	local walled = checkVineWalled(sensor)
	vineWalled[sensor] = walled
	-- Don't bother setting CanCollide — the sensor is always CanCollide=false
	-- on the server (and the visual vine model is too), so the player already
	-- walks through every vine. The walled/free-hanging distinction only
	-- affects whether climbing starts.
end

local function applySlowdown()
	if not getCharacterParts() then return end
	if not savedWalkSpeed then
		savedWalkSpeed = humanoid.WalkSpeed
	end
	humanoid.WalkSpeed = SLOW_WALK_SPEED
	if DEBUG_VINES then
		print(string.format("[BB-VINE] Slowdown applied (%d -> %d)", savedWalkSpeed, SLOW_WALK_SPEED))
	end
end

local function removeSlowdown()
	if humanoid and humanoid.Parent and savedWalkSpeed then
		humanoid.WalkSpeed = savedWalkSpeed
		if DEBUG_VINES then
			print(string.format("[BB-VINE] Slowdown removed (-> %d)", savedWalkSpeed))
		end
	end
	savedWalkSpeed = nil
end

-- ============================================
-- TOUCH DETECTION
-- ============================================

local function onSensorTouched(sensor, otherPart)
	if not otherPart then return end
	if not otherPart.Parent then return end
	
	local touchChar = otherPart.Parent
	if touchChar ~= LocalPlayer.Character then return end
	
	-- Determine current walled state (cached or fresh check)
	local walled = vineWalled[sensor]
	if walled == nil then
		updateVineState(sensor)
		walled = vineWalled[sensor]
	end
	
	if walled then
		touchingVines[sensor] = true
		lastClimbTouchTime = tick()
		if DEBUG_VINES then
			local vineModel = getVineModel(sensor)
			local gx = vineModel and vineModel:GetAttribute("BlockPosX") or 0
			local gy = vineModel and vineModel:GetAttribute("BlockPosY") or 0
			local gz = vineModel and vineModel:GetAttribute("BlockPosZ") or 0
			local vf = vineModel and vineModel:GetAttribute("VineFace") or "?"
			print(string.format("[BB-VINE] TOUCHED WALLED vine at (%.1f,%.1f,%.1f) face=%s - starting climb", gx, gy, gz, vf))
		end
		startClimbing()
	else
		slowingVines[sensor] = true
		if DEBUG_VINES then
			local vineModel = getVineModel(sensor)
			local gx = vineModel and vineModel:GetAttribute("BlockPosX") or 0
			local gy = vineModel and vineModel:GetAttribute("BlockPosY") or 0
			local gz = vineModel and vineModel:GetAttribute("BlockPosZ") or 0
			local vf = vineModel and vineModel:GetAttribute("VineFace") or "?"
			print(string.format("[BB-VINE] TOUCHED FREE-HANGING vine at (%.1f,%.1f,%.1f) face=%s - slowdown only", gx, gy, gz, vf))
		end
		applySlowdown()
	end
end

local function onSensorTouchEnded(sensor, otherPart)
	if not otherPart then return end
	if not otherPart.Parent then return end
	
	local touchChar = otherPart.Parent
	if touchChar ~= LocalPlayer.Character then return end
	
	touchingVines[sensor] = nil
	slowingVines[sensor] = nil
	
	-- NOTE: We don't immediately stopClimbing() when touchingVines empties —
	-- the heartbeat loop handles that with a grace period (CLIMB_GRACE_PERIOD)
	-- to bridge brief gaps when transitioning between stacked vines.
	
	-- Stop slowdown if no free-hanging vines are touched anymore
	local stillSlowing = false
	for s, _ in pairs(slowingVines) do
		if s and s.Parent then
			stillSlowing = true
			break
		end
	end
	if not stillSlowing then
		removeSlowdown()
	end
end

-- Connect touch events for a sensor
local function connectSensor(sensor)
	if not sensor:IsA("BasePart") then return end
	
	-- Initialize wall state + CanCollide on first connect
	updateVineState(sensor)
	
	sensor.Touched:Connect(function(otherPart)
		onSensorTouched(sensor, otherPart)
	end)
	
	sensor.TouchEnded:Connect(function(otherPart)
		onSensorTouchEnded(sensor, otherPart)
	end)
end

-- ============================================
-- INPUT HANDLING
-- ============================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	
	if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.W then
		jumpHeld = true
	end
	
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.S then
		crouchHeld = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.W then
		jumpHeld = false
	end
	
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.S then
		crouchHeld = false
	end
end)

-- Also track mobile jump button
UserInputService.JumpRequest:Connect(function()
	if isClimbing then
		jumpHeld = true
		-- Auto-release after a short delay (mobile tap)
		task.delay(0.15, function()
			jumpHeld = false
		end)
	end
end)

-- ============================================
-- MAIN LOOP
-- ============================================

RunService.Heartbeat:Connect(function()
	if not isClimbing or not bodyVelocity then return end
	if not rootPart or not rootPart.Parent then
		stopClimbing()
		return
	end
	
	-- Clean up dead sensors
	for sensor, _ in pairs(touchingVines) do
		if not sensor or not sensor.Parent then
			touchingVines[sensor] = nil
		end
	end
	
	-- Check if still touching anything (with grace period to bridge gaps)
	local stillTouching = false
	for _ in pairs(touchingVines) do
		stillTouching = true
		break
	end
	local inGracePeriod = false
	if not stillTouching then
		-- Grace period: keep climb state alive briefly so transitions between
		-- adjacent vine sensors don't drop the climb. During grace we HOVER
		-- (don't keep accelerating upward) so the player doesn't shoot past
		-- the top of a vine column.
		if tick() - lastClimbTouchTime > CLIMB_GRACE_PERIOD then
			stopClimbing()
			return
		end
		inGracePeriod = true
	else
		lastClimbTouchTime = tick() -- keep timer fresh while in contact
	end
	
	-- Calculate vertical velocity based on input
	local yVelocity = 0
	
	if inGracePeriod then
		-- Hover during grace: either a new vine touches soon (climb resumes)
		-- or grace expires and stopClimbing fires. Either way, don't keep
		-- accelerating upward.
		yVelocity = 0
	elseif jumpHeld then
		yVelocity = CLIMB_SPEED
	elseif crouchHeld then
		yVelocity = -DESCEND_SPEED
	else
		yVelocity = 0 -- Hover in place
	end
	
	bodyVelocity.Velocity = Vector3.new(0, yVelocity, 0)
	
	-- Suppress default jump while climbing
	if humanoid and humanoid:GetState() == Enum.HumanoidStateType.Jumping then
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
	end
end)

-- ============================================
-- VINE SENSOR BACKFILL (client-side)
-- ============================================
-- Vines loaded from save go through SaveManager.createBlockFromSave which adds
-- a Hitbox but NOT a ClimbSensor (only the live placement path in VineHandler
-- creates the sensor). Without a tagged sensor, this script never sees the vine.
-- We backfill the sensor on the client for any vine that's missing one, both at
-- startup and as new vines stream in via workspace.DescendantAdded.
local BLOCK_SIZE = 3

local function ensureVineHasSensor(vineInstance)
	if not vineInstance or not vineInstance.Parent then return end
	if not vineInstance:GetAttribute("IsVine") then return end
	
	local vineFace = vineInstance:GetAttribute("VineFace") or "North"
	
	-- Determine the vine's pivot (visual position, flush against the host wall)
	local pivot
	if vineInstance:IsA("Model") then
		pivot = vineInstance:GetPivot()
	elseif vineInstance:IsA("BasePart") then
		pivot = vineInstance.CFrame
	else
		return
	end
	
	-- Backfill BlockPosX/Y/Z attributes if missing. The vine's pivot is flush
	-- against the host wall, so the grid CENTER of the vine cell is offset
	-- BLOCK_SIZE/2 OUTWARD (in the face direction) from the pivot.
	if not vineInstance:GetAttribute("BlockPosX") then
		local faceOffset
		if vineFace == "North" then
			faceOffset = Vector3.new(0, 0, -BLOCK_SIZE / 2)
		elseif vineFace == "South" then
			faceOffset = Vector3.new(0, 0, BLOCK_SIZE / 2)
		elseif vineFace == "East" then
			faceOffset = Vector3.new(BLOCK_SIZE / 2, 0, 0)
		elseif vineFace == "West" then
			faceOffset = Vector3.new(-BLOCK_SIZE / 2, 0, 0)
		else
			faceOffset = Vector3.zero
		end
		local gridCenter = pivot.Position + faceOffset
		vineInstance:SetAttribute("BlockPosX", gridCenter.X)
		vineInstance:SetAttribute("BlockPosY", gridCenter.Y)
		vineInstance:SetAttribute("BlockPosZ", gridCenter.Z)
		if DEBUG_VINES then
			print(string.format("[BB-VINE] Backfilled grid position (%.1f,%.1f,%.1f) on vine (face=%s, pivot at %.1f,%.1f,%.1f)",
				gridCenter.X, gridCenter.Y, gridCenter.Z, vineFace,
				pivot.Position.X, pivot.Position.Y, pivot.Position.Z))
		end
	end
	
	-- Skip if a sensor already exists
	if vineInstance:FindFirstChild("ClimbSensor") then return end
	
	-- Match the orientation of the existing hitbox (face-oriented thin slab).
	-- The thickness here (1.5) is slightly larger than the server's 1.0 to give
	-- a more forgiving touch area so climbing doesn't drop on minor wobbles.
	local sensorSize
	if vineFace == "North" or vineFace == "South" then
		sensorSize = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, 1.5)
	elseif vineFace == "East" or vineFace == "West" then
		sensorSize = Vector3.new(1.5, BLOCK_SIZE, BLOCK_SIZE)
	else
		sensorSize = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
	end
	
	local sensor = Instance.new("Part")
	sensor.Name = "ClimbSensor"
	sensor.Anchored = true
	sensor.CanCollide = false
	sensor.CanQuery = false
	sensor.CanTouch = true
	sensor.CastShadow = false
	sensor.Transparency = 1
	sensor.Size = sensorSize
	sensor.CFrame = CFrame.new(pivot.Position)
	sensor:AddTag(SENSOR_TAG)
	sensor.Parent = vineInstance
	
	if DEBUG_VINES then
		print(string.format("[BB-VINE] Backfilled ClimbSensor on vine at (%.1f,%.1f,%.1f)",
			pivot.Position.X, pivot.Position.Y, pivot.Position.Z))
	end
end

local function scanWorkspaceForVines()
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:GetAttribute("IsVine") then
			ensureVineHasSensor(descendant)
		end
	end
end

-- Scan once at startup (after a brief delay to let the world load in)
task.spawn(function()
	task.wait(2)
	scanWorkspaceForVines()
end)

-- Watch for newly-streamed vines (block placements, plot loads, etc.)
workspace.DescendantAdded:Connect(function(descendant)
	-- Attribute may not be set yet on the first frame, so retry briefly
	task.spawn(function()
		for _ = 1, 5 do
			if descendant.Parent and descendant:GetAttribute("IsVine") then
				ensureVineHasSensor(descendant)
				return
			end
			task.wait(0.2)
		end
	end)
end)

-- ============================================
-- SENSOR DISCOVERY
-- ============================================

-- Connect to existing sensors
for _, sensor in ipairs(CollectionService:GetTagged(SENSOR_TAG)) do
	connectSensor(sensor)
end

-- Connect to new sensors as they appear
CollectionService:GetInstanceAddedSignal(SENSOR_TAG):Connect(function(sensor)
	connectSensor(sensor)
end)

-- ============================================
-- PERIODIC WALL-STATE RE-SCAN
-- ============================================
-- Periodically re-check each vine's walled state so vines update when their
-- adjacent wall is broken or a new wall is placed next to them.
task.spawn(function()
	while true do
		task.wait(VINE_POLL_INTERVAL)
		for _, sensor in ipairs(CollectionService:GetTagged(SENSOR_TAG)) do
			if sensor and sensor.Parent then
				local prev = vineWalled[sensor]
				updateVineState(sensor)
				local now = vineWalled[sensor]
				-- If a vine just lost its wall while the player is climbing it,
				-- promote the touch from "climbing" to "slowdown" so the player
				-- can fall away from it instead of being stuck mid-air.
				if prev == true and now == false and touchingVines[sensor] then
					touchingVines[sensor] = nil
					slowingVines[sensor] = true
					local stillClimbing = false
					for s in pairs(touchingVines) do
						if s and s.Parent then stillClimbing = true; break end
					end
					if not stillClimbing then stopClimbing() end
					applySlowdown()
				end
			end
		end
	end
end)

-- ============================================
-- CHARACTER RESPAWN CLEANUP
-- ============================================

LocalPlayer.CharacterAdded:Connect(function(newCharacter)
	-- Reset climbing state on respawn
	isClimbing = false
	touchingVines = {}
	slowingVines = {}
	savedWalkSpeed = nil
	lastClimbTouchTime = 0
	if bodyVelocity then
		bodyVelocity:Destroy()
		bodyVelocity = nil
	end
	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid", 5)
	rootPart = newCharacter:WaitForChild("HumanoidRootPart", 5)
end)

-- Initial character setup
if LocalPlayer.Character then
	character = LocalPlayer.Character
	humanoid = character:FindFirstChildOfClass("Humanoid")
	rootPart = character:FindFirstChild("HumanoidRootPart")
end

print("[VineClimber] Vine climbing system loaded")
