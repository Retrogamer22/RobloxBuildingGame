--[[
	BuildingController
	Minecraft-style: highlight block you're looking at, click to place adjacent
	No ghost preview - server handles all placement logic
	EXCEPTION: Slabs and Doors have ghost previews due to complex orientation
	
	CLIENT PREDICTION: Breaking and placing give instant visual feedback.
	Server is authoritative but client predicts results for responsiveness.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local NetherConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("NetherConfig", 10))
local StairPlacement = require(ReplicatedStorage:WaitForChild("StairPlacement", 10))
local LogPlacement = require(ReplicatedStorage:WaitForChild("LogPlacement", 10))
local SlabPlacement = require(ReplicatedStorage:WaitForChild("SlabPlacement", 10))
local DoorPlacement = require(ReplicatedStorage:WaitForChild("DoorPlacement", 10))
local SurfacePlacement = require(ReplicatedStorage:WaitForChild("SurfacePlacement", 10))
local GlassPlacement = require(ReplicatedStorage:WaitForChild("GlassPlacement", 10))
local FencePlacement = require(ReplicatedStorage:WaitForChild("FencePlacement", 10))
local LadderPlacement = require(ReplicatedStorage:WaitForChild("LadderPlacement", 10))
local VinePlacement = require(ReplicatedStorage:WaitForChild("VinePlacement", 10))
local TorchPlacement = require(ReplicatedStorage:WaitForChild("TorchPlacement", 10))
local LanternPlacement = require(ReplicatedStorage:WaitForChild("LanternPlacement", 10))
local SignPlacement = require(ReplicatedStorage:WaitForChild("SignPlacement", 10))
local WallpaperPlacement = require(ReplicatedStorage:WaitForChild("WallpaperPlacement", 10))
local ClientPrediction = require(ReplicatedStorage:WaitForChild("ClientPrediction", 10))

local BlockTemplates = ReplicatedStorage:WaitForChild("BlockTemplates", 10)
local BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlaceBlock = Remotes:WaitForChild("PlaceBlock", 10)
local RemoveBlock = Remotes:WaitForChild("RemoveBlock", 10)
local RemoveBlockAtPosition = Remotes:WaitForChild("RemoveBlockAtPosition", 10)
local PressButton = Remotes:WaitForChild("PressButton", 5)
local RequestSignInteraction = Remotes:WaitForChild("RequestSignInteraction", 15)
local ToggleFenceConnection = Remotes:WaitForChild("ToggleFenceConnection", 5)
local StackSnowLayer = Remotes:WaitForChild("StackSnowLayer", 5)
local BuildRejected = Remotes:WaitForChild("BuildRejected", 5)
local GetMySharedAccessList = Remotes:WaitForChild("GetMySharedAccessList", 5)
local SharedAccessChanged = Remotes:WaitForChild("SharedAccessChanged", 5)

-- Water bucket remotes
local PlaceWater = Remotes:WaitForChild("PlaceWater", 5)
local PickupWater = Remotes:WaitForChild("PickupWater", 5)

-- Frame block remotes
local FillFrameBlock = Remotes:WaitForChild("FillFrameBlock", 5)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local REACH_DISTANCE = 50
local BREAK_TIME = 0.3
local PLACE_RATE = 0.15 -- Time between continuous placements when holding

-- Ghost preview settings
local GHOST_TRANSPARENCY = 0.5

-- State
local LastRaycastResult = nil
local CurrentLogAxis = "Y"
local CurrentSlabOrientation = "bottom"
local CurrentDecorationOffset = Vector3.new(0, 0, 0)
local DECORATION_MAX_OFFSET = 0.8

local NoOffsetDecorations = {
	["SugarCane"] = true,
	["Cactus"] = true,
	["Torch"] = true,
	["Campfire"] = true,
	["Lantern"] = true,
}

local CurrentDoorDirection = 0
local CurrentDoorDepth = "middle"
local CurrentDoorHingeSide = "left"
local CurrentSurfaceData = nil
local CurrentGlassOrientation = "NS"

-- Breaking state
local BreakingState = {
	isBreaking = false,
	target = nil,
	progress = 0,
	timeRequired = BREAK_TIME,
}

-- Fire is extinguished by a single break action (no hold, no crack overlay).
-- Track fires we've already told the server to remove so that holding the
-- mouse button down doesn't re-fire RemoveBlock every frame before the block
-- actually disappears.
local ExtinguishedFires = setmetatable({}, { __mode = "k" })

-- Slab ghost preview state
local SlabGhost = {
	model = nil,
	currentOrientation = nil,
	currentPosition = nil,
	currentBlockType = nil,
}

-- Door ghost preview state
local DoorGhost = {
	model = nil,
	currentDirection = nil,
	currentDepth = nil,
	currentHingeSide = nil,
	currentPosition = nil,
	currentBlockType = nil,
}

-- UI elements
local BreakProgressUI = nil
local ProgressFill = nil
local SelectionBox = nil
local SelectionBoundingBox = nil -- Invisible part that defines the outline shape
local CurrentSelectionTarget = nil -- Track which block we're highlighting

-- Input state
local MouseDown = false
local RightMouseDown = false
local RightMouseHoldStart = 0 -- Track when right mouse was pressed
local PlaceCooldown = 0 -- Cooldown timer for continuous placement
local HOLD_THRESHOLD_FOR_CONTINUOUS = 0.25 -- Must hold this long before continuous placement kicks in
local PredictionCleanupTimer = 0
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Touch state
local TouchState = {
	activeId = nil,
	startTime = nil,
	startPos = nil,
	isHeld = false,
	movedTooMuch = false,
}
local TOUCH_MOVE_THRESHOLD = 15
local HOLD_TIME_TO_BREAK = 0.3
local TAP_MAX_TIME = 0.25

task.wait(0.5)

-- ============================================
-- UI CREATION
-- ============================================

local function createBreakProgressUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BreakProgressGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = PlayerGui
	
	local progressFrame = Instance.new("Frame")
	progressFrame.Name = "ProgressFrame"
	progressFrame.Size = UDim2.new(0, 60, 0, 8)
	progressFrame.Position = UDim2.new(0.5, -30, 0.5, 25)
	progressFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	progressFrame.BorderSizePixel = 0
	progressFrame.Visible = false
	progressFrame.Parent = screenGui
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = progressFrame
	
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 80, 80)
	stroke.Thickness = 1
	stroke.Parent = progressFrame
	
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	fill.BorderSizePixel = 0
	fill.Parent = progressFrame
	
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill
	
	BreakProgressUI = progressFrame
	ProgressFill = fill
end

local function createSelectionBox()
	-- Create an invisible bounding box part for the wireframe to adorn
	local bbox = Instance.new("Part")
	bbox.Name = "SelectionBoundingBox"
	bbox.Anchored = true
	bbox.CanCollide = false
	bbox.CanQuery = false
	bbox.CanTouch = false
	bbox.Transparency = 1
	bbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
	bbox.Parent = workspace
	SelectionBoundingBox = bbox
	
	-- Use SelectionBox for a clean wireframe outline
	local selBox = Instance.new("SelectionBox")
	selBox.Name = "BlockSelectionWireframe"
	selBox.Color3 = Color3.fromRGB(0, 0, 0)
	selBox.LineThickness = 0.02
	selBox.Transparency = 0.2
	selBox.SurfaceTransparency = 1 -- No fill, wireframe only
	selBox.SurfaceColor3 = Color3.fromRGB(0, 0, 0)
	selBox.Adornee = bbox
	selBox.Parent = bbox
	SelectionBox = selBox
end

-- Get the bounding box (CFrame + Size) of a block (BasePart or Model)
-- Excludes invisible Hitbox parts so wireframe matches the visual block shape
local function getBlockBoundingBox(block)
	if block:IsA("BasePart") then
		return block.CFrame, block.Size
	elseif block:IsA("Model") then
		-- Collect only visual parts (exclude Hitbox)
		-- For chests: exclude Latch (sticks out), Top lid when open
		local isChest = block:GetAttribute("IsChest")
		local isOpenChest = isChest and block:GetAttribute("IsOpen")
		local topModel = isOpenChest and block:FindFirstChild("Top") or nil
		local parts = {}
		for _, desc in block:GetDescendants() do
			if desc:IsA("BasePart") and desc.Name ~= "Hitbox" then
				-- Skip lid parts when chest is open
				if topModel and desc:IsDescendantOf(topModel) then
					continue
				end
				-- Skip Latch parts on chests (they stick out and make the highlight too big)
				if isChest then
					local ancestor = desc.Parent
					local isLatch = false
					while ancestor and ancestor ~= block do
						if ancestor.Name == "Latch" then isLatch = true; break end
						ancestor = ancestor.Parent
					end
					if not isLatch and desc.Name == "Latch" then isLatch = true end
					if isLatch then continue end
				end
				table.insert(parts, desc)
			end
		end
		if #parts == 0 then
			return block:GetBoundingBox()
		end
		-- Compute axis-aligned bounding box from visual parts only
		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for _, part in parts do
			local cf = part.CFrame
			local sx, sy, sz = part.Size.X / 2, part.Size.Y / 2, part.Size.Z / 2
			for _, offset in {
				Vector3.new(sx, sy, sz), Vector3.new(-sx, sy, sz),
				Vector3.new(sx, -sy, sz), Vector3.new(-sx, -sy, sz),
				Vector3.new(sx, sy, -sz), Vector3.new(-sx, sy, -sz),
				Vector3.new(sx, -sy, -sz), Vector3.new(-sx, -sy, -sz)
			} do
				local worldPos = cf:PointToWorldSpace(offset)
				minX = math.min(minX, worldPos.X)
				minY = math.min(minY, worldPos.Y)
				minZ = math.min(minZ, worldPos.Z)
				maxX = math.max(maxX, worldPos.X)
				maxY = math.max(maxY, worldPos.Y)
				maxZ = math.max(maxZ, worldPos.Z)
			end
		end
		local center = CFrame.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
		local boxSize = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
		return center, boxSize
	end
	return nil, nil
end

createBreakProgressUI()
createSelectionBox()

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getBlocksFolder()
	local plotData = _G.PlotClient and _G.PlotClient.GetMyPlot()
	if plotData and plotData.BuildArea then
		return plotData.BuildArea:FindFirstChild("Blocks")
	end
	return nil
end

local function getBasePlate()
	local plotData = _G.PlotClient and _G.PlotClient.GetMyPlot()
	return plotData and plotData.BasePlate
end

-- Get basePlate data for ANY plot at a given position (for shared building)
local function getBasePlateAtPosition(position)
	-- In MegaPlot mode, always use MegaPlotBuildArea for grid alignment
	if _G.PlotClient and _G.PlotClient.IsMegaPlotMode and _G.PlotClient.IsMegaPlotMode() then
		local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then
			local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
			if megaBuildArea then
				local posX = megaBuildArea:GetAttribute("BasePlatePositionX")
				local posZ = megaBuildArea:GetAttribute("BasePlatePositionZ")
				local sizeX = megaBuildArea:GetAttribute("BasePlateSizeX")
				local sizeZ = megaBuildArea:GetAttribute("BasePlateSizeZ")
				local plateTop = megaBuildArea:GetAttribute("BasePlateTop")
				
				if posX and posZ and sizeX and sizeZ and plateTop then
					local sizeY = 3
					local posY = plateTop - sizeY / 2
					return {
						Position = Vector3.new(posX, posY, posZ),
						Size = Vector3.new(sizeX, sizeY, sizeZ),
					}
				end
			end
		end
	end
	
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local posX = buildArea:GetAttribute("BasePlatePositionX")
			local posY = buildArea:GetAttribute("BasePlatePositionY")
			local posZ = buildArea:GetAttribute("BasePlatePositionZ")
			local sizeX = buildArea:GetAttribute("BasePlateSizeX")
			local sizeY = buildArea:GetAttribute("BasePlateSizeY")
			local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
			
			if posX and posY and posZ and sizeX and sizeY and sizeZ then
				local halfX = sizeX / 2
				local halfZ = sizeZ / 2
				
				-- Check if position is within this plot's bounds
				if position.X >= posX - halfX and position.X <= posX + halfX and
				   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
					return {
						Position = Vector3.new(posX, posY, posZ),
						Size = Vector3.new(sizeX, sizeY, sizeZ),
					}
				end
			end
		end
	end

	-- NetherPlots: snap to the NETHER baseplate's own grid origin so placed blocks
	-- line up with the portal (which the server built relative to NetherPlot{N}).
	-- Without this, nether placement falls through to the overworld plate below
	-- and snaps to the wrong grid.
	for i = 1, GridConfig.TOTAL_PLOTS do
		local netherPlot = workspace:FindFirstChild(NetherConfig.NETHER_PLOT_PREFIX .. i)
		if netherPlot then
			local posX = netherPlot:GetAttribute("BasePlatePositionX")
			local posY = netherPlot:GetAttribute("BasePlatePositionY")
			local posZ = netherPlot:GetAttribute("BasePlatePositionZ")
			local sizeX = netherPlot:GetAttribute("BasePlateSizeX")
			local sizeY = netherPlot:GetAttribute("BasePlateSizeY")
			local sizeZ = netherPlot:GetAttribute("BasePlateSizeZ")
			if not (posX and posY and posZ and sizeX and sizeY and sizeZ) and netherPlot:IsA("BasePart") then
				posX, posY, posZ = netherPlot.Position.X, netherPlot.Position.Y, netherPlot.Position.Z
				sizeX, sizeY, sizeZ = netherPlot.Size.X, netherPlot.Size.Y, netherPlot.Size.Z
			end
			if posX and posY and posZ and sizeX and sizeY and sizeZ then
				local halfX = sizeX / 2
				local halfZ = sizeZ / 2
				if position.X >= posX - halfX and position.X <= posX + halfX and
				   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
					return {
						Position = Vector3.new(posX, posY, posZ),
						Size = Vector3.new(sizeX, sizeY, sizeZ),
					}
				end
			end
		end
	end

	-- Fallback to local player's basePlate
	return getBasePlate()
end

local function snapToGrid(position, basePlate)
	if not basePlate then
		local x = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
		local y = math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE
		local z = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
		return Vector3.new(x, y, z)
	end
	
	local platePos = basePlate.Position
	local plateSize = basePlate.Size
	local plateTop = platePos.Y + plateSize.Y / 2
	
	local originX = platePos.X - plateSize.X / 2 + BLOCK_SIZE / 2
	local originZ = platePos.Z - plateSize.Z / 2 + BLOCK_SIZE / 2
	local surfaceY = plateTop - BLOCK_SIZE / 2
	
	local relX = position.X - originX
	local relY = position.Y - surfaceY
	local relZ = position.Z - originZ
	
	local gridX = math.round(relX / BLOCK_SIZE) * BLOCK_SIZE + originX
	local gridY = math.round(relY / BLOCK_SIZE) * BLOCK_SIZE + surfaceY
	local gridZ = math.round(relZ / BLOCK_SIZE) * BLOCK_SIZE + originZ
	
	return Vector3.new(gridX, gridY, gridZ)
end

local function getCameraLookVector()
	return Camera.CFrame.LookVector
end

local function isInMyPlot(position)
	local basePlate = getBasePlate()
	if not basePlate then return false end
	
	local platePos = basePlate.Position
	local plateSize = basePlate.Size
	local halfX = plateSize.X / 2
	local halfZ = plateSize.Z / 2
	
	if position.X < platePos.X - halfX or position.X > platePos.X + halfX then return false end
	if position.Z < platePos.Z - halfZ or position.Z > platePos.Z + halfZ then return false end
	
	local plateTop = platePos.Y + plateSize.Y / 2
	local terrainDepth = GridConfig.TERRAIN and GridConfig.TERRAIN.MAX_DEPTH or 20
	local minY = plateTop - (terrainDepth * BLOCK_SIZE) - BLOCK_SIZE
	local maxY = plateTop + GridConfig.PLOT_HEIGHT
	if position.Y < minY or position.Y > maxY then return false end
	
	return true
end

local function isInventoryOpen()
	return _G.InventoryController and _G.InventoryController.IsInventoryOpen and _G.InventoryController.IsInventoryOpen()
end

local function isBlockUIOpen()
	return _G.BlockInteractionController and _G.BlockInteractionController.IsAnyBlockUIOpen and _G.BlockInteractionController.IsAnyBlockUIOpen()
end

local function isWiringToolSelected()
	if _G.InventoryController and _G.InventoryController.GetSelectedBlock then
		local selected = _G.InventoryController.GetSelectedBlock()
		if not selected then return false end
		-- Water buckets are tools but need full input (not wiring tools)
		if selected.IsWaterBucket or selected.IsEmptyBucket then return false end
		return selected.IsWiringTool or selected.IsTool
	end
	return false
end

-- ============================================
-- PLOT BUILD PERMISSION (client-side pre-check)
-- Prevents predictions from even firing on plots we can't build on
-- ============================================

local sharedAccessOwners = {} -- { [ownerUserId] = true } — owners who shared their plot with us

-- Fetch initial shared access list from server
task.spawn(function()
	task.wait(2) -- Wait for server permissions to load
	if GetMySharedAccessList then
		local success, result = pcall(function()
			return GetMySharedAccessList:InvokeServer()
		end)
		if success and result then
			for _, ownerUserId in ipairs(result) do
				sharedAccessOwners[ownerUserId] = true
			end
			print("[BuildPermission] Loaded shared access from " .. #result .. " owner(s)")
		end
	end
end)

-- Listen for real-time changes
if SharedAccessChanged then
	SharedAccessChanged.OnClientEvent:Connect(function(ownerUserId, hasAccess)
		if hasAccess then
			sharedAccessOwners[ownerUserId] = true
			print("[BuildPermission] Gained build access on plot owned by " .. tostring(ownerUserId))
		else
			sharedAccessOwners[ownerUserId] = nil
			print("[BuildPermission] Lost build access on plot owned by " .. tostring(ownerUserId))
		end
	end)
end

-- Check if the local player can interact (break/place) at a world position
local function canInteractAtPosition(position)
	if not position then return false end
	
	-- Private server: everyone can build on all plots
	local isPrivate = false
	pcall(function() isPrivate = game.PrivateServerId ~= "" end)
	if isPrivate then return true end
	
	-- MegaPlot mode: everyone can build
	if _G.PlotClient and _G.PlotClient.IsMegaPlotMode and _G.PlotClient.IsMegaPlotMode() then
		return true
	end
	
	-- Find which plot this position is on
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local posX = buildArea:GetAttribute("BasePlatePositionX")
			local posZ = buildArea:GetAttribute("BasePlatePositionZ")
			local sizeX = buildArea:GetAttribute("BasePlateSizeX")
			local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
			
			if posX and posZ and sizeX and sizeZ then
				local halfX = sizeX / 2
				local halfZ = sizeZ / 2
				if position.X >= posX - halfX and position.X <= posX + halfX and
				   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
					-- Position is on this plot — check ownership/sharing
					local ownerUserId = buildArea:GetAttribute("OwnerUserId")
					if not ownerUserId then return false end
					if ownerUserId == LocalPlayer.UserId then return true end
					if sharedAccessOwners[ownerUserId] then return true end
					return false -- On someone else's plot, no access
				end
			end
		end
	end

	-- NetherPlot check: NetherPlot{N} pairs with BuildArea{N}. Access mirrors the
	-- overworld plot's owner/sharing, so you can build in your own nether (and so
	-- can anyone you've shared the overworld plot with). Uses the part's geometry
	-- since NetherPlots may be bare baseplates without cached attributes.
	for i = 1, GridConfig.TOTAL_PLOTS do
		local netherPlot = workspace:FindFirstChild(NetherConfig.NETHER_PLOT_PREFIX .. i)
		if netherPlot then
			local posX = netherPlot:GetAttribute("BasePlatePositionX")
			local posZ = netherPlot:GetAttribute("BasePlatePositionZ")
			local sizeX = netherPlot:GetAttribute("BasePlateSizeX")
			local sizeZ = netherPlot:GetAttribute("BasePlateSizeZ")
			if not (posX and posZ and sizeX and sizeZ) and netherPlot:IsA("BasePart") then
				posX, posZ = netherPlot.Position.X, netherPlot.Position.Z
				sizeX, sizeZ = netherPlot.Size.X, netherPlot.Size.Z
			end
			if posX and posZ and sizeX and sizeZ then
				local halfX = sizeX / 2
				local halfZ = sizeZ / 2
				if position.X >= posX - halfX and position.X <= posX + halfX and
				   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
					-- On this nether plot — derive access from the paired overworld plot.
					local overworld = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
					if overworld then
						local ownerUserId = overworld:GetAttribute("OwnerUserId")
						if ownerUserId == LocalPlayer.UserId then return true end
						if ownerUserId and sharedAccessOwners[ownerUserId] then return true end
					end
					return false
				end
			end
		end
	end

	-- Not on any plot
	return false
end

-- Helper: get grid position from a block instance (for permission checks)
local function getBlockWorldPosition(block)
	if not block then return nil end
	local bpx = block:GetAttribute("BlockPosX") or block:GetAttribute("GridPosX")
	local bpy = block:GetAttribute("BlockPosY") or block:GetAttribute("GridPosY")
	local bpz = block:GetAttribute("BlockPosZ") or block:GetAttribute("GridPosZ")
	if bpx and bpy and bpz then
		return Vector3.new(bpx, bpy, bpz)
	end
	if block:IsA("BasePart") then
		return block:GetPivot().Position
	elseif block:IsA("Model") then
		return block:GetPivot().Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
	end
	return nil
end

-- ============================================
-- SLAB GHOST PREVIEW
-- ============================================

local function clearSlabGhost()
	if SlabGhost.model then
		SlabGhost.model:Destroy()
		SlabGhost.model = nil
	end
	SlabGhost.currentOrientation = nil
	SlabGhost.currentPosition = nil
	SlabGhost.currentBlockType = nil
end

local function createSlabGhost(blockType)
	-- Clear existing ghost
	clearSlabGhost()
	
	-- Get the slab template
	local template = BlockTemplates:FindFirstChild("Slab")
	if not template then return nil end
	
	-- Clone and set up as ghost
	local ghost = template:Clone()
	ghost.Name = "SlabGhost"
	
	-- Make ghost transparent and non-collidable
	if ghost:IsA("BasePart") then
		ghost.Transparency = GHOST_TRANSPARENCY
		ghost.CanCollide = false
		ghost.CanQuery = false
		ghost.CastShadow = false
	elseif ghost:IsA("Model") then
		for _, part in ipairs(ghost:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Transparency = GHOST_TRANSPARENCY
				part.CanCollide = false
				part.CanQuery = false
				part.CastShadow = false
			end
		end
	end
	
	-- Get the preset color for this slab type
	local preset = BlockPresets.GetPreset(blockType)
	if preset and preset.DefaultColor then
		if ghost:IsA("BasePart") then
			ghost.Color = preset.DefaultColor
		elseif ghost:IsA("Model") then
			for _, part in ipairs(ghost:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Color = preset.DefaultColor
				end
			end
		end
	end
	
	ghost.Parent = workspace
	SlabGhost.model = ghost
	SlabGhost.currentBlockType = blockType
	
	return ghost
end

local function updateSlabGhost(position, orientation, blockType)
	-- Check if we need to create/recreate the ghost
	if not SlabGhost.model or SlabGhost.currentBlockType ~= blockType then
		createSlabGhost(blockType)
	end
	
	if not SlabGhost.model then return end
	
	-- Get the CFrame for this orientation
	local cframe = SlabPlacement.GetSlabCFrame(position, orientation)
	
	-- Apply offset for model (bottom-center pivot)
	if SlabGhost.model:IsA("Model") then
		local offsetCFrame = cframe * CFrame.new(0, -BLOCK_SIZE / 2, 0)
		SlabGhost.model:PivotTo(offsetCFrame)
	else
		SlabGhost.model.CFrame = cframe
	end
	
	SlabGhost.currentOrientation = orientation
	SlabGhost.currentPosition = position
end

-- ============================================
-- DOOR GHOST PREVIEW
-- ============================================

local function clearDoorGhost()
	if DoorGhost.model then
		DoorGhost.model:Destroy()
		DoorGhost.model = nil
	end
	DoorGhost.currentDirection = nil
	DoorGhost.currentDepth = nil
	DoorGhost.currentHingeSide = nil
	DoorGhost.currentPosition = nil
	DoorGhost.currentBlockType = nil
end

local function createDoorGhost(blockType)
	-- Clear existing ghost
	clearDoorGhost()
	
	-- Get the door template (try Blocks folder first where actual door models are)
	local BlocksFolder = ReplicatedStorage:FindFirstChild("Blocks")
	local FrameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")
	local template = nil
	
	-- Try FrameBlocks folder for frame doors
	if FrameBlocksFolder and BlockPresets.IsFrameBlock(blockType) then
		template = FrameBlocksFolder:FindFirstChild(blockType)
	end
	
	-- Try specific door in Blocks folder
	if not template and BlocksFolder then
		template = BlocksFolder:FindFirstChild(blockType)
	end
	
	-- Fallback to BlockTemplates
	if not template then
		template = BlockTemplates:FindFirstChild(blockType) or BlockTemplates:FindFirstChild("Door")
	end
	
	if not template then return nil end
	
	-- Clone and set up as ghost
	local ghost = template:Clone()
	ghost.Name = "DoorGhost"
	
	-- Make ghost transparent and non-collidable
	if ghost:IsA("BasePart") then
		ghost.Transparency = GHOST_TRANSPARENCY
		ghost.CanCollide = false
		ghost.CanQuery = false
		ghost.CastShadow = false
	elseif ghost:IsA("Model") then
		for _, part in ipairs(ghost:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Transparency = GHOST_TRANSPARENCY
				part.CanCollide = false
				part.CanQuery = false
				part.CastShadow = false
			end
		end
	end
	
	-- Get the preset color for this door type
	local preset = BlockPresets.GetPreset(blockType)
	if preset and preset.DefaultColor then
		if ghost:IsA("BasePart") then
			ghost.Color = preset.DefaultColor
		elseif ghost:IsA("Model") then
			for _, part in ipairs(ghost:GetDescendants()) do
				if part:IsA("BasePart") then
					-- Only color the door panel, not hardware (hinges/knobs keep template appearance)
					if part.Name == "Hinge" or part.Name == "Knob" then
						continue
					end
					part.Color = preset.DefaultColor
				end
			end
		end
	end
	
	ghost.Parent = workspace
	DoorGhost.model = ghost
	DoorGhost.currentBlockType = blockType
	
	return ghost
end

local function updateDoorGhost(position, direction, depth, hingeSide, blockType)
	-- Check if we need to create/recreate the ghost
	if not DoorGhost.model or DoorGhost.currentBlockType ~= blockType then
		createDoorGhost(blockType)
	end
	
	if not DoorGhost.model then return end
	
	-- Get the CFrame for this door configuration
	local cframe = DoorPlacement.GetDoorCFrame(position, direction, depth, hingeSide)
	
	-- Apply offset for model (bottom-center pivot) - doors are 2 blocks tall
	if DoorGhost.model:IsA("Model") then
		local isFrameDoor = BlockPresets.IsFrameBlock(blockType)
		if isFrameDoor then
			-- Frame door models have pivot at bounding box center, not bottom-center
			-- and the Union part is pre-rotated 90° around Y, so we compensate
			local _, bbSize = DoorGhost.model:GetBoundingBox()
			local pivotY = DoorGhost.model.WorldPivot.Position.Y
			local bbCFrame = DoorGhost.model:GetBoundingBox()
			local bbBottomY = bbCFrame.Position.Y - bbSize.Y / 2
			local pivotToBottom = pivotY - bbBottomY
			local offsetCFrame = cframe * CFrame.Angles(0, math.rad(90), 0) * CFrame.new(0, -BLOCK_SIZE / 2 + pivotToBottom, 0)
			DoorGhost.model:PivotTo(offsetCFrame)
		else
			-- Regular door models have pivot at bottom-center
			local offsetCFrame = cframe * CFrame.new(0, -BLOCK_SIZE / 2, 0)
			DoorGhost.model:PivotTo(offsetCFrame)
		end
	else
		DoorGhost.model.CFrame = cframe
	end
	
	DoorGhost.currentDirection = direction
	DoorGhost.currentDepth = depth
	DoorGhost.currentHingeSide = hingeSide
	DoorGhost.currentPosition = position
end

-- ============================================
-- RAYCASTING
-- ============================================

local function raycastForBlock()
	-- Compute the ray origin + unit direction. First person uses the screen-
	-- center camera ray (full vertical freedom). Third person uses the head's
	-- horizontal forward direction — because the 3P camera is angled down at
	-- the player, a screen-center ray would point at the ground in front of
	-- the player and you couldn't interact with doors/blocks in front of you.
	local origin, direction
	do
		local isFirstPerson = _G.CameraController and _G.CameraController.IsFirstPerson and _G.CameraController.IsFirstPerson()
		local character = LocalPlayer.Character
		local head = character and character:FindFirstChild("Head")
		if isFirstPerson or not head then
			local viewportSize = Camera.ViewportSize
			local vpRay = Camera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
			origin, direction = vpRay.Origin, vpRay.Direction
		else
			local look = Camera.CFrame.LookVector
			local horizontalLook = Vector3.new(look.X, 0, look.Z)
			if horizontalLook.Magnitude < 0.01 then
				horizontalLook = Vector3.new(0, 0, -1)
			else
				horizontalLook = horizontalLook.Unit
			end
			origin, direction = head.Position, horizontalLook
		end
	end
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	
	-- Exclude player character, ghost previews, and prediction blocks
	local filterList = {LocalPlayer.Character}
	if SlabGhost.model then
		table.insert(filterList, SlabGhost.model)
	end
	if DoorGhost.model then
		table.insert(filterList, DoorGhost.model)
	end
	-- NOTE: ClientPredictions folder is NOT excluded from raycasts.
	-- Terrain prediction blocks are targetable so the player can keep digging
	-- without waiting for server round-trips to spawn real blocks.
	raycastParams.FilterDescendantsInstances = filterList
	
	-- Check if we're holding a bucket (EmptyBucket targets water for pickup, WaterBucket targets water to convert flowing→source)
	local blockData = _G.InventoryController and _G.InventoryController.GetSelectedBlock()
	local isEmptyBucket = blockData and blockData.IsEmptyBucket
	local isWaterBucket = blockData and blockData.IsWaterBucket
	local isBucketTool = isEmptyBucket or isWaterBucket
	
	-- Raycast loop: if we hit water and aren't holding a bucket,
	-- add the water block to the filter and re-cast through it.
	-- EmptyBucket: stops at SOURCE water only (passes through flowing)
	-- WaterBucket: stops at ANY water (to convert flowing->source) or passes through to place on blocks below
	local MAX_PASSES = 20 -- Safety limit
	for _ = 1, MAX_PASSES do
		local result = workspace:Raycast(origin, direction * REACH_DISTANCE, raycastParams)
		if not result or not result.Instance then
			return result
		end
		
		-- Check if we hit a water block
		local hitBlock = result.Instance
		if not hitBlock:GetAttribute("IsWater") then
			-- Check parent (water might be a child part)
			if hitBlock.Parent and hitBlock.Parent:GetAttribute("IsWater") then
				hitBlock = hitBlock.Parent
			else
				-- Not water, return the result
				return result
			end
		end
		
		-- Hit water block
		local waterLevel = hitBlock:GetAttribute("WaterLevel") or 0
		
		if isEmptyBucket then
			-- EmptyBucket: only stop at source blocks (level 0), pass through flowing
			if waterLevel == 0 then
				return result
			end
			-- Flowing water: skip through to reach source behind/below it
			table.insert(filterList, hitBlock)
			raycastParams.FilterDescendantsInstances = filterList
			continue
		end
		
		if isWaterBucket then
			-- WaterBucket: stop at ANY water (to convert flowing->source or reject placing on source)
			return result
		end
		
		-- Not a bucket: skip through water by adding to filter
		table.insert(filterList, hitBlock)
		raycastParams.FilterDescendantsInstances = filterList
	end
	
	return nil -- Exhausted passes (shouldn't happen normally)
end

local function getBlockTarget()
	local result = raycastForBlock()
	LastRaycastResult = result
	
	if result and result.Instance then
		local hit = result.Instance
		local block = nil
		if hit:GetAttribute("BlockType") then
			block = hit
		elseif hit.Parent and hit.Parent:GetAttribute("BlockType") then
			block = hit.Parent
		elseif hit.Parent and hit.Parent.Parent and hit.Parent.Parent:GetAttribute("BlockType") then
			block = hit.Parent.Parent
		end
		
		-- Skip blocks that are hidden by client prediction (already being destroyed)
		if block and ClientPrediction.IsBlockHidden(block) then
			return nil, result
		end
		
		if block then return block, result end
	end
	
	return nil, result
end

local function getHitBlockGridPosition(result)
	if not result then return nil end
	
	local hitInstance = result.Instance
	local hitBlock = nil
	
	if hitInstance:GetAttribute("BlockType") then
		hitBlock = hitInstance
	elseif hitInstance.Parent and hitInstance.Parent:GetAttribute("BlockType") then
		hitBlock = hitInstance.Parent
	elseif hitInstance.Parent and hitInstance.Parent.Parent and hitInstance.Parent.Parent:GetAttribute("BlockType") then
		hitBlock = hitInstance.Parent.Parent
	end
	
	if not hitBlock then return nil end
	
	local hitBlockPos
	
	-- For Models that store their grid position as attributes (beds, chests, crafting tables,
	-- and any other multi-part block with an internal Hitbox), trust the stored values.
	-- This avoids `:FindFirstChildWhichIsA("BasePart")` returning the Hitbox part, whose
	-- position is the midpoint of multi-cell blocks rather than the actual grid cell.
	if hitBlock:IsA("Model") then
		local storedX = hitBlock:GetAttribute("BlockPosX")
		local storedY = hitBlock:GetAttribute("BlockPosY")
		local storedZ = hitBlock:GetAttribute("BlockPosZ")
		if storedX and storedY and storedZ then
			hitBlockPos = Vector3.new(storedX, storedY, storedZ)

			-- Beds occupy two cells (head + foot). Pick whichever cell the raycast hit is
			-- physically closer to, so placement adjacent to either end works correctly.
			if hitBlock:GetAttribute("IsBed") then
				local secX = hitBlock:GetAttribute("BedSecondaryX")
				local secY = hitBlock:GetAttribute("BedSecondaryY")
				local secZ = hitBlock:GetAttribute("BedSecondaryZ")
				if secX and secY and secZ then
					local footPos = Vector3.new(secX, secY, secZ)
					local hitWorldPos = result.Position
					if (hitWorldPos - footPos).Magnitude < (hitWorldPos - hitBlockPos).Magnitude then
						hitBlockPos = footPos
					end
				end
			end

			-- Double chests also span two cells (same pattern as beds). Pick whichever
			-- cell the raycast hit is closer to so wall-sign placement (and any other
			-- adjacent-cell operation) targets the correct half.
			if hitBlock:GetAttribute("IsDoubleChest") then
				local secX = hitBlock:GetAttribute("ChestSecondaryX")
				local secY = hitBlock:GetAttribute("ChestSecondaryY")
				local secZ = hitBlock:GetAttribute("ChestSecondaryZ")
				if secX and secY and secZ then
					local secondaryPos = Vector3.new(secX, secY, secZ)
					local hitWorldPos = result.Position
					if (hitWorldPos - secondaryPos).Magnitude < (hitWorldPos - hitBlockPos).Magnitude then
						hitBlockPos = secondaryPos
					end
				end
			end
		end
	end
	
	if hitBlockPos then
		-- Already resolved via stored attributes above.
	elseif hitBlock:IsA("BasePart") then
		-- Use stored grid position if available (e.g., SnowLayer has offset visual position)
		local storedX = hitBlock:GetAttribute("BlockPosX")
		local storedY = hitBlock:GetAttribute("BlockPosY")
		local storedZ = hitBlock:GetAttribute("BlockPosZ")
		if storedX and storedY and storedZ then
			hitBlockPos = Vector3.new(storedX, storedY, storedZ)
		else
			hitBlockPos = hitBlock.Position
		end
	elseif hitBlock:IsA("Model") then
		-- Use GetPivot for special blocks that need it
		if hitBlock:GetAttribute("IsGlass") or hitBlock:GetAttribute("IsFence") then
			hitBlockPos = hitBlock:GetPivot().Position
		else
			-- For logs with axis rotation, the model offset is applied in local space
			-- which shifts along the rotated axis. We need to compensate properly.
			local logAxis = hitBlock:GetAttribute("LogAxis")
			if logAxis and logAxis ~= "Y" and logAxis ~= "Y+" and logAxis ~= "Y-" then
				-- Sideways log - pivot is offset in world X or Z, not Y
				-- The server does: cframe * CFrame.new(0, -1.5, 0) which applies offset in local space
				-- For X-axis (90° Z rotation): local Y points to world +X, so -1.5 local Y = +1.5 world X
				-- For Z-axis (90° X rotation): local Y points to world +Z, so -1.5 local Y = -1.5 world Z
				-- To get grid center from pivot, we reverse the offset
				local pivotPos = hitBlock:GetPivot().Position
				if logAxis == "X" or logAxis == "X+" or logAxis == "X-" then
					-- Pivot was shifted +1.5 in world X, so subtract to get grid center
					hitBlockPos = pivotPos - Vector3.new(BLOCK_SIZE / 2, 0, 0)
				elseif logAxis == "Z" or logAxis == "Z+" or logAxis == "Z-" then
					-- Pivot was shifted -1.5 in world Z, so add to get grid center
					hitBlockPos = pivotPos + Vector3.new(0, 0, BLOCK_SIZE / 2)
				else
					hitBlockPos = pivotPos + Vector3.new(0, BLOCK_SIZE / 2, 0)
				end
			else
				-- Vertical log or other model - standard Y compensation
				local primary = hitBlock.PrimaryPart or hitBlock:FindFirstChildWhichIsA("BasePart")
				if primary then hitBlockPos = primary.Position end
			end
		end
	end
	
	if not hitBlockPos then return nil end
	
	-- Use the basePlate of the plot containing this block (for shared building)
	return snapToGrid(hitBlockPos, getBasePlateAtPosition(hitBlockPos)), hitBlock
end

local function getPlacementPosition(blockData)
	local result = LastRaycastResult
	if not result then return nil end
	
	-- Use the basePlate of the plot where we're placing (for shared building)
	local basePlate = getBasePlateAtPosition(result.Position)
	local hitBlockGridPos, hitBlock = getHitBlockGridPosition(result)
	
	local gridPos
	if hitBlockGridPos and hitBlock then
		local useNormal = result.Normal
		
		-- Glass is thin, so hitting from above should place on top
		if hitBlock:GetAttribute("IsGlass") then
			local glassTop = hitBlockGridPos.Y + BLOCK_SIZE / 2
			if result.Position.Y > (glassTop - 0.5) and Camera.CFrame.Position.Y > hitBlockGridPos.Y then
				useNormal = Vector3.new(0, 1, 0)
			end
		end
		
		gridPos = snapToGrid(hitBlockGridPos + useNormal * BLOCK_SIZE, basePlate)
	else
		gridPos = snapToGrid(result.Position + result.Normal * (BLOCK_SIZE / 2), basePlate)
	end
	
	-- Decorations go on top of the hit block (or inside snow layers)
	if blockData and blockData.IsDecoration and hitBlockGridPos then
		-- Check if targeting a SnowLayer with < 8 layers: place inside the snow
		if hitBlock and hitBlock:GetAttribute("BlockType") == "SnowLayer" then
			local snowLayers = hitBlock:GetAttribute("SnowLayers") or 1
			if snowLayers < 8 then
				-- Place decoration inside the snow layer's grid cell
				gridPos = hitBlockGridPos
			else
				-- Full 8-layer snow block, place on top
				gridPos = Vector3.new(hitBlockGridPos.X, hitBlockGridPos.Y + BLOCK_SIZE / 2, hitBlockGridPos.Z)
			end
		else
			gridPos = Vector3.new(hitBlockGridPos.X, hitBlockGridPos.Y + BLOCK_SIZE / 2, hitBlockGridPos.Z)
		end
	end
	
	return gridPos
end

local function getHitBlockPosition()
	if not LastRaycastResult then return nil end
	
	local hitInstance = LastRaycastResult.Instance
	
	if hitInstance:GetAttribute("BlockType") then
		if hitInstance:IsA("BasePart") then return hitInstance.Position end
		local p = hitInstance.PrimaryPart or hitInstance:FindFirstChildWhichIsA("BasePart")
		return p and p.Position
	elseif hitInstance.Parent and hitInstance.Parent:GetAttribute("BlockType") then
		local parentBlock = hitInstance.Parent
		if parentBlock:IsA("BasePart") then return parentBlock.Position end
		local p = parentBlock.PrimaryPart or parentBlock:FindFirstChildWhichIsA("BasePart")
		return p and p.Position
	end
	
	return LastRaycastResult.Position
end

-- ============================================
-- BREAKING SYSTEM
-- ============================================

local CrackOverlays = {}

local function clearCrackOverlays()
	for _, overlay in pairs(CrackOverlays) do
		if overlay and overlay.Parent then overlay:Destroy() end
	end
	CrackOverlays = {}
end

local function createCrackOverlaysForBlock(block)
	clearCrackOverlays()
	if not block or not block.Parent then return end
	
	local targetPart = block
	if block:IsA("Model") then
		targetPart = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
	end
	if not targetPart then return end
	
	local faces = {Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Top, Enum.NormalId.Bottom}
	
	for _, face in ipairs(faces) do
		local surfaceGui = Instance.new("SurfaceGui")
		surfaceGui.Name = "CrackOverlay_" .. face.Name
		surfaceGui.Face = face
		surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		surfaceGui.PixelsPerStud = 32
		surfaceGui.LightInfluence = 0
		surfaceGui.Adornee = targetPart
		surfaceGui.Parent = PlayerGui
		
		local overlay = Instance.new("Frame")
		overlay.Name = "Overlay"
		overlay.Size = UDim2.new(1, 0, 1, 0)
		overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		overlay.BackgroundTransparency = 1
		overlay.BorderSizePixel = 0
		overlay.Parent = surfaceGui
		
		CrackOverlays[face.Name] = surfaceGui
	end
end

local function startBreaking(target)
	if not target then return end
	
	-- Water blocks can't be broken by hand - use Empty Bucket to pick up sources
	if target:GetAttribute("IsWater") then return end
	
	-- Check permission before starting break
	local targetPos = getBlockWorldPosition(target)
	if not canInteractAtPosition(targetPos) then return end
	
	-- FIRE: a single break action puts it out instantly. No hold, no crack
	-- overlay, no progress bar - just hide it and tell the server once.
	if target:GetAttribute("IsFire") or target:GetAttribute("BlockType") == "Fire" then
		if ExtinguishedFires[target] then return end -- already extinguishing this one
		ExtinguishedFires[target] = true
		-- Tell the server first (it does its own authoritative destroy), then
		-- destroy the model LOCALLY right away. We don't wait for the server's
		-- removal to replicate back -- that round-trip was taking ~1.25s, and the
		-- teardown of this heavy model (SurfaceGuis, the flame animation script,
		-- ember textures, etc.) was hitting all at once a beat AFTER the click,
		-- which is the stutter. Destroying locally moves that cost to click-time,
		-- where the feedback is expected, and the screen clears instantly.
		local _fxStart = os.clock()
		local _fxDesc = #target:GetDescendants()
		if RemoveBlock then
			RemoveBlock:FireServer(target, LastRaycastResult and LastRaycastResult.Position)
		end
		pcall(function()
			target:Destroy()
		end)
		local _ms = (os.clock() - _fxStart) * 1000
		print(string.format("[BB-FIRE-PERF] client: local destroy took %.2fms (desc=%d)", _ms, _fxDesc))
		return -- do NOT enter breaking state
	end
	
	BreakingState.isBreaking = true
	BreakingState.target = target
	BreakingState.progress = 0
	BreakingState.timeRequired = BREAK_TIME
	createCrackOverlaysForBlock(target)
end

local function stopBreaking()
	BreakingState.isBreaking = false
	BreakingState.target = nil
	BreakingState.progress = 0
	if BreakProgressUI then BreakProgressUI.Visible = false end
	clearCrackOverlays()
end

local function getBlockGridKey(block)
	local bpx = block:GetAttribute("BlockPosX")
	local bpy = block:GetAttribute("BlockPosY")
	local bpz = block:GetAttribute("BlockPosZ")
	if bpx and bpy and bpz then
		-- Use %.1f to match ClientPrediction's posKey format (terrain grid may not
		-- align to integer multiples of BLOCK_SIZE, e.g., Y=10.5, 7.5, etc.)
		return string.format("%.1f,%.1f,%.1f",
			math.round(bpx * 10) / 10,
			math.round(bpy * 10) / 10,
			math.round(bpz * 10) / 10)
	end
	local gpx = block:GetAttribute("GridPosX")
	local gpy = block:GetAttribute("GridPosY")
	local gpz = block:GetAttribute("GridPosZ")
	if gpx and gpy and gpz then
		return string.format("%.1f,%.1f,%.1f",
			math.round(gpx * 10) / 10,
			math.round(gpy * 10) / 10,
			math.round(gpz * 10) / 10)
	end
	return nil
end

local function updateBreaking(deltaTime)
	if not BreakingState.isBreaking or not BreakingState.target then return end
	if not BreakingState.target.Parent then stopBreaking() return end
	
	local currentTarget, _ = getBlockTarget()
	if currentTarget ~= BreakingState.target then
		-- Race condition fix: if a real block replaced a prediction (or vice versa)
		-- at the SAME grid position, transfer breaking progress instead of resetting.
		if currentTarget and BreakingState.target then
			local currentKey = getBlockGridKey(currentTarget)
			local targetKey = getBlockGridKey(BreakingState.target)
			if currentKey and targetKey and currentKey == targetKey then
				-- Same position — seamlessly transfer to the new block
				BreakingState.target = currentTarget
			else
				stopBreaking()
				return
			end
		else
			stopBreaking()
			return
		end
	end
	
	BreakingState.progress = BreakingState.progress + (deltaTime / BreakingState.timeRequired)
	
	if BreakProgressUI then BreakProgressUI.Visible = true end
	if ProgressFill then ProgressFill.Size = UDim2.new(BreakingState.progress, 0, 1, 0) end
	
	local targetTransparency = 1 - (BreakingState.progress * 0.7)
	for _, overlay in pairs(CrackOverlays) do
		local frame = overlay:FindFirstChild("Overlay")
		if frame then frame.BackgroundTransparency = targetTransparency end
	end
	
	if BreakingState.progress >= 1 then
		local targetBlock = BreakingState.target
		local blocksFolder = getBlocksFolder()
		
		-- Check if this is a client prediction block (not a real server block)
		if ClientPrediction.IsPredictionBlock(targetBlock) then
			-- PREDICTION BLOCK: Handle entirely client-side, tell server by position
			local bpx = targetBlock:GetAttribute("BlockPosX")
			local bpy = targetBlock:GetAttribute("BlockPosY")
			local bpz = targetBlock:GetAttribute("BlockPosZ")
			local blockPos = (bpx and bpy and bpz) and Vector3.new(bpx, bpy, bpz) or nil
			
			local buildArea = nil
			if blockPos then
				buildArea = ClientPrediction.GetBuildAreaAtPosition(blockPos)
			end
			
			-- Destroy prediction and spawn new adjacent predictions
			local pos = ClientPrediction.OnPredictionBreak(targetBlock, buildArea)
			
			-- Tell server to mark position as dug and spawn adjacent terrain
			if pos and RemoveBlockAtPosition then
				print(string.format("[BB-NET] CLIENT -> RemoveBlockAtPosition pos=(%.1f,%.1f,%.1f)", pos.X, pos.Y, pos.Z))
				RemoveBlockAtPosition:FireServer(pos)
			end
		else
			-- REAL BLOCK: Hide block instantly, predict terrain, then tell server
			local blockPos = nil
			
			-- Get grid position from attributes (most accurate)
			local bpx = targetBlock:GetAttribute("BlockPosX")
			local bpy = targetBlock:GetAttribute("BlockPosY")
			local bpz = targetBlock:GetAttribute("BlockPosZ")
			if bpx and bpy and bpz then
				blockPos = Vector3.new(bpx, bpy, bpz)
			end
			
			-- Find the build area for terrain prediction
			local buildArea = nil
			if blockPos then
				buildArea = ClientPrediction.GetBuildAreaAtPosition(blockPos)
			elseif blocksFolder and blocksFolder.Parent then
				buildArea = blocksFolder.Parent
			end
			
			-- Instantly hide block and predict adjacent terrain (no waiting for server)
			ClientPrediction.OnBlockBreak(targetBlock, blocksFolder, buildArea)
			
			-- Now tell the server (it will catch up)
			if RemoveBlock then
				local _bt = targetBlock:GetAttribute("BlockType") or "?"
				print(string.format("[BB-NET] CLIENT -> RemoveBlock type=%s block=%s", _bt, targetBlock.Name))
				RemoveBlock:FireServer(targetBlock, LastRaycastResult and LastRaycastResult.Position)
			end
		end
		
		stopBreaking()
		if _G.OnBlockBroken then _G.OnBlockBroken() end
	end
end

-- ============================================
-- PLACEMENT
-- ============================================

-- ============================================
-- FRAME BLOCK FILLING
-- Right-click a placed frame block while holding a regular block
-- to fill it with the held block's color/material
-- ============================================
local function TryFillFrameBlock()
	local blockData = _G.InventoryController and _G.InventoryController.GetSelectedBlock()
	if not blockData then
		print("[FrameFill] SKIP: no blockData")
		return false
	end
	if blockData.IsTool then
		print("[FrameFill] SKIP: is tool")
		return false
	end
	
	-- Must be holding a regular block (not a frame, slab, stair, decoration, door, fence, etc.)
	local isRegularBlock = (blockData.Shape == "Block")
		and not blockData.IsFrameBlock
		and not blockData.IsDecoration
		and not blockData.IsDoor
		and not blockData.IsFence
		and not blockData.IsVine -- Vines mount onto frame faces like any other block; never fill them.
		and not BlockPresets.IsGlass(blockData.Id)
		and not BlockPresets.IsTorch(blockData.Id)
		and not BlockPresets.IsCampfire(blockData.Id)
		and not BlockPresets.IsLantern(blockData.Id)
		and not BlockPresets.IsLadder(blockData.Id)
		and not BlockPresets.IsGlowstone(blockData.Id)
		and not BlockPresets.IsSign(blockData.Id)
		and not (BlockPresets.IsColumn and BlockPresets.IsColumn(blockData.Id))
		and not blockData.IsController -- buttons/pressure plates
		and not blockData.IsControllable -- lamps
		and blockData.Id ~= "SnowLayer" -- Special thin block, not a real full block
	
	if not isRegularBlock then
		print("[FrameFill] SKIP: not regular block - " .. tostring(blockData.Id) .. " Shape=" .. tostring(blockData.Shape))
		return false
	end
	
	-- Check if target is a placed frame block
	local target, _ = getBlockTarget()
	if not target then
		print("[FrameFill] SKIP: no target from raycast")
		return false
	end
	
	local targetBlockType = target:GetAttribute("BlockType") or ""
	print("[FrameFill] Target: " .. target.Name .. " BlockType=" .. targetBlockType .. " IsFrameBlock=" .. tostring(target:GetAttribute("IsFrameBlock")))
	
	-- Check both attribute and BlockType name (fallback for frames placed before attribute was added)
	-- But skip if already filled (FrameFillBlockId is set)
	local isTargetFrame = (target:GetAttribute("IsFrameBlock")
		or BlockPresets.IsFrameBlock(targetBlockType))
		and not target:GetAttribute("FrameFillBlockId")
	if not isTargetFrame then
		return false
	end
	
	-- Check permission
	local targetPos = target:IsA("Model") and target:GetPivot().Position or target.Position
	if not canInteractAtPosition(targetPos) then return false end
	
	-- Fire the fill remote with target block and the held block's ID
	if FillFrameBlock then
		print(string.format("[FrameFill] Filling frame with %s (color=%s, matVariant=%s)",
			blockData.Id,
			tostring(blockData.Color or blockData.DefaultColor),
			tostring(blockData.MaterialVariant)))
		FillFrameBlock:FireServer(target, blockData.Id)
	else
		warn("[FrameFill] FillFrameBlock remote not found!")
	end
	
	return true
end

local function placeBlock()
	if isInventoryOpen() then return end
	
	local blockData = _G.InventoryController and _G.InventoryController.GetSelectedBlock()
	if not blockData or blockData.IsTool then return end
	
	-- SnowLayer stacking: right-clicking an existing SnowLayer with SnowLayer in hand
	-- adds a layer instead of placing a new block (up to 8 layers = full block)
	if blockData.Id == "SnowLayer" then
		local hitBlock, _ = getBlockTarget()
		print(string.format("[SnowLayer CLIENT] hitBlock=%s, type=%s", 
			tostring(hitBlock), 
			hitBlock and tostring(hitBlock:GetAttribute("BlockType")) or "nil"))
		if hitBlock and hitBlock:GetAttribute("BlockType") == "SnowLayer" then
			local currentLayers = hitBlock:GetAttribute("SnowLayers") or 1
			print(string.format("[SnowLayer CLIENT] Found SnowLayer with %d layers, StackSnowLayer=%s", currentLayers, tostring(StackSnowLayer)))
			if currentLayers < 8 then
				-- Stack on existing snow layer
				if StackSnowLayer then
					print("[SnowLayer CLIENT] Firing StackSnowLayer")
					StackSnowLayer:FireServer(hitBlock)
				else
					warn("[SnowLayer CLIENT] StackSnowLayer remote is nil!")
				end
				if _G.OnBlockPlaced then _G.OnBlockPlaced() end
				return
			end
			-- If 8 layers (full block), fall through to normal placement (place on top)
		end
	end
	
	local gridPos = getPlacementPosition(blockData)
	if not gridPos then return end
	
	-- Check permission before placing (own plot OR shared access)
	if not canInteractAtPosition(gridPos) then return end
	
	local placementData = {
		BlockType = blockData.Id,
		Position = gridPos,
		Rotation = _G.InventoryController and _G.InventoryController.GetRotation() or 0,
		MaterialName = blockData.Material and blockData.Material.Name or "Plastic",
		Color = blockData.Color,
	}
	
	local lookVector = getCameraLookVector()
	
	-- Stair data
	if (StairPlacement.IsStairType(blockData.Id) or StairPlacement.IsArchType(blockData.Id)) and LastRaycastResult then
		placementData.StairData = {
			HitPosition = LastRaycastResult.Position,
			HitNormal = LastRaycastResult.Normal,
			HitBlockPosition = getHitBlockPosition(),
			LookVector = lookVector,
		}
	end
	
	-- Log/piston axis
	if LogPlacement.UsesAxisRotation(blockData.Id) then
		if LastRaycastResult and LastRaycastResult.Normal then
			if LogPlacement.NeedsDirectionalPlacement(blockData.Id) then
				CurrentLogAxis = LogPlacement.GetDirectionalAxisFromNormal(LastRaycastResult.Normal)
			else
				CurrentLogAxis = LogPlacement.GetAxisFromNormal(LastRaycastResult.Normal)
			end
		end
		placementData.LogData = { Axis = CurrentLogAxis }
	end
	
	-- Slab orientation
	if SlabPlacement.IsSlab(blockData.Id) and LastRaycastResult then
		local hitBlockPos = getHitBlockPosition()
		if hitBlockPos then
			local forceVertical = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			CurrentSlabOrientation = SlabPlacement.GetOrientation(
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockPos,
				lookVector,
				forceVertical
			)
		end
		placementData.SlabData = { Orientation = CurrentSlabOrientation }
	end
	
	-- Decoration offset
	if blockData.IsDecoration then
		placementData.DecorationData = {
			DecorationName = blockData.DecorationName,
			Offset = CurrentDecorationOffset,
		}
		if not NoOffsetDecorations[blockData.DecorationName] then
			CurrentDecorationOffset = Vector3.new(
				(math.random() - 0.5) * 2 * DECORATION_MAX_OFFSET,
				0,
				(math.random() - 0.5) * 2 * DECORATION_MAX_OFFSET
			)
		end
	end
	
	-- Door data
	if DoorPlacement.IsDoor(blockData.Id) then
		CurrentDoorDirection = DoorPlacement.GetDirectionFromLookVector(lookVector)
		if LastRaycastResult then
			local hitBlockPos = getHitBlockPosition()
			if hitBlockPos then
				CurrentDoorDepth = DoorPlacement.GetDepthFromHit(
					LastRaycastResult.Position, LastRaycastResult.Normal, hitBlockPos, gridPos, lookVector
				)
				CurrentDoorHingeSide = DoorPlacement.GetHingeSideFromHit(
					LastRaycastResult.Position, LastRaycastResult.Normal, hitBlockPos, lookVector
				)
			end
		end
		placementData.DoorData = {
			Direction = CurrentDoorDirection,
			Depth = CurrentDoorDepth,
			HingeSide = CurrentDoorHingeSide,
			LookVector = lookVector,
			HitPosition = LastRaycastResult and LastRaycastResult.Position,
			HitNormal = LastRaycastResult and LastRaycastResult.Normal,
			HitBlockPosition = getHitBlockPosition(),
		}
	end
	
	-- Surface blocks (buttons, pressure plates)
	if SurfacePlacement.IsSurfaceBlock(blockData.Id) and LastRaycastResult then
		local hitBlockPos = getHitBlockPosition()
		if hitBlockPos then
			local surfaceInfo = SurfacePlacement.GetPlacementInfo(
				blockData.Id, LastRaycastResult.Position, LastRaycastResult.Normal, hitBlockPos
			)
			placementData.SurfaceData = {
				Face = surfaceInfo.face,
				HostPosition = surfaceInfo.hostPosition,
			}
		end
	end
	
	-- Wallpaper frames (placed on any face of solid blocks)
	if WallpaperPlacement.IsWallpaperFrame(blockData.Id) and LastRaycastResult then
		local hitBlockGridPos, hitBlock = getHitBlockGridPosition(LastRaycastResult)
		if hitBlockGridPos and hitBlock then
			local wallpaperInfo = WallpaperPlacement.GetPlacementInfo(
				hitBlock, LastRaycastResult.Position, LastRaycastResult.Normal, hitBlockGridPos
			)
			if wallpaperInfo then
				placementData.WallpaperData = {
					Face = wallpaperInfo.face,
					HostPosition = wallpaperInfo.hostPosition,
				}
				-- Override position to the wallpaper's calculated surface position
				placementData.Position = wallpaperInfo.position
			else
				-- Invalid host (decoration, fence, etc.) - cancel placement
				return
			end
		end
	end
	
	-- Glass orientation
	if GlassPlacement.IsGlass(blockData.Id) then
		CurrentGlassOrientation = GlassPlacement.GetOrientationFromLookVector(lookVector)
		placementData.GlassData = { Orientation = CurrentGlassOrientation }
	end
	
	-- Ladder placement (side faces only, one per grid cell)
	if BlockPresets.IsLadder(blockData.Id) and LastRaycastResult then
		local hitBlockGridPos = getHitBlockGridPosition(LastRaycastResult)
		if hitBlockGridPos then
			local blocksFolder = getBlocksFolder()
			local ladderInfo, errorMsg = LadderPlacement.GetPlacementInfo(
				blockData.Id,
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockGridPos,
				blocksFolder
			)
			if ladderInfo then
				placementData.LadderData = {
					Face = ladderInfo.face,
					GridPosition = ladderInfo.gridPosition,
					Rotation = ladderInfo.rotation,
					HostPosition = ladderInfo.hostPosition,
				}
				-- Override position with the ladder's calculated grid position
				placementData.Position = ladderInfo.gridPosition
			else
				-- Invalid placement (top/bottom face or already occupied)
				return
			end
		end
	end
	
	-- Vine placement (side faces only, like ladders)
	if BlockPresets.IsVine and BlockPresets.IsVine(blockData.Id) and LastRaycastResult then
		local hitBlockGridPos = getHitBlockGridPosition(LastRaycastResult)
		if hitBlockGridPos then
			local blocksFolder = getBlocksFolder()
			local vineInfo, errorMsg = VinePlacement.GetPlacementInfo(
				blockData.Id,
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockGridPos,
				blocksFolder
			)
			if vineInfo then
				placementData.VineData = {
					Face = vineInfo.face,
					GridPosition = vineInfo.gridPosition,
					Rotation = vineInfo.rotation,
					HostPosition = vineInfo.hostPosition,
				}
				-- Override position with the vine's calculated grid position
				placementData.Position = vineInfo.gridPosition
			else
				-- Invalid placement (top/bottom face or already occupied)
				return
			end
		end
	end
	
	-- Torch placement (straight on top, angled on sides)
	if BlockPresets.IsTorch(blockData.Id) and LastRaycastResult then
		-- Don't allow placing torches ON other torches (clicking a torch)
		local hitBlock, _ = getBlockTarget()
		if hitBlock and hitBlock:GetAttribute("IsTorch") then
			return -- Can't click on a torch to place another torch
		end
		
		local hitBlockGridPos = getHitBlockGridPosition(LastRaycastResult)
		if hitBlockGridPos then
			local blocksFolder = getBlocksFolder()
			local torchInfo, errorMsg = TorchPlacement.GetPlacementInfo(
				blockData.Id,
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockGridPos,
				blocksFolder
			)
			if torchInfo then
				placementData.TorchData = {
					Face = torchInfo.face,
					GridPosition = torchInfo.gridPosition,
					Rotation = torchInfo.rotation,
					ModelName = torchInfo.modelName,
					IsAngled = torchInfo.isAngled,
					HostPosition = torchInfo.hostPosition,
				}
				-- Override position with the torch's calculated grid position
				placementData.Position = torchInfo.gridPosition
			else
				-- Invalid placement (bottom face or already occupied)
				return
			end
		end
	end
	
	-- Lantern placement (top or bottom faces only)
	if BlockPresets.IsLantern and BlockPresets.IsLantern(blockData.Id) and LastRaycastResult then
		-- Don't allow placing lanterns ON other lanterns (clicking a lantern)
		local hitBlock, _ = getBlockTarget()
		if hitBlock and hitBlock:GetAttribute("IsLantern") then
			return -- Can't click on a lantern to place another lantern
		end
		
		local hitBlockGridPos = getHitBlockGridPosition(LastRaycastResult)
		if hitBlockGridPos then
			local blocksFolder = getBlocksFolder()
			local lanternInfo, errorMsg = LanternPlacement.GetPlacementInfo(
				blockData.Id,
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockGridPos,
				blocksFolder
			)
			if lanternInfo then
				placementData.LanternData = {
					Face = lanternInfo.face,
					GridPosition = lanternInfo.gridPosition,
					IsHanging = lanternInfo.isHanging,
					HostPosition = lanternInfo.hostPosition,
				}
				-- Override position with the lantern's calculated grid position
				placementData.Position = lanternInfo.gridPosition
			else
				-- Invalid placement (side face or already occupied)
				return
			end
		end
	end
	
	-- Standing Sign placement (top face only, 16-direction rotation)
	-- OR auto-convert to wall sign if clicking on a side face
	local isSignStandingBlock = BlockPresets.IsSignStanding and BlockPresets.IsSignStanding(blockData.Id)
	
	if isSignStandingBlock and LastRaycastResult then
		-- Don't allow placing signs ON other signs
		local hitBlock, _ = getBlockTarget()
		if hitBlock and SignPlacement.IsSignBlock(hitBlock) then
			return
		end
		
		local hitBlockGridPos = getHitBlockGridPosition(LastRaycastResult)
		
		if hitBlockGridPos then
			local blocksFolder = getBlocksFolder()
			local lookVector = getCameraLookVector()
			
			-- First try standing sign (top face)
			local signInfo, errorMsg = SignPlacement.GetStandingSignPlacementInfo(
				blockData.Id,
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockGridPos,
				lookVector,
				blocksFolder
			)
			
			if signInfo then
				-- Standing sign placement works
				placementData.SignData = {
					Face = signInfo.face,
					GridPosition = signInfo.gridPosition,
					Rotation = signInfo.rotation,
					RotationIndex = signInfo.rotationIndex,
					HostPosition = signInfo.hostPosition,
					SignType = "standing",
					ModelName = signInfo.modelName,
				}
				placementData.Position = signInfo.gridPosition
			else
				-- Try wall sign instead (for side faces)
				-- Convert block ID from "OakSignStanding" to "OakSign"
				-- Also handle frame signs: "SignStandingFrame" to "SignFrame"
				local wallSignId
				if blockData.Id == "SignStandingFrame" then
					wallSignId = "SignFrame"
				else
					wallSignId = string.gsub(blockData.Id, "SignStanding$", "Sign")
				end
				
				local wallSignInfo, wallErrorMsg = SignPlacement.GetWallSignPlacementInfo(
					wallSignId,
					LastRaycastResult.Position,
					LastRaycastResult.Normal,
					hitBlockGridPos,
					blocksFolder
				)
				
				if wallSignInfo then
						-- Wall sign placement works - use it instead
						placementData.BlockType = wallSignId -- Switch to wall sign type
						placementData.SignData = {
							Face = wallSignInfo.face,
							GridPosition = wallSignInfo.gridPosition,
							Rotation = wallSignInfo.rotation,
							HostPosition = wallSignInfo.hostPosition,
							SignType = "wall",
							ModelName = wallSignInfo.modelName,
							IsOnFencePost = wallSignInfo.isOnFencePost,
						}
						placementData.Position = wallSignInfo.gridPosition
					else
					-- Neither works - invalid placement
					return
				end
			end
		end
	end
	
	-- Wall Sign placement (side faces only) - only if not already a standing sign
	if BlockPresets.IsWallSign(blockData.Id) and LastRaycastResult then
		-- Don't allow placing signs ON other signs
		local hitBlock, _ = getBlockTarget()
		if hitBlock and SignPlacement.IsSignBlock(hitBlock) then
			return
		end
		
		local hitBlockGridPos = getHitBlockGridPosition(LastRaycastResult)
		if hitBlockGridPos then
			local blocksFolder = getBlocksFolder()
			local signInfo, errorMsg = SignPlacement.GetWallSignPlacementInfo(
				blockData.Id,
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockGridPos,
				blocksFolder
			)
			if signInfo then
				placementData.SignData = {
					Face = signInfo.face,
					GridPosition = signInfo.gridPosition,
					Rotation = signInfo.rotation,
					HostPosition = signInfo.hostPosition,
					SignType = "wall",
					ModelName = signInfo.modelName,
					IsOnFencePost = signInfo.isOnFencePost,
				}
				-- Override position with the sign's calculated grid position
				placementData.Position = signInfo.gridPosition
			else
				-- Invalid placement (not side face or already occupied)
				return
			end
		end
	end
	
	-- CLIENT PREDICTION: Create instant visual feedback for simple blocks
	-- Skip prediction for complex blocks (doors, decorations, torches, lanterns, signs, surface blocks)
	-- as their visual positioning is handled specially by the server
	local skipPrediction = blockData.IsDecoration
		or DoorPlacement.IsDoor(blockData.Id)
		or SurfacePlacement.IsSurfaceBlock(blockData.Id)
		or BlockPresets.IsTorch(blockData.Id)
		or (BlockPresets.IsLantern and BlockPresets.IsLantern(blockData.Id))
		or (BlockPresets.IsSignStanding and BlockPresets.IsSignStanding(blockData.Id))
		or BlockPresets.IsWallSign(blockData.Id)
		or (BlockPresets.IsLadder and BlockPresets.IsLadder(blockData.Id))
		or WallpaperPlacement.IsWallpaperFrame(blockData.Id)
		or (BlockPresets.IsCarpet and BlockPresets.IsCarpet(blockData.Id))
		or (BlockPresets.IsVine and BlockPresets.IsVine(blockData.Id))
		or blockData.Id == "SnowLayer" -- Special sizing/positioning handled by server
		or (BlockPresets.IsArchitrave and BlockPresets.IsArchitrave(blockData.Id))
		or (BlockPresets.IsArch and BlockPresets.IsArch(blockData.Id))
	
	-- Architrave data: send look direction for smart corner placement
	if BlockPresets.IsArchitrave and BlockPresets.IsArchitrave(blockData.Id) then
		placementData.ArchitraveData = {
			LookVector = lookVector,
		}
	end
	
	if not skipPrediction then
		local blocksFldr = getBlocksFolder()
		ClientPrediction.OnBlockPlace(blockData.Id, gridPos, placementData, blocksFldr)
	end
	
	if PlaceBlock then
		print(string.format("[BB-NET] CLIENT -> PlaceBlock type=%s pos=(%.1f,%.1f,%.1f)", placementData.BlockType, placementData.Position.X, placementData.Position.Y, placementData.Position.Z))
		PlaceBlock:FireServer(placementData)
	end
	if _G.OnBlockPlaced then _G.OnBlockPlaced() end
end

-- ============================================
-- INTERACTIONS
-- ============================================

local function TryPressButton()
	if isWiringToolSelected() then return false end
	
	local target, _ = getBlockTarget()
	if not target then return false end
	
	local blockType = target:GetAttribute("BlockType")
	if not blockType or not SurfacePlacement.IsButton(blockType) then return false end
	if target:GetAttribute("IsPressed") then return false end
	
	if PressButton then
		PressButton:FireServer(target)
		return true
	end
	return false
end

local function TryToggleFenceConnection()
	if isWiringToolSelected() then return false end
	if not ToggleFenceConnection then return false end
	
	-- Only allow toggling with empty hand (no block selected)
	local blockData = _G.InventoryController and _G.InventoryController.GetSelectedBlock()
	if blockData then return false end
	
	local target, result = getBlockTarget()
	if not target then return false end
	
	-- Check if target is a fence
	if not target:GetAttribute("IsFence") then return false end
	
	-- Get the click position from the raycast result
	local clickPosition = result and result.Position
	if not clickPosition then return false end
	
	-- Get the fence position
	local fencePos
	if target:IsA("BasePart") then
		fencePos = target:GetPivot().Position
	elseif target:IsA("Model") then
		fencePos = target:GetPivot().Position
	end
	
	if not fencePos then return false end
	
	-- Check if there are any toggleable connections (solid blocks or blocked directions)
	local blocksFolder = getBlocksFolder()
	if not blocksFolder then return false end
	
	-- Get adjacent solid blocks
	local adjacentSolids = FencePlacement.GetAdjacentSolidBlockDirections(fencePos, blocksFolder)
	
	-- Get currently blocked directions
	local blockedDirs = FencePlacement.ParseBlockedDirections(target:GetAttribute("BlockedDirections"))
	
	-- Check if there's anything to toggle
	local hasToggleable = #adjacentSolids > 0
	for _ in pairs(blockedDirs) do
		hasToggleable = true
		break
	end
	
	if not hasToggleable then
		return false
	end
	
	-- Send toggle request to server (server will figure out which direction)
	ToggleFenceConnection:FireServer(target, clickPosition)
	return true
end

local function TrySignInteraction()
	if not IsMobile or not RequestSignInteraction then return false end
	
	local result = raycastForBlock()
	if not result or not result.Instance then return false end
	
	local current = result.Instance
	local sign, signType = nil, nil
	
	while current and current ~= workspace do
		local name = current.Name
		if name == "BiomeSign" or name == "SaveLoadSign" or name == "LikeSign" then
			sign, signType = current, name
			break
		end
		current = current.Parent
	end
	
	if not sign then return false end
	
	local buildArea = nil
	current = sign.Parent
	while current and current ~= workspace do
		if string.match(current.Name, GridConfig.BUILD_AREA_PREFIX) then
			buildArea = current
			break
		end
		current = current.Parent
	end
	
	if not buildArea then return false end
	
	RequestSignInteraction:FireServer(signType, buildArea)
	return true
end

local function TryWaterBucketAction()
	local blockData = _G.InventoryController and _G.InventoryController.GetSelectedBlock()
	if not blockData then return false end
	
	if blockData.IsWaterBucket then
		local target, _ = getBlockTarget()
		if not target then return false end
		
		-- Check if we're targeting a water block (for flowing->source conversion)
		if target:GetAttribute("IsWater") then
			local waterLevel = target:GetAttribute("WaterLevel") or 0
			if waterLevel > 0 then
				-- Flowing water: convert to source block
				local blockPos
				local bpx = target:GetAttribute("BlockPosX")
				local bpy = target:GetAttribute("BlockPosY")
				local bpz = target:GetAttribute("BlockPosZ")
				if bpx and bpy and bpz then
					blockPos = Vector3.new(bpx, bpy, bpz)
				elseif target:IsA("BasePart") then
					blockPos = target.Position
				end
				if not blockPos then return false end
				if not canInteractAtPosition(blockPos) then return false end
				
				if PlaceWater then
					PlaceWater:FireServer({ Position = blockPos, ConvertFlowing = true })
					if _G.OnBlockPlaced then _G.OnBlockPlaced() end
				end
				return true
			else
				-- Source water: can't place another source on top of a source
				return true -- Consume the click but do nothing
			end
		end
		
		-- Not targeting water: place water source at adjacent position (like placing a block)
		local gridPos = getPlacementPosition(blockData)
		if not gridPos then return false end
		
		if not canInteractAtPosition(gridPos) then return false end
		
		if PlaceWater then
			PlaceWater:FireServer({ Position = gridPos })
			if _G.OnBlockPlaced then _G.OnBlockPlaced() end
		end
		return true
		
	elseif blockData.IsEmptyBucket then
		-- Pick up water source at targeted block
		local target, _ = getBlockTarget()
		if not target then return false end
		
		-- Must be targeting a water source block
		if not target:GetAttribute("IsWater") then return false end
		if target:GetAttribute("WaterLevel") ~= 0 then return false end -- Only pick up sources
		
		local blockPos
		if target:IsA("BasePart") then
			blockPos = target.Position
		elseif target:IsA("Model") then
			local p = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart")
			blockPos = p and p.Position
		end
		if not blockPos then return false end
		
		if not canInteractAtPosition(blockPos) then return false end
		
		if PickupWater then
			PickupWater:FireServer({ Position = blockPos })
		end
		return true
	end
	
	return false
end

-- ============================================
-- INPUT HANDLING
-- ============================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or isInventoryOpen() or isWiringToolSelected() or isBlockUIOpen() then return end
	
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		-- While laying on a bed, left-click does nothing (can't break blocks from bed)
		if _G.BedController and _G.BedController.IsLayingDown() then return end
		MouseDown = true
		local target, _ = getBlockTarget()
		if target then startBreaking(target) end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		RightMouseDown = true
		RightMouseHoldStart = tick()
		PlaceCooldown = PLACE_RATE
		-- Shift-place: holding shift bypasses the entire block-interaction priority chain
		-- (doors, chests, crafting tables, furnaces, buttons, signs, fence toggles, etc.)
		-- AND skips frame-block filling, so you can place a block adjacent to an empty
		-- frame instead of filling it. Goes straight to placing a block on whatever the
		-- player is looking at. Matches Minecraft's behavior. Water bucket still runs since
		-- that IS a placement action (the bucket places water, not a block).
		local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		if not shiftHeld then
			if TryPressButton() then return end
			if _G.DoorController and _G.DoorController.TryInteract() then return end
			if _G.BlockInteractionController and _G.BlockInteractionController.TryInteract() then return end
			if _G.ChestController and _G.ChestController.TryInteract() then return end
			if TryToggleFenceConnection() then return end
			print("[BuildingController] Checking SignEditController:", _G.SignEditController ~= nil)
			if _G.SignEditController and _G.SignEditController.TryEditSign() then 
				print("[BuildingController] Sign edit started, returning")
				return 
			end
			if _G.TextBlockEditController and _G.TextBlockEditController.TryEditTextBlock() then return end
			if TryFillFrameBlock() then return end
		end
		if TryWaterBucketAction() then return end
		placeBlock()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		MouseDown = false
		stopBreaking()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		RightMouseDown = false
	end
end)

-- Mobile touch
UserInputService.TouchStarted:Connect(function(input, gameProcessed)
	if gameProcessed or not IsMobile or isInventoryOpen() or isWiringToolSelected() or isBlockUIOpen() or TouchState.activeId then return end
	
	local screenSize = Camera.ViewportSize
	if input.Position.X < screenSize.X * 0.3 then return end
	if input.Position.Y > screenSize.Y - 100 then return end
	if input.Position.X > screenSize.X - 100 and input.Position.Y < 450 then return end
	
	TouchState.activeId = input
	TouchState.startTime = tick()
	TouchState.startPos = input.Position
	TouchState.isHeld = false
	TouchState.movedTooMuch = false
end)

UserInputService.TouchMoved:Connect(function(input)
	if not IsMobile or input ~= TouchState.activeId or not TouchState.startPos then return end
	if (input.Position - TouchState.startPos).Magnitude > TOUCH_MOVE_THRESHOLD then
		TouchState.movedTooMuch = true
	end
end)

UserInputService.TouchEnded:Connect(function(input)
	if not IsMobile or input ~= TouchState.activeId then return end
	
	local touchDuration = tick() - (TouchState.startTime or 0)
	
	if not TouchState.movedTooMuch and touchDuration < TAP_MAX_TIME and not TouchState.isHeld then
		if not isWiringToolSelected() then
			-- Priority 1: Player-placed sign editing (highest priority for tap)
			if _G.SignEditController and _G.SignEditController.TryEditSign() then
				-- Editing player-placed sign
			-- Priority 1b: Player-placed text block editing
			elseif _G.TextBlockEditController and _G.TextBlockEditController.TryEditTextBlock() then
				-- Editing player-placed text block
			-- Priority 2: Plot signs (biome/save/load)
			elseif TrySignInteraction() then
				-- done
			-- Priority 3: Buttons
			elseif TryPressButton() then
				-- done
			-- Priority 4: Doors
			elseif _G.DoorController and _G.DoorController.TryInteract() then
				-- done
			-- Priority 4b: Block UIs (chests, crafting tables, furnaces)
			elseif _G.BlockInteractionController and _G.BlockInteractionController.TryInteract() then
			-- done
			-- Priority 4c: Chest lid toggle (fallback if BlockInteractionController not ready)
			elseif _G.ChestController and _G.ChestController.TryInteract() then
			 -- done
			-- Priority 5: Fence connections
			elseif TryToggleFenceConnection() then
				-- done
			-- Priority 6: Tool use (shovel for paths, etc.)
			elseif _G.InventoryController and _G.InventoryController.GetSelectedTool and _G.InventoryController.GetSelectedTool() and _G.InventoryController.UseToolOnBlock and _G.InventoryController.UseToolOnBlock() then
				-- Tool used on block
			-- Priority 7: Water bucket
			elseif TryWaterBucketAction() then
			 -- done
			-- Priority 8: Fill frame block
			elseif TryFillFrameBlock() then
			 -- done
			-- Default: Place block
			else
			placeBlock()
			end
		else
			placeBlock()
		end
	end
	
	if TouchState.isHeld then
		MouseDown = false
		stopBreaking()
	end
	
	TouchState.activeId = nil
	TouchState.startTime = nil
	TouchState.startPos = nil
	TouchState.isHeld = false
	TouchState.movedTooMuch = false
end)

-- ============================================
-- MAIN LOOP
-- ============================================

RunService.RenderStepped:Connect(function(deltaTime)
	if isInventoryOpen() then
		stopBreaking()
		clearSlabGhost()
		clearDoorGhost()
		RightMouseDown = false -- Stop continuous placement
		if SelectionBox then SelectionBox.Visible = false end
		return
	end
	
	-- Update selection highlight
	local target, _ = getBlockTarget()
	
	-- Recreate if destroyed (e.g. target block broken while highlighted)
	if SelectionBox then
		local ok = pcall(function() return SelectionBox.Name end)
		if not ok then SelectionBox = nil; SelectionBoundingBox = nil end
	end
	if SelectionBoundingBox then
		local ok = pcall(function() return SelectionBoundingBox.Name end)
		if not ok then SelectionBox = nil; SelectionBoundingBox = nil end
	end
	if not SelectionBox or not SelectionBoundingBox then createSelectionBox() end
	
	if SelectionBox and SelectionBoundingBox then
		if target then
			-- Hide highlight during chest lid animation
			if target:GetAttribute("IsAnimating") then
				SelectionBox.Visible = false
				CurrentSelectionTarget = target
			else
				-- Position the bounding box to match the target block
				local cf, size = getBlockBoundingBox(target)
				if cf and size then
					SelectionBoundingBox.CFrame = cf
					SelectionBoundingBox.Size = size
					if not SelectionBoundingBox.Parent then
						SelectionBoundingBox.Parent = workspace
					end
					SelectionBox.Visible = true
				end
				CurrentSelectionTarget = target
			end
		else
			SelectionBox.Visible = false
			CurrentSelectionTarget = nil
		end
	end
	

	
	-- Get current block data
	local blockData = _G.InventoryController and _G.InventoryController.GetSelectedBlock()
	local isSlab = blockData and SlabPlacement.IsSlab(blockData.Id)
	local isDoor = blockData and DoorPlacement.IsDoor(blockData.Id)
	
	-- Update slab ghost preview
	if isSlab and LastRaycastResult then
		local gridPos = getPlacementPosition(blockData)
		local hitBlockPos = getHitBlockPosition()
		
		-- Show ghost if we have valid position (server will validate permissions)
		if gridPos and hitBlockPos then
			local lookVector = getCameraLookVector()
			local forceVertical = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			local orientation = SlabPlacement.GetOrientation(
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockPos,
				lookVector,
				forceVertical
			)
			
			updateSlabGhost(gridPos, orientation, blockData.Id)
		else
			clearSlabGhost()
		end
	else
		clearSlabGhost()
	end
	
	-- Update door ghost preview
	if isDoor and LastRaycastResult then
		local gridPos = getPlacementPosition(blockData)
		local hitBlockPos = getHitBlockPosition()
		
		-- Show ghost if we have valid position (server will validate permissions)
		if gridPos and hitBlockPos then
			local lookVector = getCameraLookVector()
			local direction = DoorPlacement.GetDirectionFromLookVector(lookVector)
			local depth = DoorPlacement.GetDepthFromHit(
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockPos,
				gridPos,
				lookVector
			)
			local hingeSide = DoorPlacement.GetHingeSideFromHit(
				LastRaycastResult.Position,
				LastRaycastResult.Normal,
				hitBlockPos,
				lookVector
			)
			
			updateDoorGhost(gridPos, direction, depth, hingeSide, blockData.Id)
		else
			clearDoorGhost()
		end
	else
		clearDoorGhost()
	end
	
	-- Mobile hold-to-break
	if IsMobile and TouchState.activeId and TouchState.startTime then
		local touchDuration = tick() - TouchState.startTime
		if not TouchState.isHeld and not TouchState.movedTooMuch and touchDuration >= HOLD_TIME_TO_BREAK then
			TouchState.isHeld = true
			MouseDown = true
			local t, _ = getBlockTarget()
			if t then startBreaking(t) end
		end
	end
	
	-- Update breaking
	if MouseDown and BreakingState.isBreaking then
		updateBreaking(deltaTime)
	elseif MouseDown and not BreakingState.isBreaking then
		local t, _ = getBlockTarget()
		if t then startBreaking(t) end
	end
	
	-- Continuous placement when holding right mouse button (PC only)
	-- Only allow continuous placement after holding for HOLD_THRESHOLD_FOR_CONTINUOUS
	-- Don't allow continuous placement while editing a sign
	local isEditingSign = _G.SignEditController and _G.SignEditController.IsEditing()
	local isEditingTextBlock = _G.TextBlockEditController and _G.TextBlockEditController.IsEditing()
	if RightMouseDown and not IsMobile and not isWiringToolSelected() and not isEditingSign and not isEditingTextBlock then
		local holdDuration = tick() - RightMouseHoldStart
		if holdDuration >= HOLD_THRESHOLD_FOR_CONTINUOUS then
			PlaceCooldown = PlaceCooldown - deltaTime
			if PlaceCooldown <= 0 then
				placeBlock()
				PlaceCooldown = PLACE_RATE
			end
		end
	end
	
	-- Periodically clean up timed-out predictions (every ~1 second)
	PredictionCleanupTimer = (PredictionCleanupTimer or 0) + deltaTime
	if PredictionCleanupTimer >= 1 then
		PredictionCleanupTimer = 0
		ClientPrediction.CleanupTimedOut()
	end
end)

-- ============================================
-- SERVER REJECTION HANDLER
-- When server rejects a build action (no permission), undo the client prediction
-- ============================================

if BuildRejected then
	BuildRejected.OnClientEvent:Connect(function(actionType, position)
		if not position or typeof(position) ~= "Vector3" then return end
		
		print(string.format("[BuildRejected] Server rejected %s at (%.1f, %.1f, %.1f)", 
			tostring(actionType), position.X, position.Y, position.Z))
		
		if actionType == "break" then
			-- Restore the block we hid (undo break prediction)
			ClientPrediction.UndoBreakAtPosition(position)
		elseif actionType == "place" then
			-- Remove the ghost block we placed (undo place prediction)
			ClientPrediction.UndoPlaceAtPosition(position)
		end
	end)
end

print("BuildingController initialized (with client-side prediction)")
