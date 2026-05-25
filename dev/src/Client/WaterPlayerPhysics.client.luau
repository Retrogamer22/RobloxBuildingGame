--[[
	WaterPlayerPhysics
	Client-side player physics when interacting with water blocks.
	
	Handles:
	- Swimming/floating when submerged (buoyancy force)
	- Slow movement when walking through water (reduced WalkSpeed)
	- Flow push (water pushes player in flow direction)
	- Smooth transitions entering/exiting water
	
	Uses workspace spatial queries to detect water blocks near the player.
	Runs on Heartbeat for smooth physics integration.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local WaterSystem = require(ReplicatedStorage:WaitForChild("WaterSystem", 10))

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- ============================================
-- CONFIGURATION
-- ============================================

-- Movement
local NORMAL_WALK_SPEED = 16          -- Default Roblox walk speed
local WATER_WALK_SPEED = 8            -- Speed when wading in shallow water
local SWIM_WALK_SPEED = 6             -- Speed when fully submerged/swimming
local SPEED_LERP_RATE = 8             -- How fast speed transitions (per second)

-- Buoyancy / Swimming
local BUOYANCY_FORCE = 120            -- Upward force when submerged (studs/s²)
local SURFACE_FLOAT_FORCE = 60        -- Gentler force when at water surface
local GRAVITY_REDUCTION = 0.7         -- How much gravity is reduced in water (0-1)
local SWIM_UP_FORCE = 80              -- Force when pressing jump while swimming
local SINK_DAMPING = 0.85             -- Velocity damping when in water (per frame)
local MAX_VERTICAL_SPEED = 20         -- Cap vertical velocity in water

-- Flow push
local FLOW_PUSH_FORCE = 12            -- How strongly flow pushes the player (studs/s²)
local FLOW_PUSH_MAX = 8               -- Max flow push velocity

-- Detection
local CHECK_RADIUS = BLOCK_SIZE * 0.6 -- Radius around player to check for water
local SUBMERGE_THRESHOLD = 0.5        -- Fraction of player height that counts as "submerged"

-- ============================================
-- STATE
-- ============================================

local isInWater = false
local isSubmerged = false              -- Head underwater
local waterDepthFraction = 0           -- 0 = dry, 1 = fully submerged
local currentFlowDirection = Vector3.zero
local bodyVelocity = nil               -- BodyVelocity for buoyancy
local bodyForce = nil                  -- BodyForce for flow push
local targetSpeed = NORMAL_WALK_SPEED
local currentSpeed = NORMAL_WALK_SPEED
local originalJumpPower = nil
local originalJumpHeight = nil

-- ============================================
-- UTILITY
-- ============================================

local function getWaterBlocksNearPosition(position)
	-- Use GetPartBoundsInBox to find water blocks near the player
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	
	-- Build filter list from nearby build areas
	local filterList = {}
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				table.insert(filterList, blocksFolder)
			end
		end
	end
	
	-- Also check MegaPlot
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaPlot = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaPlot then
			local blocksFolder = megaPlot:FindFirstChild("Blocks")
			if blocksFolder then
				table.insert(filterList, blocksFolder)
			end
		end
	end
	
	if #filterList == 0 then return {} end
	overlapParams.FilterDescendantsInstances = filterList
	
	local checkSize = Vector3.new(BLOCK_SIZE * 2, BLOCK_SIZE * 3, BLOCK_SIZE * 2)
	local parts = workspace:GetPartBoundsInBox(CFrame.new(position), checkSize, overlapParams)
	
	local waterBlocks = {}
	for _, part in ipairs(parts) do
		if part:GetAttribute("IsWater") then
			table.insert(waterBlocks, part)
		end
	end
	
	return waterBlocks
end

local function getWaterLevelAtPosition(waterBlocks, playerPos)
	-- Find the highest water surface the player is touching
	local highestWaterTop = -math.huge
	local deepestWaterBottom = math.huge
	local totalFlowDir = Vector3.zero
	local flowCount = 0
	
	for _, block in ipairs(waterBlocks) do
		local waterLevel = block:GetAttribute("WaterLevel") or 0
		local waterHeight = WaterSystem.GetWaterHeight(waterLevel)
		
		-- Water block position is center; top of water is offset up
		local blockCenter = block.Position
		local waterTop = blockCenter.Y + (waterHeight / 2)
		local waterBottom = blockCenter.Y - (BLOCK_SIZE / 2)
		
		if waterTop > highestWaterTop then
			highestWaterTop = waterTop
		end
		if waterBottom < deepestWaterBottom then
			deepestWaterBottom = waterBottom
		end
		
		-- Calculate flow direction from this water block
		-- Flowing water pushes toward lower levels
		if waterLevel > 0 then -- flowing water (not source)
			local isFalling = block:GetAttribute("IsFalling")
			if isFalling then
				totalFlowDir = totalFlowDir + Vector3.new(0, -1, 0)
				flowCount = flowCount + 1
			else
				-- Check neighbors to determine flow direction (toward lower levels)
				local blockPos = WaterSystem.SnapToGrid(block.Position)
				for _, neighbor in ipairs(waterBlocks) do
					if neighbor ~= block then
						local neighborPos = WaterSystem.SnapToGrid(neighbor.Position)
						local neighborLevel = neighbor:GetAttribute("WaterLevel") or 0
						
						-- Only consider horizontal neighbors
						if math.abs(neighborPos.Y - blockPos.Y) < 1 then
							local diff = neighborPos - blockPos
							local dist = diff.Magnitude
							if dist < BLOCK_SIZE * 1.5 then
								-- Flow goes from low level number (closer to source) toward high level number
								if neighborLevel > waterLevel then
									-- This neighbor is further from source, flow goes toward it
									totalFlowDir = totalFlowDir + diff.Unit
									flowCount = flowCount + 1
								end
							end
						end
					end
				end
			end
		end
	end
	
	-- Average flow direction
	if flowCount > 0 then
		currentFlowDirection = (totalFlowDir / flowCount).Unit * math.min(flowCount / 2, 1)
	else
		currentFlowDirection = Vector3.zero
	end
	
	return highestWaterTop, deepestWaterBottom
end

-- ============================================
-- PHYSICS SETUP
-- ============================================

local function createWaterPhysics()
	-- BodyVelocity for buoyancy (vertical control)
	if not bodyVelocity then
		bodyVelocity = Instance.new("BodyVelocity")
		bodyVelocity.Name = "WaterBuoyancy"
		bodyVelocity.MaxForce = Vector3.new(0, 0, 0) -- Start inactive
		bodyVelocity.Velocity = Vector3.zero
		bodyVelocity.P = 1250
		bodyVelocity.Parent = rootPart
	end
	
	-- BodyForce for flow push (horizontal)
	if not bodyForce then
		bodyForce = Instance.new("BodyForce")
		bodyForce.Name = "WaterFlowPush"
		bodyForce.Force = Vector3.zero
		bodyForce.Parent = rootPart
	end
end

local function removeWaterPhysics()
	if bodyVelocity then
		bodyVelocity:Destroy()
		bodyVelocity = nil
	end
	if bodyForce then
		bodyForce:Destroy()
		bodyForce = nil
	end
end

local function storeOriginalValues()
	if not originalJumpPower then
		originalJumpPower = humanoid.JumpPower
	end
	if not originalJumpHeight then
		originalJumpHeight = humanoid.JumpHeight
	end
end

local function restoreOriginalValues()
	if originalJumpPower then
		humanoid.JumpPower = originalJumpPower
	end
	if originalJumpHeight then
		humanoid.JumpHeight = originalJumpHeight
	end
end

-- ============================================
-- MAIN UPDATE LOOP
-- ============================================

local function updateWaterPhysics(dt)
	if not character or not rootPart or not rootPart.Parent then return end
	if not humanoid or humanoid.Health <= 0 then return end
	
	local playerPos = rootPart.Position
	local playerFeetY = playerPos.Y - 3 -- Approximate feet position (half humanoid height)
	local playerHeadY = playerPos.Y + 1.5 -- Approximate head position
	
	-- Find water blocks near the player
	local waterBlocks = getWaterBlocksNearPosition(playerPos)
	
	local wasInWater = isInWater
	
	if #waterBlocks > 0 then
		local waterTop, waterBottom = getWaterLevelAtPosition(waterBlocks, playerPos)
		
		-- Determine how deep the player is
		if playerFeetY < waterTop then
			isInWater = true
			
			-- Calculate depth fraction (0 = feet barely in, 1 = head under)
			local playerHeight = playerHeadY - playerFeetY
			local depthInWater = waterTop - playerFeetY
			waterDepthFraction = math.clamp(depthInWater / playerHeight, 0, 1)
			
			isSubmerged = playerHeadY < waterTop
		else
			isInWater = false
			waterDepthFraction = 0
			isSubmerged = false
			currentFlowDirection = Vector3.zero
		end
	else
		isInWater = false
		waterDepthFraction = 0
		isSubmerged = false
		currentFlowDirection = Vector3.zero
	end
	
	-- ====== ENTERING WATER ======
	if isInWater and not wasInWater then
		storeOriginalValues()
		createWaterPhysics()
	end
	
	-- ====== EXITING WATER ======
	if not isInWater and wasInWater then
		restoreOriginalValues()
		removeWaterPhysics()
		currentSpeed = NORMAL_WALK_SPEED
		humanoid.WalkSpeed = NORMAL_WALK_SPEED
		return
	end
	
	-- ====== IN WATER PHYSICS ======
	if isInWater and bodyVelocity and bodyForce then
		-- -- Movement speed --
		if isSubmerged then
			targetSpeed = SWIM_WALK_SPEED
		else
			-- Interpolate between normal and water speed based on depth
			targetSpeed = NORMAL_WALK_SPEED + (WATER_WALK_SPEED - NORMAL_WALK_SPEED) * waterDepthFraction
		end
		
		currentSpeed = currentSpeed + (targetSpeed - currentSpeed) * math.min(dt * SPEED_LERP_RATE, 1)
		humanoid.WalkSpeed = currentSpeed
		
		-- -- Buoyancy --
		local currentVelY = rootPart.AssemblyLinearVelocity.Y
		
		if isSubmerged then
			-- Fully submerged: strong buoyancy to float up
			local buoyancyTarget = BUOYANCY_FORCE * waterDepthFraction
			
			-- If pressing jump, boost upward
			if humanoid.Jump or UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				buoyancyTarget = buoyancyTarget + SWIM_UP_FORCE
			end
			
			-- Dampen vertical velocity
			local dampedVelY = currentVelY * SINK_DAMPING
			local targetVelY = math.clamp(dampedVelY + buoyancyTarget * dt, -MAX_VERTICAL_SPEED, MAX_VERTICAL_SPEED)
			
			bodyVelocity.MaxForce = Vector3.new(0, math.huge, 0)
			bodyVelocity.Velocity = Vector3.new(0, targetVelY, 0)
			
			-- Reduce jump in water
			humanoid.JumpPower = 0
			humanoid.JumpHeight = 0
		else
			-- Partially in water: gentle surface floating
			local surfaceForce = SURFACE_FLOAT_FORCE * waterDepthFraction
			
			-- Only apply upward force when sinking
			if currentVelY < 0 then
				local dampedVelY = currentVelY * (1 - GRAVITY_REDUCTION * waterDepthFraction)
				bodyVelocity.MaxForce = Vector3.new(0, math.huge, 0)
				bodyVelocity.Velocity = Vector3.new(0, dampedVelY + surfaceForce * dt, 0)
			else
				bodyVelocity.MaxForce = Vector3.zero
			end
			
			-- Reduce jump power based on depth
			if originalJumpPower then
				humanoid.JumpPower = originalJumpPower * (1 - waterDepthFraction * 0.5)
			end
			if originalJumpHeight then
				humanoid.JumpHeight = originalJumpHeight * (1 - waterDepthFraction * 0.5)
			end
		end
		
		-- -- Flow Push --
		if currentFlowDirection.Magnitude > 0.01 then
			-- Apply horizontal push force in flow direction
			local pushStrength = FLOW_PUSH_FORCE * waterDepthFraction
			local currentHorizontalVel = Vector3.new(
				rootPart.AssemblyLinearVelocity.X,
				0,
				rootPart.AssemblyLinearVelocity.Z
			)
			
			-- Limit flow push so it doesn't stack indefinitely
			local flowVelComponent = currentHorizontalVel:Dot(currentFlowDirection)
			if flowVelComponent < FLOW_PUSH_MAX then
				local pushForce = currentFlowDirection * pushStrength * rootPart.AssemblyMass
				bodyForce.Force = Vector3.new(pushForce.X, 0, pushForce.Z)
			else
				bodyForce.Force = Vector3.zero
			end
		else
			bodyForce.Force = Vector3.zero
		end
	end
end

-- ============================================
-- CHARACTER SETUP
-- ============================================

local heartbeatConnection = nil

local function onCharacterAdded(newCharacter)
	-- Clean up old physics
	removeWaterPhysics()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	
	-- Reset state
	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid")
	rootPart = newCharacter:WaitForChild("HumanoidRootPart")
	isInWater = false
	isSubmerged = false
	waterDepthFraction = 0
	currentFlowDirection = Vector3.zero
	currentSpeed = NORMAL_WALK_SPEED
	originalJumpPower = nil
	originalJumpHeight = nil
	
	-- Start physics loop
	heartbeatConnection = RunService.Heartbeat:Connect(updateWaterPhysics)
end

-- Initialize for current character
if character then
	humanoid = character:WaitForChild("Humanoid")
	rootPart = character:WaitForChild("HumanoidRootPart")
	heartbeatConnection = RunService.Heartbeat:Connect(updateWaterPhysics)
end

-- Handle respawns
player.CharacterAdded:Connect(onCharacterAdded)

-- Cleanup on player leaving
Players.PlayerRemoving:Connect(function(leavingPlayer)
	if leavingPlayer == player then
		removeWaterPhysics()
		if heartbeatConnection then
			heartbeatConnection:Disconnect()
		end
	end
end)

print("[WaterPlayerPhysics] Initialized - swimming, slow movement, and flow push ready!")
