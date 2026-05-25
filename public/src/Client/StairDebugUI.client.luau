--[[
	StairDebugUI
	Enhanced debug panel for stair/fence placement
	
	Press F to toggle
	Shows:
	- Block info
	- Direction visualization with color coding
	- Step-by-step corner decision tree
	- Clear pass/fail indicators
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- Only load for the game owner. Using BetaConfig.OWNER_USER_ID (with a fallback to
-- game.CreatorId) instead of a name match means this keeps working through username
-- changes AND through group-ownership transfers (game.CreatorId returns the group ID
-- in that case, but BetaConfig.OWNER_USER_ID is set to the personal UserId).
local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))
local ownerUserId = (BetaConfig.OWNER_USER_ID ~= 0) and BetaConfig.OWNER_USER_ID or game.CreatorId
if player.UserId ~= ownerUserId then
	return -- Exit early, don't create UI for non-owners
end
local camera = workspace.CurrentCamera

-- Try to load modules
local FencePlacement = nil
local StairPlacement = nil
pcall(function()
	FencePlacement = require(ReplicatedStorage:WaitForChild("FencePlacement", 5))
end)
pcall(function()
	StairPlacement = require(ReplicatedStorage:WaitForChild("StairPlacement", 5))
end)

local BLOCK_SIZE = 3

-- Direction mapping
local DIR_NAMES = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }
local DIR_FULL = { [0] = "NORTH (+Z)", [1] = "EAST (+X)", [2] = "SOUTH (-Z)", [3] = "WEST (-X)" }

-- Colors
local COLORS = {
	PASS = Color3.fromRGB(100, 255, 100),
	FAIL = Color3.fromRGB(255, 100, 100),
	NEUTRAL = Color3.fromRGB(200, 200, 200),
	HIGHLIGHT = Color3.fromRGB(255, 200, 50),
	INNER = Color3.fromRGB(0, 255, 200),
	OUTER = Color3.fromRGB(255, 100, 200),
}

-- ============================================
-- UI CREATION
-- ============================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "StairDebugUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 450, 0, 500)
mainFrame.Position = UDim2.new(0, 10, 0.5, -250)
mainFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
mainFrame.BackgroundTransparency = 0.1
mainFrame.BorderSizePixel = 0
mainFrame.Visible = false
mainFrame.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = mainFrame

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(60, 60, 70)
mainStroke.Thickness = 2
mainStroke.Parent = mainFrame

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, 0, 0, 35)
titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 10)
titleCorner.Parent = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.Size = UDim2.new(1, -10, 1, 0)
titleLabel.Position = UDim2.new(0, 10, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "🔧 Stair/Arch Debug (F to toggle)"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.TextSize = 16
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = titleBar

-- Content area
local content = Instance.new("ScrollingFrame")
content.Name = "Content"
content.Size = UDim2.new(1, -20, 1, -45)
content.Position = UDim2.new(0, 10, 0, 40)
content.BackgroundTransparency = 1
content.ScrollBarThickness = 6
content.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 100)
content.CanvasSize = UDim2.new(0, 0, 0, 800)
content.Parent = mainFrame

local contentLayout = Instance.new("UIListLayout")
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Padding = UDim.new(0, 8)
contentLayout.Parent = content

-- ============================================
-- UI COMPONENT CREATORS
-- ============================================

local function createSection(name, layoutOrder)
	local section = Instance.new("Frame")
	section.Name = name
	section.Size = UDim2.new(1, 0, 0, 0)
	section.AutomaticSize = Enum.AutomaticSize.Y
	section.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
	section.BorderSizePixel = 0
	section.LayoutOrder = layoutOrder
	section.Parent = content
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = section
	
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.Parent = section
	
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = section
	
	return section
end

local function createLabel(parent, text, color, bold, order)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 18)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color or Color3.fromRGB(200, 200, 200)
	label.TextSize = 12
	label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = order or 0
	label.Parent = parent
	return label
end

local function createCheckRow(parent, label, passed, detail, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 20)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order or 0
	row.Parent = parent
	
	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.new(0, 20, 0, 20)
	icon.BackgroundTransparency = 1
	icon.Text = passed and "✓" or "✗"
	icon.TextColor3 = passed and COLORS.PASS or COLORS.FAIL
	icon.TextSize = 14
	icon.Font = Enum.Font.GothamBold
	icon.Parent = row
	
	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, -25, 0, 20)
	text.Position = UDim2.new(0, 25, 0, 0)
	text.BackgroundTransparency = 1
	text.Text = label .. (detail and (" → " .. detail) or "")
	text.TextColor3 = passed and COLORS.PASS or COLORS.NEUTRAL
	text.TextSize = 11
	text.Font = Enum.Font.Gotham
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextTruncate = Enum.TextTruncate.AtEnd
	text.Parent = row
	
	return row
end

local function createDirectionGrid(parent, order)
	local container = Instance.new("Frame")
	container.Name = "DirectionGrid"
	container.Size = UDim2.new(1, 0, 0, 120)
	container.BackgroundTransparency = 1
	container.LayoutOrder = order or 0
	container.Parent = parent
	
	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.Size = UDim2.new(0, 110, 0, 110)
	grid.Position = UDim2.new(0.5, -55, 0, 5)
	grid.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	grid.BorderSizePixel = 0
	grid.Parent = container
	
	local gridCorner = Instance.new("UICorner")
	gridCorner.CornerRadius = UDim.new(0, 8)
	gridCorner.Parent = grid
	
	-- Direction cells
	local positions = {
		N = UDim2.new(0.5, -15, 0, 5),
		E = UDim2.new(1, -35, 0.5, -15),
		S = UDim2.new(0.5, -15, 1, -35),
		W = UDim2.new(0, 5, 0.5, -15),
	}
	
	local cells = {}
	for dir, pos in pairs(positions) do
		local cell = Instance.new("Frame")
		cell.Name = dir
		cell.Size = UDim2.new(0, 30, 0, 30)
		cell.Position = pos
		cell.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
		cell.BorderSizePixel = 0
		cell.Parent = grid
		
		local cellCorner = Instance.new("UICorner")
		cellCorner.CornerRadius = UDim.new(0, 4)
		cellCorner.Parent = cell
		
		local cellLabel = Instance.new("TextLabel")
		cellLabel.Name = "Label"
		cellLabel.Size = UDim2.new(1, 0, 1, 0)
		cellLabel.BackgroundTransparency = 1
		cellLabel.Text = dir
		cellLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
		cellLabel.TextSize = 12
		cellLabel.Font = Enum.Font.GothamBold
		cellLabel.Parent = cell
		
		cells[dir] = cell
	end
	
	-- Center cell
	local center = Instance.new("Frame")
	center.Name = "Center"
	center.Size = UDim2.new(0, 30, 0, 30)
	center.Position = UDim2.new(0.5, -15, 0.5, -15)
	center.BackgroundColor3 = COLORS.HIGHLIGHT
	center.BorderSizePixel = 0
	center.Parent = grid
	
	local centerCorner = Instance.new("UICorner")
	centerCorner.CornerRadius = UDim.new(0.5, 0)
	centerCorner.Parent = center
	
	local centerLabel = Instance.new("TextLabel")
	centerLabel.Name = "Label"
	centerLabel.Size = UDim2.new(1, 0, 1, 0)
	centerLabel.BackgroundTransparency = 1
	centerLabel.Text = "?"
	centerLabel.TextColor3 = Color3.fromRGB(0, 0, 0)
	centerLabel.TextSize = 12
	centerLabel.Font = Enum.Font.GothamBold
	centerLabel.Parent = center
	
	cells.Center = center
	
	return container, cells
end

-- ============================================
-- SECTIONS
-- ============================================

-- Info section
local infoSection = createSection("InfoSection", 1)
local infoTitle = createLabel(infoSection, "📋 BLOCK INFO", Color3.fromRGB(255, 255, 255), true, 1)
local infoType = createLabel(infoSection, "Type: -", nil, false, 2)
local infoCorner = createLabel(infoSection, "Corner: -", nil, false, 3)
local infoDir = createLabel(infoSection, "Direction: -", nil, false, 4)
local infoPos = createLabel(infoSection, "Position: -", nil, false, 5)

-- Direction visualization
local dirSection = createSection("DirSection", 2)
local dirTitle = createLabel(dirSection, "🧭 DIRECTION MAP", Color3.fromRGB(255, 255, 255), true, 1)
local dirGrid, dirCells = createDirectionGrid(dirSection, 2)

-- Legend
local legendLabel = createLabel(dirSection, "🟡 Facing  🔵 Same  🟢 Perp  🟠 Opp  ⬜ Empty", Color3.fromRGB(120, 120, 120), false, 3)

-- Corner logic section
local logicSection = createSection("LogicSection", 3)
local logicTitle = createLabel(logicSection, "🔍 CORNER DECISION TREE", Color3.fromRGB(255, 255, 255), true, 1)

-- Result section
local resultSection = createSection("ResultSection", 4)
local resultTitle = createLabel(resultSection, "📊 RESULT", Color3.fromRGB(255, 255, 255), true, 1)
local resultLabel = createLabel(resultSection, "NORMAL", COLORS.NEUTRAL, true, 2)

-- ============================================
-- UPDATE LOGIC
-- ============================================
-- Updated: BACK check turn RIGHT = INNER, turn LEFT = OUTER

local enabled = false

local function clearLogicSection()
	for _, child in ipairs(logicSection:GetChildren()) do
		if child:IsA("Frame") or (child:IsA("TextLabel") and child.Name ~= "Title" and child.LayoutOrder > 1) then
			child:Destroy()
		end
	end
end

local function updateDirectionCells(facingDir, adjacentData)
	local dirMap = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }
	
	for i = 0, 3 do
		local dirName = dirMap[i]
		local cell = dirCells[dirName]
		if cell then
			local adj = adjacentData and adjacentData[i]
			
			if i == facingDir then
				cell.BackgroundColor3 = COLORS.HIGHLIGHT
				cell:FindFirstChild("Label").TextColor3 = Color3.fromRGB(0, 0, 0)
			elseif adj and adj.exists then
				if adj.direction == facingDir then
					cell.BackgroundColor3 = Color3.fromRGB(80, 150, 255) -- Blue - same
				elseif adj.isPerpendicular then
					cell.BackgroundColor3 = Color3.fromRGB(100, 200, 100) -- Green - perp
				else
					cell.BackgroundColor3 = Color3.fromRGB(255, 150, 50) -- Orange - opp
				end
				cell:FindFirstChild("Label").TextColor3 = Color3.fromRGB(255, 255, 255)
			else
				cell.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
				cell:FindFirstChild("Label").TextColor3 = Color3.fromRGB(150, 150, 150)
			end
		end
	end
	
	-- Update center
	dirCells.Center.BackgroundColor3 = COLORS.HIGHLIGHT
	dirCells.Center:FindFirstChild("Label").Text = dirMap[facingDir] or "?"
end

local function getBlocksFolder(instance)
	local current = instance.Parent
	while current do
		if current.Name == "Blocks" then return current end
		current = current.Parent
	end
	return nil
end

local function analyzeAdjacentStairs(pos, facingDir, blocksFolder)
	if not StairPlacement then return nil end
	
	local adjacent = {}
	-- Use IsStairOrArchType so we find both stairs and arches as neighbors
	local typeChecker = StairPlacement.IsStairOrArchType or StairPlacement.IsStairType
	for checkDir = 0, 3 do
		local offset = StairPlacement.GetDirectionOffset(checkDir) * BLOCK_SIZE
		local checkPos = pos + offset
		local stairInfo = StairPlacement.GetStairAt(checkPos, blocksFolder, typeChecker)
		
		if stairInfo then
			local isPerpendicular = (math.abs(stairInfo.direction - facingDir) % 2) == 1
			adjacent[checkDir] = {
				exists = true,
				direction = stairInfo.direction,
				upsideDown = stairInfo.upsideDown,
				isPerpendicular = isPerpendicular,
				cornerType = stairInfo.cornerType or "normal",
			}
		else
			adjacent[checkDir] = { exists = false }
		end
	end
	return adjacent
end

local function buildCornerDecisionTree(direction, upsideDown, adjacentStairs)
	clearLogicSection()
	
	if not StairPlacement or not adjacentStairs then
		createLabel(logicSection, "No data available", COLORS.NEUTRAL, false, 10)
		return "normal", "No StairPlacement module"
	end
	
	local backDir = StairPlacement.GetOppositeDirection(direction)
	local frontDir = direction
	local leftDir = StairPlacement.GetLeftDirection(direction)
	local rightDir = StairPlacement.GetRightDirection(direction)
	
	local order = 10
	local cornerResult = "normal"
	local cornerReason = "No corner condition met"
	
	-- Header: Direction map
	createLabel(logicSection, string.format("Dirs: FRONT=%s BACK=%s LEFT=%s RIGHT=%s",
		DIR_NAMES[frontDir], DIR_NAMES[backDir], DIR_NAMES[leftDir], DIR_NAMES[rightDir]),
		Color3.fromRGB(150, 150, 150), false, order)
	order = order + 1
	
	-- STEP 1: Check BACK stair
	createLabel(logicSection, "━━━ STEP 1: Back Check (" .. DIR_NAMES[backDir] .. ") ━━━", COLORS.NEUTRAL, true, order)
	order = order + 1
	
	local backStair = adjacentStairs[backDir]
	local backHasStair = backStair and backStair.exists
	createCheckRow(logicSection, "Stair behind?", backHasStair, backHasStair and ("dir=" .. DIR_NAMES[backStair.direction]) or "empty", order)
	order = order + 1
	
	if backHasStair then
		local backIsPerp = backStair.isPerpendicular
		createCheckRow(logicSection, "Is perpendicular?", backIsPerp, backIsPerp and "YES" or "NO", order)
		order = order + 1
		
		if backIsPerp then
			local sameUpDown = (backStair.upsideDown == upsideDown)
			createCheckRow(logicSection, "Same upside-down?", sameUpDown, sameUpDown and "YES" or "NO", order)
			order = order + 1
			
			if sameUpDown then
				-- BACK check: perpendicular stair behind = ALWAYS INNER
				-- (You're filling the inside of an L-shape)
				cornerResult = "inner"
				cornerReason = "BACK stair perpendicular"
				createLabel(logicSection, "→ INNER CORNER!", COLORS.INNER, true, order)
				order = order + 1
			end
		end
	end
	
	-- STEP 2: Check FRONT stair (only if no corner from step 1)
	-- SKIP if front stair is already a corner (corners don't influence other corners via FRONT check)
	if cornerResult == "normal" then
		createLabel(logicSection, "━━━ STEP 2: Front Check (" .. DIR_NAMES[frontDir] .. ") ━━━", COLORS.NEUTRAL, true, order)
		order = order + 1
		
		local frontStair = adjacentStairs[frontDir]
		local frontHasStair = frontStair and frontStair.exists
		createCheckRow(logicSection, "Stair in front?", frontHasStair, frontHasStair and ("dir=" .. DIR_NAMES[frontStair.direction]) or "empty", order)
		order = order + 1
		
		if frontHasStair then
			-- Check if front stair is a corner (skip if so)
			local frontIsCorner = frontStair.cornerType ~= "normal"
			if frontIsCorner then
				createCheckRow(logicSection, "Front is corner?", false, "YES (" .. frontStair.cornerType:upper() .. ") - SKIP", order)
				order = order + 1
				createLabel(logicSection, "→ Corners don't influence corners via FRONT", COLORS.FAIL, false, order)
				order = order + 1
			else
				createCheckRow(logicSection, "Front is corner?", true, "NO (normal stair)", order)
				order = order + 1
				
				local frontIsPerp = frontStair.isPerpendicular
				createCheckRow(logicSection, "Is perpendicular?", frontIsPerp, frontIsPerp and "YES" or "NO", order)
				order = order + 1
				
				if frontIsPerp then
					local sameUpDown = (frontStair.upsideDown == upsideDown)
					createCheckRow(logicSection, "Same upside-down?", sameUpDown, sameUpDown and "YES" or "NO", order)
					order = order + 1
					
					if sameUpDown then
						local frontStairBackDir = StairPlacement.GetOppositeDirection(frontStair.direction)
						local connectsOnLeft = (leftDir == frontStairBackDir)
						local connectsOnRight = (rightDir == frontStairBackDir)
						
						createCheckRow(logicSection, "L-connection?", connectsOnLeft or connectsOnRight,
							connectsOnLeft and "LEFT" or (connectsOnRight and "RIGHT" or "NONE"), order)
						order = order + 1
						
						if connectsOnLeft or connectsOnRight then
							-- Check BACK for same-direction stair (the fix!)
							local backStairSameCheck = adjacentStairs[backDir]
							local hasSameDirBehind = backStairSameCheck and backStairSameCheck.exists 
								and backStairSameCheck.direction == direction 
								and backStairSameCheck.upsideDown == upsideDown
							
							createCheckRow(logicSection, "Same-dir stair BEHIND?", not hasSameDirBehind,
								hasSameDirBehind and "YES (blocks corner!)" or "NO (corner OK)", order)
							order = order + 1
							
							if not hasSameDirBehind then
								-- FRONT check = completing a square corner = always OUTER
								cornerResult = "outer"
								cornerReason = "FRONT perp + L-connection + no same-dir BEHIND"
								createLabel(logicSection, "→ OUTER CORNER!", COLORS.OUTER, true, order)
								order = order + 1
							else
								createLabel(logicSection, "→ Blocked by same-dir neighbor", COLORS.FAIL, false, order)
								cornerReason = "FRONT perp but same-dir BEHIND blocks corner"
								order = order + 1
							end
						end
					end
				end
			end
		end
	end
	
	return cornerResult, cornerReason
end

local function update()
	if not enabled then return end
	
	-- Raycast from camera center
	local ray = camera:ViewportPointToRay(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	local debugVisualsFolder = workspace:FindFirstChild("StairDebugVisuals")
	local excludeList = {player.Character}
	if debugVisualsFolder then
		table.insert(excludeList, debugVisualsFolder)
	end
	raycastParams.FilterDescendantsInstances = excludeList
	
	local result = workspace:Raycast(ray.Origin, ray.Direction * 50, raycastParams)
	
	if result and result.Instance and StairPlacement then
		local hit = result.Instance
		local blockType = hit:GetAttribute("BlockType")
		
		if not blockType and hit.Parent then
			blockType = hit.Parent:GetAttribute("BlockType")
			if blockType then hit = hit.Parent end
		end
		
		local isStairBlock = blockType and StairPlacement.IsStairType(blockType)
		local isArchBlock = blockType and StairPlacement.IsArchType and StairPlacement.IsArchType(blockType)
		if isStairBlock or isArchBlock then
			-- Get stair info
			local cornerType = hit:GetAttribute("CornerType") or "normal"
			local rotation = hit:GetAttribute("Rotation") or 0
			local direction = hit:GetAttribute("StairDirection")
			local isUpsideDown = hit:GetAttribute("IsUpsideDown") or false
			
			if direction == nil then
				direction = StairPlacement.RotationToDirection(rotation)
			end
			
			local pos
			if hit:IsA("BasePart") then pos = hit.Position
			elseif hit:IsA("Model") then
				local primary = hit.PrimaryPart or hit:FindFirstChildWhichIsA("BasePart")
				if primary then pos = primary.Position end
			end
			
			-- Update info section
			local typeTag = isArchBlock and " [ARCH]" or " [STAIR]"
			local isLargeArch = isArchBlock and StairPlacement.IsArchLargeType and StairPlacement.IsArchLargeType(blockType)
			if isLargeArch then typeTag = " [ARCH-LARGE]" end
			infoType.Text = "Type: " .. blockType .. typeTag
			infoCorner.Text = "Corner: " .. cornerType:upper()
			infoDir.Text = string.format("Direction: %s (%d°)", DIR_NAMES[direction] or "?", rotation)
			infoPos.Text = pos and string.format("Position: (%.0f, %.0f, %.0f)", pos.X, pos.Y, pos.Z) or "Position: -"
			
			if isUpsideDown then
				infoDir.Text = infoDir.Text .. " [UPSIDE DOWN]"
			end
			if isArchBlock and cornerType == "normal" then
				infoDir.Text = infoDir.Text .. " [X-flip applied]"
			end
			
			-- Analyze adjacent stairs
			local blocksFolder = getBlocksFolder(hit)
			local adjacentStairs = analyzeAdjacentStairs(pos, direction, blocksFolder)
			
			-- Update direction visualization
			updateDirectionCells(direction, adjacentStairs)
			
			-- Build corner decision tree
			local calculatedCorner, reason = buildCornerDecisionTree(direction, isUpsideDown, adjacentStairs)
			
			-- Update result
			if calculatedCorner == "inner" then
				resultLabel.Text = "INNER CORNER"
				resultLabel.TextColor3 = COLORS.INNER
			elseif calculatedCorner == "outer" then
				resultLabel.Text = "OUTER CORNER"
				resultLabel.TextColor3 = COLORS.OUTER
			else
				resultLabel.Text = "NORMAL"
				resultLabel.TextColor3 = COLORS.NEUTRAL
			end
			
			-- Show if current doesn't match calculated
			if cornerType ~= calculatedCorner then
				resultLabel.Text = resultLabel.Text .. string.format("\n(Actual: %s)", cornerType:upper())
			end
			
			return
		end
	end
	
	-- Not looking at a stair
	infoType.Text = "Type: -"
	infoCorner.Text = "Corner: -"
	infoDir.Text = "Direction: -"
	infoPos.Text = "Look at a stair..."
	
	for _, cell in pairs(dirCells) do
		if cell.Name ~= "Center" then
			cell.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
			cell:FindFirstChild("Label").TextColor3 = Color3.fromRGB(150, 150, 150)
		end
	end
	dirCells.Center:FindFirstChild("Label").Text = "?"
	
	clearLogicSection()
	createLabel(logicSection, "Look at a stair to see analysis", COLORS.NEUTRAL, false, 10)
	
	resultLabel.Text = "-"
	resultLabel.TextColor3 = COLORS.NEUTRAL
end

-- Toggle with F key
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	
	if input.KeyCode == Enum.KeyCode.F then
		enabled = not enabled
		mainFrame.Visible = enabled
		print("[StairDebugUI] " .. (enabled and "Enabled" or "Disabled"))
	end
end)

RunService.RenderStepped:Connect(update)

print("[StairDebugUI] Loaded - Press F to toggle")
