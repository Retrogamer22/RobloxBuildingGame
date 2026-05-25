--[[
	StairDebugVisuals
	Comprehensive 3D debugging for stair placement
	
	Features:
	- Direction arrows on all nearby stairs
	- Adjacent position check markers (FRONT/BACK/LEFT/RIGHT)
	- Color-coded connection visualization
	- Test hotkeys for spawning stair configurations
	
	Press F to toggle debug mode
	Press 1-4 to spawn test stairs (when debug enabled)
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Load modules
local StairPlacement = nil
pcall(function()
	StairPlacement = require(ReplicatedStorage:WaitForChild("StairPlacement", 5))
end)

local BLOCK_SIZE = 3
local DEBUG_FOLDER_NAME = "StairDebugVisuals"

-- Direction mappings
local DIR_NAMES = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }
local DIR_FULL = { [0] = "NORTH", [1] = "EAST", [2] = "SOUTH", [3] = "WEST" }
local DIR_OFFSETS = {
	[0] = Vector3.new(0, 0, 1),   -- NORTH +Z
	[1] = Vector3.new(1, 0, 0),   -- EAST +X
	[2] = Vector3.new(0, 0, -1),  -- SOUTH -Z
	[3] = Vector3.new(-1, 0, 0),  -- WEST -X
}

-- Colors
local COLORS = {
	FACING = Color3.fromRGB(255, 200, 50),      -- Yellow - direction stair faces
	BACK = Color3.fromRGB(150, 100, 255),       -- Purple - back direction (ascends toward)
	SAME_DIR = Color3.fromRGB(80, 150, 255),    -- Blue - same direction stair
	PERPENDICULAR = Color3.fromRGB(100, 255, 100), -- Green - perpendicular stair
	OPPOSITE = Color3.fromRGB(255, 150, 50),    -- Orange - opposite direction stair
	EMPTY = Color3.fromRGB(100, 100, 100),      -- Gray - no stair found
	BLOCKED = Color3.fromRGB(255, 80, 80),      -- Red - blocked/invalid
	CORNER_INNER = Color3.fromRGB(0, 255, 200), -- Cyan - inner corner
	CORNER_OUTER = Color3.fromRGB(255, 100, 200), -- Pink - outer corner
}

-- State
local debugEnabled = false
local debugFolder = nil
local arrowParts = {}
local markerParts = {}
local labelParts = {}

-- ============================================
-- DEBUG FOLDER MANAGEMENT
-- ============================================

local function getDebugFolder()
	if debugFolder and debugFolder.Parent then
		return debugFolder
	end
	
	debugFolder = workspace:FindFirstChild(DEBUG_FOLDER_NAME)
	if not debugFolder then
		debugFolder = Instance.new("Folder")
		debugFolder.Name = DEBUG_FOLDER_NAME
		debugFolder.Parent = workspace
	end
	
	return debugFolder
end

local function clearDebugVisuals()
	local folder = workspace:FindFirstChild(DEBUG_FOLDER_NAME)
	if folder then
		folder:ClearAllChildren()
	end
	arrowParts = {}
	markerParts = {}
	labelParts = {}
end

-- ============================================
-- VISUAL CREATION HELPERS
-- ============================================

local function createArrow(position, direction, color, label)
	local folder = getDebugFolder()
	
	-- Arrow shaft
	local shaft = Instance.new("Part")
	shaft.Name = "ArrowShaft_" .. (label or "")
	shaft.Size = Vector3.new(0.15, 0.15, 1.2)
	shaft.Color = color
	shaft.Material = Enum.Material.Neon
	shaft.Anchored = true
	shaft.CanCollide = false
	shaft.CastShadow = false
	
	local dirOffset = DIR_OFFSETS[direction] or Vector3.new(0, 0, 1)
	local lookAt = position + dirOffset
	shaft.CFrame = CFrame.lookAt(position + Vector3.new(0, 1.8, 0), lookAt + Vector3.new(0, 1.8, 0))
	shaft.CFrame = shaft.CFrame * CFrame.new(0, 0, -0.6)
	
	shaft.Parent = folder
	
	-- Arrow head (cone approximation with wedge)
	local head = Instance.new("Part")
	head.Name = "ArrowHead_" .. (label or "")
	head.Size = Vector3.new(0.4, 0.4, 0.4)
	head.Color = color
	head.Material = Enum.Material.Neon
	head.Anchored = true
	head.CanCollide = false
	head.CastShadow = false
	head.CFrame = shaft.CFrame * CFrame.new(0, 0, -0.8)
	head.Parent = folder
	
	-- Make head pointed (use special mesh)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Wedge
	mesh.Scale = Vector3.new(1, 1, 1)
	mesh.Parent = head
	head.CFrame = head.CFrame * CFrame.Angles(math.rad(-90), 0, 0)
	
	table.insert(arrowParts, shaft)
	table.insert(arrowParts, head)
	
	return shaft, head
end

local function createMarker(position, color, label, size)
	local folder = getDebugFolder()
	size = size or 0.5
	
	local marker = Instance.new("Part")
	marker.Name = "Marker_" .. (label or "")
	marker.Shape = Enum.PartType.Ball
	marker.Size = Vector3.new(size, size, size)
	marker.Color = color
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.3
	marker.Anchored = true
	marker.CanCollide = false
	marker.CastShadow = false
	marker.Position = position
	marker.Parent = folder
	
	table.insert(markerParts, marker)
	
	return marker
end

local function createLabel(position, text, color)
	local folder = getDebugFolder()
	
	local part = Instance.new("Part")
	part.Name = "LabelAnchor"
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Position = position
	part.Parent = folder
	
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DebugLabel"
	billboard.Size = UDim2.new(0, 120, 0, 50)
	billboard.StudsOffset = Vector3.new(0, 0.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = part
	
	local bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	bg.BackgroundTransparency = 0.3
	bg.BorderSizePixel = 0
	bg.Parent = billboard
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = bg
	
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.new(1, -4, 1, -4)
	textLabel.Position = UDim2.new(0, 2, 0, 2)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	textLabel.TextSize = 12
	textLabel.Font = Enum.Font.GothamBold
	textLabel.TextWrapped = true
	textLabel.Parent = bg
	
	table.insert(labelParts, part)
	
	return part
end

local function createConnectionLine(fromPos, toPos, color)
	local folder = getDebugFolder()
	
	local distance = (toPos - fromPos).Magnitude
	local midPoint = (fromPos + toPos) / 2
	
	local line = Instance.new("Part")
	line.Name = "ConnectionLine"
	line.Size = Vector3.new(0.08, 0.08, distance)
	line.Color = color
	line.Material = Enum.Material.Neon
	line.Transparency = 0.5
	line.Anchored = true
	line.CanCollide = false
	line.CastShadow = false
	line.CFrame = CFrame.lookAt(midPoint, toPos)
	line.Parent = folder
	
	table.insert(markerParts, line)
	
	return line
end

-- ============================================
-- STAIR ANALYSIS
-- ============================================

local function getBlocksFolder()
	local plotData = _G.PlotClient and _G.PlotClient.GetMyPlot()
	if plotData and plotData.BuildArea then
		return plotData.BuildArea:FindFirstChild("Blocks")
	end
	return nil
end

local function getStairPosition(stair)
	if stair:IsA("BasePart") then
		return stair.Position
	elseif stair:IsA("Model") then
		local primary = stair.PrimaryPart or stair:FindFirstChildWhichIsA("UnionOperation") or stair:FindFirstChildWhichIsA("BasePart")
		if primary then return primary.Position end
	end
	return nil
end

local function getAllNearbyStairs(centerPos, radius)
	local blocksFolder = getBlocksFolder()
	if not blocksFolder or not StairPlacement then return {} end
	
	local stairs = {}
	radius = radius or 30
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")
		local isStairOrArch = blockType and (StairPlacement.IsStairType(blockType) or (StairPlacement.IsArchType and StairPlacement.IsArchType(blockType)))
		if isStairOrArch then
			local pos = getStairPosition(block)
			if pos and (pos - centerPos).Magnitude < radius then
				local direction = block:GetAttribute("StairDirection")
				if direction == nil then
					local rotation = block:GetAttribute("Rotation") or 0
					direction = StairPlacement.RotationToDirection(rotation)
				end
				
				table.insert(stairs, {
					object = block,
					position = pos,
					direction = direction,
					upsideDown = block:GetAttribute("IsUpsideDown") or false,
					cornerType = block:GetAttribute("CornerType") or "normal",
					blockType = blockType,
				})
			end
		end
	end
	
	return stairs
end

local function analyzeStairAt(position, direction, upsideDown, blocksFolder)
	if not StairPlacement then return nil end
	
	local analysis = {
		position = position,
		direction = direction,
		upsideDown = upsideDown,
		checks = {},
		wouldBeCorner = false,
		cornerType = "normal",
		cornerReason = "No corner condition met",
	}
	
	-- Direction helpers
	local backDir = StairPlacement.GetOppositeDirection(direction)
	local frontDir = direction
	local leftDir = StairPlacement.GetLeftDirection(direction)
	local rightDir = StairPlacement.GetRightDirection(direction)
	
	-- Check each direction
	for checkDir = 0, 3 do
		local offset = DIR_OFFSETS[checkDir] * BLOCK_SIZE
		local checkPos = position + offset
		local typeChecker = StairPlacement.IsStairOrArchType or StairPlacement.IsStairType
		local stair = StairPlacement.GetStairAt(checkPos, blocksFolder, typeChecker)
		
		local checkName
		if checkDir == backDir then checkName = "BACK"
		elseif checkDir == frontDir then checkName = "FRONT"
		elseif checkDir == leftDir then checkName = "LEFT"
		else checkName = "RIGHT"
		end
		
		local checkData = {
			direction = checkDir,
			directionName = DIR_NAMES[checkDir],
			position = checkPos,
			role = checkName,
			found = stair ~= nil,
			stairDirection = stair and stair.direction,
			stairDirectionName = stair and DIR_NAMES[stair.direction],
			stairUpsideDown = stair and stair.upsideDown,
			stairCornerType = stair and stair.cornerType or "normal",
			isPerpendicular = false,
			isSameDir = false,
			isOpposite = false,
			color = COLORS.EMPTY,
			reason = "Empty",
		}
		
		if stair then
			local dirDiff = math.abs(stair.direction - direction)
			checkData.isPerpendicular = (dirDiff == 1) or (dirDiff == 3)
			checkData.isSameDir = (stair.direction == direction)
			checkData.isOpposite = (dirDiff == 2)
			
			if checkData.isSameDir then
				checkData.color = COLORS.SAME_DIR
				checkData.reason = "Same direction"
			elseif checkData.isPerpendicular then
				checkData.color = COLORS.PERPENDICULAR
				checkData.reason = "Perpendicular"
			else
				checkData.color = COLORS.OPPOSITE
				checkData.reason = "Opposite"
			end
		end
		
		analysis.checks[checkDir] = checkData
	end
	
	-- Analyze corner logic (BACK check)
	-- BACK check: perpendicular stair behind = ALWAYS INNER (filling inside of L)
	local backCheck = analysis.checks[backDir]
	if backCheck.found and backCheck.isPerpendicular and backCheck.stairUpsideDown == upsideDown then
		analysis.wouldBeCorner = true
		analysis.cornerType = "inner"
		analysis.cornerReason = "BACK stair is PERP → INNER"
		analysis.checks[backDir].color = COLORS.CORNER_INNER
	end
	
	-- Analyze corner logic (FRONT check - L-shape)
	-- SKIP if front stair is already a corner (corners don't influence other corners via FRONT check)
	if not analysis.wouldBeCorner then
		local frontCheck = analysis.checks[frontDir]
		if frontCheck.found and frontCheck.isPerpendicular and frontCheck.stairUpsideDown == upsideDown and frontCheck.stairCornerType == "normal" then
			local frontStairBackDir = StairPlacement.GetOppositeDirection(frontCheck.stairDirection)
			local connectsOnLeft = (leftDir == frontStairBackDir)
			local connectsOnRight = (rightDir == frontStairBackDir)
			
			if connectsOnLeft or connectsOnRight then
				-- NEW: Check BACK for same-dir stair (not the side)
				local backStairSameCheck = analysis.checks[backDir]
				local hasSameDirBehind = backStairSameCheck.found and backStairSameCheck.isSameDir and backStairSameCheck.stairUpsideDown == upsideDown
				
				if not hasSameDirBehind then
					analysis.wouldBeCorner = true
					-- FRONT check = completing a square corner = always OUTER
					analysis.cornerType = "outer"
					analysis.cornerReason = "FRONT PERP + L-connection + no same-dir BEHIND → OUTER"
					analysis.checks[frontDir].color = analysis.cornerType == "inner" and COLORS.CORNER_INNER or COLORS.CORNER_OUTER
				else
					analysis.cornerReason = "FRONT PERP but same-dir stair BEHIND (extending run)"
					analysis.checks[backDir].color = COLORS.BLOCKED
				end
			else
				analysis.cornerReason = "FRONT PERP but no L-connection"
			end
		end
	end
	
	return analysis
end

-- ============================================
-- VISUALIZATION UPDATE
-- ============================================

local function updateVisualsForStair(targetStair)
	clearDebugVisuals()
	
	if not targetStair or not StairPlacement then return end
	
	local blocksFolder = getBlocksFolder()
	if not blocksFolder then return end
	
	local pos = getStairPosition(targetStair.object)
	if not pos then return end
	
	-- Get all nearby stairs and draw arrows on them
	local nearbyStairs = getAllNearbyStairs(pos, 20)
	
	for _, stair in ipairs(nearbyStairs) do
		local color = COLORS.SAME_DIR
		
		-- Color based on relation to target
		if stair.object == targetStair.object then
			color = COLORS.FACING
		elseif stair.direction == targetStair.direction then
			color = COLORS.SAME_DIR
		else
			local dirDiff = math.abs(stair.direction - targetStair.direction)
			if (dirDiff == 1) or (dirDiff == 3) then
				color = COLORS.PERPENDICULAR
			else
				color = COLORS.OPPOSITE
			end
		end
		
		-- Create arrow showing direction
		createArrow(stair.position, stair.direction, color, DIR_NAMES[stair.direction])
		
		-- Add small label
		local labelText = DIR_NAMES[stair.direction]
		if stair.cornerType ~= "normal" then
			labelText = labelText .. "\n" .. stair.cornerType:upper()
		end
		if stair.object == targetStair.object then
			labelText = "TARGET\n" .. labelText
		end
	end
	
	-- Analyze the target stair's corner logic
	local analysis = analyzeStairAt(pos, targetStair.direction, targetStair.upsideDown, blocksFolder)
	
	if analysis then
		-- Draw markers at each check position
		for checkDir = 0, 3 do
			local check = analysis.checks[checkDir]
			local markerPos = check.position + Vector3.new(0, 1.5, 0)
			
			-- Create marker
			local marker = createMarker(markerPos, check.color, check.role, 0.6)
			
			-- Create label
			local labelText = check.role .. " (" .. check.directionName .. ")"
			if check.found then
				labelText = labelText .. "\n" .. check.reason
				labelText = labelText .. "\nDir: " .. check.stairDirectionName
			else
				labelText = labelText .. "\nEMPTY"
			end
			createLabel(markerPos + Vector3.new(0, 0.8, 0), labelText, check.color)
			
			-- Draw connection line to target
			createConnectionLine(pos + Vector3.new(0, 1.5, 0), markerPos, check.color)
		end
		
		-- Create main result label above target
		local resultColor = analysis.wouldBeCorner and COLORS.CORNER_INNER or COLORS.EMPTY
		if analysis.cornerType == "outer" then resultColor = COLORS.CORNER_OUTER end
		
		local resultText = "RESULT: " .. analysis.cornerType:upper()
		resultText = resultText .. "\n" .. analysis.cornerReason
		createLabel(pos + Vector3.new(0, 3.5, 0), resultText, resultColor)
	end
end

local function updateVisualsForGhostPosition(position, direction, upsideDown)
	clearDebugVisuals()
	
	if not StairPlacement then return end
	
	local blocksFolder = getBlocksFolder()
	if not blocksFolder then return end
	
	-- Get all nearby stairs and draw arrows on them
	local nearbyStairs = getAllNearbyStairs(position, 20)
	
	for _, stair in ipairs(nearbyStairs) do
		local color = COLORS.SAME_DIR
		
		if stair.direction == direction then
			color = COLORS.SAME_DIR
		else
			local dirDiff = math.abs(stair.direction - direction)
			if (dirDiff == 1) or (dirDiff == 3) then
				color = COLORS.PERPENDICULAR
			else
				color = COLORS.OPPOSITE
			end
		end
		
		createArrow(stair.position, stair.direction, color, DIR_NAMES[stair.direction])
	end
	
	-- Analyze what would happen if placed here
	local analysis = analyzeStairAt(position, direction, upsideDown, blocksFolder)
	
	if analysis then
		-- Draw ghost position indicator
		createMarker(position + Vector3.new(0, 1.5, 0), COLORS.FACING, "GHOST", 0.8)
		createArrow(position, direction, COLORS.FACING, "GHOST")
		
		-- Draw markers at each check position
		for checkDir = 0, 3 do
			local check = analysis.checks[checkDir]
			local markerPos = check.position + Vector3.new(0, 1.5, 0)
			
			createMarker(markerPos, check.color, check.role, 0.5)
			
			local labelText = check.role
			if check.found then
				labelText = labelText .. ": " .. check.stairDirectionName
			else
				labelText = labelText .. ": -"
			end
			createLabel(markerPos + Vector3.new(0, 0.6, 0), labelText, check.color)
			
			createConnectionLine(position + Vector3.new(0, 1.5, 0), markerPos, check.color)
		end
		
		-- Result label
		local resultColor = analysis.wouldBeCorner and 
			(analysis.cornerType == "inner" and COLORS.CORNER_INNER or COLORS.CORNER_OUTER) or 
			COLORS.EMPTY
		
		local resultText = analysis.cornerType:upper()
		createLabel(position + Vector3.new(0, 2.8, 0), resultText, resultColor)
	end
end

-- ============================================
-- MAIN UPDATE
-- ============================================

local function getTargetStair()
	local ray = camera:ViewportPointToRay(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	
	local debugFolder = workspace:FindFirstChild(DEBUG_FOLDER_NAME)
	local excludeList = {player.Character}
	if debugFolder then table.insert(excludeList, debugFolder) end
	
	-- Also exclude ghost blocks
	local ghost = workspace:FindFirstChild("GhostBlock")
	if ghost then table.insert(excludeList, ghost) end
	
	raycastParams.FilterDescendantsInstances = excludeList
	
	local result = workspace:Raycast(ray.Origin, ray.Direction * 50, raycastParams)
	
	if result and result.Instance and StairPlacement then
		local hit = result.Instance
		local blockType = hit:GetAttribute("BlockType")
		
		if not blockType and hit.Parent then
			blockType = hit.Parent:GetAttribute("BlockType")
			if blockType then hit = hit.Parent end
		end
		
		local isStairOrArchHit = blockType and (StairPlacement.IsStairType(blockType) or (StairPlacement.IsArchType and StairPlacement.IsArchType(blockType)))
		if isStairOrArchHit then
			local direction = hit:GetAttribute("StairDirection")
			if direction == nil then
				local rotation = hit:GetAttribute("Rotation") or 0
				direction = StairPlacement.RotationToDirection(rotation)
			end
			
			return {
				object = hit,
				position = getStairPosition(hit),
				direction = direction,
				upsideDown = hit:GetAttribute("IsUpsideDown") or false,
				cornerType = hit:GetAttribute("CornerType") or "normal",
				blockType = blockType,
			}
		end
	end
	
	return nil
end

local function update()
	if not debugEnabled then return end
	
	local targetStair = getTargetStair()
	
	if targetStair then
		updateVisualsForStair(targetStair)
	else
		-- Check if player has stair selected (ghost mode)
		local blockData = _G.InventoryController and _G.InventoryController.GetSelectedBlock()
		local isStairOrArchGhost = blockData and StairPlacement and (StairPlacement.IsStairType(blockData.Id) or (StairPlacement.IsArchType and StairPlacement.IsArchType(blockData.Id)))
		if isStairOrArchGhost then
			-- Get ghost position
			local ghost = workspace:FindFirstChild("GhostBlock")
			if ghost then
				local ghostPos
				if ghost:IsA("BasePart") then
					ghostPos = ghost.Position
				elseif ghost:IsA("Model") then
					local primary = ghost.PrimaryPart or ghost:FindFirstChildWhichIsA("BasePart")
					if primary then ghostPos = primary.Position end
				end
				
				if ghostPos then
					local direction = StairPlacement.GetDirectionFromLookVector(camera.CFrame.LookVector)
					updateVisualsForGhostPosition(ghostPos, direction, false)
					return
				end
			end
		end
		
		clearDebugVisuals()
	end
end

-- ============================================
-- TEST HOTKEYS
-- ============================================

local testSpawned = {}

local function clearTestStairs()
	for _, stair in ipairs(testSpawned) do
		if stair and stair.Parent then
			stair:Destroy()
		end
	end
	testSpawned = {}
	print("[StairDebug] Cleared test stairs")
end

local function spawnTestStair(relativePos, direction, cornerType)
	-- This just prints what WOULD be spawned - actual spawning needs server
	print(string.format("[StairDebug] Would spawn: pos=%s dir=%s corner=%s",
		tostring(relativePos), DIR_NAMES[direction], cornerType or "normal"))
end

-- Test configurations
local TEST_CONFIGS = {
	-- 1: Simple L-shape (should trigger corner)
	[Enum.KeyCode.One] = {
		name = "L-Shape (FRONT perp)",
		stairs = {
			{pos = Vector3.new(0, 0, 0), dir = 1}, -- E-facing at center
			{pos = Vector3.new(3, 0, 0), dir = 2}, -- S-facing in front (EAST)
		},
	},
	-- 2: Straight line (should NOT trigger corner)  
	[Enum.KeyCode.Two] = {
		name = "Straight Line",
		stairs = {
			{pos = Vector3.new(0, 0, 0), dir = 1}, -- E-facing at center
			{pos = Vector3.new(-3, 0, 0), dir = 1}, -- E-facing behind (WEST)
		},
	},
	-- 3: Back perpendicular (inner corner)
	[Enum.KeyCode.Three] = {
		name = "Back Perp (INNER)",
		stairs = {
			{pos = Vector3.new(0, 0, 0), dir = 1}, -- E-facing at center
			{pos = Vector3.new(-3, 0, 0), dir = 0}, -- N-facing behind
		},
	},
	-- 4: Parallel lines (should NOT corner)
	[Enum.KeyCode.Four] = {
		name = "Parallel Lines",
		stairs = {
			{pos = Vector3.new(0, 0, 0), dir = 1}, -- E-facing at center
			{pos = Vector3.new(3, 0, 0), dir = 2}, -- S-facing in front
			{pos = Vector3.new(0, 0, 3), dir = 1}, -- E-facing to NORTH (parallel)
		},
	},
}

-- ============================================
-- INPUT
-- ============================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	
	-- Don't process while editing signs
	if _G.SignEditController and _G.SignEditController.IsEditing() then return end
	
	if input.KeyCode == Enum.KeyCode.F then
		debugEnabled = not debugEnabled
		
		if debugEnabled then
			print("[StairDebug] ENABLED - 3D visuals active")
			print("  Look at a stair to see corner analysis")
			print("  Select a stair in hotbar to see ghost preview analysis")
		else
			print("[StairDebug] DISABLED")
			clearDebugVisuals()
		end
	end
	
	-- Test configurations (only when debug enabled)
	if debugEnabled and TEST_CONFIGS[input.KeyCode] then
		local config = TEST_CONFIGS[input.KeyCode]
		print("[StairDebug] Test config: " .. config.name)
		for _, stair in ipairs(config.stairs) do
			spawnTestStair(stair.pos, stair.dir, stair.corner)
		end
	end
	
	-- Clear test stairs
	if debugEnabled and input.KeyCode == Enum.KeyCode.Zero then
		clearTestStairs()
	end
end)

-- Slower update rate for performance
local updateTimer = 0
local UPDATE_INTERVAL = 0.1

RunService.RenderStepped:Connect(function(dt)
	updateTimer = updateTimer + dt
	if updateTimer >= UPDATE_INTERVAL then
		updateTimer = 0
		update()
	end
end)

print("[StairDebugVisuals] Loaded - Press F to toggle 3D debug")
