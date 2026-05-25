--[[
	PlotBlockBarrier
	Client-side enforcement that prevents the local player from walking onto
	plots they are blocked from.
	
	Spawns invisible client-only wall Parts around each blocked plot boundary.
	Roblox physics handles the collision naturally — no jank, no teleporting.
	
	Server still has a periodic anti-cheat check as a fallback.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local GetBlockedPlotBoundaries = Remotes:WaitForChild("GetBlockedPlotBoundaries", 5)
local BlockedPlotsChanged = Remotes:WaitForChild("BlockedPlotsChanged", 5)

-- Current list of blocked plot boundaries
local blockedPlots = {}

-- Wall config
local WALL_HEIGHT = 200   -- Tall enough you can't jump over
local WALL_THICKNESS = 2  -- Thin invisible wall
local WALL_Y_OFFSET = 50  -- Center the wall vertically above baseplate

-- Container for all barrier walls (client-only, lives in workspace)
local barrierFolder = Instance.new("Folder")
barrierFolder.Name = "PlotBarriers_Client"
barrierFolder.Parent = workspace

-- MC-style colors
local MC_PANEL = Color3.fromRGB(139, 139, 139)
local MC_BEVEL_LIGHT = Color3.fromRGB(200, 200, 200)
local MC_BEVEL_DARK = Color3.fromRGB(55, 55, 55)
local MC_TEXT_RED = Color3.fromRGB(255, 85, 85)
local MC_TEXT_SHADOW = Color3.fromRGB(40, 40, 40)
local BEVEL = 3

-- ============================================
-- MC BEVEL HELPER
-- ============================================

local function addRaisedBevel(frame, lightColor, darkColor)
	local hl = lightColor or MC_BEVEL_LIGHT
	local sh = darkColor or MC_BEVEL_DARK

	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL)
	top.BackgroundColor3 = hl
	top.BackgroundTransparency = 0.3
	top.BorderSizePixel = 0
	top.ZIndex = 12
	top.Parent = frame

	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL, 1, 0)
	left.BackgroundColor3 = hl
	left.BackgroundTransparency = 0.3
	left.BorderSizePixel = 0
	left.ZIndex = 12
	left.Parent = frame

	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL)
	bottom.BackgroundColor3 = sh
	bottom.BackgroundTransparency = 0.3
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 12
	bottom.Parent = frame

	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL, 1, 0)
	right.Position = UDim2.new(1, -BEVEL, 0, 0)
	right.BackgroundColor3 = sh
	right.BackgroundTransparency = 0.3
	right.BorderSizePixel = 0
	right.ZIndex = 12
	right.Parent = frame
end

-- ============================================
-- WARNING UI (MC-style with bevels)
-- ============================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlotBarrierUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 140
screenGui.Parent = playerGui

local warningFrame = Instance.new("Frame")
warningFrame.Name = "BlockedWarning"
warningFrame.Size = UDim2.new(0, 380, 0, 40)
warningFrame.AnchorPoint = Vector2.new(0.5, 0)
warningFrame.Position = UDim2.new(0.5, 0, 0, 80)
warningFrame.BackgroundColor3 = MC_PANEL
warningFrame.BackgroundTransparency = 0
warningFrame.BorderSizePixel = 0
warningFrame.Visible = false
warningFrame.ZIndex = 10
warningFrame.Parent = screenGui

addRaisedBevel(warningFrame)

local warningShadow = Instance.new("TextLabel")
warningShadow.Name = "Shadow"
warningShadow.Size = UDim2.new(1, -16, 1, 0)
warningShadow.Position = UDim2.new(0, 10, 0, 2)
warningShadow.BackgroundTransparency = 1
warningShadow.Font = Enum.Font.Arcade
warningShadow.TextSize = 16
warningShadow.TextColor3 = MC_TEXT_SHADOW
warningShadow.Text = "You are blocked from this plot!"
warningShadow.TextWrapped = true
warningShadow.ZIndex = 11
warningShadow.Parent = warningFrame

local warningLabel = Instance.new("TextLabel")
warningLabel.Name = "Label"
warningLabel.Size = UDim2.new(1, -16, 1, 0)
warningLabel.Position = UDim2.new(0, 8, 0, 0)
warningLabel.BackgroundTransparency = 1
warningLabel.Font = Enum.Font.Arcade
warningLabel.TextSize = 16
warningLabel.TextColor3 = MC_TEXT_RED
warningLabel.Text = "You are blocked from this plot!"
warningLabel.TextWrapped = true
warningLabel.ZIndex = 12
warningLabel.Parent = warningFrame

local warningVisible = false
local warningHideTime = 0
local fadeTween1, fadeTween2, fadeTween3

local function showWarning()
	if fadeTween1 then fadeTween1:Cancel() end
	if fadeTween2 then fadeTween2:Cancel() end
	if fadeTween3 then fadeTween3:Cancel() end

	if not warningVisible then
		warningVisible = true
		warningFrame.Visible = true
		warningFrame.BackgroundTransparency = 0
		warningLabel.TextTransparency = 0
		warningShadow.TextTransparency = 0
	end
	warningHideTime = tick() + 2
end

local function updateWarningFade()
	if warningVisible and tick() > warningHideTime then
		warningVisible = false
		local info = TweenInfo.new(0.5)
		fadeTween1 = TweenService:Create(warningFrame, info, { BackgroundTransparency = 1 })
		fadeTween2 = TweenService:Create(warningLabel, info, { TextTransparency = 1 })
		fadeTween3 = TweenService:Create(warningShadow, info, { TextTransparency = 1 })
		fadeTween1:Play()
		fadeTween2:Play()
		fadeTween3:Play()
		task.delay(0.5, function()
			if not warningVisible then
				warningFrame.Visible = false
			end
		end)
	end
end

-- ============================================
-- WALL CREATION / DESTRUCTION
-- ============================================

local function createWall(name, position, size)
	local wall = Instance.new("Part")
	wall.Name = name
	wall.Size = size
	wall.Position = position
	wall.Anchored = true
	wall.CanCollide = true
	wall.Transparency = 1       -- Invisible
	wall.CastShadow = false
	wall.CanQuery = false        -- Don't interfere with raycasts (block placement etc)
	wall.CanTouch = true         -- Trigger Touched for warning
	wall.Parent = barrierFolder
	return wall
end

local function buildWallsForPlot(plot)
	local cx = plot.centerX
	local cz = plot.centerZ
	local hx = plot.halfX
	local hz = plot.halfZ
	local baseY = (plot.baseY or 0) + WALL_Y_OFFSET
	local tag = "Plot" .. plot.plotNumber

	-- 4 walls: North (+Z), South (-Z), East (+X), West (-X)

	-- North wall (along +Z edge)
	createWall(tag .. "_N",
		Vector3.new(cx, baseY, cz + hz),
		Vector3.new(hx * 2, WALL_HEIGHT, WALL_THICKNESS)
	)

	-- South wall (along -Z edge)
	createWall(tag .. "_S",
		Vector3.new(cx, baseY, cz - hz),
		Vector3.new(hx * 2, WALL_HEIGHT, WALL_THICKNESS)
	)

	-- East wall (along +X edge)
	createWall(tag .. "_E",
		Vector3.new(cx + hx, baseY, cz),
		Vector3.new(WALL_THICKNESS, WALL_HEIGHT, hz * 2)
	)

	-- West wall (along -X edge)
	createWall(tag .. "_W",
		Vector3.new(cx - hx, baseY, cz),
		Vector3.new(WALL_THICKNESS, WALL_HEIGHT, hz * 2)
	)
end

local function clearAllWalls()
	barrierFolder:ClearAllChildren()
end

local function rebuildWalls()
	clearAllWalls()
	for _, plot in ipairs(blockedPlots) do
		buildWallsForPlot(plot)
	end
	print("[PlotBlockBarrier] Built walls for " .. #blockedPlots .. " blocked plot(s)")
end

-- ============================================
-- PROXIMITY WARNING (lightweight check)
-- ============================================

local WARN_DISTANCE = 6 -- Studs from wall to start showing warning

RunService.Heartbeat:Connect(function()
	updateWarningFade()

	if #blockedPlots == 0 then return end

	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local posX = hrp.Position.X
	local posZ = hrp.Position.Z

	-- Check if near any blocked plot boundary
	for _, plot in ipairs(blockedPlots) do
		local minX = plot.centerX - plot.halfX
		local maxX = plot.centerX + plot.halfX
		local minZ = plot.centerZ - plot.halfZ
		local maxZ = plot.centerZ + plot.halfZ

		-- Distance to nearest edge (negative = inside)
		local distX = math.max(minX - posX, posX - maxX, 0)
		local distZ = math.max(minZ - posZ, posZ - maxZ, 0)
		local dist = math.sqrt(distX * distX + distZ * distZ)

		-- Also check if inside the plot (shouldn't happen with walls, but just in case)
		local inside = posX >= minX and posX <= maxX and posZ >= minZ and posZ <= maxZ

		if inside or dist < WARN_DISTANCE then
			showWarning()
			return
		end
	end
end)

-- ============================================
-- LOAD / UPDATE BLOCKED PLOTS
-- ============================================

local function loadBlockedPlots()
	local success, result = pcall(function()
		return GetBlockedPlotBoundaries:InvokeServer()
	end)

	if success and result then
		blockedPlots = result
		rebuildWalls()
	else
		blockedPlots = {}
		clearAllWalls()
		warn("[PlotBlockBarrier] Failed to load blocked plots: " .. tostring(result))
	end
end

-- Listen for server updates (block/unblock events)
BlockedPlotsChanged.OnClientEvent:Connect(function(newBoundaries)
	blockedPlots = newBoundaries or {}
	rebuildWalls()
end)

-- Initial load
task.spawn(function()
	task.wait(2)
	loadBlockedPlots()
end)

print("[PlotBlockBarrier] Loaded")
