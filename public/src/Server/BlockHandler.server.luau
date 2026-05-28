--[[
	BlockHandler
	Server-side block placement and removal using templates
	With look-vector-based stair placement and lazy terrain loading
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local BlockPresetsModule = ReplicatedStorage:WaitForChild("BlockPresets", 10)
local BlockPresets = BlockPresetsModule and require(BlockPresetsModule)
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BiomeConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("BiomeConfig", 10))
local StairPlacement = require(ReplicatedStorage:WaitForChild("StairPlacement", 10))
local LogPlacement = require(ReplicatedStorage:WaitForChild("LogPlacement", 10))
local SlabPlacement = require(ReplicatedStorage:WaitForChild("SlabPlacement", 10))
local DoorPlacement = require(ReplicatedStorage:WaitForChild("DoorPlacement", 10))
local SurfacePlacement = require(ReplicatedStorage:WaitForChild("SurfacePlacement", 10))
local FencePlacement = require(ReplicatedStorage:WaitForChild("FencePlacement", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local GlassPlacement = require(ReplicatedStorage:WaitForChild("GlassPlacement", 10))
local LadderPlacement = require(ReplicatedStorage:WaitForChild("LadderPlacement", 10))
local TorchPlacement = require(ReplicatedStorage:WaitForChild("TorchPlacement", 10))
local LanternPlacement = require(ReplicatedStorage:WaitForChild("LanternPlacement", 10))
local SignPlacement = require(ReplicatedStorage:WaitForChild("SignPlacement", 10))
local WallpaperPlacement = require(ReplicatedStorage:WaitForChild("WallpaperPlacement", 10))
local CarpetPlacement = require(ReplicatedStorage:WaitForChild("CarpetPlacement", 10))
local VinePlacement = require(ReplicatedStorage:WaitForChild("VinePlacement", 10))
local ColumnPlacement = require(ReplicatedStorage:WaitForChild("ColumnPlacement", 10))

-- Resolve a glass-style block's template Model from its type + generic shape name.
-- Standard glass lives in Decorations/Glass; glass-style reward sets (CandyLattice)
-- live in their RewardSets folder. GlassPlacement.ResolveTemplate is the single
-- source of truth for the folder + model name per type. Returns the template
-- Instance or nil. Used by the in-place glass-rebuild closures below.
local function resolveGlassTemplate(glassType, genericTemplateName)
	local folderPath, modelName = GlassPlacement.ResolveTemplate(glassType, genericTemplateName)
	local folder = ReplicatedStorage
	for _, folderName in ipairs(string.split(folderPath, "/")) do
		folder = folder and folder:FindFirstChild(folderName)
	end
	if not folder then
		warn(string.format("[Glass] Folder not found: %s (type=%s)", tostring(folderPath), tostring(glassType)))
		return nil
	end
	local template = folder:FindFirstChild(modelName)
	if not template then
		warn(string.format("[Glass] Template not found: %s in %s (type=%s)", tostring(modelName), tostring(folderPath), tostring(glassType)))
		return nil
	end
	return template
end
local ArchitravePlacement = require(ReplicatedStorage:WaitForChild("ArchitravePlacement", 10))
local BlockCollision = require(ReplicatedStorage:WaitForChild("BlockCollision", 10))
local BlockTemplates = ReplicatedStorage:WaitForChild("BlockTemplates", 10)
local BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
local DecorationsFolder = ReplicatedStorage:WaitForChild("Decorations", 10)
local FrameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")

-- Try to load LogicGates module
local LogicGates = nil
pcall(function()
	LogicGates = require(ReplicatedStorage:WaitForChild("LogicGates", 5))
end)

-- Debug: verify folders found (disabled for production)
--[[
if BlocksFolder then
	local children = BlocksFolder:GetChildren()
	print("[BlockHandler] Blocks folder found with " .. #children .. " blocks:")
	for _, child in ipairs(children) do
		print("  - " .. child.Name)
	end
else
	warn("[BlockHandler] Blocks folder NOT FOUND!")
end
]]

-- Load TerrainGenerator for lazy terrain spawning
local TerrainGenerator = nil
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local terrainModule = modulesFolder:WaitForChild("TerrainGenerator", 10)
		if terrainModule then
			TerrainGenerator = require(terrainModule)
			-- print("[BlockHandler] TerrainGenerator loaded successfully!")
		else
			warn("[BlockHandler] TerrainGenerator module NOT FOUND in Modules folder!")
		end
	else
		warn("[BlockHandler] Modules folder NOT FOUND in ServerScriptService!")
	end
end)

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	warn("[BlockHandler] Remotes folder not found! Block placement/removal will not work.")
	return
end

local PlaceBlock = Remotes:FindFirstChild("PlaceBlock")
if not PlaceBlock then
	PlaceBlock = Instance.new("RemoteEvent")
	PlaceBlock.Name = "PlaceBlock"
	PlaceBlock.Parent = Remotes
	print("[BlockHandler] Created PlaceBlock remote")
end

local RemoveBlock = Remotes:FindFirstChild("RemoveBlock")
if not RemoveBlock then
	RemoveBlock = Instance.new("RemoteEvent")
	RemoveBlock.Name = "RemoveBlock"
	RemoveBlock.Parent = Remotes
	print("[BlockHandler] Created RemoveBlock remote")
end

-- Create BuildRejected remote (tells client to undo predictions when server rejects action)
local BuildRejected = Remotes:FindFirstChild("BuildRejected")
if not BuildRejected then
	BuildRejected = Instance.new("RemoteEvent")
	BuildRejected.Name = "BuildRejected"
	BuildRejected.Parent = Remotes
end

-- Create RemoveBlockAtPosition remote if it doesn't exist (for client prediction digging)
local RemoveBlockAtPosition = Remotes:FindFirstChild("RemoveBlockAtPosition")
if not RemoveBlockAtPosition then
	RemoveBlockAtPosition = Instance.new("RemoteEvent")
	RemoveBlockAtPosition.Name = "RemoveBlockAtPosition"
	RemoveBlockAtPosition.Parent = Remotes
end

-- Create StackSnowLayer remote (for snow layer stacking mechanic)
local StackSnowLayer = Remotes:FindFirstChild("StackSnowLayer")
if not StackSnowLayer then
	StackSnowLayer = Instance.new("RemoteEvent")
	StackSnowLayer.Name = "StackSnowLayer"
	StackSnowLayer.Parent = Remotes
end

-- Create TerrainDugPositions remote (tells client which adjacent positions are dug,
-- so client prediction can clean up phantom blocks in saved holes)
local TerrainDugPositions = Remotes:FindFirstChild("TerrainDugPositions")
if not TerrainDugPositions then
	TerrainDugPositions = Instance.new("RemoteEvent")
	TerrainDugPositions.Name = "TerrainDugPositions"
	TerrainDugPositions.Parent = Remotes
end

-- Create FillFrameBlock remote (for filling frame blocks with material)
local FillFrameBlock = Remotes:FindFirstChild("FillFrameBlock")
if not FillFrameBlock then
	FillFrameBlock = Instance.new("RemoteEvent")
	FillFrameBlock.Name = "FillFrameBlock"
	FillFrameBlock.Parent = Remotes
end

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Wait for plot permission check (created by PlotPermissionHandler)
local CheckPlotBuildPermission = nil
task.spawn(function()
	CheckPlotBuildPermission = ReplicatedStorage:WaitForChild("CheckPlotBuildPermission", 10)
	if CheckPlotBuildPermission then
		print("[BlockHandler] CheckPlotBuildPermission loaded")
	else
		warn("[BlockHandler] CheckPlotBuildPermission not found - plot sharing disabled")
	end
end)

-- Load PrivateServerManager for private server permission checks
local PrivateServerManager = nil
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local psModule = modulesFolder:WaitForChild("PrivateServerManager", 5)
		if psModule then
			PrivateServerManager = require(psModule)
			print("[BlockHandler] PrivateServerManager loaded")
		end
	end
end)

-- Debug flags (set to true individually when debugging specific systems)
local DEBUG_STAIRS = false
local DEBUG_CORNER_DETECTION = false
local DEBUG_LOGS = false
local DEBUG_SLABS = false
local DEBUG_DOORS = false
local DEBUG_SURFACE = false
local DEBUG_FENCES = false
local DEBUG_GLASS = false
local DEBUG_LADDERS = false
local DEBUG_TORCHES = false
local DEBUG_LANTERNS = false
local DEBUG_SIGNS = false
local DEBUG_COLLISION = false
local DEBUG_ARCHITRAVES = false
local DEBUG_ARCH = false -- Verbose arch placement diagnostics (off; placement logic verified correct)
local DEBUG_ARCH_FILL = false -- Verbose arch FILL diagnostics (off; fill logic verified correct)

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Convert a world-space vector to a cardinal direction label (for arch debugging).
-- We pick the dominant horizontal axis and report sign + compass name.
local function vectorToCompass(v)
	if not v then return "nil" end
	local absX = math.abs(v.X)
	local absZ = math.abs(v.Z)
	if absX > absZ then
		return v.X > 0 and "+X (EAST)" or "-X (WEST)"
	else
		return v.Z > 0 and "+Z (NORTH)" or "-Z (SOUTH)"
	end
end

-- Format a Vector3 as compact integer grid coords for log readability.
local function gridFmt(v)
	if not v then return "nil" end
	return string.format("(%d,%d,%d)", math.floor(v.X + 0.5), math.floor(v.Y + 0.5), math.floor(v.Z + 0.5))
end

local function getPlayerBuildArea(player)
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea and buildArea:GetAttribute("OwnerUserId") == player.UserId then
			return buildArea
		end
	end
	return nil
end

-- Get the build area that contains a position (for shared building)
local function getBuildAreaAtPosition(position)
	-- First check if we're in MegaPlot mode and position is in MegaPlot
	if PrivateServerManager and PrivateServerManager.IsPrivateServer() then
		local mode = PrivateServerManager.GetMode()
		if mode == "MegaPlot" and _G.MegaPlotVisibility then
			local megaPlotBuildArea = _G.MegaPlotVisibility.GetMegaPlotBuildArea()
			if megaPlotBuildArea then
				local posX = megaPlotBuildArea:GetAttribute("BasePlatePositionX")
				local posZ = megaPlotBuildArea:GetAttribute("BasePlatePositionZ")
				local sizeX = megaPlotBuildArea:GetAttribute("BasePlateSizeX")
				local sizeZ = megaPlotBuildArea:GetAttribute("BasePlateSizeZ")
				local plateTop = megaPlotBuildArea:GetAttribute("BasePlateTop")
				
				if posX and posZ and sizeX and sizeZ and plateTop then
					local halfX = sizeX / 2
					local halfZ = sizeZ / 2
					
					if position.X >= posX - halfX and position.X <= posX + halfX and
					   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
						-- Y bounds check
						local minY = plateTop - (GridConfig.TERRAIN.MAX_DEPTH * BLOCK_SIZE) - BLOCK_SIZE
						local maxY = plateTop + GridConfig.PLOT_HEIGHT
						if position.Y >= minY and position.Y <= maxY then
							return megaPlotBuildArea, 0  -- Plot 0 = MegaPlot
						end
					end
				end
			end
		end
	end
	
	-- Check individual plots
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
				
				if position.X >= posX - halfX and position.X <= posX + halfX and
				   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
					-- Y bounds: from just below surface down to max depth, and up to plot height
					local plateTop = posY + sizeY / 2
					local minY = plateTop - (GridConfig.TERRAIN.MAX_DEPTH * BLOCK_SIZE) - BLOCK_SIZE
					local maxY = plateTop + GridConfig.PLOT_HEIGHT
					if position.Y >= minY and position.Y <= maxY then
						return buildArea, i
					end
				end
			end
		end
	end
	return nil, nil
end

-- Check if player can build at position (own plot OR shared plot OR private server)
local function canPlayerBuildAtPosition(player, position)
	local buildArea, plotNumber = getBuildAreaAtPosition(position)
	if not buildArea or plotNumber == nil then
		print(string.format("[Permission] %s: position not in any plot", player.Name))
		return false, nil -- Position not in any plot
	end
	
	-- MEGAPLOT CHECK: Plot 0 = MegaPlot in private server
	if plotNumber == 0 then
		if PrivateServerManager and PrivateServerManager.IsPrivateServer() then
			-- Everyone can build on MegaPlot in private servers
			return true, buildArea
		else
			return false, nil
		end
	end
	
	-- PRIVATE SERVER CHECK: In private servers, everyone can build on any plot
	if PrivateServerManager and PrivateServerManager.IsPrivateServer() then
		local canBuildPrivate = PrivateServerManager.CanBuildOnPlot(player, plotNumber)
		if canBuildPrivate then
			-- print(string.format("[Permission] %s: PRIVATE SERVER - allowed on plot %d", player.Name, plotNumber))
			return true, buildArea
		end
	end
	
	-- Check if player owns this plot
	local ownerUserId = buildArea:GetAttribute("OwnerUserId")
	if ownerUserId == player.UserId then
		return true, buildArea -- Player owns this plot
	end
	
	-- Check if player has shared access (via PlotPermissionManager)
	if CheckPlotBuildPermission then
		local hasPermission = CheckPlotBuildPermission:Invoke(player, plotNumber)
		print(string.format("[Permission] %s on plot %d (owner: %s): hasPermission = %s", 
			player.Name, plotNumber, tostring(ownerUserId), tostring(hasPermission)))
		if hasPermission then
			return true, buildArea -- Player has shared access
		end
	else
		print("[Permission] CheckPlotBuildPermission not loaded yet!")
	end
	
	return false, nil -- No permission
end

local function isPositionInPlot(player, position)
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false end
	
	-- Try stored baseplate attributes first (after terrain generation)
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posY = buildArea:GetAttribute("BasePlatePositionY")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeY = buildArea:GetAttribute("BasePlateSizeY")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	local platePos, plateSize
	
	if posX and posY and posZ and sizeX and sizeY and sizeZ then
		platePos = Vector3.new(posX, posY, posZ)
		plateSize = Vector3.new(sizeX, sizeY, sizeZ)
	else
		-- Fallback to actual baseplate if it still exists
		local basePlate = buildArea:FindFirstChild("BasePlate")
		if not basePlate then return false end
		platePos = basePlate.Position
		plateSize = basePlate.Size
	end
	
	local halfX = plateSize.X / 2
	local halfZ = plateSize.Z / 2
	
	if position.X < platePos.X - halfX or position.X > platePos.X + halfX then
		return false
	end
	if position.Z < platePos.Z - halfZ or position.Z > platePos.Z + halfZ then
		return false
	end
	
	-- Y bounds: from just below surface down to max depth, and up to plot height
	local plateTop = platePos.Y + plateSize.Y / 2
	local minY = plateTop - (GridConfig.TERRAIN.MAX_DEPTH * BLOCK_SIZE) - BLOCK_SIZE
	local maxY = plateTop + GridConfig.PLOT_HEIGHT
	if position.Y < minY or position.Y > maxY then
		return false
	end
	
	return true
end

-- ============================================
-- HITBOX FOR NON-FULL BLOCKS
-- ============================================
-- Adds an invisible full-cube Part to blocks that don't fill the grid cell
-- (ladders, torches, lanterns, signs, fences, glass, surface blocks, doors)
-- This ensures raycasts can select these blocks even when clicking empty space

local function addBlockHitbox(block, gridPosition)
	if not block then return end
	if block:FindFirstChild("Hitbox") then return end
	
	-- For glass, the default 3x3x3 hitbox is way too generous - it makes the cursor
	-- catch on the glass when the player is aiming at adjacent grass / blocks.
	-- - For special connections (corner / tee / 4-way) the visible Outer/Inner geometry
	--   already covers 2/3/4 sides of the cell with thin walls, so we just rely on the
	--   model's own parts as the clickable region (no extra hitbox part).
	-- - For flat panes (NS / EW) the visible pane is so thin it's hard to click, so we
	--   add a thin hitbox sized to the pane orientation - wide enough to click but not
	--   so wide that it bleeds into neighboring cells.
	if block:GetAttribute("IsGlass") then
		local markAllQueryable
		markAllQueryable = function()
			if block:IsA("BasePart") then
				block.CanQuery = true
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then
						part.CanQuery = true
					end
				end
			end
		end

		local orientation = block:GetAttribute("GlassOrientation") or "NS"
		if orientation == "corner" or orientation == "tee" or orientation == "4way" then
			-- L / T / + shapes: rely on the model's own parts.
			markAllQueryable()
			return
		end

		-- Flat pane: thin hitbox sized to the pane orientation.
		markAllQueryable()
		local PANE_THICKNESS = 0.6
		local hitboxSize
		if orientation == "EW" then
			hitboxSize = Vector3.new(PANE_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
		else -- "NS" or default
			hitboxSize = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, PANE_THICKNESS)
		end

		local hitbox = Instance.new("Part")
		hitbox.Name = "Hitbox"
		hitbox.Anchored = true
		hitbox.CanCollide = false
		hitbox.CanQuery = true
		hitbox.CanTouch = false
		hitbox.CastShadow = false
		hitbox.Transparency = 1
		hitbox.Size = hitboxSize
		hitbox.CFrame = CFrame.new(gridPosition)
		hitbox.Parent = block
		return
	end
	
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanQuery = true  -- Raycasts CAN hit this
	hitbox.CanTouch = false
	hitbox.CastShadow = false
	hitbox.Transparency = 1
	hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
	hitbox.CFrame = CFrame.new(gridPosition)
	hitbox.Parent = block
end

local function applyColorToBlock(block, color, material, materialVariant)
	-- For door models, only color the door panel (skip Hinge/Knob hardware)
	local isDoor = block:GetAttribute("IsDoor") or DoorPlacement.IsDoor(block:GetAttribute("BlockType") or block.Name or "")
	-- For chest models, only color Body and Lid (Edge/Latch get darkened variant)
	local isChest = block:GetAttribute("IsChest") or BlockPresets.IsChest(block:GetAttribute("BlockType") or block.Name or "")
	-- For crafting tables, color Block part with wood, tint Textures with leather
	local blockType = block:GetAttribute("BlockType") or block.Name or ""
	local isCraftingTable = block:GetAttribute("IsCraftingTable") or (BlockPresets.IsCraftingTable and BlockPresets.IsCraftingTable(blockType))
	
	-- Pre-compute darkened color for chest trim (60% darker, desaturated)
	local chestTrimColor = nil
	if isChest and color then
		local h, s, v = color:ToHSV()
		chestTrimColor = Color3.fromHSV(h, s * 0.75, v * 0.38)
	end
	
	-- Pre-compute leather tint and edge trim for crafting table
	local leatherTint = nil
	local ctEdgeTrimColor = nil
	if isCraftingTable then
		leatherTint = BlockPresets.GetCraftingTableLeatherTint and BlockPresets.GetCraftingTableLeatherTint(blockType)
		if not leatherTint then
			leatherTint = Color3.fromRGB(160, 110, 60) -- Fallback warm brown
		end
		if color then
			local h, s, v = color:ToHSV()
			ctEdgeTrimColor = Color3.fromHSV(h, s * 0.75, v * 0.38)
		end
	end
	
	if block:IsA("BasePart") then
		if not isChest and not isCraftingTable then
			block.Color = color
			if material then
				block.Material = material
			end
			if materialVariant and materialVariant ~= "" then
				block.MaterialVariant = materialVariant
			end
		end
	end
	
	for _, child in ipairs(block:GetDescendants()) do
		-- Crafting table: Block=wood, Edge=darkened, Side/Top=leather tint on textures
		if isCraftingTable then
			-- Tint Texture/Decal objects on Side and Top parts with leather color
			if child:IsA("Texture") or child:IsA("Decal") then
				local parentName = child.Parent and child.Parent.Name or ""
				if parentName == "Side" or parentName == "Top" then
					child.Color3 = leatherTint
				end
				continue
			end
			if child:IsA("BasePart") or child:IsA("UnionOperation") then
				local partName = child.Name
				if partName == "Block" then
					-- Wood body: apply wood color + material
					child.Color = color
					if material then
						child.Material = material
					end
					if materialVariant and materialVariant ~= "" then
						child.MaterialVariant = materialVariant
					end
				elseif partName == "Edge" then
					-- Edge trim: darkened wood color, keep template material
					if ctEdgeTrimColor then child.Color = ctEdgeTrimColor end
				end
				-- Side/Top base parts and everything else keep default appearance
			end
			continue
		end
		if child:IsA("BasePart") or child:IsA("UnionOperation") then
			if isDoor and (child.Name == "Hinge" or child.Name == "Knob") then
				continue
			end
			if isChest then
				-- Check which sub-model group this part belongs to
				local ancestor = child.Parent
				local group = nil
				while ancestor and ancestor ~= block do
					local n = ancestor.Name
					if n == "Body" or n == "Lid" or n == "Edge" or n == "Latch" or n == "Darkness" then
						group = n
						break
					end
					ancestor = ancestor.Parent
				end
				-- Also check the part itself (if Body/Lid are direct UnionOperations)
				if not group then
					local n = child.Name
					if n == "Body" or n == "Lid" or n == "Edge" or n == "Latch" or n == "Darkness" then
						group = n
					end
				end
				if group == "Body" or group == "Lid" then
					child.Color = color
					if material then
						child.Material = material
					end
					if materialVariant and materialVariant ~= "" then
						child.MaterialVariant = materialVariant
					end
				elseif group == "Edge" then
					child.Color = chestTrimColor or color
					-- Edge: only color, keep template material/texture
				end
				-- Latch and anything else keeps default
				continue
			end
			child.Color = color
			if material then
				child.Material = material
			end
			if materialVariant and materialVariant ~= "" then
				child.MaterialVariant = materialVariant
			end
		end
	end
end

local function createBlockFromTemplate(templateName, blockId, useBlockModel, blockModelName, blockModelFolder, applyColor, defaultColor, customVariantChild, presetMaterial, presetMaterialVariant, stripeColorMode)
	local template
	local actuallyUsedBlockModel = false
	
	-- If a specific folder is specified, use that
	if blockModelFolder then
		-- Support nested paths like "Decorations/Glass"
		local folder = ReplicatedStorage
		for _, folderName in ipairs(string.split(blockModelFolder, "/")) do
			folder = folder:FindFirstChild(folderName)
			if not folder then break end
		end
		
		if folder then
			local searchName = blockModelName or blockId
			if searchName then
				template = folder:FindFirstChild(searchName)
				if template then
					actuallyUsedBlockModel = true
				end
			end
		end
	end
	
	-- ALWAYS try Blocks folder first using blockId (if no specific folder)
	if not template and blockId and BlocksFolder then
		template = BlocksFolder:FindFirstChild(blockId)
		if template then
			actuallyUsedBlockModel = true
		end
	end
	
	-- Then try blockModelName if specified
	if not template and blockModelName and BlocksFolder then
		template = BlocksFolder:FindFirstChild(blockModelName)
		if template then
			actuallyUsedBlockModel = true
		end
	end
	
	-- If customVariantChild is specified, look for that child within the found template
	-- This is used for blocks with custom Union stair/slab models
	if template and customVariantChild then
		local childTemplate = template:FindFirstChild(customVariantChild)
		if childTemplate then
			template = childTemplate
			print("[Server] Using custom variant child: " .. customVariantChild .. " from " .. tostring(blockModelName or blockId))
		else
			warn("[Server] Custom variant child not found: " .. customVariantChild .. " in " .. tostring(blockModelName or blockId))
			-- Fall through to template fallback
			template = nil
			actuallyUsedBlockModel = false
		end
	end
	
	-- Fallback to BlockTemplates
	if not template and templateName then
		template = BlockTemplates:FindFirstChild(templateName)
		actuallyUsedBlockModel = false
	end
	
	if not template then
		warn("[Server] Template not found: " .. tostring(templateName) .. " (blockId: " .. tostring(blockId) .. ")")
		return nil, false
	end
	
	local block = template:Clone()
	block.Name = blockId or templateName
	
	-- TEXTURE mode (stripeColorMode == "Texture"): the block's grayscale Texture
	-- children carry the stripe pattern; tinting them produces the colored variant.
	-- Tint targets:
	--   * Every Texture/Decal descendant (the stripes)
	--   * Any Part named "Core" (the swirl on candy-cane log end caps)
	-- Everything else (the white "Bark" part) keeps its template color so the
	-- background between stripes stays white. Used by Candy Cane variants.
	if stripeColorMode == "Texture" then
		if block:IsA("BasePart") then
			block.Anchored = true
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then part.Anchored = true end
			end
		end
		if applyColor and defaultColor then
			-- Tint all Texture/Decal descendants (the stripes painted on the bark/faces).
			for _, desc in ipairs(block:GetDescendants()) do
				if desc:IsA("Texture") or desc:IsA("Decal") then
					desc.Color3 = defaultColor
				end
			end
			-- Tint Parts NAMED "Core" — the swirl-pattern end-caps of a candy-cane log.
			-- The body (Bark) intentionally stays its template color (white) so the
			-- background between stripes remains white.
			for _, desc in ipairs(block:GetDescendants()) do
				if desc:IsA("BasePart") and desc.Name == "Core" then
					desc.Color = defaultColor
				end
			end
			-- Top-level Texture/Decal children on a Part template (CandyCaneFull is a
			-- Union with Texture children directly).
			if block:IsA("BasePart") then
				for _, child in ipairs(block:GetChildren()) do
					if child:IsA("Texture") or child:IsA("Decal") then
						child.Color3 = defaultColor
					end
				end
			end
		end
		print("[Server] Created block: " .. tostring(blockId or templateName) .. " | UsedBlockModel: " .. tostring(actuallyUsedBlockModel) .. " | ApplyColor: " .. tostring(applyColor) .. " (Texture mode)")
		return block, actuallyUsedBlockModel
	end
	
	if block:IsA("BasePart") then
		block.Anchored = true
		-- Apply color, material, and materialVariant if specified
		if applyColor then
			if defaultColor then
				block.Color = defaultColor
			end
			if presetMaterial then
				block.Material = presetMaterial
			end
			if presetMaterialVariant and presetMaterialVariant ~= "" then
				block.MaterialVariant = presetMaterialVariant
			end
		end
	elseif block:IsA("Model") then
		-- For door models, skip hardware parts (Hinge/Knob keep template appearance)
		local isDoorModel = blockId and DoorPlacement.IsDoor(blockId)
		-- For chest models, Body/Lid get wood color, Edge/Latch get darkened variant
		local isChestModel = blockId and BlockPresets and BlockPresets.IsChest and BlockPresets.IsChest(blockId)
		local chestTrimColor = nil
		if isChestModel and defaultColor then
			local h, s, v = defaultColor:ToHSV()
			chestTrimColor = Color3.fromHSV(h, s * 0.75, v * 0.38)
		end
		-- For crafting table models: Block=wood, Edge=darkened, Side/Top textures=leather tint
		local isCraftingTableModel = blockId and BlockPresets and BlockPresets.IsCraftingTable and BlockPresets.IsCraftingTable(blockId)
		local ctLeatherTint = nil
		local ctEdgeTrimColor = nil
		if isCraftingTableModel then
			ctLeatherTint = BlockPresets.GetCraftingTableLeatherTint and BlockPresets.GetCraftingTableLeatherTint(blockId)
			if not ctLeatherTint then ctLeatherTint = Color3.fromRGB(160, 110, 60) end
			if defaultColor then
				local h, s, v = defaultColor:ToHSV()
				ctEdgeTrimColor = Color3.fromHSV(h, s * 0.75, v * 0.38)
			end
		end
		-- Crafting table: tint Texture/Decal objects on Side/Top parts (before BasePart loop)
		if isCraftingTableModel and applyColor and ctLeatherTint then
			for _, desc in ipairs(block:GetDescendants()) do
				if (desc:IsA("Texture") or desc:IsA("Decal")) then
					local parentName = desc.Parent and desc.Parent.Name or ""
					if parentName == "Side" or parentName == "Top" then
						desc.Color3 = ctLeatherTint
					end
				end
			end
		end
		for _, part in ipairs(block:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				-- Apply color, material, and materialVariant if specified
				if applyColor then
					-- Skip door hardware (hinges and knobs keep their metallic look)
					if isDoorModel and (part.Name == "Hinge" or part.Name == "Knob") then
						continue
					end
					-- Crafting table: Block=wood, Edge=darkened, Side/Top keep template
					if isCraftingTableModel then
						if part.Name == "Block" then
							if defaultColor then part.Color = defaultColor end
							if presetMaterial then part.Material = presetMaterial end
							if presetMaterialVariant and presetMaterialVariant ~= "" then
								part.MaterialVariant = presetMaterialVariant
							end
						elseif part.Name == "Edge" then
							if ctEdgeTrimColor then part.Color = ctEdgeTrimColor end
							-- Edge: only color, keep template material
						end
						-- Side/Top and everything else keep default appearance
						continue
					end
					-- Chest: check which sub-model group this part belongs to
					if isChestModel then
						local ancestor = part.Parent
						local group = nil
						while ancestor and ancestor ~= block do
							local n = ancestor.Name
							if n == "Body" or n == "Lid" or n == "Edge" or n == "Latch" or n == "Darkness" then
								group = n; break
							end
							ancestor = ancestor.Parent
						end
						if not group then
							local n = part.Name
							if n == "Body" or n == "Lid" or n == "Edge" or n == "Latch" or n == "Darkness" then group = n end
						end
						if group == "Latch" or group == "Darkness" then continue end
						if group == "Edge" then
							if chestTrimColor then part.Color = chestTrimColor end
							-- Edge: only color, keep template material/texture
							continue
						end
						-- Body/Lid fall through to normal color application below
					end
					if defaultColor then
						part.Color = defaultColor
					end
					if presetMaterial then
						part.Material = presetMaterial
					end
					if presetMaterialVariant and presetMaterialVariant ~= "" then
						part.MaterialVariant = presetMaterialVariant
					end
				end
			end
		end
	end
	
	print("[Server] Created block: " .. tostring(blockId or templateName) .. " | UsedBlockModel: " .. tostring(actuallyUsedBlockModel) .. " | ApplyColor: " .. tostring(applyColor))
	return block, actuallyUsedBlockModel
end

local function createDecorationFromTemplate(decorationName, customFolder)
	-- customFolder (optional): nested path like "RewardSets/CandyBlocks" that
	-- overrides the default Decorations folder. Used by reward-set decorations
	-- (e.g. CandyCaneSapling) which live alongside their themed pack rather
	-- than in the global Decorations folder.
	local sourceFolder = DecorationsFolder
	if customFolder then
		local folder = ReplicatedStorage
		for _, folderName in ipairs(string.split(customFolder, "/")) do
			folder = folder:FindFirstChild(folderName)
			if not folder then break end
		end
		if folder then
			sourceFolder = folder
		else
			warn("[Server] Decoration custom folder not found: " .. tostring(customFolder))
		end
	end
	
	if not sourceFolder then
		warn("[Server] Decorations folder not found!")
		return nil
	end
	
	local template = sourceFolder:FindFirstChild(decorationName)
	if not template then
		warn("[Server] Decoration template not found: " .. tostring(decorationName)
			.. " (folder: " .. (customFolder or "Decorations") .. ")")
		return nil
	end
	
	local decoration = template:Clone()
	decoration.Name = decorationName .. "_" .. math.random(100000, 999999)
	
	if decoration:IsA("BasePart") then
		decoration.Anchored = true
		decoration.CanCollide = false
	elseif decoration:IsA("Model") then
		for _, part in ipairs(decoration:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
	end
	
	return decoration
end

local function setBlockCFrame(block, cframe, usedBlockModel, blockId)
	local isFence = blockId and FencePlacement.IsFence(blockId)
	local isLog = blockId and LogPlacement.IsLog(blockId)
	local isSurfaceBlock = blockId and SurfacePlacement.IsSurfaceBlock(blockId)
	local isGlass = blockId and GlassPlacement.IsGlass(blockId)
	local isLadder = blockId and LadderPlacement.IsLadder(blockId)
	local isTorch = blockId and BlockPresets and BlockPresets.IsTorch(blockId)
	local isLantern = blockId and BlockPresets and BlockPresets.IsLantern and BlockPresets.IsLantern(blockId)
	local isSign = blockId and BlockPresets and BlockPresets.IsSign and BlockPresets.IsSign(blockId)
	local isFrameDoor = blockId and BlockPresets and BlockPresets.IsFrameBlock(blockId) and DoorPlacement.IsDoor(blockId)
	
	-- Check if this is a simple full-block Model (not a multi-block like doors/pistons)
	-- These should be placed like Parts (center at grid position) without the Y offset
	local isSimpleFullBlockModel = blockId and BlockPresets and BlockPresets.GetPreset(blockId)
	if isSimpleFullBlockModel then
		local preset = BlockPresets.GetPreset(blockId)
		-- Simple full blocks: not doors, not axis-rotation (pistons/logs), not any special type
		local isCampfire = preset and preset.IsCampfire
		isSimpleFullBlockModel = preset and not preset.IsDoor
			and not LogPlacement.UsesAxisRotation(blockId)
			and not StairPlacement.IsStairType(blockId)
			and not SlabPlacement.IsSlab(blockId)
			and not isSurfaceBlock and not isFence and not isGlass
			and not isLadder and not isTorch and not isLantern and not isSign
			and not isCampfire
			and not preset.IsBed
			and preset.Shape == "Block"
	else
		isSimpleFullBlockModel = false
	end
	
	if block:IsA("BasePart") then
		-- For unions (like fences and ladders), use PivotTo to respect pivot offset
		if isFence or isLadder then
			block:PivotTo(cframe)
		else
			block.CFrame = cframe
		end
	elseif block:IsA("Model") then
		if isSimpleFullBlockModel then
			-- Simple full-block Models (like GrassBlock, GlassBlock)
			-- Check if pivot is at center or bottom - only offset if pivot is at the bottom
			local bbCFrame = block:GetBoundingBox()
			local pivotOffsetY = block.WorldPivot.Position.Y - bbCFrame.Position.Y
			local pivotIsCenter = math.abs(pivotOffsetY) < 0.1
			if pivotIsCenter then
				block:PivotTo(cframe)
			else
				local offsetCFrame = cframe * CFrame.new(0, -BLOCK_SIZE / 2, 0)
				block:PivotTo(offsetCFrame)
			end
		elseif isFrameDoor then
			-- Frame door models have their pivot at bounding box center (not bottom-center like regular doors)
			-- and the Union part is pre-rotated 90° around Y, so we compensate
			local _, bbSize = block:GetBoundingBox()
			local pivotY = block.WorldPivot.Position.Y
			local bbCFrame = block:GetBoundingBox()
			local bbBottomY = bbCFrame.Position.Y - bbSize.Y / 2
			local pivotToBottom = pivotY - bbBottomY -- Distance from pivot to model bottom
			-- Place so bottom of door is at grid cell floor, with 90° rotation compensation
			local offsetCFrame = cframe * CFrame.Angles(0, math.rad(90), 0) * CFrame.new(0, -BLOCK_SIZE / 2 + pivotToBottom, 0)
			block:PivotTo(offsetCFrame)
		elseif blockId and BlockPresets and BlockPresets.IsCraftingTable and BlockPresets.IsCraftingTable(blockId) then
			-- Crafting table: center pivot, no offset needed (full-size block)
			block:PivotTo(cframe)
		elseif blockId and BlockPresets and BlockPresets.IsBed and BlockPresets.IsBed(blockId) then
			-- Beds: model is 6 studs long with pivot at its center.
			local _, bbSize = block:GetBoundingBox()
			local pivotY = block.WorldPivot.Position.Y
			local bbCFrameLocal = block:GetBoundingBox()
			local bbBottomY = bbCFrameLocal.Position.Y - bbSize.Y / 2
			local pivotToBottom = pivotY - bbBottomY
			block:PivotTo(cframe * CFrame.new(0, -BLOCK_SIZE / 2 + pivotToBottom, 0))
		elseif blockId and BlockPresets and BlockPresets.IsChest and BlockPresets.IsChest(blockId) then
			-- Chests: PivotTo with Y offset to sit flush on cell floor
			block:PivotTo(cframe * CFrame.new(0, -0.25, 0))
		elseif blockId and BlockPresets and BlockPresets.IsFurnace and BlockPresets.IsFurnace(blockId) then
			-- Furnace: center pivot, no offset needed (full-size block like crafting table)
			block:PivotTo(cframe)
		elseif not isSurfaceBlock and not isFence and not isGlass and not isLadder and not isTorch and not isLantern and not isSign then
			-- Multi-block Models (doors, pistons) need offset to account for bottom-center pivots
			local offsetCFrame = cframe * CFrame.new(0, -BLOCK_SIZE / 2, 0)
			block:PivotTo(offsetCFrame)
		else
			block:PivotTo(cframe)
		end
	end
end

-- ============================================
-- STAIR CORNER UPDATE
-- ============================================

local function replaceStairWithCorner(adjacentStair, adjacentPos, newCornerType, blocksFolder, newStairDirection)
	local oldBlock = adjacentStair.object
	local oldBlockType = oldBlock:GetAttribute("BlockType")
	local oldRotation = oldBlock:GetAttribute("Rotation") or 0
	local oldDirection = oldBlock:GetAttribute("StairDirection")
	local oldUpsideDown = adjacentStair.upsideDown
	local placedBy = oldBlock:GetAttribute("PlacedBy")
	
	-- If no stored direction, calculate from rotation
	if oldDirection == nil then
		oldDirection = StairPlacement.RotationToDirection(oldRotation)
	end
	
	local oldMaterial, oldColor, oldMaterialVariant
	if oldBlock:IsA("BasePart") then
		oldMaterial = oldBlock.Material
		oldColor = oldBlock.Color
		oldMaterialVariant = oldBlock.MaterialVariant
	elseif oldBlock:IsA("Model") then
		local firstPart = oldBlock:FindFirstChildWhichIsA("BasePart")
		if firstPart then
			oldMaterial = firstPart.Material
			oldColor = firstPart.Color
			oldMaterialVariant = firstPart.MaterialVariant
		end
	end
	
	-- Check if this is a frame stair - use FrameBlocks corner model instead of BlockTemplates
	local isFrameStair = oldBlock:GetAttribute("IsFrameBlock") or BlockPresets.IsFrameBlock(oldBlockType or "")
	local isArchBlock = oldBlock:GetAttribute("IsArch") or StairPlacement.IsArchType(oldBlockType or "")
	local templateName, newBlock
	
	local frameOuterRotationOffset = 0  -- Used for both: regular frame outer stair corners AND all arch frame corners
	if isFrameStair then
		if isArchBlock then
			-- Arch frame corners: ArchInnerFrame / ArchOuterFrame (or ArchLarge variants)
			local archTemplates = StairPlacement.GetArchTemplateNames(oldBlockType)
			local frameCornerName = newCornerType == "inner" and (archTemplates.Inner .. "Frame") or (archTemplates.Outer .. "Frame")
			newBlock = createBlockFromTemplate(nil, oldBlockType, false, frameCornerName, "FrameBlocks")
			if DEBUG_ARCH then
				print(string.format("[ARCH] replaceStairWithCorner frame: type=%s corner=%s template=%s", oldBlockType, newCornerType, frameCornerName))
			end
			-- Arch frame corner offsets: upright+inner=+90, upright+outer=0,
			-- upside-down+inner=+270, upside-down+outer=0.
			if oldUpsideDown then
				frameOuterRotationOffset = (newCornerType == "inner") and 270 or 0
			else
				frameOuterRotationOffset = (newCornerType == "inner") and 90 or 0
			end
		else
			local frameCornerName = newCornerType == "inner" and "FrameStairsCornerInner" or "FrameStairsCornerOuter"
			newBlock = createBlockFromTemplate(nil, oldBlockType, false, frameCornerName, "FrameBlocks")
		end
		if newCornerType == "outer" and not isArchBlock then
			frameOuterRotationOffset = oldUpsideDown and 90 or -90
		end
	elseif isArchBlock then
		-- Solid arch corners: ArchInner / ArchOuter (or ArchLarge variants)
		local archTemplates = StairPlacement.GetArchTemplateNames(oldBlockType)
		templateName = newCornerType == "inner" and archTemplates.Inner or archTemplates.Outer
		newBlock = createBlockFromTemplate(templateName, oldBlockType)
		if DEBUG_ARCH then
			print(string.format("[ARCH] replaceStairWithCorner solid: type=%s corner=%s template=%s", oldBlockType, newCornerType, templateName))
		end
	else
		templateName = newCornerType == "inner" and "StairInnerCorner" or "StairOuterCorner"
		newBlock = createBlockFromTemplate(templateName, oldBlockType)
	end
	
	if newBlock then
		-- Use the lookup table to get correct corner rotation (pass upsideDown for 90° adjustment)
		local cornerRotation = StairPlacement.GetCornerRotation(oldDirection, newStairDirection, newCornerType, oldUpsideDown)
		
		if DEBUG_CORNER_DETECTION then
			print(string.format("[ReplaceCorner] existing=%s, new=%s, type=%s -> rotation=%d frame=%s",
				StairPlacement.GetDirectionName(oldDirection),
				StairPlacement.GetDirectionName(newStairDirection),
				newCornerType, cornerRotation, tostring(isFrameStair)))
		end
		
		local adjustedRotation = (cornerRotation + frameOuterRotationOffset) % 360
		-- All stair/arch unions have consistent bottom-center pivots
		local cframe = StairPlacement.GetStairCFrame(adjacentPos, adjustedRotation, oldUpsideDown)
		if isArchBlock and DEBUG_ARCH then
			print(string.format("[ARCH] replaceStairWithCorner CFrame: rot=%d upsideDown=%s corner=%s", adjustedRotation, tostring(oldUpsideDown), newCornerType))
		end
		setBlockCFrame(newBlock, cframe)
		
		if oldMaterial and oldColor then
			applyColorToBlock(newBlock, oldColor, oldMaterial, oldMaterialVariant)
		end
		
		newBlock:SetAttribute("BlockType", oldBlockType)
		newBlock:SetAttribute("PlacedBy", placedBy)
		newBlock:SetAttribute("Rotation", adjustedRotation)
		newBlock:SetAttribute("StairDirection", oldDirection)  -- Keep original direction for reference
		newBlock:SetAttribute("IsUpsideDown", oldUpsideDown)
		newBlock:SetAttribute("CornerType", newCornerType)
		if isFrameStair then
			newBlock:SetAttribute("IsFrameBlock", true)
		end
		if isArchBlock then
			newBlock:SetAttribute("IsArch", true)
		end
		
		newBlock.Parent = blocksFolder
		oldBlock:Destroy()
		
		return true
	end
	
	return false
end

local function updateExistingStairsToCorners(newStairPosition, newStairDirection, newStairUpsideDown, blocksFolder, typeChecker)
	local updatedStairs = {}
	
	if DEBUG_CORNER_DETECTION then
		print(string.format("[UpdateExisting] Checking adjacent to new stair at (%.1f, %.1f, %.1f) dir=%s",
			newStairPosition.X, newStairPosition.Y, newStairPosition.Z,
			StairPlacement.GetDirectionName(newStairDirection)))
	end
	
	for checkDir = 0, 3 do
		local offset = StairPlacement.GetDirectionOffset(checkDir) * BLOCK_SIZE
		local adjacentPos = newStairPosition + offset
		
		local adjacentStair = StairPlacement.GetStairAt(adjacentPos, blocksFolder, typeChecker)
		
		if adjacentStair and adjacentStair.upsideDown == newStairUpsideDown then
			if DEBUG_CORNER_DETECTION then
				print(string.format("[UpdateExisting] Found adjacent stair at %s: dir=%s",
					StairPlacement.GetDirectionName(checkDir),
					StairPlacement.GetDirectionName(adjacentStair.direction)))
			end
			
			local existingCornerType = adjacentStair.object:GetAttribute("CornerType")
			
			local newCornerType = StairPlacement.ShouldExistingStairBecomeCorner(
				adjacentPos,
				adjacentStair.direction,
				adjacentStair.upsideDown,
				newStairPosition,
				newStairDirection,
				blocksFolder,
				typeChecker
			)
			
			if DEBUG_CORNER_DETECTION then
				print(string.format("[UpdateExisting] ShouldBecomeCorner result: %s (current: %s)", tostring(newCornerType), tostring(existingCornerType)))
			end
			
			-- Skip if already the correct corner type, or if no change needed
			-- But allow OUTER -> INNER upgrade (INNER takes priority)
			if not newCornerType then
				continue
			end
			
			if existingCornerType == newCornerType then
				if DEBUG_CORNER_DETECTION then
					print("[UpdateExisting] Skipping - already correct corner type")
				end
				continue
			end
			
			-- Allow upgrade from OUTER to INNER
			if existingCornerType == "outer" and newCornerType ~= "inner" then
				if DEBUG_CORNER_DETECTION then
					print("[UpdateExisting] Skipping - already outer and not upgrading to inner")
				end
				continue
			end
			
			if newCornerType then
				if replaceStairWithCorner(adjacentStair, adjacentPos, newCornerType, blocksFolder, newStairDirection) then
					table.insert(updatedStairs, {
						direction = StairPlacement.GetDirectionName(checkDir),
						cornerType = newCornerType
					})
				end
			end
		end
	end
	
	return updatedStairs
end

-- ============================================
-- PLACE BLOCK
-- ============================================

if PlaceBlock then
PlaceBlock.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then return end
	if not data.BlockType or not data.Position then return end
	print(string.format("[BB-NET] SERVER <- PlaceBlock from=%s type=%s pos=(%.1f,%.1f,%.1f)", player.Name, tostring(data.BlockType), data.Position.X, data.Position.Y, data.Position.Z))
	
	if not BlockPresets then return end
	
	local preset = BlockPresets.GetPreset(data.BlockType)
	if not preset then return end
	
	local shapeData = BlockPresets.GetShape(preset.Shape)
	if not shapeData then return end
	
	local position = data.Position
	if typeof(position) ~= "Vector3" then return end
	
	-- Check if player can build at this position (own plot OR shared access)
	local canBuild, buildArea = canPlayerBuildAtPosition(player, position)
	if not canBuild or not buildArea then
		-- Notify client to undo any prediction it made
		BuildRejected:FireClient(player, "place", position)
		return
	end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		blocksFolder = Instance.new("Folder")
		blocksFolder.Name = "Blocks"
		blocksFolder.Parent = buildArea
	end
	
	-- Handle decoration placement separately
	if preset.IsDecoration and data.DecorationData then
		local decoName = data.DecorationData.DecorationName
		local decoOffset = data.DecorationData.Offset or Vector3.new(0, 0, 0)
		
		local decoration = createDecorationFromTemplate(decoName, preset.BlockModelFolder)
		if not decoration then return end
		
		-- Calculate final position with offset
		local finalPos = position + decoOffset
		
		-- Calculate parent block position (block center below decoration)
		local parentBlockPos = position - Vector3.new(0, BLOCK_SIZE / 2, 0)
		local parentX = math.round(parentBlockPos.X)
		local parentY = math.round(parentBlockPos.Y)
		local parentZ = math.round(parentBlockPos.Z)
		
		-- Check if placing inside a snow layer (decoration at same grid cell as snow)
		local insideSnowLayer = false
		local snowCheckIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		if snowCheckIndex then
			local snowCandidates = snowCheckIndex:GetBlocksAt(position)
			for _, item in ipairs(snowCandidates) do
				if item:GetAttribute("BlockType") == "SnowLayer" then
					local layers = item:GetAttribute("SnowLayers") or 1
					if layers < 8 then
						insideSnowLayer = true
						-- Parent is the snow layer itself (so breaking snow breaks the decoration)
						parentX = math.round(position.X)
						parentY = math.round(position.Y)
						parentZ = math.round(position.Z)
						print(string.format("[Decoration] Placing %s inside SnowLayer (%d layers) at (%.1f, %.1f, %.1f)",
							preset.Id, layers, position.X, position.Y, position.Z))
						break
					end
				end
			end
		end
		
		-- Check placement restrictions (grass/flowers only on dirt/grass, sugar cane on dirt/grass/sand, etc.)
		-- Skip restrictions when placing inside a snow layer (snow acts as valid ground)
		if not insideSnowLayer then
			local restrictions = BlockPresets.GetPlacementRestrictions(preset.Id)
			if restrictions then
				-- Find the block below to check its type (O(1) spatial lookup)
				local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
				local blockBelow = spatialIndex:GetBlockAt(parentBlockPos)
				
				if blockBelow then
					local blockTypeBelow = blockBelow:GetAttribute("BlockType")
					if blockTypeBelow and not BlockPresets.CanPlaceDecorationOn(preset.Id, blockTypeBelow) then
						print(string.format("[Decoration] BLOCKED - %s cannot be placed on %s (only on: %s)",
							preset.Id, blockTypeBelow, table.concat(restrictions, ", ")))
						decoration:Destroy()
						return
					end
				else
					-- No block below at all - decoration needs a valid block beneath it
					print(string.format("[Decoration] BLOCKED - %s requires a block beneath it (one of: %s)",
						preset.Id, table.concat(restrictions, ", ")))
					decoration:Destroy()
					return
				end
			end
		end
		
		-- Check if there's already a decoration on this block (O(1) spatial lookup)
		local decoSpatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		local decoCheckPos = Vector3.new(parentX, parentY, parentZ)
		-- Decorations are stored at their visual position (above the parent block)
		-- Check at parent position and one level above
		for _, yOff in ipairs({0, BLOCK_SIZE}) do
			local checkPos = decoCheckPos + Vector3.new(0, yOff, 0)
			local candidates = decoSpatialIndex:GetBlocksAt(checkPos)
			for _, item in ipairs(candidates) do
				if item:GetAttribute("IsDecoration") then
					local existingParentX = item:GetAttribute("ParentBlockX")
					local existingParentY = item:GetAttribute("ParentBlockY")
					local existingParentZ = item:GetAttribute("ParentBlockZ")
					if existingParentX and existingParentY and existingParentZ then
						if math.abs(existingParentX - parentX) < 1 and
						   math.abs(existingParentY - parentY) < 1 and
						   math.abs(existingParentZ - parentZ) < 1 then
							print(string.format("[Decoration] BLOCKED - already a decoration on block (%.0f, %.0f, %.0f)",
								parentX, parentY, parentZ))
							decoration:Destroy()
							return
						end
					end
				end
			end
		end
		
		-- Cactus skips the 45-degree rotation (stacks vertically)
		local noRotationDecorations = {
			["Cactus"] = true,
		}
		local rotation45 = noRotationDecorations[decoName] and CFrame.new() or CFrame.Angles(0, math.rad(45), 0)
		
		if decoration:IsA("Model") then
			-- For Models: pivot is at bottom, so position directly at placement pos
			decoration:PivotTo(CFrame.new(finalPos) * rotation45)
		elseif decoration:IsA("BasePart") then
			-- For BaseParts (including Unions): use PivotTo to respect custom pivot points
			-- If pivot is at bottom-center, this positions correctly
			decoration:PivotTo(CFrame.new(finalPos) * rotation45)
		end
		
		-- Set attributes
		decoration:SetAttribute("BlockType", preset.Id)
		decoration:SetAttribute("PlacedBy", player.UserId)
		decoration:SetAttribute("IsDecoration", true)
		-- Store parent block position (for cleanup when block is broken)
		decoration:SetAttribute("ParentBlockX", parentX)
		decoration:SetAttribute("ParentBlockY", parentY)
		decoration:SetAttribute("ParentBlockZ", parentZ)
		
		-- Apply biome color to grass decorations (ShortGrass, TallGrass)
		if decoName == "ShortGrass" or decoName == "TallGrass" then
			local currentBiome = buildArea:GetAttribute("CurrentBiome")
			local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
			
			if currentBiome then
				local biomeColors = BiomeConfig.GetBiomeColors(currentBiome)
				if biomeColors and biomeColors.GrassColor then
					-- Use DecorationMultiplier for grass decorations
					local decorationColor = BiomeConfig.GetSeasonalDecorationColor(biomeColors.GrassColor, currentSeason)
					
					-- Apply slight brightness variation
					local h, s, v = decorationColor:ToHSV()
					local valVariation = (math.random() - 0.5) * 0.03
					local finalColor = Color3.fromHSV(h, s, math.clamp(v + valVariation, 0.3, 1))
					
					-- Apply color to all parts
					if decoration:IsA("BasePart") then
						decoration.Color = finalColor
					elseif decoration:IsA("Model") then
						for _, part in ipairs(decoration:GetDescendants()) do
							if part:IsA("BasePart") then
								part.Color = finalColor
							end
						end
					end
					
					decoration:SetAttribute("Biome", currentBiome)
					decoration:SetAttribute("Season", currentSeason)
				end
			end
		end
		
		decoration.Parent = blocksFolder
		print(string.format("[Decoration] Placed %s at (%.1f, %.1f, %.1f) with offset (%.2f, 0, %.2f)",
			decoName, finalPos.X, finalPos.Y, finalPos.Z, decoOffset.X, decoOffset.Z))
		
		-- Register saplings with SaplingHandler for growth tracking
		print(string.format("[Decoration] BlockPresets.IsSapling('%s') = %s", preset.Id, tostring(BlockPresets.IsSapling(preset.Id))))
		if BlockPresets.IsSapling(preset.Id) then
			print(string.format("[Sapling] Attempting to register %s...", preset.Id))
			print(string.format("[Sapling] decoration.Parent = %s", tostring(decoration.Parent)))
			
			-- Try multiple methods to register the sapling
			local registered = false
			
			-- Method 1: Try _G.SaplingHandler directly
			local SaplingHandler = _G.SaplingHandler
			if SaplingHandler then
				SaplingHandler.RegisterSapling(decoration)
				registered = true
				print(string.format("[Sapling] Registered %s via _G.SaplingHandler", preset.Id))
			else
				-- Method 2: Try BindableFunction
				local RegisterSaplingBindable = ReplicatedStorage:FindFirstChild("RegisterSapling")
				if RegisterSaplingBindable then
					local success = pcall(function()
						RegisterSaplingBindable:Invoke(decoration)
					end)
					if success then
						registered = true
						print(string.format("[Sapling] Registered %s via BindableFunction", preset.Id))
					end
				end
			end
			
			-- Method 3: Retry after a short delay if not registered yet
			if not registered then
				task.delay(1, function()
					if not decoration or not decoration.Parent then return end -- Sapling was destroyed
					
					local SaplingHandlerDelayed = _G.SaplingHandler
					if SaplingHandlerDelayed then
						SaplingHandlerDelayed.RegisterSapling(decoration)
						print(string.format("[Sapling] Registered %s via delayed _G.SaplingHandler", preset.Id))
					else
						-- Last resort: try BindableFunction again
						local RegisterSaplingBindable = ReplicatedStorage:FindFirstChild("RegisterSapling")
						if RegisterSaplingBindable then
							pcall(function()
								RegisterSaplingBindable:Invoke(decoration)
							end)
							print(string.format("[Sapling] Registered %s via delayed BindableFunction", preset.Id))
						else
							warn("[Sapling] FAILED to register sapling - SaplingHandler not available!")
						end
					end
				end)
			end
		end
		return
	end
	
	local rotation = data.Rotation or 0
	local isStair = StairPlacement.IsStairType(data.BlockType)
	local isLog = LogPlacement.IsLog(data.BlockType)
	local usesAxisRotation = LogPlacement.UsesAxisRotation(data.BlockType) -- For logs AND pistons
	local isSlab = SlabPlacement.IsSlab(data.BlockType)
	local isDoor = DoorPlacement.IsDoor(data.BlockType)
	local isSurfaceBlock = SurfacePlacement.IsSurfaceBlock(data.BlockType)
	local isWallpaperFrame = WallpaperPlacement.IsWallpaperFrame(data.BlockType)
	local isFence = FencePlacement.IsFence(data.BlockType)
	local isGlass = GlassPlacement.IsGlass(data.BlockType)
	local isSnowLayer = data.BlockType == "SnowLayer"
	local isLadder = LadderPlacement.IsLadder(data.BlockType)
	local isCarpet = CarpetPlacement.IsCarpet(data.BlockType)
	local isVine = VinePlacement.IsVine(data.BlockType)
	local isColumn = ColumnPlacement.IsColumn(data.BlockType)
	local isArchitrave = BlockPresets.IsArchitrave and BlockPresets.IsArchitrave(data.BlockType)
	local isChest = BlockPresets.IsChest and BlockPresets.IsChest(data.BlockType)
	local isBed = BlockPresets.IsBed and BlockPresets.IsBed(data.BlockType)
	local isCraftingTable = BlockPresets.IsCraftingTable and BlockPresets.IsCraftingTable(data.BlockType)
	local isFurnace = BlockPresets.IsFurnace and BlockPresets.IsFurnace(data.BlockType)
	local isArch = StairPlacement.IsArchType(data.BlockType)
	local upsideDown = false
	local direction = nil
	local logAxis = "Y" -- Default to vertical for logs/pistons
	local slabOrientation = "bottom" -- Default slab orientation
	local doorDirection = 0 -- Default door direction
	local doorDepth = "middle" -- Default door depth
	local doorHingeSide = "left" -- Default door hinge side
	local surfaceFace = "Top" -- Default surface face
	local surfaceHostPosition = nil -- Position of host block for surface attachment
	local fenceConnectionType = "post" -- Default fence connection type
	local glassConnectionType = "blank" -- Default glass connection type
	local glassRotationCFrame = CFrame.new() -- Default glass rotation
	local glassOrientation = "NS" -- Default glass orientation (NS or EW)
	local glassPositionOffset = nil -- Position offset for corner pieces
	local glassRotationDegrees = 0 -- Rotation degrees for special connections (corner/tee/4way)
	local ladderFace = "North" -- Default ladder face
	local ladderRotation = 0 -- Default ladder rotation
	local vineFace = "North" -- Default vine face
	local vineRotation = 0 -- Default vine rotation
	local torchFace = "Top" -- Default torch face
	local torchRotation = 0 -- Default torch rotation
	local torchModelName = "TorchStraight" -- Default torch model
	local torchIsAngled = false -- Whether torch is angled (side placement)
	local lanternFace = "Top" -- Default lantern face
	local lanternIsHanging = false -- Whether lantern is hanging (bottom placement)
	local signFace = "Top" -- Default sign face
	local signRotation = 0 -- Default sign rotation (standing signs: 0-15 * 22.5°, wall signs: 0/90/180/-90)
	local signRotationIndex = 0 -- Rotation index for standing signs (0-15)
	local signType = nil -- "standing" or "wall"
	local signModelName = nil -- "SignStanding" or "Sign"
	local isOnFencePost = false -- Whether wall sign is on a fence post (flush positioning)
	local architraveConnectionType = "single" -- Default architrave connection type
	
	-- Process axis rotation data (logs AND pistons)
	if usesAxisRotation and data.LogData then
		logAxis = data.LogData.Axis or "Y"
	end
	
	-- Process slab-specific data
	if isSlab and data.SlabData then
		slabOrientation = data.SlabData.Orientation or "bottom"
		if DEBUG_SLABS then
			print(string.format("[Slab] Received orientation: %s", slabOrientation))
		end
	end
	
	-- Process door-specific data
	if isDoor and data.DoorData then
		doorDirection = data.DoorData.Direction or 0
		doorDepth = data.DoorData.Depth or "middle"
		doorHingeSide = data.DoorData.HingeSide or "left"
		
		-- If no direction provided, calculate from look vector
		if data.DoorData.LookVector and typeof(data.DoorData.LookVector) == "Vector3" then
			doorDirection = DoorPlacement.GetDirectionFromLookVector(data.DoorData.LookVector)
		end
		
		if DEBUG_DOORS then
			print(string.format("[Door] Received direction: %s, depth: %s, hinge: %s", 
				DoorPlacement.GetDirectionName(doorDirection), 
				DoorPlacement.GetDepthName(doorDepth),
				DoorPlacement.GetHingeSideName(doorHingeSide)))
		end
	end
	
	-- Process surface-specific data (buttons, pressure plates)
	if isSurfaceBlock and data.SurfaceData then
		surfaceFace = data.SurfaceData.Face or "Top"
		surfaceHostPosition = data.SurfaceData.HostPosition
		
		if DEBUG_SURFACE then
			print(string.format("[Surface] Received face: %s, host position: %s", 
				surfaceFace, tostring(surfaceHostPosition)))
		end
	end
	
	-- Process wallpaper frame data
	local wallpaperFace = "Top"
	local wallpaperHostPosition = nil
	if isWallpaperFrame and data.WallpaperData then
		wallpaperFace = data.WallpaperData.Face or "Top"
		wallpaperHostPosition = data.WallpaperData.HostPosition
		print(string.format("[Wallpaper] Received face: %s, host position: %s",
			wallpaperFace, tostring(wallpaperHostPosition)))
	end
	
	-- Process stair-specific data (arches use the same placement system)
	if (isStair or isArch) and data.StairData then
		if isArch and DEBUG_ARCH then
			print(string.format("[ARCH-DBG] === Arch Placement Start === type=%s gridPos=%s", data.BlockType, gridFmt(position)))
			print(string.format("[ARCH-DBG] StairData: HitPos=%s HitNormal=%s HitBlockPos=%s LookVec=%s -> player facing %s",
				tostring(data.StairData.HitPosition),
				tostring(data.StairData.HitNormal),
				tostring(data.StairData.HitBlockPosition),
				tostring(data.StairData.LookVector),
				vectorToCompass(data.StairData.LookVector)))
			print(string.format("[ARCH-DBG] Client-sent rotation=%d (from inventory R-key)", rotation))
		end
		
		-- Get upside-down from hit data
		upsideDown = StairPlacement.ShouldBeUpsideDown(
			data.StairData.HitPosition,
			data.StairData.HitNormal,
			data.StairData.HitBlockPosition
		)
		
		if isArch and DEBUG_ARCH then
			print(string.format("[ARCH-DBG] ShouldBeUpsideDown => %s", tostring(upsideDown)))
		end
		
		-- Get direction from look vector (NEW!)
		if data.StairData.LookVector then
			local lookVector = data.StairData.LookVector
			if typeof(lookVector) == "Vector3" then
				direction = StairPlacement.GetDirectionFromLookVector(lookVector)
				if isArch and DEBUG_ARCH then
					print(string.format("[ARCH-DBG] Direction from LookVector => %s (%s)",
						tostring(direction), StairPlacement.GetDirectionName(direction)))
				end
			end
		end
		
		-- Fallback to rotation-based direction
		if direction == nil then
			direction = StairPlacement.RotationToDirection(rotation)
			if isArch and DEBUG_ARCH then
				print(string.format("[ARCH-DBG] Direction from rotation fallback => %s (%s)",
					tostring(direction), StairPlacement.GetDirectionName(direction)))
			end
		end
	end
	
	local templateName = shapeData.TemplateName
	local cornerType = "normal"
	local finalRotation = rotation
	
	if isStair or isArch then
		-- Arches use the same placement logic as stairs, with different templates
		local typeChecker = nil
		local templateNames = nil
		if isArch then
			typeChecker = StairPlacement.GetArchTypeChecker(data.BlockType)
			templateNames = StairPlacement.GetArchTemplateNames(data.BlockType)
		end
		
		-- Use look-vector-based placement info
		local placementInfo
		if data.StairData and data.StairData.LookVector and typeof(data.StairData.LookVector) == "Vector3" then
			-- Use the look vector directly (same as client ghost)
			placementInfo = StairPlacement.GetPlacementInfoFromLookVector(
				data.BlockType,
				position,
				data.StairData.LookVector,
				upsideDown,
				blocksFolder,
				DEBUG_CORNER_DETECTION,
				typeChecker,
				templateNames
			)
		else
			-- Fallback to rotation-based (legacy)
			placementInfo = StairPlacement.GetPlacementInfo(
				data.BlockType,
				position,
				rotation,
				upsideDown,
				blocksFolder,
				DEBUG_CORNER_DETECTION,
				typeChecker,
				templateNames
			)
		end
		
		templateName = placementInfo.templateName
		cornerType = placementInfo.cornerType
		finalRotation = placementInfo.rotation
		direction = placementInfo.direction
		
		if isArch and DEBUG_ARCH then
			print(string.format("[ARCH-DBG] PlacementInfo => template=%s corner=%s rotation=%d direction=%s upsideDown=%s",
				tostring(templateName), tostring(cornerType), finalRotation,
				StairPlacement.GetDirectionName(direction), tostring(upsideDown)))
		end
	end
	
	-- Process fence-specific placement
	if isFence then
		local fencePlacementInfo = FencePlacement.GetPlacementInfo(
			data.BlockType,
			position,
			blocksFolder,
			false, -- suppress internal debug
			true   -- checkSolidBlocks: YES on server placement
		)
		
		templateName = fencePlacementInfo.templateName
		fenceConnectionType = fencePlacementInfo.connectionType
		finalRotation = fencePlacementInfo.rotation
	end
	
	-- Process architrave-specific placement
	if isArchitrave then
		local archLookVector = data.ArchitraveData and data.ArchitraveData.LookVector or nil
		local archPlacementInfo = ArchitravePlacement.GetPlacementInfo(
			data.BlockType,
			position,
			blocksFolder,
			DEBUG_ARCHITRAVES,
			archLookVector
		)
		
		templateName = archPlacementInfo.templateName
		architraveConnectionType = archPlacementInfo.connectionType
		finalRotation = archPlacementInfo.rotation
	end
	
	-- Process glass-specific placement
	if isGlass then
		-- Get orientation from client data
		if data.GlassData then
			glassOrientation = data.GlassData.Orientation or "NS"
		end
		
		-- First check for horizontal corner case (Glass_6)
		local cornerPlacementInfo = GlassPlacement.GetCornerPlacementInfo(
			data.BlockType,
			position,
			blocksFolder
		)
		
		if cornerPlacementInfo then
			-- This is a corner / tee / 4-way! Use the appropriate template
			templateName = cornerPlacementInfo.templateName
			glassConnectionType = cornerPlacementInfo.cornerType
			glassRotationCFrame = cornerPlacementInfo.rotationCFrame
			glassPositionOffset = cornerPlacementInfo.positionOffset -- Store offset for corner alignment
			glassOrientation = cornerPlacementInfo.cornerType -- Mark with actual type: corner / tee / 4way
			glassRotationDegrees = cornerPlacementInfo.rotationDegrees -- Track for fixups
			
			if DEBUG_GLASS then
				print(string.format("[Glass] %s detected! Using template: %s, rotation: %d°", 
					string.upper(cornerPlacementInfo.cornerType), templateName, cornerPlacementInfo.rotationDegrees))
			end
		else
			-- Standard glass placement (vertical connections)
			local glassPlacementInfo = GlassPlacement.GetPlacementInfo(
				data.BlockType,
				position,
				blocksFolder,
				glassOrientation,
				DEBUG_GLASS
			)
			
			templateName = glassPlacementInfo.templateName
			glassConnectionType = glassPlacementInfo.connectionType
			glassRotationCFrame = glassPlacementInfo.rotationCFrame
			
			if DEBUG_GLASS then
				print(string.format("[Glass] Using template: %s, connection: %s, orientation: %s", templateName, glassConnectionType, glassOrientation))
			end
		end
	end
	
	-- Process ladder-specific data
	if isLadder and data.LadderData then
		ladderFace = data.LadderData.Face or "North"
		ladderRotation = data.LadderData.Rotation or 0
		if DEBUG_LADDERS then
			print(string.format("[Ladder] Received face: %s, rotation: %d", ladderFace, ladderRotation))
		end
	end
	
	-- Process vine-specific data
	if isVine and data.VineData then
		vineFace = data.VineData.Face or "North"
		vineRotation = data.VineData.Rotation or 0
	end
	
	-- Check if this is a torch
	local isTorch = BlockPresets.IsTorch(data.BlockType)
	
	-- Check if this is a campfire
	local isCampfire = BlockPresets.IsCampfire and BlockPresets.IsCampfire(data.BlockType)
	
	-- Don't allow placing campfire-type blocks on top of other campfire-type blocks
	if isCampfire then
		local belowPos = position - Vector3.new(0, BLOCK_SIZE, 0)
		local campfireIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		if campfireIndex then
			for _, item in ipairs(campfireIndex:GetBlocksAt(belowPos)) do
				if item:GetAttribute("IsCampfire") then
					print("[Campfire] BLOCKED - can't stack on top of another campfire/column torch")
					return
				end
			end
		end
	end
	
	-- Check if this is a lantern
	local isLantern = BlockPresets.IsLantern and BlockPresets.IsLantern(data.BlockType)
	
	-- Check if this is a sign (standing or wall)
	local isSignStanding = BlockPresets.IsSignStanding and BlockPresets.IsSignStanding(data.BlockType)
	local isWallSign = BlockPresets.IsWallSign and BlockPresets.IsWallSign(data.BlockType)
	local isSign = isSignStanding or isWallSign
	
	-- Process torch-specific data
	if isTorch and data.TorchData then
		torchFace = data.TorchData.Face or "Top"
		torchRotation = data.TorchData.Rotation or 0
		torchModelName = data.TorchData.ModelName or "TorchStraight"
		torchIsAngled = data.TorchData.IsAngled or false
		
		-- Server-side validation: Don't allow placing torch at same grid position as another torch
		-- (Multiple torches on different faces of the same host block IS allowed)
		if data.TorchData.GridPosition then
			local targetPos = data.TorchData.GridPosition
			local torchIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			local torchCandidates = torchIndex:GetBlocksAt(targetPos)
			for _, item in ipairs(torchCandidates) do
				if item:GetAttribute("IsTorch") then
					local itemPos = item:GetPivot().Position
					if itemPos and (itemPos - targetPos).Magnitude < 1 then
						if DEBUG_TORCHES then
							print("[Torch] BLOCKED - torch already exists at this grid position")
						end
						return
					end
				end
			end
		end
		
		if DEBUG_TORCHES then
			print(string.format("[Torch] Received face: %s, rotation: %d, model: %s, angled: %s", 
				torchFace, torchRotation, torchModelName, tostring(torchIsAngled)))
		end
	end
	
	-- Process lantern-specific data
	if isLantern and data.LanternData then
		lanternFace = data.LanternData.Face or "Top"
		lanternIsHanging = data.LanternData.IsHanging or false
		
		-- Server-side validation: Don't allow placing lantern at same grid position as another lantern
		if data.LanternData.GridPosition then
			local targetPos = data.LanternData.GridPosition
			local lanternIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			local lanternCandidates = lanternIndex:GetBlocksAt(targetPos)
			for _, item in ipairs(lanternCandidates) do
				if item:GetAttribute("IsLantern") then
					local itemPos = item:GetPivot().Position
					-- Check if lantern exists at the same grid cell (within 1 stud tolerance)
					if itemPos and (itemPos - targetPos).Magnitude < 1 then
						if DEBUG_LANTERNS then
							print("[Lantern] BLOCKED - lantern already exists at this grid position")
						end
						return -- Block placement at same position
					end
				end
			end
		end
		
		if DEBUG_LANTERNS then
			print(string.format("[Lantern] Received face: %s, hanging: %s", 
				lanternFace, tostring(lanternIsHanging)))
		end
	end
	
	-- Process sign-specific data
	if isSign and data.SignData then
		signFace = data.SignData.Face or "Top"
		signRotation = data.SignData.Rotation or 0
		signRotationIndex = data.SignData.RotationIndex or 0
		signType = data.SignData.SignType -- "standing" or "wall"
		signModelName = data.SignData.ModelName -- "SignStanding" or "Sign"
		isOnFencePost = data.SignData.IsOnFencePost or false -- For flush positioning on fence posts
		
		-- Server-side validation: Don't allow placing sign at same grid position as another sign
		if data.SignData.GridPosition then
			local targetPos = data.SignData.GridPosition
			local signIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			local signCandidates = signIndex:GetBlocksAt(targetPos)
			for _, item in ipairs(signCandidates) do
				if item:GetAttribute("IsSignStanding") or item:GetAttribute("IsWallSign") then
					local itemPos = item:GetPivot().Position
					-- Check if sign exists at the same grid cell (within 1 stud tolerance)
					if itemPos and (itemPos - targetPos).Magnitude < 1 then
						if DEBUG_SIGNS then
							print("[Sign] BLOCKED - sign already exists at this grid position")
						end
						return -- Block placement at same position
					end
				end
			end
		end
		
		if DEBUG_SIGNS then
			print(string.format("[Sign] Received face: %s, rotation: %.1f, type: %s, model: %s", 
				signFace, signRotation, signType or "?", signModelName or "?"))
		end
	end
	
	-- ============================================
	-- COLLISION DETECTION
	-- ============================================
	-- Check if the new block would overlap with existing blocks
	
	-- Get basePlate data for proper grid alignment
	local basePlateData = nil
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posY = buildArea:GetAttribute("BasePlatePositionY")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeY = buildArea:GetAttribute("BasePlateSizeY")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if posX and posY and posZ and sizeX and sizeY and sizeZ then
		-- Create a virtual basePlate object with Position and Size
		basePlateData = {
			Position = Vector3.new(posX, posY, posZ),
			Size = Vector3.new(sizeX, sizeY, sizeZ),
		}
	else
		-- Try to find actual BasePlate part
		local basePlatePart = buildArea:FindFirstChild("BasePlate")
		if basePlatePart and basePlatePart:IsA("BasePart") then
			basePlateData = basePlatePart
		end
	end
	
	local collisionExtraData = {
		orientation = slabOrientation,
		isDoor = isDoor,
		isBed = isBed, -- Tells BlockCollision to use the bed-specific (more permissive) skip list
		basePlate = basePlateData,
	}
	
	-- Wallpaper frames skip collision checking (they're 0.001 thick and can overlap in inner corners)
	local canPlace, collisionReason = true, nil
	if not isWallpaperFrame then
		canPlace, collisionReason = BlockCollision.CanPlace(data.BlockType, position, blocksFolder, collisionExtraData)
	end
	
	if not canPlace then
		if DEBUG_COLLISION then
			print(string.format("[Collision] BLOCKED placement of %s at (%.1f, %.1f, %.1f): %s",
				data.BlockType, position.X, position.Y, position.Z, collisionReason or "overlap"))
		end
		-- Always log the reason (even without DEBUG_COLLISION) so players can see WHY a placement failed.
		print(string.format("[BB-NET] BLOCKED place of %s at (%.1f, %.1f, %.1f): %s",
			data.BlockType, position.X, position.Y, position.Z, collisionReason or "overlap"))
		-- Also print what's at that cell so we can diagnose unexpected collisions (e.g., stale bed registrations)
		local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		if spatialIndex then
			local whatsThere = spatialIndex:GetBlocksAt(position)
			for _, b in ipairs(whatsThere) do
				local bType = b:GetAttribute("BlockType") or "?"
				local isBed = b:GetAttribute("IsBed") and " (bed)" or ""
				local bx = b:GetAttribute("BlockPosX") or -9999
				local by = b:GetAttribute("BlockPosY") or -9999
				local bz = b:GetAttribute("BlockPosZ") or -9999
				print(string.format("[BB-NET]   Cell occupied by %s%s (primary=(%.1f,%.1f,%.1f))", bType, isBed, bx, by, bz))
			end
		end
		BuildRejected:FireClient(player, "place", position)
		return -- Don't place the block
	end
	
	if DEBUG_COLLISION then
		print(string.format("[Collision] ALLOWED placement of %s at (%.1f, %.1f, %.1f)",
			data.BlockType, position.X, position.Y, position.Z))
	end
	
	-- Remove any water blocks at the placement position (water is displaced by solid blocks)
	local placeSpatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if placeSpatialIndex then
		local waterBlocksToRemove = {}
		local blocksAtPlacePos = placeSpatialIndex:GetBlocksAt(position)
		for _, existingBlock in ipairs(blocksAtPlacePos) do
			if existingBlock:GetAttribute("IsWater") then
				table.insert(waterBlocksToRemove, existingBlock)
			end
		end
		-- Also check upper cell for doors (they occupy 2 cells)
		if isDoor then
			local upperPos = position + Vector3.new(0, BLOCK_SIZE, 0)
			local blocksAtUpperPos = placeSpatialIndex:GetBlocksAt(upperPos)
			for _, existingBlock in ipairs(blocksAtUpperPos) do
				if existingBlock:GetAttribute("IsWater") then
					table.insert(waterBlocksToRemove, existingBlock)
				end
			end
		end
		if #waterBlocksToRemove > 0 then
			for _, waterBlock in ipairs(waterBlocksToRemove) do
				waterBlock:Destroy()
			end
			print(string.format("[BlockHandler] Removed %d water block(s) at placement position", #waterBlocksToRemove))
			-- Trigger water flow recalculation
			task.defer(function()
				if _G.WaterHandler then
					_G.WaterHandler.OnBlockChanged(position, buildArea)
				end
			end)
		end
	end
	
	-- SnowLayer support check: snow layers cannot float, they need a block or basePlate below
	if isSnowLayer then
		local belowPos = position - Vector3.new(0, BLOCK_SIZE, 0)
		local supportFound = false
		
		-- Check if basePlate is directly below (first layer on ground)
		if basePlateData then
			local plateTop
			if basePlateData.Position and basePlateData.Size then
				plateTop = basePlateData.Position.Y + basePlateData.Size.Y / 2
			else
				plateTop = basePlateData.Position.Y + basePlateData.Size.Y / 2
			end
			local blockBottom = position.Y - BLOCK_SIZE / 2
			if math.abs(blockBottom - plateTop) < 0.5 then
				supportFound = true
			end
		end
		
		-- Check for a block below using spatial index
		if not supportFound then
			local snowSpatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			if snowSpatialIndex then
				local blocksBelow = snowSpatialIndex:GetBlocksAt(belowPos)
				for _, item in ipairs(blocksBelow) do
					if item:GetAttribute("BlockType") and not item:GetAttribute("IsDecoration") then
						supportFound = true
						break
					end
				end
			end
		end
		
		if not supportFound then
			print(string.format("[SnowLayer] BLOCKED - no support below (%.1f, %.1f, %.1f)", position.X, position.Y, position.Z))
			BuildRejected:FireClient(player, "place", position)
			return
		end
	end
	
	-- CarpetFrame support check: can only be placed on top of blocks, stairs, or fences
	if isCarpet then
		local belowPos = position - Vector3.new(0, BLOCK_SIZE, 0)
		local supportFound = false
		
		local carpetSpatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		if carpetSpatialIndex then
			local blocksBelow = carpetSpatialIndex:GetBlocksAt(belowPos)
			for _, item in ipairs(blocksBelow) do
				if CarpetPlacement.IsValidSupport(item) then
					supportFound = true
					break
				end
			end
		end
		
		if not supportFound then
			print(string.format("[Carpet] BLOCKED - no valid support below (%.1f, %.1f, %.1f)", position.X, position.Y, position.Z))
			BuildRejected:FireClient(player, "place", position)
			return
		end
	end
	
	-- Create the block (pass UseBlockModel for blocks from Blocks folder)
	-- For fences, glass, and architraves, don't pass preset's BlockModelFolder/Name - use dynamic template from GetPlacementInfo
	-- Also pass nil for blockId so it doesn't search Blocks folder
	-- NOTE: Can't use `isFence and nil or X` pattern because nil is falsy in Lua!
	local useBlockModelFolder = (not isFence and not isGlass and not isArchitrave) and preset.BlockModelFolder or nil
	local useBlockModelName = (not isFence and not isGlass and not isArchitrave) and preset.BlockModelName or nil
	local useBlockId = (not isFence and not isGlass and not isArchitrave) and preset.Id or nil
	
	-- For glass, resolve the model folder + name from the glass-type registry.
	-- Standard glass -> Decorations/Glass; CandyLattice -> RewardSets/CandyBlocks; etc.
	-- templateName here is the generic shape name (Glass_0 / Glass_Corner / ...);
	-- ResolveTemplate translates it to the real model name for this block's type.
	if isGlass then
		local glassFolderPath, glassModelName = GlassPlacement.ResolveTemplate(data.BlockType, templateName)
		useBlockModelFolder = glassFolderPath
		useBlockModelName = glassModelName
	end
	
	-- For torches, look in Decorations folder and use the correct model (TorchStraight or TorchAngled)
	if isTorch then
		useBlockModelFolder = "Decorations"
		useBlockModelName = torchModelName -- "TorchStraight" or "TorchAngled"
		useBlockId = preset.Id
	end
	
	-- For lanterns, look in Decorations folder
	if isLantern then
		useBlockModelFolder = "Decorations"
		useBlockModelName = "Lantern"
		useBlockId = preset.Id
	end
	
	-- For signs, look in BlockTemplates folder and use correct model
	-- Frame signs use their FrameBlocks model instead
	if isSign then
		if preset.IsFrameBlock then
			useBlockModelFolder = "FrameBlocks"
			useBlockModelName = preset.BlockModelName or preset.Id
		else
			useBlockModelFolder = "BlockTemplates"
			useBlockModelName = signModelName or (isSignStanding and "SignStanding" or "Sign")
		end
		useBlockId = preset.Id
	end
	
	-- For frame fences, use the connection-specific template from FrameBlocks
	if isFence and preset.IsFrameBlock then
		useBlockModelFolder = "FrameBlocks"
		useBlockModelName = templateName -- e.g. "FencePostFrame", "FenceMiddleFrame"
		useBlockId = preset.Id
	end
	
	-- For columns, determine which piece model to use based on neighbors
	local columnModelName = nil
	if isColumn then
		columnModelName = ColumnPlacement.DetermineModelName(position, blocksFolder)
		useBlockModelFolder = "Blocks"
		useBlockModelName = columnModelName
		useBlockId = preset.Id
	end
	
	-- For architraves, use the dynamic template from GetPlacementInfo
	if isArchitrave then
		useBlockModelFolder = "Architraves"
		useBlockModelName = templateName -- e.g. "ArchitraveSingle", "ArchitraveSingleEnd", "ArchitraveSingleMiddle"
		useBlockId = preset.Id
	end
	
	-- For frame stairs, use corner model from FrameBlocks when corner is detected
	if preset.IsFrameBlock and isStair and cornerType ~= "normal" then
		if cornerType == "inner" then
			useBlockModelName = "FrameStairsCornerInner"
		elseif cornerType == "outer" then
			useBlockModelName = "FrameStairsCornerOuter"
			-- Frame outer corner model is rotated differently from BlockTemplates version
			if upsideDown then
				finalRotation = (finalRotation + 90) % 360
			else
				finalRotation = (finalRotation - 90) % 360
			end
		end
		useBlockModelFolder = "FrameBlocks"
		useBlockId = preset.Id
	end
	
	-- For frame arch blocks, use arch corner model from FrameBlocks when corner is detected
	if preset.IsFrameBlock and isArch and cornerType ~= "normal" then
		local archTemplates = StairPlacement.GetArchTemplateNames(data.BlockType)
		if cornerType == "inner" then
			useBlockModelName = archTemplates.Inner .. "Frame"
		elseif cornerType == "outer" then
			useBlockModelName = archTemplates.Outer .. "Frame"
		end
		useBlockModelFolder = "FrameBlocks"
		useBlockId = preset.Id
		-- Arch frame corner rotation offsets, by case:
		--   upright + inner: +90
		--   upright + outer: no offset
		--   upside-down + inner: +270
		--   upside-down + outer: no offset (+270 - 270 effective wrap)
		-- (Templates are authored with different orientations per case.)
		local rotationBefore = finalRotation
		if upsideDown then
			if cornerType == "inner" then
				finalRotation = (finalRotation + 270) % 360
			end
		elseif cornerType == "inner" then
			finalRotation = (finalRotation + 90) % 360
		end
		if DEBUG_ARCH then
			print(string.format("[ARCH] Frame corner model: %s from %s | rotation offset: %d -> %d (upsideDown=%s)",
				tostring(useBlockModelName), useBlockModelFolder, rotationBefore, finalRotation, tostring(upsideDown)))
		end
	end
	
	local block, usedBlockModel = createBlockFromTemplate(
		templateName, 
		useBlockId, 
		preset.UseBlockModel, 
		useBlockModelName,
		useBlockModelFolder,
		preset.ApplyColor,
		preset.DefaultColor,
		preset.CustomVariantChild, -- For custom Union stair/slab models
		preset.Material,
		preset.MaterialVariant,
		preset.StripeColorMode  -- "Texture" tints Texture descendants instead of the Part
	)
	if not block then return end
	
	-- For fences and glass, set the name to the block type (since we passed nil for blockId)
	if isFence then
		block.Name = preset.Id
	end
	if isGlass then
		block.Name = preset.Id
	end
	
	local cframe
	if isStair or isArch then
		-- All stair/arch unions have consistent bottom-center pivots
		cframe = StairPlacement.GetStairCFrame(position, finalRotation, upsideDown)
		-- Straight arch templates are inverted vs stairs: local X(180) fixes both facing and vertical
		local appliedX180 = false
		if isArch and cornerType == "normal" then
			cframe = cframe * CFrame.Angles(math.rad(180), 0, 0)
			appliedX180 = true
		end
		if isArch and DEBUG_ARCH then
			print(string.format("[ARCH] Placement CFrame: gridPos=%s rot=%d upsideDown=%s corner=%s appliedX180=%s",
				gridFmt(position), finalRotation, tostring(upsideDown), tostring(cornerType), tostring(appliedX180)))
		end
	elseif usesAxisRotation then
		-- Use directional rotation for pistons, regular axis for logs
		if LogPlacement.NeedsDirectionalPlacement(data.BlockType) then
			cframe = LogPlacement.GetPistonCFrame(position, logAxis)
		else
			cframe = LogPlacement.GetLogCFrame(position, logAxis)
		end
	elseif isSlab then
		-- Use orientation-based CFrame for slabs
		cframe = SlabPlacement.GetSlabCFrame(position, slabOrientation)
	elseif isDoor then
		-- Use direction, depth, and hinge side-based CFrame for doors
		cframe = DoorPlacement.GetDoorCFrame(position, doorDirection, doorDepth, doorHingeSide)
	elseif isSurfaceBlock and surfaceHostPosition then
		-- Use surface-based CFrame for buttons/pressure plates
		local isPressurePlate = SurfacePlacement.IsPressurePlate(data.BlockType)
		local thickness = isPressurePlate and 0.15 or 0.3
		cframe = SurfacePlacement.GetSurfaceCFrame(surfaceHostPosition, surfaceFace, thickness, isPressurePlate)
	elseif isWallpaperFrame and wallpaperHostPosition then
		-- Use wallpaper-specific CFrame (flush against host block face)
		cframe = WallpaperPlacement.GetWallpaperCFrame(wallpaperHostPosition, wallpaperFace)
	elseif isFence then
		-- Use fence-specific CFrame with auto-rotation
		cframe = FencePlacement.GetFenceCFrame(position, finalRotation, preset.IsFrameBlock)
	elseif isArchitrave then
		-- Use architrave-specific CFrame (center pivot, Y rotation only)
		cframe = ArchitravePlacement.GetArchitraveCFrame(position, finalRotation)
	elseif isGlass then
		-- Use glass-specific CFrame with auto-rotation (and optional corner offset)
		cframe = GlassPlacement.GetGlassCFrame(position, glassRotationCFrame, glassPositionOffset, glassConnectionType)
	elseif isLadder then
		-- Use ladder-specific CFrame with face-based rotation
		cframe = LadderPlacement.GetLadderCFrame(position, ladderFace)
	elseif isVine then
		-- Use vine-specific CFrame with face-based rotation
		cframe = VinePlacement.GetVineCFrame(position, vineFace)
	elseif isTorch then
		-- Use torch-specific CFrame with face-based rotation
		cframe = TorchPlacement.GetTorchCFrame(position, torchFace)
	elseif isLantern then
		-- Use lantern-specific CFrame
		cframe = LanternPlacement.GetLanternCFrame(position, lanternFace)
	elseif isSignStanding then
		-- Use standing sign CFrame (16-direction rotation, bottom-center pivot)
		cframe = SignPlacement.GetStandingSignCFrame(position, signRotation)
	elseif isWallSign then
		-- Use wall sign CFrame (4-direction based on face, flush positioning for fence posts)
		cframe = SignPlacement.GetWallSignCFrame(position, signFace, isOnFencePost)
	elseif isCampfire then
		-- Campfires/column torches: no player rotation (they're symmetric)
		cframe = CFrame.new(position)
	elseif isChest then
		-- Chests face toward the player (snap to nearest 90°)
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local lookDir = (position - rootPart.Position) * Vector3.new(1, 0, 1) -- flatten Y
			if lookDir.Magnitude > 0.01 then
				local angle = math.atan2(lookDir.X, lookDir.Z)
				-- Snap to nearest 90°
				local snapped = math.round(angle / (math.pi / 2)) * (math.pi / 2)
				-- Offset backward by half latch depth to center visually on grid
				cframe = CFrame.new(position) * CFrame.Angles(0, snapped, 0) * CFrame.new(0, 0, 0.15)
				finalRotation = math.deg(snapped) % 360
			else
				cframe = CFrame.new(position)
			end
		else
			cframe = CFrame.new(position) * CFrame.Angles(0, math.rad(rotation), 0)
		end
	elseif isBed then
		-- Beds: pillow at click point, bed extends TOWARD the player (foot near camera).
		-- We compute lookDir from player→click, then snap to 90°; this makes the bed's
		-- forward axis point at the click. To extend the bed toward the player, the
		-- foot offset uses the OPPOSITE direction (player→click reversed).
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local lookDir = (position - rootPart.Position) * Vector3.new(1, 0, 1)
			if lookDir.Magnitude > 0.01 then
				local angle = math.atan2(lookDir.X, lookDir.Z)
				local snapped = math.round(angle / (math.pi / 2)) * (math.pi / 2)
				cframe = CFrame.new(position) * CFrame.Angles(0, snapped, 0)
				finalRotation = math.deg(snapped) % 360
			else
				cframe = CFrame.new(position)
			end
		else
			cframe = CFrame.new(position)
		end
		
		-- Foot cell is one block TOWARD the player from the pillow (head at click point,
		-- foot extends back toward camera). We only care about whether the foot cell is
		-- blocked — the head cell (where the player clicked) is allowed to overlap.
		local bedSnapped = math.rad(finalRotation or 0)
		local footOffset = Vector3.new(
			-math.round(math.sin(bedSnapped)) * BLOCK_SIZE,
			0,
			-math.round(math.cos(bedSnapped)) * BLOCK_SIZE
		)
		local footPosition = position + footOffset
		
		-- Check if anything is in the foot cell at the same height
		local footSpatialIndex = BlockSpatialIndex and BlockSpatialIndex.GetOrCreate(blocksFolder)
		local blocksAtFoot
		if footSpatialIndex then
			blocksAtFoot = footSpatialIndex:GetBlocksAt(footPosition)
		else
			blocksAtFoot = {}
			for _, b in ipairs(blocksFolder:GetChildren()) do
				local bp = b.PrimaryPart and b.PrimaryPart.Position or (b:IsA("BasePart") and b.Position)
				if bp and (bp - footPosition).Magnitude < (BLOCK_SIZE * 0.5) then
					table.insert(blocksAtFoot, b)
				end
			end
		end
		
		for _, existingBlock in ipairs(blocksAtFoot) do
			-- Skip blocks that don't meaningfully fill the foot cell at bed level
			if existingBlock:GetAttribute("IsDecoration") then continue end
			if existingBlock:GetAttribute("IsSurfaceBlock") then continue end
			if existingBlock:GetAttribute("IsWater") then continue end
			if existingBlock:GetAttribute("IsBed") then continue end
			if existingBlock:GetAttribute("IsWallpaperFrame") then continue end
			if existingBlock:GetAttribute("IsVine") then continue end
			if existingBlock:GetAttribute("IsLadder") then continue end
			if existingBlock:GetAttribute("IsSignStanding") then continue end
			if existingBlock:GetAttribute("IsWallSign") then continue end
			if existingBlock:GetAttribute("IsCarpet") then continue end
			if existingBlock:GetAttribute("IsTorch") then continue end
			if existingBlock:GetAttribute("IsLantern") then continue end
			-- A solid block occupies the foot cell — refuse placement.
			local blockingType = existingBlock:GetAttribute("BlockType") or "block"
			print(string.format("[Bed] Foot cell blocked by %s at (%.0f,%.0f,%.0f); refusing placement",
				tostring(blockingType), footPosition.X, footPosition.Y, footPosition.Z))
			return false, "Bed foot would overlap with an existing block"
		end
	elseif isCraftingTable then
		-- Crafting tables face toward the player (snap to nearest 90°), no Y offset
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local lookDir = (position - rootPart.Position) * Vector3.new(1, 0, 1) -- flatten Y
			if lookDir.Magnitude > 0.01 then
				local angle = math.atan2(lookDir.X, lookDir.Z)
				-- Snap to nearest 90°
				local snapped = math.round(angle / (math.pi / 2)) * (math.pi / 2)
				cframe = CFrame.new(position) * CFrame.Angles(0, snapped, 0)
				finalRotation = math.deg(snapped) % 360
			else
				cframe = CFrame.new(position)
			end
		else
			cframe = CFrame.new(position) * CFrame.Angles(0, math.rad(rotation), 0)
		end
	elseif isFurnace then
		-- Furnaces face toward the player (snap to nearest 90°), no Y offset.
		-- Same pattern as crafting tables / chests / beds.
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local lookDir = (position - rootPart.Position) * Vector3.new(1, 0, 1) -- flatten Y
			if lookDir.Magnitude > 0.01 then
				local angle = math.atan2(lookDir.X, lookDir.Z)
				local snapped = math.round(angle / (math.pi / 2)) * (math.pi / 2)
				cframe = CFrame.new(position) * CFrame.Angles(0, snapped, 0)
				finalRotation = math.deg(snapped) % 360
			else
				cframe = CFrame.new(position)
			end
		else
			cframe = CFrame.new(position) * CFrame.Angles(0, math.rad(rotation), 0)
		end
	else
		cframe = CFrame.new(position) * CFrame.Angles(0, math.rad(rotation), 0)
	end
	setBlockCFrame(block, cframe, usedBlockModel, preset.Id)
	
	-- [ARCH-DBG] Smoking-gun log: read the block's ACTUAL world orientation after
	-- setBlockCFrame is done with it. If two arch placements have the same input
	-- direction but different `front` values here, the placement code is producing
	-- inconsistent rotations. The `front` axis is the direction the arch's opening
	-- faces in world space (CFrame's -Z by convention for Roblox parts).
	if isArch and DEBUG_ARCH then
		local finalPivot = block:GetPivot()
		local worldLook = finalPivot.LookVector       -- forward (block-local -Z)
		local worldRight = finalPivot.RightVector
		local worldUp = finalPivot.UpVector
		print(string.format(
			"[ARCH-DBG] FINAL world orientation: gridPos=%s look=(%.2f,%.2f,%.2f) right=(%.2f,%.2f,%.2f) up=(%.2f,%.2f,%.2f) | facing %s | up %s",
			gridFmt(position),
			worldLook.X, worldLook.Y, worldLook.Z,
			worldRight.X, worldRight.Y, worldRight.Z,
			worldUp.X, worldUp.Y, worldUp.Z,
			vectorToCompass(worldLook),
			worldUp.Y > 0.5 and "UP (normal)" or (worldUp.Y < -0.5 and "DOWN (upside-down)" or vectorToCompass(worldUp))
		))
		print(string.format(
			"[ARCH-DBG] SUMMARY: type=%s gridPos=%s storedRot=%d storedCorner=%s storedUpsideDown=%s storedDir=%s -> world-facing=%s",
			data.BlockType, gridFmt(position), finalRotation, tostring(cornerType), tostring(upsideDown),
			direction ~= nil and StairPlacement.GetDirectionName(direction) or "nil",
			vectorToCompass(worldLook)
		))
	end
	
	-- Apply color/material for template blocks, or block models with ApplyColor set.
	-- BUT skip this entirely for Texture-mode blocks (candy canes etc.): their
	-- coloring was already done correctly inside createBlockFromTemplate, which
	-- tints only Texture descendants + the Core part — NOT the white Bark.
	-- applyColorToBlock would naively tint every part, undoing that work.
	if (not usedBlockModel or preset.ApplyColor) and preset.StripeColorMode ~= "Texture" then
		local material = preset.Material
		if data.MaterialName and type(data.MaterialName) == "string" then
			local success, result = pcall(function()
				return Enum.Material[data.MaterialName]
			end)
			if success and result then
				material = result
			end
		end
		
		local color = preset.DefaultColor
		if typeof(data.Color) == "Color3" then
			color = data.Color
		end
		
		-- Get MaterialVariant from preset or data
		local materialVariant = preset.MaterialVariant or ""
		if data.MaterialVariant and type(data.MaterialVariant) == "string" then
			materialVariant = data.MaterialVariant
		end
		
		applyColorToBlock(block, color, material, materialVariant)
	end
	
	block:SetAttribute("BlockType", preset.Id)
	block:SetAttribute("PlacedBy", player.UserId)
	block:SetAttribute("Rotation", finalRotation)
	
	if preset.IsFrameBlock then
		block:SetAttribute("IsFrameBlock", true)
	end
	
	if isStair or isArch then
		block:SetAttribute("IsUpsideDown", upsideDown)
		block:SetAttribute("CornerType", cornerType)
		block:SetAttribute("StairDirection", direction)  -- Store direction explicitly
		if isArch then
			block:SetAttribute("IsArch", true)
		end
	end
	
	if usesAxisRotation then
		block:SetAttribute("LogAxis", logAxis)
		if DEBUG_LOGS then
			print(string.format("[AxisBlock] Placed %s with axis %s (%s)", preset.Id, logAxis, LogPlacement.GetAxisName(logAxis)))
		end
	end
	
	if isSlab then
		block:SetAttribute("SlabOrientation", slabOrientation)
		if DEBUG_SLABS then
			print(string.format("[Slab] Placed %s with orientation: %s", preset.Id, SlabPlacement.GetOrientationName(slabOrientation)))
		end
	end
	
	if isDoor then
		block:SetAttribute("DoorDirection", doorDirection)
		block:SetAttribute("DoorDepth", doorDepth)
		block:SetAttribute("DoorHingeSide", doorHingeSide)
		block:SetAttribute("IsOpen", false)
		block:SetAttribute("IsDoor", true)
		-- Store the actual grid position for accurate save/load
		-- (Door model center is higher than grid position due to 2-block height)
		block:SetAttribute("GridPosX", position.X)
		block:SetAttribute("GridPosY", position.Y)
		block:SetAttribute("GridPosZ", position.Z)
		if DEBUG_DOORS then
			print(string.format("[Door] Placed %s facing %s at %s depth, hinge on %s, gridPos=(%.1f,%.1f,%.1f)", 
				preset.Id, 
				DoorPlacement.GetDirectionName(doorDirection),
				DoorPlacement.GetDepthName(doorDepth),
				DoorPlacement.GetHingeSideName(doorHingeSide),
				position.X, position.Y, position.Z))
		end
	end
	
	if isSurfaceBlock then
		block:SetAttribute("SurfaceFace", surfaceFace)
		block:SetAttribute("IsSurfaceBlock", true)
		if surfaceHostPosition then
			block:SetAttribute("HostBlockX", math.round(surfaceHostPosition.X))
			block:SetAttribute("HostBlockY", math.round(surfaceHostPosition.Y))
			block:SetAttribute("HostBlockZ", math.round(surfaceHostPosition.Z))
		end
		if DEBUG_SURFACE then
			print(string.format("[Surface] Placed %s on %s face", preset.Id, surfaceFace))
		end
	end
	
	if isWallpaperFrame then
		block:SetAttribute("IsWallpaperFrame", true)
		block:SetAttribute("WallpaperFace", wallpaperFace)
		if wallpaperHostPosition then
			block:SetAttribute("HostBlockX", wallpaperHostPosition.X)
			block:SetAttribute("HostBlockY", wallpaperHostPosition.Y)
			block:SetAttribute("HostBlockZ", wallpaperHostPosition.Z)
			-- Store grid-aligned position for the serializer (visual position is offset to host surface)
			block:SetAttribute("BlockPosX", wallpaperHostPosition.X)
			block:SetAttribute("BlockPosY", wallpaperHostPosition.Y)
			block:SetAttribute("BlockPosZ", wallpaperHostPosition.Z)
		end
		-- Make wallpaper non-collidable (it's 0.001 thick)
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end
		print(string.format("[Wallpaper] Placed on %s face", wallpaperFace))
	end
	
	if isFence then
		block:SetAttribute("IsFence", true)
		block:SetAttribute("FenceConnectionType", fenceConnectionType)
		-- Store grid position for spatial index (fence unions have offset geometric centers)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		print(string.format("[Fence] %s -> %s", preset.Id, fenceConnectionType))
	end
	
	if isColumn then
		block:SetAttribute("IsColumn", true)
		block:SetAttribute("ColumnModelName", columnModelName or "ColumnSingle")
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		print(string.format("[Column] Placed %s at (%.0f, %.0f, %.0f)", columnModelName or "ColumnSingle", position.X, position.Y, position.Z))
	end
	
	if isBed then
		-- === BED PLACEMENT ===
		-- Foot offset must match the collision check above: foot extends toward the player,
		-- so we negate the sin/cos of finalRotation.
		local bedSnapped = math.rad(finalRotation or 0)
		local footOffset = Vector3.new(
			-math.round(math.sin(bedSnapped)) * BLOCK_SIZE,
			0,
			-math.round(math.cos(bedSnapped)) * BLOCK_SIZE
		)
		local footPosition = position + footOffset
		
		-- Apply sheet color to Sheets > SurfaceAppearance
		local sheets = block:FindFirstChild("Sheets")
		if sheets then
			local sa = sheets:FindFirstChildWhichIsA("SurfaceAppearance")
			if sa and preset.DefaultColor then
				sa.Color = preset.DefaultColor
			end
		end
		
		-- Set bed attributes
		block:SetAttribute("IsBed", true)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		block:SetAttribute("BedSecondaryX", footPosition.X)
		block:SetAttribute("BedSecondaryY", footPosition.Y)
		block:SetAttribute("BedSecondaryZ", footPosition.Z)
		block:SetAttribute("Rotation", finalRotation)
		
		-- Store sheet color for save/load
		if preset.DefaultColor then
			block:SetAttribute("CustomColorR", math.round(preset.DefaultColor.R * 255))
			block:SetAttribute("CustomColorG", math.round(preset.DefaultColor.G * 255))
			block:SetAttribute("CustomColorB", math.round(preset.DefaultColor.B * 255))
		end
		
		-- Add invisible hitbox that matches the bed's visible silhouette.
		-- We compute size/position from the actual visible parts (Frame, Sheets, Pillow)
		-- rather than assuming cell dimensions — this way the hitbox always matches what
		-- the player sees, and the cursor can't catch the bed from above or off the side.
		-- IMPORTANT: We transform each part's 8 corners through its world CFrame to get
		-- a correct world-axis AABB. Using Position ± Size/2 directly only works for
		-- unrotated parts — at rotations 90°/270° the part's local Size axes don't align
		-- with world axes, which would produce a hitbox roughly half the correct width
		-- along the bed's length and let raycasts pass through the outer halves of both cells.
		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for _, descendant in ipairs(block:GetDescendants()) do
			if descendant:IsA("BasePart") then
				local cf = descendant.CFrame
				local hx, hy, hz = descendant.Size.X / 2, descendant.Size.Y / 2, descendant.Size.Z / 2
				for _, dx in ipairs({-1, 1}) do
					for _, dy in ipairs({-1, 1}) do
						for _, dz in ipairs({-1, 1}) do
							local corner = cf * Vector3.new(dx * hx, dy * hy, dz * hz)
							minX = math.min(minX, corner.X); maxX = math.max(maxX, corner.X)
							minY = math.min(minY, corner.Y); maxY = math.max(maxY, corner.Y)
							minZ = math.min(minZ, corner.Z); maxZ = math.max(maxZ, corner.Z)
						end
					end
				end
			end
		end

		local hitbox = Instance.new("Part")
		hitbox.Name = "Hitbox"
		hitbox.Anchored = true
		hitbox.CanCollide = false
		hitbox.CanQuery = true
		hitbox.CanTouch = false
		hitbox.CastShadow = false
		hitbox.Transparency = 1

		if minX < math.huge then
			-- Use the actual visible bounds, with a tiny margin so we don't undershoot
			local margin = 0.05
			hitbox.Size = Vector3.new(
				(maxX - minX) + margin * 2,
				(maxY - minY) + margin * 2,
				(maxZ - minZ) + margin * 2
			)
			hitbox.CFrame = CFrame.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
		else
			-- Fallback (shouldn't happen): previous cell-spanning sizing
			local midpoint = (position + footPosition) / 2
			local rot = (finalRotation or 0) % 360
			if rot == 0 or rot == 180 then
				hitbox.Size = Vector3.new(BLOCK_SIZE, 1.6, BLOCK_SIZE * 2)
			else
				hitbox.Size = Vector3.new(BLOCK_SIZE * 2, 1.6, BLOCK_SIZE)
			end
			hitbox.CFrame = CFrame.new(midpoint.X, position.Y - BLOCK_SIZE / 2 + 0.8, midpoint.Z)
		end

		hitbox.Parent = block

		-- Make the visible bed parts non-queryable so raycasts only hit the Hitbox.
		-- This makes the targeting region predictable and prevents stray hits on protruding geometry
		-- (e.g. the pillow sticking up above the frame).
		for _, descendant in ipairs(block:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant ~= hitbox then
				descendant.CanQuery = false
			end
		end
		
		-- Register foot cell in spatial index
		local bedSpatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		if bedSpatialIndex then
			bedSpatialIndex:RegisterSecondaryPosition(block, footPosition)
		end
		
		print(string.format("[Bed] Placed %s at (%.0f,%.0f,%.0f) foot=(%.0f,%.0f,%.0f) rot=%d",
			preset.Id, position.X, position.Y, position.Z,
			footPosition.X, footPosition.Y, footPosition.Z, finalRotation or 0))
	end
	
	if isChest then
		block:SetAttribute("IsChest", true)
		block:SetAttribute("IsOpen", false)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		block:SetAttribute("Rotation", finalRotation)
		addBlockHitbox(block, position)
		print(string.format("[Chest] === SINGLE PLACED ==="))
		print(string.format("[Chest]   type=%s pos=(%.2f, %.2f, %.2f) rot=%d", preset.Id, position.X, position.Y, position.Z, finalRotation or 0))
		local pivotAfter = block:GetPivot().Position
		print(string.format("[Chest]   pivotPos=(%.2f, %.2f, %.2f)", pivotAfter.X, pivotAfter.Y, pivotAfter.Z))
		local gridCellX = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
		local gridCellY = math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE
		local gridCellZ = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
		print(string.format("[Chest]   gridCenter=(%.2f, %.2f, %.2f) offsetFromGrid=(%.2f, %.2f, %.2f)",
			gridCellX, gridCellY, gridCellZ,
			pivotAfter.X - gridCellX, pivotAfter.Y - gridCellY, pivotAfter.Z - gridCellZ))
		-- Log bounding box info
		if block:IsA("Model") then
			local bbCFrame, bbSize = block:GetBoundingBox()
			print(string.format("[Chest]   bbCenter=(%.2f, %.2f, %.2f) bbSize=(%.2f, %.2f, %.2f)",
				bbCFrame.Position.X, bbCFrame.Position.Y, bbCFrame.Position.Z,
				bbSize.X, bbSize.Y, bbSize.Z))
		end
		print(string.format("[Chest]   presetColor=(%d,%d,%d) material=%s variant=%s",
			math.round(preset.DefaultColor.R*255), math.round(preset.DefaultColor.G*255), math.round(preset.DefaultColor.B*255),
			tostring(preset.Material), tostring(preset.MaterialVariant or "")))
		
		-- === DOUBLE CHEST MERGE CHECK ===
		-- Check perpendicular neighbors for a matching single chest to merge into a double
		local rot = (finalRotation or 0) % 360
		local sideOffset
		if rot == 0 or rot == 180 then
			sideOffset = Vector3.new(BLOCK_SIZE, 0, 0)
		else
			sideOffset = Vector3.new(0, 0, BLOCK_SIZE)
		end
		
		local chestSpatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		local mergeNeighbor = nil
		local neighborPos = nil
		
		for _, dir in ipairs({1, -1}) do
			local checkPos = position + sideOffset * dir
			local candidates = chestSpatialIndex:GetBlocksAt(checkPos)
			for _, candidate in ipairs(candidates) do
				if candidate:GetAttribute("IsChest")
					and not candidate:GetAttribute("IsDoubleChest")
					and candidate:GetAttribute("Rotation") == finalRotation
					and candidate:GetAttribute("BlockType") == block:GetAttribute("BlockType")
					and candidate ~= block then
					mergeNeighbor = candidate
					neighborPos = checkPos
					break
				end
			end
			if mergeNeighbor then break end
		end
		
		if mergeNeighbor then
			-- Use preset color/material directly (reliable, no sampling issues)
			local chestColor = preset.DefaultColor
			local chestMaterial = preset.Material
			local chestMaterialVariant = preset.MaterialVariant or ""
			
			local chestBlockType = block:GetAttribute("BlockType")
			local primaryPos = position
			local secondaryPos = neighborPos
			local midpoint = (primaryPos + secondaryPos) / 2
			
			-- Remove both single chests
			block:Destroy()
			mergeNeighbor:Destroy()
			
			-- Clone DoubleChest template
			local BlockTemplates = ReplicatedStorage:FindFirstChild("BlockTemplates")
			local doubleTemplate = BlockTemplates and BlockTemplates:FindFirstChild("DoubleChest")
			if doubleTemplate then
				local doubleChest = doubleTemplate:Clone()
				
				-- Position at midpoint with same rotation + visual offsets
				-- DoubleChest has center pivot (no Y offset needed unlike SingleChest)
				local doubleCFrame = CFrame.new(midpoint) * CFrame.Angles(0, math.rad(rot), 0) * CFrame.new(0, 0, 0.15)
				doubleChest:PivotTo(doubleCFrame)
				
				-- Apply color/material to all parts (skip Latch/Darkness, darken Edge)
				if chestColor then
					local trimH, trimS, trimV = chestColor:ToHSV()
					local trimColor = Color3.fromHSV(trimH, trimS * 0.7, trimV * 0.4)
					for _, part in ipairs(doubleChest:GetDescendants()) do
						if part:IsA("BasePart") and part.Name ~= "Hitbox" then
							local ancestor = part.Parent
							local group = nil
							while ancestor and ancestor ~= doubleChest do
								local n = ancestor.Name
								if n == "Edge" or n == "Latch" or n == "Darkness" then
									group = n; break
								end
								ancestor = ancestor.Parent
							end
							-- Also check the part's own name
							if not group then
								local n = part.Name
								if n == "Edge" or n == "Latch" or n == "Darkness" then group = n end
							end
							if group == "Latch" or group == "Darkness" then continue end
							if group == "Edge" then
								part.Color = trimColor
								-- Edge: only color, keep template material/texture
							else
								part.Color = chestColor
								part.Material = chestMaterial
								if chestMaterialVariant then part.MaterialVariant = chestMaterialVariant end
							end
							part.Anchored = true
							part.CanCollide = true
							part.CastShadow = false
							part.CanTouch = false
						end
					end
				end
				
				-- Set attributes
				doubleChest:SetAttribute("IsChest", true)
				doubleChest:SetAttribute("IsDoubleChest", true)
				doubleChest:SetAttribute("IsOpen", false)
				doubleChest:SetAttribute("BlockType", chestBlockType)
				doubleChest:SetAttribute("PlacedBy", player.UserId)
				doubleChest:SetAttribute("BlockPosX", primaryPos.X)
				doubleChest:SetAttribute("BlockPosY", primaryPos.Y)
				doubleChest:SetAttribute("BlockPosZ", primaryPos.Z)
				doubleChest:SetAttribute("ChestSecondaryX", secondaryPos.X)
				doubleChest:SetAttribute("ChestSecondaryY", secondaryPos.Y)
				doubleChest:SetAttribute("ChestSecondaryZ", secondaryPos.Z)
				doubleChest:SetAttribute("Rotation", finalRotation)
				
				-- Add hitbox spanning both cells
				local hitbox = Instance.new("Part")
				hitbox.Name = "Hitbox"
				hitbox.Anchored = true
				hitbox.CanCollide = false
				hitbox.CanQuery = true
				hitbox.CanTouch = false
				hitbox.CastShadow = false
				hitbox.Transparency = 1
				-- Hitbox spans both cells in the side direction
				hitbox.Size = Vector3.new(
					(rot == 0 or rot == 180) and BLOCK_SIZE * 2 or BLOCK_SIZE,
					BLOCK_SIZE,
					(rot == 90 or rot == 270) and BLOCK_SIZE * 2 or BLOCK_SIZE
				)
				hitbox.CFrame = CFrame.new(midpoint)
				hitbox.Parent = doubleChest
				
				doubleChest.Parent = blocksFolder
				local dPivot = doubleChest:GetPivot().Position
				local dbbCFrame, dbbSize = doubleChest:GetBoundingBox()
				print(string.format("[Chest] === MERGED TO DOUBLE ==="))
				print(string.format("[Chest]   primaryPos=(%.2f, %.2f, %.2f) secondaryPos=(%.2f, %.2f, %.2f)", primaryPos.X, primaryPos.Y, primaryPos.Z, secondaryPos.X, secondaryPos.Y, secondaryPos.Z))
				print(string.format("[Chest]   midpoint=(%.2f, %.2f, %.2f) pivotPos=(%.2f, %.2f, %.2f) rot=%d", midpoint.X, midpoint.Y, midpoint.Z, dPivot.X, dPivot.Y, dPivot.Z, finalRotation))
				print(string.format("[Chest]   bbCenter=(%.2f, %.2f, %.2f) bbSize=(%.2f, %.2f, %.2f)",
					dbbCFrame.Position.X, dbbCFrame.Position.Y, dbbCFrame.Position.Z,
					dbbSize.X, dbbSize.Y, dbbSize.Z))
				local priGridX = math.round(primaryPos.X / BLOCK_SIZE) * BLOCK_SIZE
				local secGridX = math.round(secondaryPos.X / BLOCK_SIZE) * BLOCK_SIZE
				local priGridZ = math.round(primaryPos.Z / BLOCK_SIZE) * BLOCK_SIZE
				local secGridZ = math.round(secondaryPos.Z / BLOCK_SIZE) * BLOCK_SIZE
				print(string.format("[Chest]   primaryGrid=(%.2f, %.2f) secondaryGrid=(%.2f, %.2f) expectedMid=(%.2f, %.2f)",
					priGridX, priGridZ, secGridX, secGridZ, (priGridX+secGridX)/2, (priGridZ+secGridZ)/2))
				print(string.format("[Chest]   bbLeft=%.2f bbRight=%.2f (span=%.2f, expected=%.2f)",
					dbbCFrame.Position.X - dbbSize.X/2, dbbCFrame.Position.X + dbbSize.X/2, dbbSize.X, BLOCK_SIZE * 2))
				print(string.format("[Chest]   color=(%d,%d,%d) material=%s variant=%s",
					chestColor and math.round(chestColor.R*255) or -1, chestColor and math.round(chestColor.G*255) or -1, chestColor and math.round(chestColor.B*255) or -1,
					tostring(chestMaterial), tostring(chestMaterialVariant)))
			end
			return -- Original block was destroyed during merge, stop processing
		end
	end
	
	if isCraftingTable then
		block:SetAttribute("IsCraftingTable", true)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		block:SetAttribute("Rotation", finalRotation)
		addBlockHitbox(block, position)
		print(string.format("[CraftingTable] Placed %s at (%.0f, %.0f, %.0f) rot=%d", preset.Id, position.X, position.Y, position.Z, finalRotation or 0))
	end
	
	if isArchitrave then
		block:SetAttribute("IsArchitrave", true)
		block:SetAttribute("ArchitraveConnectionType", architraveConnectionType)
		block:SetAttribute("ArchitraveModelName", templateName)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		print(string.format("[Architrave] Placed %s -> %s (%s) at (%.0f, %.0f, %.0f)", preset.Id, architraveConnectionType, templateName, position.X, position.Y, position.Z))
	end
	
	if isGlass then
		block:SetAttribute("IsGlass", true)
		block:SetAttribute("GlassConnectionType", glassConnectionType)
		block:SetAttribute("GlassOrientation", glassOrientation)
		block:SetAttribute("GlassRotationDegrees", glassRotationDegrees)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		-- Ensure all glass parts have collision enabled
		if block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = true
				end
			end
		elseif block:IsA("BasePart") then
			block.CanCollide = true
		end
		-- Debug: log placement position vs final position
		local finalPivot = block:GetPivot().Position
		print(string.format("[Glass PLACE] type=%s inputPos=(%.2f,%.2f,%.2f) finalPivot=(%.2f,%.2f,%.2f) diff=(%.2f,%.2f,%.2f)",
			glassConnectionType,
			position.X, position.Y, position.Z,
			finalPivot.X, finalPivot.Y, finalPivot.Z,
			finalPivot.X - position.X, finalPivot.Y - position.Y, finalPivot.Z - position.Z))
		if DEBUG_GLASS then
			print(string.format("[Glass] %s -> %s (%s)", preset.Id, glassConnectionType, glassOrientation))
		end
	end
	
	if isLadder then
		block:SetAttribute("IsLadder", true)
		block:SetAttribute("LadderFace", ladderFace)
		block:SetAttribute("LadderRotation", ladderRotation)
		if DEBUG_LADDERS then
			print(string.format("[Ladder] Placed %s on %s face", preset.Id, ladderFace))
		end
	end
	
	if isVine then
		block:SetAttribute("IsVine", true)
		block:SetAttribute("VineFace", vineFace)
		block:SetAttribute("VineRotation", vineRotation)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		-- Make vine non-collidable
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end
		print(string.format("[Vine] Placed on %s face at (%.1f, %.1f, %.1f)", vineFace, position.X, position.Y, position.Z))
		
		-- Add ceiling vine piece if there's a solid block directly above
		if VinePlacement.ShouldHaveCeiling and VinePlacement.ShouldHaveCeiling(position, blocksFolder) then
			local vineTemplate = DecorationsFolder and DecorationsFolder:FindFirstChild("Vine")
			if vineTemplate then
				local ceiling = vineTemplate:Clone()
				ceiling.Name = "CeilingVine"
				local ceilingCFrame = VinePlacement.GetCeilingCFrame(position)
				if ceiling:IsA("BasePart") then
					ceiling.Anchored = true
					ceiling.CanCollide = false
					ceiling.CanQuery = false
					ceiling.CastShadow = false
					ceiling:PivotTo(ceilingCFrame)
				elseif ceiling:IsA("Model") then
					for _, part in ipairs(ceiling:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Anchored = true
							part.CanCollide = false
							part.CanQuery = false
							part.CastShadow = false
						end
					end
					ceiling:PivotTo(ceilingCFrame)
				end
				ceiling.Parent = block
			end
		end
	end
	
	if isTorch then
		block:SetAttribute("IsTorch", true)
		block:SetAttribute("TorchFace", torchFace)
		block:SetAttribute("TorchRotation", torchRotation)
		block:SetAttribute("TorchModelName", torchModelName)
		block:SetAttribute("IsAngled", torchIsAngled)
		-- Store host position for cleanup when host block breaks
		if data.TorchData and data.TorchData.HostPosition then
			local hostPos = data.TorchData.HostPosition
			block:SetAttribute("HostBlockX", math.round(hostPos.X))
			block:SetAttribute("HostBlockY", math.round(hostPos.Y))
			block:SetAttribute("HostBlockZ", math.round(hostPos.Z))
		end
		-- Torches don't need collision (they're decorative)
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end
		if DEBUG_TORCHES then
			print(string.format("[Torch] Placed %s on %s face (angled: %s)", preset.Id, torchFace, tostring(torchIsAngled)))
		end
	end
	
	-- Handle campfire blocks - tag for SmokeManager
	if isCampfire then
		block:SetAttribute("IsCampfire", true)
		-- Tag for SmokeManager to pick up
		CollectionService:AddTag(block, "Campfire")
		-- Campfires don't need collision on most parts (decorative)
		if block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
					-- Keep collision on the base logs, disable on fire/smoke
					if part.Name == "Fire" or part.Name == "Ash" or string.find(part.Name, "Emitter") then
						part.CanCollide = false
					end
				end
			end
		end
		print(string.format("[Campfire] Placed %s - tagged for SmokeManager", preset.Id))
		
		-- If this is a column cap (e.g. ColumnTorch), update the column below
		if ColumnPlacement.IsColumnCap(block) then
			local belowPos = position - Vector3.new(0, BLOCK_SIZE, 0)
			local columnBelow = nil
			local capIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			if capIndex then
				for _, item in ipairs(capIndex:GetBlocksAt(belowPos)) do
					if item:GetAttribute("IsColumn") then
						columnBelow = item
						break
					end
				end
			end
			if columnBelow then
				local oldModel = columnBelow:GetAttribute("ColumnModelName") or "ColumnSingle"
				local newModel = ColumnPlacement.DetermineModelName(belowPos, blocksFolder)
				if oldModel ~= newModel then
					local placedBy = columnBelow:GetAttribute("PlacedBy")
					local blockRotation = columnBelow:GetAttribute("Rotation") or 0
					local newTemplate = BlocksFolder:FindFirstChild(newModel)
					if newTemplate then
						local newBlock = newTemplate:Clone()
						newBlock.Name = "Column"
						if newBlock:IsA("BasePart") then
							newBlock.Anchored = true
						elseif newBlock:IsA("Model") then
							for _, part in ipairs(newBlock:GetDescendants()) do
								if part:IsA("BasePart") then part.Anchored = true end
							end
						end
						newBlock:SetAttribute("BlockType", "Column")
						newBlock:SetAttribute("IsColumn", true)
						newBlock:SetAttribute("ColumnModelName", newModel)
						newBlock:SetAttribute("PlacedBy", placedBy)
						newBlock:SetAttribute("Rotation", blockRotation)
						newBlock:SetAttribute("BlockPosX", belowPos.X)
						newBlock:SetAttribute("BlockPosY", belowPos.Y)
						newBlock:SetAttribute("BlockPosZ", belowPos.Z)
						setBlockCFrame(newBlock, CFrame.new(belowPos), true, "Column")
						newBlock.Parent = blocksFolder
						addBlockHitbox(newBlock, belowPos)
						columnBelow:Destroy()
						print(string.format("[Column] Updated below ColumnTorch: %s -> %s", oldModel, newModel))
					end
				end
			end
		end
	end
	
	-- Handle lantern blocks
	if isLantern then
		block:SetAttribute("IsLantern", true)
		block:SetAttribute("LanternFace", lanternFace)
		block:SetAttribute("IsHanging", lanternIsHanging)
		-- Store host position for cleanup when host block breaks (keep actual grid position)
		if data.LanternData and data.LanternData.HostPosition then
			local hostPos = data.LanternData.HostPosition
			block:SetAttribute("HostBlockX", hostPos.X)
			block:SetAttribute("HostBlockY", hostPos.Y)
			block:SetAttribute("HostBlockZ", hostPos.Z)
		end
		-- Lanterns don't need collision (they're decorative)
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end
		if DEBUG_LANTERNS then
			print(string.format("[Lantern] Placed %s on %s face (hanging: %s)", preset.Id, lanternFace, tostring(lanternIsHanging)))
		end
	end
	
	-- Handle sign blocks
	if isSign then
		block:SetAttribute("IsSignStanding", isSignStanding or false)
		block:SetAttribute("IsWallSign", isWallSign or false)
		block:SetAttribute("SignFace", signFace)
		block:SetAttribute("SignRotation", signRotation)
		if isSignStanding then
			block:SetAttribute("SignRotationIndex", signRotationIndex)
		end
		if isWallSign then
			block:SetAttribute("IsOnFencePost", isOnFencePost or false)
			print(string.format("[BlockHandler] Placed wall sign: face=%s, isOnFencePost=%s", tostring(signFace), tostring(isOnFencePost)))
		end
		block:SetAttribute("SignType", signType)
		-- Store grid position for accurate removal (signs on fence posts have offset visual position)
		block:SetAttribute("GridPosX", position.X)
		block:SetAttribute("GridPosY", position.Y)
		block:SetAttribute("GridPosZ", position.Z)
		-- Store host position for cleanup when host block breaks
		if data.SignData and data.SignData.HostPosition then
			local hostPos = data.SignData.HostPosition
			block:SetAttribute("HostBlockX", math.round(hostPos.X))
			block:SetAttribute("HostBlockY", math.round(hostPos.Y))
			block:SetAttribute("HostBlockZ", math.round(hostPos.Z))
		end
		-- Signs don't need collision (they're decorative)
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end
		
		-- Apply wood color to ENTIRE sign model uniformly (both Sign and Post parts)
		if preset.ApplyColor and preset.DefaultColor then
			if block:IsA("BasePart") then
				block.Color = preset.DefaultColor
				if preset.Material then block.Material = preset.Material end
				if preset.MaterialVariant and preset.MaterialVariant ~= "" then
					block.MaterialVariant = preset.MaterialVariant
				end
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Color = preset.DefaultColor
						if preset.Material then part.Material = preset.Material end
						if preset.MaterialVariant and preset.MaterialVariant ~= "" then
							part.MaterialVariant = preset.MaterialVariant
						end
					end
				end
			end
		end
		
		if DEBUG_SIGNS then
			if isSignStanding then
				print(string.format("[Sign] Placed standing %s rotation=%.1f (index=%d, direction=%s)", 
					preset.Id, signRotation, signRotationIndex, SignPlacement.GetDirectionName(signRotationIndex)))
			else
				print(string.format("[Sign] Placed wall %s on %s face (rotation=%.1f)", 
					preset.Id, signFace, signRotation))
			end
		end
	end
	
	-- SnowLayer: position at bottom of grid cell (template already has correct size 3×0.375×3)
	if isSnowLayer and block:IsA("BasePart") then
		local layerHeight = BLOCK_SIZE / 8 -- 0.375
		block.Size = Vector3.new(BLOCK_SIZE, layerHeight, BLOCK_SIZE)
		-- Pivot at bottom so it grows upward when stacking
		block.PivotOffset = CFrame.new(0, -layerHeight / 2, 0)
		-- Position center so bottom sits at grid cell floor
		local bottomOfCell = position.Y - BLOCK_SIZE / 2
		local centerY = bottomOfCell + layerHeight / 2
		block.CFrame = CFrame.new(position.X, centerY, position.Z)
		block:SetAttribute("SnowLayers", 1)
		-- Store grid position for spatial index (visual position differs from grid)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		block.CanCollide = false -- Thin layer, don't block movement
		print(string.format("[SnowLayer] Placed 1 layer at grid(%.1f,%.1f,%.1f) centerY=%.3f", position.X, position.Y, position.Z, centerY))
	end
	
	-- CarpetFrame: position at bottom of grid cell (thin 0.38 stud carpet)
	if isCarpet then
		local carpetCFrame = CarpetPlacement.GetCarpetCFrame(position)
		if block:IsA("BasePart") then
			block.CFrame = carpetCFrame
		elseif block:IsA("Model") then
			block:PivotTo(carpetCFrame)
		end
		block:SetAttribute("IsCarpet", true)
		block:SetAttribute("BlockPosX", position.X)
		block:SetAttribute("BlockPosY", position.Y)
		block:SetAttribute("BlockPosZ", position.Z)
		print(string.format("[Carpet] Placed at grid(%.1f,%.1f,%.1f) visualY=%.3f", position.X, position.Y, position.Z, carpetCFrame.Position.Y))
	end
	
	block.Parent = blocksFolder
	print(string.format("[BB-NET] SERVER => PlaceBlock SUCCESS type=%s pos=(%.1f,%.1f,%.1f) player=%s", preset.Id, position.X, position.Y, position.Z, player.Name))
	
	-- Track block placement for Build Coins achievement
	task.spawn(function()
		local coinAccess = ServerScriptService:FindFirstChild("CoinManagerAccess")
		if coinAccess then
			pcall(function()
				coinAccess:Invoke("IncrementBlocks", player.UserId, 1)
			end)
		end
	end)
	
	-- Add invisible hitbox for non-full blocks (so raycasts can select them)
	local isFrameBlock = preset and preset.IsFrameBlock
	if isSnowLayer or isLadder or isTorch or isCampfire or isLantern or isSign or isFence or isGlass or isSurfaceBlock or isDoor or isWallpaperFrame or isCarpet or isVine or isFrameBlock or isArchitrave then
		addBlockHitbox(block, position)
		-- SnowLayer: resize hitbox to match actual layer height
		if isSnowLayer then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local layerHeight = BLOCK_SIZE / 8
				hitbox.Size = Vector3.new(BLOCK_SIZE, layerHeight, BLOCK_SIZE)
				local bottomOfCell = position.Y - BLOCK_SIZE / 2
				hitbox.CFrame = CFrame.new(position.X, bottomOfCell + layerHeight / 2, position.Z)
			end
		end
		-- WallpaperFrame: thin face-oriented hitbox instead of full cube
		-- Prevents overlap with adjacent wallpapers and host block
		if isWallpaperFrame then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local HITBOX_THICKNESS = 0.5
				if wallpaperFace == "North" or wallpaperFace == "South" then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, HITBOX_THICKNESS)
				elseif wallpaperFace == "East" or wallpaperFace == "West" then
					hitbox.Size = Vector3.new(HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				else -- Top or Bottom
					hitbox.Size = Vector3.new(BLOCK_SIZE, HITBOX_THICKNESS, BLOCK_SIZE)
				end
				-- Position flush against host surface (use wallpaper CFrame position)
				hitbox.CFrame = CFrame.new(position)
			end
		end
		-- Door: thin hitbox matching the door panel orientation and depth
		-- Prevents selecting the door when aiming at the wall behind/beside it
		if isDoor and cframe then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local DOOR_HITBOX_THICKNESS = 1.0
				-- doorDirection: 0=North(-Z), 2=South(+Z) → thin in Z
				-- doorDirection: 1=East(+X), 3=West(-X) → thin in X
				if doorDirection == 0 or doorDirection == 2 then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, DOOR_HITBOX_THICKNESS)
				else
					hitbox.Size = Vector3.new(DOOR_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				end
				-- Position at actual door location (includes depth offset)
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
		-- Carpet: thin hitbox matching carpet height, positioned at bottom of cell
		if isCarpet then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local carpetHeight = CarpetPlacement.CARPET_HEIGHT
				hitbox.Size = Vector3.new(BLOCK_SIZE, carpetHeight, BLOCK_SIZE)
				local bottomOfCell = position.Y - BLOCK_SIZE / 2
				hitbox.CFrame = CFrame.new(position.X, bottomOfCell + carpetHeight / 2, position.Z)
			end
		end
		-- Torch: thin hitbox so you can target the block behind/below it
		if isTorch and cframe then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local TORCH_HITBOX = 1.0
				if torchFace == "Top" then
					-- Top-mounted: small column hitbox
					hitbox.Size = Vector3.new(TORCH_HITBOX, BLOCK_SIZE, TORCH_HITBOX)
				elseif torchFace == "North" or torchFace == "South" then
					hitbox.Size = Vector3.new(TORCH_HITBOX, BLOCK_SIZE, TORCH_HITBOX)
				elseif torchFace == "East" or torchFace == "West" then
					hitbox.Size = Vector3.new(TORCH_HITBOX, BLOCK_SIZE, TORCH_HITBOX)
				end
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
		-- Wall sign: thin hitbox matching face orientation, positioned at sign visual location
		-- Skip for fence post signs — they're pushed into the fence's grid cell so a thin
		-- hitbox would be inside the fence's hitbox; keep the full cube for selectability
		if isWallSign and cframe and not isOnFencePost then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local SIGN_HITBOX_THICKNESS = 0.5
				if signFace == "North" or signFace == "South" then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, SIGN_HITBOX_THICKNESS)
				elseif signFace == "East" or signFace == "West" then
					hitbox.Size = Vector3.new(SIGN_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				end
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
		-- Standing sign: thinner hitbox (sign is a flat panel on a post)
		if isSignStanding and cframe then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local SIGN_HITBOX_THICKNESS = 1.0
				local rot = signRotation or 0
				-- Determine thin axis based on rotation (0/180 = thin in Z, 90/270 = thin in X)
				local absRot = rot % 360
				if (absRot >= 45 and absRot < 135) or (absRot >= 225 and absRot < 315) then
					hitbox.Size = Vector3.new(SIGN_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				else
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, SIGN_HITBOX_THICKNESS)
				end
				hitbox.CFrame = CFrame.new(position)
			end
		end
		-- Vine: thin face-oriented hitbox (like wallpaper) so you can target blocks behind it
		if isVine then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local VINE_HITBOX_THICKNESS = 1.0 -- Thin but still easy to click
				if vineFace == "North" or vineFace == "South" then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, VINE_HITBOX_THICKNESS)
				elseif vineFace == "East" or vineFace == "West" then
					hitbox.Size = Vector3.new(VINE_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				end
				-- Position flush against the wall the vine is on
				if cframe then
					hitbox.CFrame = CFrame.new(cframe.Position)
				end
			end
		end
		-- Vine: add climb sensor for client-side climbing
		if isVine and cframe then
			local climbSensor = Instance.new("Part")
			climbSensor.Name = "ClimbSensor"
			climbSensor.Anchored = true
			climbSensor.CanCollide = false
			climbSensor.CanQuery = false
			climbSensor.CanTouch = true
			climbSensor.CastShadow = false
			climbSensor.Transparency = 1
			climbSensor.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, 1.0)
			climbSensor.CFrame = cframe
			climbSensor:AddTag("VineClimbSensor")
			climbSensor.Parent = block
		end
	end
	
	-- Increment lifetime blocks placed counter (for beta tester qualification)
	local lifetimeBlocks = buildArea:GetAttribute("LifetimeBlocksPlaced") or 0
	buildArea:SetAttribute("LifetimeBlocksPlaced", lifetimeBlocks + 1)
	
	-- Apply random color variation to leaves for a more natural look
	-- Also apply biome and season tinting
	local isLeaves = preset.Id == "Leaves"
	if isLeaves then
		-- Get biome and season from build area for proper tinting
		local currentBiome = buildArea:GetAttribute("CurrentBiome")
		local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
		local leafColor
		
		if currentBiome then
			-- Use biome-tinted color with season (defaults to Oak leaf type for player-placed)
			leafColor = BiomeConfig.GetRandomizedTintedLeafColor("Oak", currentBiome, currentSeason)
		else
			-- No biome, use default Oak color with season
			leafColor = BiomeConfig.GetRandomizedTintedLeafColor("Oak", "Plains", currentSeason)
		end
		
		if leafColor then
			if block:IsA("BasePart") then
				block.Color = leafColor
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Color = leafColor
					end
				end
			end
			
			-- Store biome and season for save/load
			if currentBiome then
				block:SetAttribute("Biome", currentBiome)
			end
			block:SetAttribute("Season", currentSeason)
		end
	end
	
	-- Apply biome color and random variation to grass blocks
	local isGrassBlock = preset.Id == "GrassBlock" or preset.Id == "SnowyGrassBlock" or preset.Id == "SnowGrassBlock" or preset.Id == "TaigaGrassBlock"
	if isGrassBlock and block:IsA("Model") then
		local grassPart = block:FindFirstChild("Grass")
		if grassPart and grassPart:IsA("BasePart") then
			-- Get biome and season from build area for proper tinting
			local currentBiome = buildArea:GetAttribute("CurrentBiome")
			local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
			local grassColor
			
			if currentBiome then
				local biomeColors = BiomeConfig.GetBiomeColors(currentBiome)
				if biomeColors and biomeColors.GrassColor then
					-- Apply both biome color AND season multiplier
					grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, currentSeason)
				else
					-- Biome has no grass color (e.g., Desert), fall back to Plains
					local plainsColors = BiomeConfig.GetBiomeColors("Plains")
					if plainsColors and plainsColors.GrassColor then
						grassColor = BiomeConfig.GetRandomizedGrassColor(plainsColors.GrassColor, currentSeason)
					end
				end
				block:SetAttribute("Biome", currentBiome)
				block:SetAttribute("Season", currentSeason)
			else
				-- No biome, use default Plains grass color with season
				local defaultBiomeColors = BiomeConfig.GetBiomeColors("Plains")
				if defaultBiomeColors and defaultBiomeColors.GrassColor then
					grassColor = BiomeConfig.GetRandomizedGrassColor(defaultBiomeColors.GrassColor, currentSeason)
				else
					grassColor = BiomeConfig.GetRandomizedGrassColor(grassPart.Color, currentSeason)
				end
				block:SetAttribute("Season", currentSeason)
			end
			
			if grassColor then
				grassPart.Color = grassColor
			end
		end
	end
	
	-- Handle Glowstone blocks - apply color to both block and PointLight
	local isGlowstone = BlockPresets.IsGlowstone and BlockPresets.IsGlowstone(preset.Id)
	if isGlowstone then
		local glowColor = preset.DefaultColor
		
		-- Apply color to all BaseParts
		if block:IsA("BasePart") then
			block.Color = glowColor
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Color = glowColor
				end
			end
		end
		
		-- Apply boosted color to PointLight (more vivid than block surface)
		-- Boost saturation so the emitted light has a stronger color tint
		local h, s, v = glowColor:ToHSV()
		local boostedSaturation = math.clamp(s * 1.5, 0, 1) -- 50% more saturated
		local boostedValue = math.clamp(v * 1.15, 0, 1)     -- Slightly brighter tint
		local boostedLightColor = Color3.fromHSV(h, boostedSaturation, boostedValue)
		
		for _, descendant in ipairs(block:GetDescendants()) do
			if descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
				descendant.Color = boostedLightColor
			end
		end
		
		-- Store the color name for save/load
		block:SetAttribute("IsGlowstone", true)
		block:SetAttribute("GlowstoneColor", preset.GlowstoneColor)
		
		print(string.format("[Glowstone] Placed %s with color %s", preset.Id, preset.GlowstoneColor or "unknown"))
	end
	
	-- Handle Rainbow / ColorCycle blocks - set ColorMode attribute for client-side animation
	-- Driven by preset.Behavior.ColorCycle (new manifest-driven path) with a fallback
	-- to the legacy preset.IsRainbow flag for any manually-authored presets.
	local cycleCfg = preset.Behavior and preset.Behavior.ColorCycle
	local isRainbow = cycleCfg ~= nil or (BlockPresets.IsRainbow and BlockPresets.IsRainbow(preset.Id))
	if isRainbow then
		block:SetAttribute("ColorMode", "Rainbow")
		
		-- For blocks with an animated light, flag it so ColorCycleController also animates the PointLight
		if (cycleCfg and cycleCfg.Light) or preset.HasPointLight then
			block:SetAttribute("HasPointLight", true)
		end
		
		-- Phase propagation: check 6 neighbors for existing rainbow blocks of the SAME type
		-- (same BlockType -> same cycle duration -> safe to share phase). Different block types
		-- may have different Durations in their manifest, so syncing them would cause drift.
		local syncWithNeighbors = (cycleCfg and cycleCfg.SyncWithNeighbors ~= false) or (not cycleCfg) -- default true
		local rainbowPhase = nil
		if syncWithNeighbors then
			local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			local directions = {
				Vector3.new(BLOCK_SIZE, 0, 0), Vector3.new(-BLOCK_SIZE, 0, 0),
				Vector3.new(0, BLOCK_SIZE, 0), Vector3.new(0, -BLOCK_SIZE, 0),
				Vector3.new(0, 0, BLOCK_SIZE), Vector3.new(0, 0, -BLOCK_SIZE),
			}
			for _, dir in ipairs(directions) do
				local neighborPos = position + dir
				local neighbor = spatialIndex:GetBlockAt(neighborPos)
				if neighbor
					and neighbor:GetAttribute("ColorMode") == "Rainbow"
					and neighbor:GetAttribute("BlockType") == preset.Id then
					rainbowPhase = neighbor:GetAttribute("RainbowPhase")
					if rainbowPhase then break end
				end
			end
		end
		
		if not rainbowPhase then
			-- Random phase offset, in seconds. Range is the block's own cycle duration so phase
			-- covers exactly one full cycle. Defaults to 6s if no manifest config.
			local duration = (cycleCfg and cycleCfg.Duration) or 6
			rainbowPhase = math.random() * duration
		end
		block:SetAttribute("RainbowPhase", rainbowPhase)
		
		-- Random XYZ rotation to break up texture tiling. Driven by Behavior.RandomRotation
		-- (defaults true for legacy IsRainbow presets that have no Behavior table).
		local wantRandomRotation
		if preset.Behavior then
			wantRandomRotation = preset.Behavior.RandomRotation == true
		else
			wantRandomRotation = true -- legacy default for IsRainbow without a Behavior table
		end
		if wantRandomRotation and preset.Shape == "Block" and not preset.UseBlockModel then
			local randomRotX = math.random(0, 3)
			local randomRotY = math.random(0, 3)
			local randomRotZ = math.random(0, 3)
			local rotCFrame = CFrame.Angles(
				math.rad(randomRotX * 90),
				math.rad(randomRotY * 90),
				math.rad(randomRotZ * 90)
			)
			if block:IsA("BasePart") then
				block.CFrame = block.CFrame * rotCFrame
			elseif block:IsA("Model") then
				block:PivotTo(block:GetPivot() * rotCFrame)
			end
			-- Store Y rotation for save system (visual rotation is baked into CFrame)
			block:SetAttribute("Rotation", randomRotY)
			block:SetAttribute("RainbowRotX", randomRotX)
			block:SetAttribute("RainbowRotZ", randomRotZ)
		end
		
		print(string.format("[Rainbow] Placed %s with ColorMode=Rainbow phase=%.2f", preset.Id, rainbowPhase))
	end
	
	-- DISABLED: Lamp initialization temporarily disabled
	-- The "Light" name matching incorrectly catches LightBlue/LightGreen wool/glass
	-- TODO: Re-enable with attribute-based detection instead of name matching
	
	-- Initialize logic gates to their default state
	if LogicGates and LogicGates.IsLogicGate(preset.Id) then
		LogicGates.InitializeGate(block, preset.Id)
		print(string.format("[LogicGate] Placed %s - initialized (outputting: %s)", preset.Id, tostring(block:GetAttribute("IsOutputting"))))
	end
	
	-- Only update existing stairs/arches if the NEW one is NORMAL
	local updatedStairs = {}
	if (isStair or isArch) and cornerType == "normal" and direction ~= nil then
		local typeChecker = nil
		if isArch then
			typeChecker = StairPlacement.GetArchTypeChecker(data.BlockType)
		end
		updatedStairs = updateExistingStairsToCorners(position, direction, upsideDown, blocksFolder, typeChecker)
	end
	
	-- Update adjacent fences when ANY solid block is placed (fences connect to solid blocks)
	local isSolidBlock = FencePlacement.IsSolidBlock(preset.Id)
	if isSolidBlock and not isFence then
		-- Create a function to create fence blocks for the update
		local function createFenceBlockForSolid(templateName, fenceType, fencePos, fenceRotation, placedBy, connectionType, oldColor, oldMaterial, oldMaterialVariant)
			-- Check if this is a frame fence (use FrameBlocks folder)
			local isFrameFence = FencePlacement.IsFrameFence(fenceType)
			local newFence
			if isFrameFence then
				newFence = createBlockFromTemplate(templateName, fenceType, false, templateName, "FrameBlocks")
			else
				newFence = createBlockFromTemplate(templateName, nil)
			end
			if newFence then
				newFence.Name = fenceType  -- Set name after creation
				local fenceCFrame = FencePlacement.GetFenceCFrame(fencePos, fenceRotation, isFrameFence)
				setBlockCFrame(newFence, fenceCFrame, false, fenceType)
				
				-- Get preset defaults for this fence type
				local fencePreset = BlockPresets and BlockPresets.GetPreset(fenceType)
				
				-- Use preserved values, or fall back to preset defaults
				local finalColor = oldColor or (fencePreset and fencePreset.DefaultColor)
				local finalMaterial = oldMaterial or (fencePreset and fencePreset.Material)
				local finalMaterialVariant = (oldMaterialVariant and oldMaterialVariant ~= "") and oldMaterialVariant or (fencePreset and fencePreset.MaterialVariant or "")
				
				-- Apply color/material/materialVariant (skip for frame fences - they keep original appearance)
				if not isFrameFence and finalColor and finalMaterial and newFence:IsA("BasePart") then
					newFence.Color = finalColor
					newFence.Material = finalMaterial
					if finalMaterialVariant and finalMaterialVariant ~= "" then
						newFence.MaterialVariant = finalMaterialVariant
					end
				end
				
				newFence:SetAttribute("BlockType", fenceType)
				newFence:SetAttribute("PlacedBy", placedBy)
				newFence:SetAttribute("Rotation", fenceRotation)
				newFence:SetAttribute("IsFence", true)
				newFence:SetAttribute("FenceConnectionType", connectionType)
				-- Store grid position for spatial index (fence unions have offset geometric centers)
				newFence:SetAttribute("BlockPosX", fencePos.X)
				newFence:SetAttribute("BlockPosY", fencePos.Y)
				newFence:SetAttribute("BlockPosZ", fencePos.Z)
				if isFrameFence then
					newFence:SetAttribute("IsFrameBlock", true)
				end
				
				newFence.Parent = blocksFolder
				addBlockHitbox(newFence, fencePos)
				return newFence
			end
			return nil
		end
		
		local updatedFences = FencePlacement.UpdateFencesNearSolidBlock(position, blocksFolder, BlockTemplates, createFenceBlockForSolid)
		
		if #updatedFences > 0 then
			print(string.format("[Fence] Updated %d adjacent fences due to solid block placement", #updatedFences))
		end
		
		-- Also update adjacent glass panes (they may need to become / un-become L-corners)
		local function createGlassBlockForSolid(glassTemplateName, glassType, glassPos, glassRotationCF, placedBy, connectionType, primaryDir, secondaryDir, orientation)
			local template = resolveGlassTemplate(glassType, glassTemplateName)
			if not template then return nil end

			local newGlass = template:Clone()
			newGlass.Name = glassType

			if newGlass:IsA("BasePart") then
				newGlass.Anchored = true
				newGlass.CanCollide = true
			elseif newGlass:IsA("Model") then
				for _, part in ipairs(newGlass:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = true
						part.CanCollide = true
					end
				end
			end

			local glassCFrame = GlassPlacement.GetGlassCFrame(glassPos, glassRotationCF, nil, connectionType)
			if newGlass:IsA("BasePart") then
				newGlass.CFrame = glassCFrame
			elseif newGlass:IsA("Model") then
				newGlass:PivotTo(glassCFrame)
			end

			newGlass:SetAttribute("BlockType", glassType)
			newGlass:SetAttribute("PlacedBy", placedBy)
			newGlass:SetAttribute("IsGlass", true)
			newGlass:SetAttribute("GlassConnectionType", connectionType)
			newGlass:SetAttribute("GlassPrimaryDir", primaryDir)
			newGlass:SetAttribute("GlassSecondaryDir", secondaryDir)
			newGlass:SetAttribute("GlassOrientation", orientation or "NS")
			newGlass:SetAttribute("BlockPosX", glassPos.X)
			newGlass:SetAttribute("BlockPosY", glassPos.Y)
			newGlass:SetAttribute("BlockPosZ", glassPos.Z)

			newGlass.Parent = blocksFolder
			addBlockHitbox(newGlass, glassPos)
			return newGlass
		end

		local updatedGlass = GlassPlacement.UpdateGlassNearSolidBlock(position, blocksFolder, createGlassBlockForSolid)
		if #updatedGlass > 0 then
			print(string.format("[Glass] Updated %d adjacent glass panes due to solid block placement", #updatedGlass))
		end
	end
	
	-- Update adjacent fences when a fence is placed
	if isFence then
		-- Create a function to create fence blocks for the update
		local function createFenceBlock(templateName, fenceType, fencePos, fenceRotation, placedBy, connectionType, oldColor, oldMaterial, oldMaterialVariant)
			-- Check if this is a frame fence (use FrameBlocks folder)
			local isFrameFence = FencePlacement.IsFrameFence(fenceType)
			local newFence
			if isFrameFence then
				newFence = createBlockFromTemplate(templateName, fenceType, false, templateName, "FrameBlocks")
			else
				newFence = createBlockFromTemplate(templateName, nil)
			end
			if newFence then
				newFence.Name = fenceType  -- Set name after creation
				local fenceCFrame = FencePlacement.GetFenceCFrame(fencePos, fenceRotation, isFrameFence)
				setBlockCFrame(newFence, fenceCFrame, false, fenceType)
				
				-- Get preset defaults for this fence type
				local fencePreset = BlockPresets and BlockPresets.GetPreset(fenceType)
				
				-- Use preserved values, or fall back to preset defaults
				local finalColor = oldColor or (fencePreset and fencePreset.DefaultColor)
				local finalMaterial = oldMaterial or (fencePreset and fencePreset.Material)
				local finalMaterialVariant = (oldMaterialVariant and oldMaterialVariant ~= "") and oldMaterialVariant or (fencePreset and fencePreset.MaterialVariant or "")
				
				-- Apply color/material/materialVariant (skip for frame fences - they keep original appearance)
				if not isFrameFence and finalColor and finalMaterial and newFence:IsA("BasePart") then
					newFence.Color = finalColor
					newFence.Material = finalMaterial
					if finalMaterialVariant and finalMaterialVariant ~= "" then
						newFence.MaterialVariant = finalMaterialVariant
					end
				end
				
				newFence:SetAttribute("BlockType", fenceType)
				newFence:SetAttribute("PlacedBy", placedBy)
				newFence:SetAttribute("Rotation", fenceRotation)
				newFence:SetAttribute("IsFence", true)
				newFence:SetAttribute("FenceConnectionType", connectionType)
				-- Store grid position for spatial index (fence unions have offset geometric centers)
				newFence:SetAttribute("BlockPosX", fencePos.X)
				newFence:SetAttribute("BlockPosY", fencePos.Y)
				newFence:SetAttribute("BlockPosZ", fencePos.Z)
				if isFrameFence then
					newFence:SetAttribute("IsFrameBlock", true)
				end
				
				newFence.Parent = blocksFolder
				addBlockHitbox(newFence, fencePos)
				return newFence
			end
			return nil
		end
		
		local updatedFences = FencePlacement.UpdateAdjacentFences(position, blocksFolder, BlockTemplates, createFenceBlock)
		
		if #updatedFences > 0 then
			print(string.format("[Fence] Updated %d neighbors", #updatedFences))
		end
	end
	
	-- Update adjacent columns when a column is placed
	if isColumn then
		local function replaceColumnNeighbor(oldBlock, newModelName, colPos)
			-- Preserve attributes
			local placedBy = oldBlock:GetAttribute("PlacedBy")
			local blockRotation = oldBlock:GetAttribute("Rotation") or 0
			
			-- Clone new model
			local newModel = BlocksFolder:FindFirstChild(newModelName)
			if not newModel then
				warn("[Column] Model not found: " .. newModelName)
				return
			end
			local newBlock = newModel:Clone()
			newBlock.Name = "Column"
			
			-- Anchor parts
			if newBlock:IsA("BasePart") then
				newBlock.Anchored = true
			elseif newBlock:IsA("Model") then
				for _, part in ipairs(newBlock:GetDescendants()) do
					if part:IsA("BasePart") then part.Anchored = true end
				end
			end
			
			-- Set attributes BEFORE parenting (so spatial index reads BlockPos on ChildAdded)
			newBlock:SetAttribute("BlockType", "Column")
			newBlock:SetAttribute("IsColumn", true)
			newBlock:SetAttribute("ColumnModelName", newModelName)
			newBlock:SetAttribute("PlacedBy", placedBy)
			newBlock:SetAttribute("Rotation", blockRotation)
			newBlock:SetAttribute("BlockPosX", colPos.X)
			newBlock:SetAttribute("BlockPosY", colPos.Y)
			newBlock:SetAttribute("BlockPosZ", colPos.Z)
			
			-- Position
			local cframe = CFrame.new(colPos)
			setBlockCFrame(newBlock, cframe, true, "Column")
			
			-- Parent new FIRST, then destroy old (avoids flicker from destroy→create gap)
			newBlock.Parent = blocksFolder
			addBlockHitbox(newBlock, colPos)
			oldBlock:Destroy()
			
			print(string.format("[Column] Updated neighbor at (%.0f,%.0f,%.0f) -> %s", colPos.X, colPos.Y, colPos.Z, newModelName))
		end
		
		local updated = ColumnPlacement.UpdateNeighborColumns(position, blocksFolder, replaceColumnNeighbor)
		if #updated > 0 then
			print(string.format("[Column] Updated %d neighbors", #updated))
		end
	end
	
	-- Update adjacent architraves when an architrave is placed
	if isArchitrave then
		local ArchitravesFolder = ReplicatedStorage:FindFirstChild("Architraves")
		local function createArchitraveBlock(archTemplateName, archPos, archRotation, archPlacedBy, connectionType, modelName)
			if not ArchitravesFolder then
				warn("[Architrave] Architraves folder not found!")
				return nil
			end
			local template = ArchitravesFolder:FindFirstChild(archTemplateName)
			if not template then
				warn("[Architrave] Template not found: " .. tostring(archTemplateName))
				return nil
			end
			
			local newBlock = template:Clone()
			newBlock.Name = "Architrave"
			
			if newBlock:IsA("BasePart") then
				newBlock.Anchored = true
			elseif newBlock:IsA("Model") then
				for _, part in ipairs(newBlock:GetDescendants()) do
					if part:IsA("BasePart") then part.Anchored = true end
				end
			end
			
			newBlock:SetAttribute("BlockType", "Architrave")
			newBlock:SetAttribute("IsArchitrave", true)
			newBlock:SetAttribute("ArchitraveConnectionType", connectionType)
			newBlock:SetAttribute("ArchitraveModelName", modelName or archTemplateName)
			newBlock:SetAttribute("PlacedBy", archPlacedBy)
			newBlock:SetAttribute("Rotation", archRotation)
			newBlock:SetAttribute("BlockPosX", archPos.X)
			newBlock:SetAttribute("BlockPosY", archPos.Y)
			newBlock:SetAttribute("BlockPosZ", archPos.Z)
			
			local archCFrame = ArchitravePlacement.GetArchitraveCFrame(archPos, archRotation)
			setBlockCFrame(newBlock, archCFrame, true, "Architrave")
			
			newBlock.Parent = blocksFolder
			addBlockHitbox(newBlock, archPos)
			return newBlock
		end
		
		local updatedArchitraves = ArchitravePlacement.UpdateAdjacentArchitraves(position, blocksFolder, createArchitraveBlock)
		if #updatedArchitraves > 0 then
			print(string.format("[Architrave] Updated %d neighbors", #updatedArchitraves))
		end
	end
	
	-- Update adjacent glass when a glass pane is placed
	if isGlass then
		-- Create a function to create glass blocks for the update
		local function createGlassBlock(glassTemplateName, glassType, glassPos, glassRotationCF, placedBy, connectionType, primaryDir, secondaryDir, orientation)
			-- Resolve template from the glass-type registry (Decorations/Glass, RewardSets, etc.)
			local template = resolveGlassTemplate(glassType, glassTemplateName)
			if not template then
				return nil
			end
			
			local newGlass = template:Clone()
			newGlass.Name = glassType
			
			-- Anchor all parts and enable collision
			if newGlass:IsA("BasePart") then
				newGlass.Anchored = true
				newGlass.CanCollide = true
			elseif newGlass:IsA("Model") then
				for _, part in ipairs(newGlass:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = true
						part.CanCollide = true
					end
				end
			end
			
			local glassCFrame = GlassPlacement.GetGlassCFrame(glassPos, glassRotationCF, nil, connectionType)
			if newGlass:IsA("BasePart") then
				newGlass.CFrame = glassCFrame
			elseif newGlass:IsA("Model") then
				-- Glass models have center pivots, no offset needed
				newGlass:PivotTo(glassCFrame)
			end
			
			newGlass:SetAttribute("BlockType", glassType)
			newGlass:SetAttribute("PlacedBy", placedBy)
			newGlass:SetAttribute("IsGlass", true)
			newGlass:SetAttribute("GlassConnectionType", connectionType)
			newGlass:SetAttribute("GlassPrimaryDir", primaryDir)
			newGlass:SetAttribute("GlassSecondaryDir", secondaryDir)
			newGlass:SetAttribute("GlassOrientation", orientation or "NS")
			newGlass:SetAttribute("BlockPosX", glassPos.X)
			newGlass:SetAttribute("BlockPosY", glassPos.Y)
			newGlass:SetAttribute("BlockPosZ", glassPos.Z)
			
			newGlass.Parent = blocksFolder
			addBlockHitbox(newGlass, glassPos)
			return newGlass
		end
		
		-- Update vertical connections (same-orientation neighbors)
		local updatedGlass = GlassPlacement.UpdateAdjacentGlass(position, blocksFolder, createGlassBlock, glassOrientation)
		
		if #updatedGlass > 0 and DEBUG_GLASS then
			print(string.format("[Glass] Updated %d vertical neighbors", #updatedGlass))
		end
		
		-- Re-evaluate the just-placed pane itself in case the perpendicular-stub
		-- corner rule applies (flat pane oriented perpendicular to its sole neighbor).
		if glassOrientation == "NS" or glassOrientation == "EW" then
			GlassPlacement.FixupGlassAtPosition(position, blocksFolder, createGlassBlock)
		end
		
		-- Check if adjacent glass should become a special connection (corner / tee / 4-way)
		-- NOTE: UpdateAdjacentGlass above already handles most of this. This pass is
		--       idempotent and catches anything missed.
		do
			local toConvert = GlassPlacement.GetAdjacentGlassToConvertToCorners(position, glassOrientation, blocksFolder)
			
			for _, convertData in ipairs(toConvert) do
				local oldGlass = convertData.existingGlass.instance
				local cornerInfo = convertData.cornerInfo
				local adjPos = convertData.position
				
				-- Preserve attributes from old glass
				local oldBlockType = oldGlass:GetAttribute("BlockType")
				local oldPlacedBy = oldGlass:GetAttribute("PlacedBy")
				
				-- Capture per-part appearance (Outer/Inner colors and materials) before destroying
				local perPartAppearance = {}
				local fallbackColor = nil
				if oldGlass:IsA("BasePart") then
					fallbackColor = oldGlass.Color
					perPartAppearance["__root__"] = { color = oldGlass.Color, material = oldGlass.Material, materialVariant = oldGlass.MaterialVariant }
				elseif oldGlass:IsA("Model") then
					for _, p in ipairs(oldGlass:GetDescendants()) do
						if p:IsA("BasePart") then
							perPartAppearance[p.Name] = { color = p.Color, material = p.Material, materialVariant = p.MaterialVariant }
							if not fallbackColor then fallbackColor = p.Color end
						end
					end
				end
				
				-- Destroy old glass
				oldGlass:Destroy()
				
				-- Create new special-connection glass (corner / tee / 4way)
				local newSpecialGlass = createGlassBlock(
					cornerInfo.templateName,
					oldBlockType,
					adjPos,
					cornerInfo.rotationCFrame,
					oldPlacedBy,
					cornerInfo.cornerType,
					nil, nil,
					cornerInfo.cornerType
				)
				
				if newSpecialGlass then
					-- Reapply preserved appearance per-part
					local function applyTo(part)
						local app = perPartAppearance[part.Name] or perPartAppearance["__root__"]
						if app then
							part.Color = app.color
							part.Material = app.material
							if app.materialVariant and app.materialVariant ~= "" then
								part.MaterialVariant = app.materialVariant
							end
						elseif fallbackColor then
							part.Color = fallbackColor
						end
					end
					if newSpecialGlass:IsA("BasePart") then
						applyTo(newSpecialGlass)
					elseif newSpecialGlass:IsA("Model") then
						for _, p in ipairs(newSpecialGlass:GetDescendants()) do
							if p:IsA("BasePart") then applyTo(p) end
						end
					end
					
					newSpecialGlass:SetAttribute("GlassRotationDegrees", cornerInfo.rotationDegrees)
					if DEBUG_GLASS then
						print(string.format("[Glass] Converted neighbor at (%.1f, %.1f, %.1f) to %s!",
							adjPos.X, adjPos.Y, adjPos.Z, cornerInfo.cornerType))
					end
				end
			end
		end
	end
	
	-- Log result
	if DEBUG_STAIRS and isStair then
		local dirName = direction ~= nil and StairPlacement.GetDirectionName(direction) or "?"
		local log = string.format("[Stair] Placed %s facing %s", cornerType:upper(), dirName)
		
		if #updatedStairs > 0 then
			local updates = {}
			for _, info in ipairs(updatedStairs) do
				table.insert(updates, info.direction .. "→" .. info.cornerType:upper())
			end
			log = log .. " | Updated: " .. table.concat(updates, ", ")
		end
		
		print(log)
	end
end)
end -- if PlaceBlock

-- ============================================
-- REMOVE BLOCK
-- ============================================

local function getPlotNumberFromBuildArea(buildArea)
	-- Extract plot number from buildArea name (e.g., "BuildArea1" -> 1)
	-- MegaPlotBuildArea uses plot number 0
	local name = buildArea.Name
	if name == "MegaPlotBuildArea" then
		return 0
	end
	local num = name:match("%d+")
	return num and tonumber(num) or nil
end

if RemoveBlock then
RemoveBlock.OnServerEvent:Connect(function(player, block, hitPosition)
	if not block then return end
	if not block:GetAttribute("BlockType") then return end
	print(string.format("[BB-NET] SERVER <- RemoveBlock from=%s type=%s block=%s", player.Name, tostring(block:GetAttribute("BlockType")), block.Name))
	
	-- Can't break edge walls
	if block:GetAttribute("IsEdgeWall") then
		return
	end
	
	-- Can't break water blocks (use Empty Bucket to pick up sources)
	if block:GetAttribute("IsWater") then
		return
	end
	
	-- Get block position to check permissions
	local blockPos
	if block:IsA("BasePart") then
		blockPos = block:GetPivot().Position
	elseif block:IsA("Model") then
		-- Use stored grid position if available, otherwise calculate from pivot
		local storedX = block:GetAttribute("BlockPosX") or block:GetAttribute("GridPosX")
		local storedY = block:GetAttribute("BlockPosY") or block:GetAttribute("GridPosY")
		local storedZ = block:GetAttribute("BlockPosZ") or block:GetAttribute("GridPosZ")
		if storedX and storedY and storedZ then
			blockPos = Vector3.new(storedX, storedY, storedZ)
		else
			blockPos = block:GetPivot().Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
	end
	
	-- Check if player can build at this position (own plot OR shared access)
	local canBuild, buildArea = canPlayerBuildAtPosition(player, blockPos)
	if not canBuild or not buildArea then return end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	if block.Parent ~= blocksFolder then return end
	
	-- Get block position before destroying
	-- Use stored grid position attributes for accuracy (models have bottom-center pivots)
	local blockPos
	local blockPosX = block:GetAttribute("BlockPosX")
	local blockPosY = block:GetAttribute("BlockPosY")
	local blockPosZ = block:GetAttribute("BlockPosZ")
	
	-- Also check for GridPosX/Y/Z (used by doors and signs)
	local gridPosX = block:GetAttribute("GridPosX")
	local gridPosY = block:GetAttribute("GridPosY")
	local gridPosZ = block:GetAttribute("GridPosZ")
	
	if blockPosX and blockPosY and blockPosZ then
		-- Use stored block position (most accurate for terrain blocks)
		blockPos = Vector3.new(blockPosX, blockPosY, blockPosZ)
	elseif gridPosX and gridPosY and gridPosZ then
		-- Use stored grid position (for doors, signs, etc.)
		blockPos = Vector3.new(gridPosX, gridPosY, gridPosZ)
	else
		-- Fallback to pivot position (adjust for models)
		if block:IsA("BasePart") then
			blockPos = block:GetPivot().Position
		elseif block:IsA("Model") then
			-- Models have bottom-center pivot, add half block to get grid center
			blockPos = block:GetPivot().Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
	end
	
	-- Check block attributes for later use
	local isFence = block:GetAttribute("IsFence")
	local isGlass = block:GetAttribute("IsGlass")
	local isColumn = block:GetAttribute("IsColumn")
	local isColumnCap = ColumnPlacement.IsColumnCap(block)
	local isArchitrave = block:GetAttribute("IsArchitrave")
	
	-- Check block type
	local isTerrainBlock = block:GetAttribute("IsTerrainBlock")
	local isDecoration = block:GetAttribute("IsDecoration")
	
	-- Check if this is a path block (created by shovel from grass)
	local pathYOffset = block:GetAttribute("PathYOffset")
	local isPathBlock = pathYOffset ~= nil
	local pathBasePosition = nil
	if isPathBlock then
		-- Get the original grid position (before the path was raised)
		local pathBaseX = block:GetAttribute("PathBaseX")
		local pathBaseY = block:GetAttribute("PathBaseY")
		local pathBaseZ = block:GetAttribute("PathBaseZ")
		if pathBaseX and pathBaseY and pathBaseZ then
			pathBasePosition = Vector3.new(pathBaseX, pathBaseY, pathBaseZ)
		elseif blockPos then
			-- Fallback: calculate base position from raised position
			pathBasePosition = blockPos - Vector3.new(0, pathYOffset, 0)
			print(string.format("[PathBlock] Using fallback base position calculation: (%.1f, %.1f, %.1f)",
				pathBasePosition.X, pathBasePosition.Y, pathBasePosition.Z))
		end
	end
	
	-- CRITICAL: Mark position as dug BEFORE destroying the block
	-- This prevents race conditions where lazy loading might try to refill this position
	-- Must use grid position from attributes (not pivot position which is offset for models)
	if isTerrainBlock and blockPos and TerrainGenerator and not isDecoration then
		local plotNumber = getPlotNumberFromBuildArea(buildArea)
		if plotNumber then
			-- Get actual grid position from stored attributes (most accurate)
			local gridPosX = block:GetAttribute("BlockPosX")
			local gridPosY = block:GetAttribute("BlockPosY")
			local gridPosZ = block:GetAttribute("BlockPosZ")
			
			local gridPosition
			if gridPosX and gridPosY and gridPosZ then
				gridPosition = Vector3.new(gridPosX, gridPosY, gridPosZ)
			else
				-- Fallback: adjust pivot position for models (add half block height)
				if block:IsA("Model") then
					gridPosition = blockPos + Vector3.new(0, BLOCK_SIZE / 2, 0)
				else
					gridPosition = blockPos
				end
			end
			
			TerrainGenerator.MarkPositionAsDug(gridPosition, plotNumber)
			-- Debug print disabled for performance
			-- print(string.format("[LazyLoad] Pre-marked position as dug: (%.1f, %.1f, %.1f)", gridPosition.X, gridPosition.Y, gridPosition.Z))
		end
	end
	
	-- Get glass orientation before destroying (for neighbor updates)
	local glassOrientation = isGlass and block:GetAttribute("GlassOrientation") or "NS"
	
	-- Check if this is a solid block that fences could connect to (before destroying)
	local blockType = block:GetAttribute("BlockType")
	local wasSolidBlock = blockType and FencePlacement.IsSolidBlock(blockType)
	
	-- OPTIMIZED: Use spatial index to find attached items instead of scanning ALL children
	-- Checks only nearby positions where attached items could be (O(1) lookups vs O(n) scan)
	local isSign = block:GetAttribute("IsSignStanding") or block:GetAttribute("IsWallSign")
	if blockPos and not isDecoration and not isSign then
		local blockGridX = math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE
		local blockGridY = math.round(blockPos.Y / BLOCK_SIZE) * BLOCK_SIZE
		local blockGridZ = math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
		local blockGridPos = Vector3.new(blockGridX, blockGridY, blockGridZ)

		-- Most blocks occupy one grid cell. Double chests occupy two (primary + secondary),
		-- so attached items on either cell need to be cleaned up when the chest breaks.
		-- We accumulate every host grid cell here and run the same offset sweep for each.
		local hostGridCells = { blockGridPos }
		if block:GetAttribute("IsDoubleChest") then
			local sx = block:GetAttribute("ChestSecondaryX")
			local sy = block:GetAttribute("ChestSecondaryY")
			local sz = block:GetAttribute("ChestSecondaryZ")
			if sx and sy and sz then
				table.insert(hostGridCells, Vector3.new(
					math.round(sx / BLOCK_SIZE) * BLOCK_SIZE,
					math.round(sy / BLOCK_SIZE) * BLOCK_SIZE,
					math.round(sz / BLOCK_SIZE) * BLOCK_SIZE
				))
			end
		end

		local itemsToDestroy = {}
		local seenItems = {} -- dedupe across host cells (an item adjacent to both cells)
		local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		
		if spatialIndex then
			-- Check positions where attached items could be:
			-- Same position, above, below, and 4 horizontal faces
			local checkOffsets = {
				Vector3.new(0, 0, 0),             -- same position
				Vector3.new(0, BLOCK_SIZE, 0),     -- above (decorations, standing signs)
				Vector3.new(0, -BLOCK_SIZE, 0),    -- below (hanging lanterns)
				Vector3.new(BLOCK_SIZE, 0, 0),     -- +X face (torches, wall signs)
				Vector3.new(-BLOCK_SIZE, 0, 0),    -- -X face
				Vector3.new(0, 0, BLOCK_SIZE),     -- +Z face
				Vector3.new(0, 0, -BLOCK_SIZE),    -- -Z face
				Vector3.new(BLOCK_SIZE, BLOCK_SIZE, 0),  -- above +X (torches on top face)
				Vector3.new(-BLOCK_SIZE, BLOCK_SIZE, 0), -- above -X
				Vector3.new(0, BLOCK_SIZE, BLOCK_SIZE),  -- above +Z
				Vector3.new(0, BLOCK_SIZE, -BLOCK_SIZE), -- above -Z
			}

			for _, hostCell in ipairs(hostGridCells) do
				for _, offset in ipairs(checkOffsets) do
					local checkPos = hostCell + offset
					for _, item in ipairs(spatialIndex:GetBlocksAt(checkPos)) do
						if seenItems[item] then continue end
						-- Check if this item is attached to the broken block
						if item:GetAttribute("IsDecoration") then
							local px = item:GetAttribute("ParentBlockX")
							local py = item:GetAttribute("ParentBlockY")
							local pz = item:GetAttribute("ParentBlockZ")
							if px and py and pz then
								-- Snap the stored ParentBlock to the grid the SAME way hostCell
								-- is snapped before comparing. ParentBlockX/Y/Z were stored as
								-- math.round(worldPos) at placement, which on an off-grid plot
								-- doesn't equal the multiple-of-BLOCK_SIZE hostCell. Snapping both
								-- sides puts them in the same space so saplings/decorations on
								-- off-grid blocks (e.g. candy cane saplings) still get cleaned up.
								local snappedParent = Vector3.new(
									math.round(px / BLOCK_SIZE) * BLOCK_SIZE,
									math.round(py / BLOCK_SIZE) * BLOCK_SIZE,
									math.round(pz / BLOCK_SIZE) * BLOCK_SIZE
								)
								if (snappedParent - hostCell).Magnitude < 1 then
									seenItems[item] = true
									table.insert(itemsToDestroy, item)
								end
							end
						elseif item:GetAttribute("IsTorch") then
							local hx = item:GetAttribute("HostBlockX")
							local hy = item:GetAttribute("HostBlockY")
							local hz = item:GetAttribute("HostBlockZ")
							if hx and hy and hz then
								local hostGridPos = Vector3.new(
									math.round(hx / BLOCK_SIZE) * BLOCK_SIZE,
									math.round(hy / BLOCK_SIZE) * BLOCK_SIZE,
									math.round(hz / BLOCK_SIZE) * BLOCK_SIZE
								)
								if (hostGridPos - hostCell).Magnitude < 0.5 then
									seenItems[item] = true
									table.insert(itemsToDestroy, item)
								end
							end
						elseif item:GetAttribute("IsLantern") then
							local hx = item:GetAttribute("HostBlockX")
							local hy = item:GetAttribute("HostBlockY")
							local hz = item:GetAttribute("HostBlockZ")
							if hx and hy and hz then
								if (Vector3.new(hx, hy, hz) - hostCell).Magnitude < BLOCK_SIZE then
									seenItems[item] = true
									table.insert(itemsToDestroy, item)
								end
							end
						elseif item:GetAttribute("IsSignStanding") or item:GetAttribute("IsWallSign") then
							local hx = item:GetAttribute("HostBlockX")
							local hy = item:GetAttribute("HostBlockY")
							local hz = item:GetAttribute("HostBlockZ")
							if hx and hy and hz then
								local hostGridPos = Vector3.new(
									math.round(hx / BLOCK_SIZE) * BLOCK_SIZE,
									math.round(hy / BLOCK_SIZE) * BLOCK_SIZE,
									math.round(hz / BLOCK_SIZE) * BLOCK_SIZE
								)
								if (hostGridPos - hostCell).Magnitude < 0.5 then
									seenItems[item] = true
									table.insert(itemsToDestroy, item)
								end
							end
						elseif item:GetAttribute("IsCarpet") then
							-- Carpet breaks if the block directly below it is removed
							local cpx = item:GetAttribute("BlockPosX")
							local cpy = item:GetAttribute("BlockPosY")
							local cpz = item:GetAttribute("BlockPosZ")
							if cpx and cpy and cpz then
								local carpetGridPos = Vector3.new(cpx, cpy, cpz)
								-- Carpet is one grid cell above its support block
								local expectedSupport = carpetGridPos - Vector3.new(0, BLOCK_SIZE, 0)
								if (expectedSupport - hostCell).Magnitude < 1 then
									seenItems[item] = true
									table.insert(itemsToDestroy, item)
								end
							end
						end
					end
				end
			end
		else
			-- Fallback: scan all blocks (shouldn't happen)
			for _, item in ipairs(blocksFolder:GetChildren()) do
				if item:GetAttribute("IsDecoration") then
					local px = item:GetAttribute("ParentBlockX")
					local py = item:GetAttribute("ParentBlockY")
					local pz = item:GetAttribute("ParentBlockZ")
					if px and py and pz then
						-- Grid-snap both sides before comparing (see note in the spatial-index
						-- path above) so decorations on off-grid blocks still match.
						local snappedParent = Vector3.new(
							math.round(px / BLOCK_SIZE) * BLOCK_SIZE,
							math.round(py / BLOCK_SIZE) * BLOCK_SIZE,
							math.round(pz / BLOCK_SIZE) * BLOCK_SIZE
						)
						local snappedBlock = Vector3.new(
							math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE,
							math.round(blockPos.Y / BLOCK_SIZE) * BLOCK_SIZE,
							math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
						)
						if (snappedParent - snappedBlock).Magnitude < 1 then
							table.insert(itemsToDestroy, item)
						end
					end
				elseif item:GetAttribute("IsTorch") or item:GetAttribute("IsLantern") or item:GetAttribute("IsSignStanding") or item:GetAttribute("IsWallSign") then
					local hx = item:GetAttribute("HostBlockX")
					local hy = item:GetAttribute("HostBlockY")
					local hz = item:GetAttribute("HostBlockZ")
					if hx and hy and hz and (Vector3.new(hx, hy, hz) - blockPos).Magnitude < BLOCK_SIZE then
						table.insert(itemsToDestroy, item)
					end
				elseif item:GetAttribute("IsCarpet") then
					local cpx = item:GetAttribute("BlockPosX")
					local cpy = item:GetAttribute("BlockPosY")
					local cpz = item:GetAttribute("BlockPosZ")
					if cpx and cpy and cpz then
						local expectedSupport = Vector3.new(cpx, cpy, cpz) - Vector3.new(0, BLOCK_SIZE, 0)
						if (expectedSupport - blockPos).Magnitude < 1 then
							table.insert(itemsToDestroy, item)
						end
					end
				end
			end
		end
		
		for _, item in ipairs(itemsToDestroy) do
			item:Destroy()
		end
	end
	
	-- LAZY LOADING: Spawn adjacent terrain blocks
	-- Client handles instant visual feedback via ClientPrediction.SpawnTerrainPrediction
	-- Server spawns the real blocks which will replace client's temporary ones
	-- NOTE: Skip for path blocks - they use pathBasePosition instead (handled below)
	if isTerrainBlock and blockPos and TerrainGenerator and not isDecoration and not isPathBlock then
		local plotNumber = getPlotNumberFromBuildArea(buildArea)
		TerrainGenerator.OnTerrainBlockBroken(blockPos, buildArea, plotNumber)
		-- Tell client ALL dug positions in a cube around the break point.
		-- This covers the client's PREDICTION_DEPTH=2 plus wall fills,
		-- so phantom predictions in saved holes get cleaned up immediately.
		local nearbyDug = TerrainGenerator.GetDugPositionsInArea(blockPos, plotNumber, buildArea, 3)
		if #nearbyDug > 0 then
			TerrainDugPositions:FireClient(player, nearbyDug)
		end
	end
	
	-- PATH BLOCK LAZY LOADING: When a path block is broken, spawn dirt at the original position
	-- Path blocks are raised 1.5 studs above the original grass position, so we use pathBasePosition
	if isPathBlock and pathBasePosition and TerrainGenerator and not isDecoration then
		local plotNumber = getPlotNumberFromBuildArea(buildArea)
		if plotNumber then
			-- Mark the original position as dug (prevents terrain from being regenerated here)
			TerrainGenerator.MarkPositionAsDug(pathBasePosition, plotNumber)
			-- Trigger lazy loading at the original position to spawn dirt below
			TerrainGenerator.OnTerrainBlockBroken(pathBasePosition, buildArea, plotNumber)
			-- Tell client ALL dug positions nearby
			local nearbyDug = TerrainGenerator.GetDugPositionsInArea(pathBasePosition, plotNumber, buildArea, 3)
			if #nearbyDug > 0 then
				TerrainDugPositions:FireClient(player, nearbyDug)
			end
			print(string.format("[PathBlock] Broken at raised pos, triggering lazy load at base pos: (%.1f, %.1f, %.1f)",
				pathBasePosition.X, pathBasePosition.Y, pathBasePosition.Z))
		end
	end
	
	-- Update adjacent columns BEFORE destroying (so swap + destroy replicate together)
	if isColumn and blockPos then
		local function replaceColumnOnRemove(oldBlock, newModelName, colPos)
			local placedBy = oldBlock:GetAttribute("PlacedBy")
			local blockRotation = oldBlock:GetAttribute("Rotation") or 0
			
			local newModel = BlocksFolder:FindFirstChild(newModelName)
			if not newModel then
				warn("[Column] Model not found: " .. newModelName)
				return
			end
			local newBlock = newModel:Clone()
			newBlock.Name = "Column"
			
			if newBlock:IsA("BasePart") then
				newBlock.Anchored = true
			elseif newBlock:IsA("Model") then
				for _, part in ipairs(newBlock:GetDescendants()) do
					if part:IsA("BasePart") then part.Anchored = true end
				end
			end
			
			-- Set attributes BEFORE parenting
			newBlock:SetAttribute("BlockType", "Column")
			newBlock:SetAttribute("IsColumn", true)
			newBlock:SetAttribute("ColumnModelName", newModelName)
			newBlock:SetAttribute("PlacedBy", placedBy)
			newBlock:SetAttribute("Rotation", blockRotation)
			newBlock:SetAttribute("BlockPosX", colPos.X)
			newBlock:SetAttribute("BlockPosY", colPos.Y)
			newBlock:SetAttribute("BlockPosZ", colPos.Z)
			
			local cframe = CFrame.new(colPos)
			setBlockCFrame(newBlock, cframe, true, "Column")
			
			-- Parent new FIRST, then destroy old (avoids flicker from destroy->create gap)
			newBlock.Parent = blocksFolder
			addBlockHitbox(newBlock, colPos)
			oldBlock:Destroy()
			
			print(string.format("[Column] Updated neighbor at (%.0f,%.0f,%.0f) -> %s", colPos.X, colPos.Y, colPos.Z, newModelName))
		end
		
		-- Pass blockPos as excludePosition so neighbors recalculate as if this block is already gone
		local updated = ColumnPlacement.UpdateNeighborColumns(blockPos, blocksFolder, replaceColumnOnRemove, blockPos)
		if #updated > 0 then
			print(string.format("[Column] Updated %d neighbors before removal", #updated))
		end
	end
	
	-- If a column cap (ColumnTorch) was removed, update the column below
	if isColumnCap and blockPos then
		local belowPos = blockPos - Vector3.new(0, BLOCK_SIZE, 0)
		local capRemoveIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		if capRemoveIndex then
			for _, item in ipairs(capRemoveIndex:GetBlocksAt(belowPos)) do
				if item:GetAttribute("IsColumn") then
					local oldModel = item:GetAttribute("ColumnModelName") or "ColumnSingle"
					-- Use excludePos to pretend the cap is already gone
					local newModel = ColumnPlacement.DetermineModelName(belowPos, blocksFolder, blockPos)
					if oldModel ~= newModel then
						local placedBy = item:GetAttribute("PlacedBy")
						local rot = item:GetAttribute("Rotation") or 0
						local newTemplate = BlocksFolder:FindFirstChild(newModel)
						if newTemplate then
							local newBlock = newTemplate:Clone()
							newBlock.Name = "Column"
							if newBlock:IsA("BasePart") then
								newBlock.Anchored = true
							elseif newBlock:IsA("Model") then
								for _, part in ipairs(newBlock:GetDescendants()) do
									if part:IsA("BasePart") then part.Anchored = true end
								end
							end
							newBlock:SetAttribute("BlockType", "Column")
							newBlock:SetAttribute("IsColumn", true)
							newBlock:SetAttribute("ColumnModelName", newModel)
							newBlock:SetAttribute("PlacedBy", placedBy)
							newBlock:SetAttribute("Rotation", rot)
							newBlock:SetAttribute("BlockPosX", belowPos.X)
							newBlock:SetAttribute("BlockPosY", belowPos.Y)
							newBlock:SetAttribute("BlockPosZ", belowPos.Z)
							setBlockCFrame(newBlock, CFrame.new(belowPos), true, "Column")
							newBlock.Parent = blocksFolder
							addBlockHitbox(newBlock, belowPos)
							item:Destroy()
							print(string.format("[Column] Updated below removed ColumnTorch: %s -> %s", oldModel, newModel))
						end
					end
					break
				end
			end
		end
	end
	
	-- === DOUBLE CHEST SPLIT ===
	-- If breaking a double chest, spawn a single chest on the remaining half
	if block:GetAttribute("IsDoubleChest") then
		local primaryX = block:GetAttribute("BlockPosX")
		local primaryY = block:GetAttribute("BlockPosY")
		local primaryZ = block:GetAttribute("BlockPosZ")
		local secondaryX = block:GetAttribute("ChestSecondaryX")
		local secondaryY = block:GetAttribute("ChestSecondaryY")
		local secondaryZ = block:GetAttribute("ChestSecondaryZ")
		local chestRot = block:GetAttribute("Rotation") or 0
		local chestBlockType = block:GetAttribute("BlockType")
		local chestPlacedBy = block:GetAttribute("PlacedBy")
		
		if primaryX and secondaryX then
			local primaryPos = Vector3.new(primaryX, primaryY, primaryZ)
			local secondaryPos = Vector3.new(secondaryX, secondaryY, secondaryZ)
			
			-- Determine which half the player is looking at (that's the one being broken)
			local remainingPos = secondaryPos -- default: break primary, keep secondary
			if hitPosition and typeof(hitPosition) == "Vector3" then
				-- Use the exact hit point from the client's crosshair raycast
				local distToPrimary = (hitPosition - primaryPos).Magnitude
				local distToSecondary = (hitPosition - secondaryPos).Magnitude
				if distToSecondary < distToPrimary then
					remainingPos = primaryPos -- player hit secondary side, keep primary
				end
			else
				-- Fallback: use player position if hit position unavailable
				local character = player.Character
				local rootPart = character and character:FindFirstChild("HumanoidRootPart")
				if rootPart then
					local distToPrimary = (rootPart.Position - primaryPos).Magnitude
					local distToSecondary = (rootPart.Position - secondaryPos).Magnitude
					if distToSecondary < distToPrimary then
						remainingPos = primaryPos
					end
				end
			end
			
			-- Get color/material from preset (reliable, no sampling issues)
			local chestPreset = BlockPresets.GetPreset(chestBlockType)
			local chestColor = chestPreset and chestPreset.DefaultColor
			local chestMaterial = chestPreset and chestPreset.Material
			local chestMaterialVariant = chestPreset and (chestPreset.MaterialVariant or "")
			
			-- Destroy the double chest
			print(string.format("[Chest] === SPLITTING DOUBLE ==="))
			print(string.format("[Chest]   type=%s primaryPos=(%.1f, %.1f, %.1f) secondaryPos=(%.1f, %.1f, %.1f)",
				chestBlockType or "?", primaryPos.X, primaryPos.Y, primaryPos.Z, secondaryPos.X, secondaryPos.Y, secondaryPos.Z))
			print(string.format("[Chest]   remainingPos=(%.1f, %.1f, %.1f) rot=%d", remainingPos.X, remainingPos.Y, remainingPos.Z, chestRot))
			print(string.format("[Chest]   presetColor=(%d,%d,%d) material=%s variant=%s",
				chestColor and math.round(chestColor.R*255) or -1, chestColor and math.round(chestColor.G*255) or -1, chestColor and math.round(chestColor.B*255) or -1,
				tostring(chestMaterial), tostring(chestMaterialVariant)))
			block:Destroy()
			
			-- Spawn a single chest on the remaining half
			local BlockTemplates = ReplicatedStorage:FindFirstChild("BlockTemplates")
			local singleTemplate = BlockTemplates and BlockTemplates:FindFirstChild("SingleChest")
			if singleTemplate then
				local singleChest = singleTemplate:Clone()
				
				local singleCFrame = CFrame.new(remainingPos) * CFrame.Angles(0, math.rad(chestRot), 0) * CFrame.new(0, 0, 0.15)
				singleChest:PivotTo(singleCFrame)
				
				-- Apply color/material to all parts (skip Latch/Darkness, darken Edge)
				if chestColor then
					local trimH, trimS, trimV = chestColor:ToHSV()
					local trimColor = Color3.fromHSV(trimH, trimS * 0.7, trimV * 0.4)
					for _, part in ipairs(singleChest:GetDescendants()) do
						if part:IsA("BasePart") and part.Name ~= "Hitbox" then
							local ancestor = part.Parent
							local group = nil
							while ancestor and ancestor ~= singleChest do
								local n = ancestor.Name
								if n == "Edge" or n == "Latch" or n == "Darkness" then
									group = n; break
								end
								ancestor = ancestor.Parent
							end
							if not group then
								local n = part.Name
								if n == "Edge" or n == "Latch" or n == "Darkness" then group = n end
							end
							if group == "Latch" or group == "Darkness" then continue end
							if group == "Edge" then
								part.Color = trimColor
								-- Edge: only color, keep template material/texture
							else
								part.Color = chestColor
								part.Material = chestMaterial
								if chestMaterialVariant then part.MaterialVariant = chestMaterialVariant end
							end
							part.Anchored = true
							part.CastShadow = false
							part.CanTouch = false
						end
					end
				end
				
				-- Set attributes
				singleChest:SetAttribute("IsChest", true)
				singleChest:SetAttribute("IsOpen", false)
				singleChest:SetAttribute("BlockType", chestBlockType)
				singleChest:SetAttribute("PlacedBy", chestPlacedBy)
				singleChest:SetAttribute("BlockPosX", remainingPos.X)
				singleChest:SetAttribute("BlockPosY", remainingPos.Y)
				singleChest:SetAttribute("BlockPosZ", remainingPos.Z)
				singleChest:SetAttribute("Rotation", chestRot)
				addBlockHitbox(singleChest, remainingPos)
				singleChest.Parent = blocksFolder
				local sPivot = singleChest:GetPivot().Position
				print(string.format("[Chest]   spawned SingleChest pivotPos=(%.2f, %.2f, %.2f)", sPivot.X, sPivot.Y, sPivot.Z))
			end
		end
		return -- Double chest handled, skip normal destroy
	end
	
	-- Capture vine info BEFORE destroying, so we can cascade-break free-hanging
	-- vines below this one. (Vines that spread downward past their host wall have
	-- no support of their own — breaking the vine above them should drop the
	-- whole hanging chain.)
	local wasVine = block:GetAttribute("IsVine")
	local cascadeVineFace = wasVine and block:GetAttribute("VineFace") or nil
	
	-- Destroy the block
	print(string.format("[BB-NET] SERVER => RemoveBlock SUCCESS type=%s pos=(%.1f,%.1f,%.1f) player=%s", tostring(blockType), blockPos.X, blockPos.Y, blockPos.Z, player.Name))
	block:Destroy()
	
	-- Cascade-break free-hanging vines below the broken vine. Walks downward
	-- from the broken vine's position; for each vine on the same face, if it
	-- has no solid host wall behind it (free-hanging), destroy it and continue.
	-- Stops at the first walled vine, a different-face vine, or empty cell.
	if wasVine and cascadeVineFace and blockPos then
		local currentPos = blockPos - Vector3.new(0, BLOCK_SIZE, 0)
		local breakCount = 0
		local MAX_CASCADE = 50 -- safety bound (max vine chain length)
		local oppositeFace = VinePlacement.GetOppositeFace(cascadeVineFace)
		local hostOffsetDir = VinePlacement.GetFaceOffset(oppositeFace)
		
		for _ = 1, MAX_CASCADE do
			local vineBelow = VinePlacement.GetVineAtPosition(currentPos, blocksFolder)
			if not vineBelow then break end
			if vineBelow.face ~= cascadeVineFace then break end
			
			-- If this vine has its own host wall, it's still anchored — stop here
			local hostPos = currentPos + hostOffsetDir * BLOCK_SIZE
			if VinePlacement.HasSolidBlockAt(hostPos, blocksFolder) then
				break
			end
			
			-- Free-hanging: destroy and continue down the chain
			if vineBelow.instance and vineBelow.instance.Parent then
				vineBelow.instance:Destroy()
				breakCount = breakCount + 1
			end
			currentPos = currentPos - Vector3.new(0, BLOCK_SIZE, 0)
		end
		
		if breakCount > 0 then
			print(string.format("[Vine] Cascade-broke %d free-hanging vine(s) below (%.1f,%.1f,%.1f) face=%s",
				breakCount, blockPos.X, blockPos.Y, blockPos.Z, cascadeVineFace))
		end
	end
	
	-- If solid block was broken, update adjacent fences
	if wasSolidBlock and blockPos and not isFence then
		local function createFenceBlockForSolid(templateName, fenceType, fencePos, fenceRotation, placedBy, connectionType, oldColor, oldMaterial, oldMaterialVariant)
			-- Check if this is a frame fence (use FrameBlocks folder)
			local isFrameFence = FencePlacement.IsFrameFence(fenceType)
			local newFence
			if isFrameFence then
				newFence = createBlockFromTemplate(templateName, fenceType, false, templateName, "FrameBlocks")
			else
				newFence = createBlockFromTemplate(templateName, nil)
			end
			if newFence then
				newFence.Name = fenceType  -- Set name after creation
				local fenceCFrame = FencePlacement.GetFenceCFrame(fencePos, fenceRotation, isFrameFence)
				setBlockCFrame(newFence, fenceCFrame, false, fenceType)
				
				-- Get preset defaults for this fence type
				local fencePreset = BlockPresets and BlockPresets.GetPreset(fenceType)
				
				-- Use preserved values, or fall back to preset defaults
				local finalColor = oldColor or (fencePreset and fencePreset.DefaultColor)
				local finalMaterial = oldMaterial or (fencePreset and fencePreset.Material)
				local finalMaterialVariant = (oldMaterialVariant and oldMaterialVariant ~= "") and oldMaterialVariant or (fencePreset and fencePreset.MaterialVariant or "")
				
				-- Apply color/material/materialVariant (skip for frame fences)
				if not isFrameFence and finalColor and finalMaterial and newFence:IsA("BasePart") then
					newFence.Color = finalColor
					newFence.Material = finalMaterial
					if finalMaterialVariant and finalMaterialVariant ~= "" then
						newFence.MaterialVariant = finalMaterialVariant
					end
				end
				
				newFence:SetAttribute("BlockType", fenceType)
				newFence:SetAttribute("PlacedBy", placedBy)
				newFence:SetAttribute("Rotation", fenceRotation)
				newFence:SetAttribute("IsFence", true)
				newFence:SetAttribute("FenceConnectionType", connectionType)
				-- Store grid position for spatial index (fence unions have offset geometric centers)
				newFence:SetAttribute("BlockPosX", fencePos.X)
				newFence:SetAttribute("BlockPosY", fencePos.Y)
				newFence:SetAttribute("BlockPosZ", fencePos.Z)
				if isFrameFence then
					newFence:SetAttribute("IsFrameBlock", true)
				end
				
				newFence.Parent = blocksFolder
				addBlockHitbox(newFence, fencePos)
				return newFence
			end
			return nil
		end
		
		task.defer(function()
			local updatedFences = FencePlacement.UpdateFencesNearSolidBlock(blockPos, blocksFolder, BlockTemplates, createFenceBlockForSolid)
			if #updatedFences > 0 then
				print(string.format("[Fence] Updated %d adjacent fences due to solid block removal", #updatedFences))
			end
		end)

		-- Also update adjacent glass panes (corner anchors may have been removed)
		local function createGlassBlockForSolid(glassTemplateName, glassType, glassPos, glassRotationCF, placedBy, connectionType, primaryDir, secondaryDir, orientation)
			local template = resolveGlassTemplate(glassType, glassTemplateName)
			if not template then return nil end

			local newGlass = template:Clone()
			newGlass.Name = glassType

			if newGlass:IsA("BasePart") then
				newGlass.Anchored = true
				newGlass.CanCollide = true
			elseif newGlass:IsA("Model") then
				for _, part in ipairs(newGlass:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = true
						part.CanCollide = true
					end
				end
			end

			local glassCFrame = GlassPlacement.GetGlassCFrame(glassPos, glassRotationCF, nil, connectionType)
			if newGlass:IsA("BasePart") then
				newGlass.CFrame = glassCFrame
			elseif newGlass:IsA("Model") then
				newGlass:PivotTo(glassCFrame)
			end

			newGlass:SetAttribute("BlockType", glassType)
			newGlass:SetAttribute("PlacedBy", placedBy)
			newGlass:SetAttribute("IsGlass", true)
			newGlass:SetAttribute("GlassConnectionType", connectionType)
			newGlass:SetAttribute("GlassPrimaryDir", primaryDir)
			newGlass:SetAttribute("GlassSecondaryDir", secondaryDir)
			newGlass:SetAttribute("GlassOrientation", orientation or "NS")
			newGlass:SetAttribute("BlockPosX", glassPos.X)
			newGlass:SetAttribute("BlockPosY", glassPos.Y)
			newGlass:SetAttribute("BlockPosZ", glassPos.Z)

			newGlass.Parent = blocksFolder
			addBlockHitbox(newGlass, glassPos)
			return newGlass
		end

		task.defer(function()
			local updatedGlass = GlassPlacement.UpdateGlassNearSolidBlock(blockPos, blocksFolder, createGlassBlockForSolid)
			if #updatedGlass > 0 then
				print(string.format("[Glass] Updated %d adjacent glass panes due to solid block removal", #updatedGlass))
			end
		end)
	end
	
	-- If fence was broken, update adjacent fences
	if isFence and blockPos then
		local function createFenceBlock(templateName, fenceType, fencePos, fenceRotation, placedBy, connectionType, oldColor, oldMaterial, oldMaterialVariant)
			-- Check if this is a frame fence (use FrameBlocks folder)
			local isFrameFence = FencePlacement.IsFrameFence(fenceType)
			local newFence
			if isFrameFence then
				newFence = createBlockFromTemplate(templateName, fenceType, false, templateName, "FrameBlocks")
			else
				newFence = createBlockFromTemplate(templateName, nil)
			end
			if newFence then
				newFence.Name = fenceType  -- Set name after creation
				local fenceCFrame = FencePlacement.GetFenceCFrame(fencePos, fenceRotation, isFrameFence)
				setBlockCFrame(newFence, fenceCFrame, false, fenceType)
				
				-- Get preset defaults for this fence type
				local fencePreset = BlockPresets and BlockPresets.GetPreset(fenceType)
				
				-- Use preserved values, or fall back to preset defaults
				local finalColor = oldColor or (fencePreset and fencePreset.DefaultColor)
				local finalMaterial = oldMaterial or (fencePreset and fencePreset.Material)
				local finalMaterialVariant = (oldMaterialVariant and oldMaterialVariant ~= "") and oldMaterialVariant or (fencePreset and fencePreset.MaterialVariant or "")
				
				-- Apply color/material/materialVariant (skip for frame fences)
				if not isFrameFence and finalColor and finalMaterial and newFence:IsA("BasePart") then
					newFence.Color = finalColor
					newFence.Material = finalMaterial
					if finalMaterialVariant and finalMaterialVariant ~= "" then
						newFence.MaterialVariant = finalMaterialVariant
					end
				end
				
				newFence:SetAttribute("BlockType", fenceType)
				newFence:SetAttribute("PlacedBy", placedBy)
				newFence:SetAttribute("Rotation", fenceRotation)
				newFence:SetAttribute("IsFence", true)
				newFence:SetAttribute("FenceConnectionType", connectionType)
				-- Store grid position for spatial index (fence unions have offset geometric centers)
				newFence:SetAttribute("BlockPosX", fencePos.X)
				newFence:SetAttribute("BlockPosY", fencePos.Y)
				newFence:SetAttribute("BlockPosZ", fencePos.Z)
				if isFrameFence then
					newFence:SetAttribute("IsFrameBlock", true)
				end
				
				newFence.Parent = blocksFolder
				addBlockHitbox(newFence, fencePos)
				return newFence
			end
			return nil
		end
		
		task.defer(function()
			local updatedFences = FencePlacement.UpdateAdjacentFences(blockPos, blocksFolder, BlockTemplates, createFenceBlock)
			if #updatedFences > 0 then
				print(string.format("[Fence] Updated %d neighbors", #updatedFences))
			end
		end)
	end
	
	-- If glass was broken, update adjacent glass
	if isGlass and blockPos then
		local function createGlassBlock(glassTemplateName, glassType, glassPos, glassRotationCF, placedBy, connectionType, primaryDir, secondaryDir, orientation)
			-- Resolve template from the glass-type registry (Decorations/Glass, RewardSets, etc.)
			local template = resolveGlassTemplate(glassType, glassTemplateName)
			if not template then
				return nil
			end
			
			local newGlass = template:Clone()
			newGlass.Name = glassType
			
			-- Anchor all parts and enable collision
			if newGlass:IsA("BasePart") then
				newGlass.Anchored = true
				newGlass.CanCollide = true
			elseif newGlass:IsA("Model") then
				for _, part in ipairs(newGlass:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = true
						part.CanCollide = true
					end
				end
			end
			
			local glassCFrame = GlassPlacement.GetGlassCFrame(glassPos, glassRotationCF, nil, connectionType)
			if newGlass:IsA("BasePart") then
				newGlass.CFrame = glassCFrame
			elseif newGlass:IsA("Model") then
				-- Glass models have center pivots, no offset needed
				newGlass:PivotTo(glassCFrame)
			end
			
			newGlass:SetAttribute("BlockType", glassType)
			newGlass:SetAttribute("PlacedBy", placedBy)
			newGlass:SetAttribute("IsGlass", true)
			newGlass:SetAttribute("GlassConnectionType", connectionType)
			newGlass:SetAttribute("GlassPrimaryDir", primaryDir)
			newGlass:SetAttribute("GlassSecondaryDir", secondaryDir)
			newGlass:SetAttribute("GlassOrientation", orientation or "NS")
			newGlass:SetAttribute("BlockPosX", glassPos.X)
			newGlass:SetAttribute("BlockPosY", glassPos.Y)
			newGlass:SetAttribute("BlockPosZ", glassPos.Z)
			
			newGlass.Parent = blocksFolder
			addBlockHitbox(newGlass, glassPos)
			return newGlass
		end
		
		task.defer(function()
			-- Update neighbors for both orientations since we don't know which neighbors exist
			-- Actually, we should update based on the removed glass's orientation
			local updatedGlass = GlassPlacement.UpdateAdjacentGlass(blockPos, blocksFolder, createGlassBlock, glassOrientation)
			if #updatedGlass > 0 then
				print(string.format("[Glass] Updated %d neighbors after removal", #updatedGlass))
			end
		end)
	end
	
	-- If architrave was broken, update adjacent architraves
	if isArchitrave and blockPos then
		local ArchitravesFolder = ReplicatedStorage:FindFirstChild("Architraves")
		local function createArchitraveOnBreak(archTemplateName, archPos, archRotation, archPlacedBy, connectionType, modelName)
			if not ArchitravesFolder then
				warn("[Architrave] Architraves folder not found!")
				return nil
			end
			local template = ArchitravesFolder:FindFirstChild(archTemplateName)
			if not template then
				warn("[Architrave] Template not found: " .. tostring(archTemplateName))
				return nil
			end
			
			local newBlock = template:Clone()
			newBlock.Name = "Architrave"
			
			if newBlock:IsA("BasePart") then
				newBlock.Anchored = true
			elseif newBlock:IsA("Model") then
				for _, part in ipairs(newBlock:GetDescendants()) do
					if part:IsA("BasePart") then part.Anchored = true end
				end
			end
			
			newBlock:SetAttribute("BlockType", "Architrave")
			newBlock:SetAttribute("IsArchitrave", true)
			newBlock:SetAttribute("ArchitraveConnectionType", connectionType)
			newBlock:SetAttribute("ArchitraveModelName", modelName or archTemplateName)
			newBlock:SetAttribute("PlacedBy", archPlacedBy)
			newBlock:SetAttribute("Rotation", archRotation)
			newBlock:SetAttribute("BlockPosX", archPos.X)
			newBlock:SetAttribute("BlockPosY", archPos.Y)
			newBlock:SetAttribute("BlockPosZ", archPos.Z)
			
			local archCFrame = ArchitravePlacement.GetArchitraveCFrame(archPos, archRotation)
			setBlockCFrame(newBlock, archCFrame, true, "Architrave")
			
			newBlock.Parent = blocksFolder
			addBlockHitbox(newBlock, archPos)
			return newBlock
		end
		
		task.defer(function()
			local updatedArchitraves = ArchitravePlacement.UpdateAdjacentArchitraves(blockPos, blocksFolder, createArchitraveOnBreak)
			if #updatedArchitraves > 0 then
				print(string.format("[Architrave] Updated %d neighbors after break", #updatedArchitraves))
			end
		end)
	end
	
	-- NOTE: Lazy loading now happens BEFORE block:Destroy() to prevent sky flash
	-- (See above where we call TerrainGenerator.OnTerrainBlockBroken before destroying)
end)
end -- if RemoveBlock

-- ============================================
-- POSITION-BASED BLOCK REMOVAL (for client prediction digging)
-- When client breaks a prediction block, the real block may not exist yet.
-- This handler marks the position as dug and spawns adjacent terrain.
-- ============================================
RemoveBlockAtPosition.OnServerEvent:Connect(function(player, position)
	if not position or typeof(position) ~= "Vector3" then return end
	print(string.format("[BB-NET] SERVER <- RemoveBlockAtPosition from=%s pos=(%.1f,%.1f,%.1f)", player.Name, position.X, position.Y, position.Z))

	-- Snap to grid
	local gridPos = Vector3.new(
		math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
	)

	-- Check if player can build at this position
	local canBuild, buildArea = canPlayerBuildAtPosition(player, gridPos)
	if not canBuild or not buildArea then
		-- Notify client to undo any prediction it made
		BuildRejected:FireClient(player, "break", gridPos)
		return
	end

	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end

	local plotNumber = getPlotNumberFromBuildArea(buildArea)

	-- Try to find and destroy any real block at this position
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	local foundBlock = nil
	if spatialIndex then
		local blocksAtPos = spatialIndex:GetBlocksAt(gridPos)
		for _, block in ipairs(blocksAtPos) do
			if block:GetAttribute("IsTerrainBlock") and not block:GetAttribute("IsEdgeWall") then
				foundBlock = block
				break
			end
		end
	end

	-- Mark position as dug
	if plotNumber and TerrainGenerator then
		TerrainGenerator.MarkPositionAsDug(gridPos, plotNumber)
	end

	-- Spawn adjacent terrain blocks
	if TerrainGenerator then
		TerrainGenerator.OnTerrainBlockBroken(gridPos, buildArea, plotNumber)
		-- Tell client ALL dug positions nearby
		local nearbyDug = TerrainGenerator.GetDugPositionsInArea(gridPos, plotNumber, buildArea, 3)
		if #nearbyDug > 0 then
			TerrainDugPositions:FireClient(player, nearbyDug)
		end
	end

	-- Destroy the real block if it exists
	if foundBlock then
		print(string.format("[BB-NET] SERVER => RemoveBlockAtPosition SUCCESS found+destroyed real block at (%.1f,%.1f,%.1f) player=%s", gridPos.X, gridPos.Y, gridPos.Z, player.Name))
		foundBlock:Destroy()
	else
		print(string.format("[BB-NET] SERVER => RemoveBlockAtPosition OK no real block at (%.1f,%.1f,%.1f) (prediction only) player=%s", gridPos.X, gridPos.Y, gridPos.Z, player.Name))
	end
end)

-- ========================================
-- SNOW LAYER STACKING
-- ========================================
StackSnowLayer.OnServerEvent:Connect(function(player, hitBlock)
	print(string.format("[SnowLayer] StackSnowLayer received from %s, hitBlock=%s", player.Name, tostring(hitBlock)))
	
	if not hitBlock or not hitBlock.Parent then
		print("[SnowLayer] ABORT: hitBlock nil or no parent")
		return
	end
	if hitBlock:GetAttribute("BlockType") ~= "SnowLayer" then
		print(string.format("[SnowLayer] ABORT: BlockType is '%s', not SnowLayer", tostring(hitBlock:GetAttribute("BlockType"))))
		return
	end
	if not hitBlock:IsA("BasePart") then
		print(string.format("[SnowLayer] ABORT: hitBlock is %s, not BasePart", hitBlock.ClassName))
		return
	end
	
	-- Verify player has build permission
	local blocksFolder = hitBlock.Parent
	local buildArea = blocksFolder and blocksFolder.Parent
	if not buildArea then
		print("[SnowLayer] ABORT: no buildArea found")
		return
	end
	
	-- Extract plot number from buildArea name (e.g. "BuildArea3" -> 3)
	local plotNumber = tonumber(string.match(buildArea.Name, "%d+$"))
	if plotNumber and CheckPlotBuildPermission then
		local canBuild = CheckPlotBuildPermission:Invoke(player, plotNumber)
		if not canBuild then
			print("[SnowLayer] ABORT: no build permission")
			return
		end
	end
	
	local currentLayers = hitBlock:GetAttribute("SnowLayers") or 1
	if currentLayers >= 8 then
		print("[SnowLayer] ABORT: already at 8 layers")
		return
	end
	
	local newLayers = currentLayers + 1
	local layerHeight = BLOCK_SIZE / 8 -- 0.375 per layer
	local newHeight = layerHeight * newLayers
	
	-- Get grid position from stored attributes
	local gridX = hitBlock:GetAttribute("BlockPosX")
	local gridY = hitBlock:GetAttribute("BlockPosY")
	local gridZ = hitBlock:GetAttribute("BlockPosZ")
	if not (gridX and gridY and gridZ) then
		print(string.format("[SnowLayer] ABORT: missing BlockPos attributes (X=%s Y=%s Z=%s)", tostring(gridX), tostring(gridY), tostring(gridZ)))
		return
	end
	
	-- Resize and reposition (bottom-aligned in grid cell, grows upward)
	hitBlock.Size = Vector3.new(BLOCK_SIZE, newHeight, BLOCK_SIZE)
	-- Keep pivot at the bottom of the part so it grows upward
	hitBlock.PivotOffset = CFrame.new(0, -newHeight / 2, 0)
	-- Position center so bottom edge stays at grid cell bottom
	local bottomOfCell = gridY - BLOCK_SIZE / 2
	local centerY = bottomOfCell + newHeight / 2
	hitBlock.CFrame = CFrame.new(gridX, centerY, gridZ)
	hitBlock:SetAttribute("SnowLayers", newLayers)
	
	-- At 4+ layers enable collision (thick enough to stand on)
	if newLayers >= 4 then
		hitBlock.CanCollide = true
	end
	
	-- Update or remove hitbox
	local hitbox = hitBlock:FindFirstChild("Hitbox")
	if hitbox then
		if newLayers == 8 then
			-- Full block, no longer needed
			hitbox:Destroy()
		else
			-- Resize hitbox to match new snow height
			hitbox.Size = Vector3.new(BLOCK_SIZE, newHeight, BLOCK_SIZE)
			local bottomOfCell = gridY - BLOCK_SIZE / 2
			hitbox.CFrame = CFrame.new(gridX, bottomOfCell + newHeight / 2, gridZ)
		end
	end
	
	print(string.format("[SnowLayer] Stacked to %d/%d layers, height=%.3f, centerY=%.3f at (%.1f,%.1f,%.1f) by %s", 
		newLayers, 8, newHeight, centerY, gridX, gridY, gridZ, player.Name))
end)

-- ========================================
-- FRAME BLOCK FILLING
-- ========================================

-- Maps frame block types to their solid template names in BlockTemplates
local FrameToTemplateMap = {
	["FrameBlock"] = "Block",
	["FrameSlab"] = "Slab",
	["FrameStairs"] = "Stair",
	["FrameStairsCornerInner"] = "StairInnerCorner",
	["FrameStairsCornerOuter"] = "StairOuterCorner",
	["FrameDoor"] = "FramedDoorFilled", -- Uses filled door template from BlockTemplates
	["FrameFence"] = "FENCE", -- Special: depends on FenceConnectionType attribute
	["WallpaperFrame"] = "WallpaperTemplate", -- Fills with solid flat panel from BlockTemplates
	["SignStandingFrame"] = "SignStanding", -- Fills with standing sign from BlockTemplates
	["SignFrame"] = "Sign", -- Fills with wall sign from BlockTemplates
	["CarpetFrame"] = "Block", -- Fills with solid block, resized to carpet height
	-- Arch frame blocks
	["ArchFrame"] = "Arch",
	["ArchInnerFrame"] = "ArchInner",
	["ArchOuterFrame"] = "ArchOuter",
	["ArchLargeFrame"] = "ArchLarge",
	["ArchLargeInnerFrame"] = "ArchLargeInner",
	["ArchLargeOuterFrame"] = "ArchLargeOuter",
}

-- Map fence connection types to their standard (non-frame) template names
local FenceConnectionToTemplate = {
	["post"] = "FencePost",
	["end"] = "FenceEnd",
	["middle"] = "FenceMiddle",
	["corner"] = "FenceCorner",
	["tee"] = "FenceMiddleCorner",
	["cross"] = "FenceMiddleFour",
}

FillFrameBlock.OnServerEvent:Connect(function(player, targetBlock, fillBlockId)
	print(string.format("[FrameFill] Received from %s: fill with %s", player.Name, tostring(fillBlockId)))
	
	-- Validate target block exists and is a frame block
	if not targetBlock or not targetBlock.Parent then
		print("[FrameFill] ABORT: target nil or no parent")
		return
	end
	local isFrame = (targetBlock:GetAttribute("IsFrameBlock")
		or BlockPresets.IsFrameBlock(targetBlock:GetAttribute("BlockType") or ""))
		and not targetBlock:GetAttribute("FrameFillBlockId")
	if not isFrame then
		print("[FrameFill] ABORT: target is not a frame block (BlockType=" .. tostring(targetBlock:GetAttribute("BlockType")) .. ")")
		return
	end
	
	-- Validate fill block preset exists and is a regular block
	if not fillBlockId or type(fillBlockId) ~= "string" then return end
	local fillPreset = BlockPresets.GetPreset(fillBlockId)
	if not fillPreset then
		print("[FrameFill] ABORT: fill preset not found for " .. tostring(fillBlockId))
		return
	end
	if fillPreset.Shape ~= "Block" then
		print("[FrameFill] ABORT: fill block must be Shape=Block, got " .. tostring(fillPreset.Shape))
		return
	end
	if fillBlockId == "SnowLayer" then
		print("[FrameFill] ABORT: SnowLayer cannot be used as fill")
		return
	end
	if fillPreset.IsGlass or fillBlockId == "GlassBlock" or string.find(fillBlockId, "GlassBlock") then
		print("[FrameFill] ABORT: Glass blocks cannot be used as fill")
		return
	end
	if fillBlockId == "Furnace" or fillPreset.IsCraftingTable or fillPreset.IsChest then
		print("[FrameFill] ABORT: Model blocks (Furnace/Chest/CraftingTable) cannot be used as fill")
		return
	end
	-- Defense in depth: surface-mounted types (vines, ladders, decorations) must not
	-- fill frame blocks. They get placed ON the frame's face by the normal placement
	-- pipeline; the client should already exclude them from TryFillFrameBlock.
	if fillPreset.IsVine or fillPreset.IsLadder or fillPreset.IsDecoration then
		print("[FrameFill] ABORT: " .. tostring(fillBlockId) .. " cannot fill frame blocks (mounts on faces instead)")
		return
	end
	
	-- Verify player has build permission at target location
	local targetPos = targetBlock:IsA("Model") and targetBlock:GetPivot().Position or targetBlock.Position
	local canBuild, buildArea = canPlayerBuildAtPosition(player, targetPos)
	if not canBuild or not buildArea then
		print("[FrameFill] ABORT: no build permission")
		return
	end
	
	-- Get the frame's block type to determine which solid template to use
	local frameType = targetBlock:GetAttribute("BlockType")
	if not frameType then
		print("[FrameFill] ABORT: target has no BlockType")
		return
	end
	
	local solidTemplateName = FrameToTemplateMap[frameType]
	if not solidTemplateName then
		print("[FrameFill] ABORT: no solid template mapping for " .. frameType)
		return
	end
	
	-- For frame fences, resolve template based on connection type
	local isFrameFence = (solidTemplateName == "FENCE")
	if isFrameFence then
		local connectionType = targetBlock:GetAttribute("FenceConnectionType") or "post"
		solidTemplateName = FenceConnectionToTemplate[connectionType] or "FencePost"
		print(string.format("[FrameFill] FrameFence connection=%s -> template=%s", connectionType, solidTemplateName))
	end
	
	-- For frame stairs, check if it's a corner piece and use the right solid template
	local cornerType = targetBlock:GetAttribute("CornerType")
	if frameType == "FrameStairs" and cornerType then
		if cornerType == "inner" then
			solidTemplateName = "StairInnerCorner"
		elseif cornerType == "outer" then
			solidTemplateName = "StairOuterCorner"
		end
	end
	
	-- For frame arches, check if it's a corner piece and use the right solid template
	if (frameType == "ArchFrame" or frameType == "ArchLargeFrame") and cornerType then
		local archTemplates = StairPlacement.GetArchTemplateNames(frameType)
		if cornerType == "inner" then
			solidTemplateName = archTemplates.Inner
		elseif cornerType == "outer" then
			solidTemplateName = archTemplates.Outer
		end
	end
	
	-- Find the solid template in BlockTemplates
	local solidTemplate = BlockTemplates and BlockTemplates:FindFirstChild(solidTemplateName)
	if not solidTemplate then
		print("[FrameFill] ABORT: solid template not found: " .. solidTemplateName)
		return
	end
	
	-- Clone the solid template
	local newBlock = solidTemplate:Clone()
	newBlock.Name = frameType -- Keep the frame block type name
	
	-- Anchor all parts
	if newBlock:IsA("BasePart") then
		newBlock.Anchored = true
	elseif newBlock:IsA("Model") then
		for _, part in ipairs(newBlock:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
	end
	
	-- Apply the fill block's color, material, and materialVariant
	local fillColor = fillPreset.DefaultColor or Color3.fromRGB(128, 128, 128)
	local fillMaterial = fillPreset.Material or Enum.Material.Plastic
	local fillMaterialVariant = fillPreset.MaterialVariant or ""
	
	-- Check if filling with Leaves - apply biome/season/random coloring
	local isLeavesFill = (fillBlockId == "Leaves")
	if isLeavesFill then
		local currentBiome = buildArea:GetAttribute("CurrentBiome")
		local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
		local leafColor
		
		if currentBiome then
			leafColor = BiomeConfig.GetRandomizedTintedLeafColor("Oak", currentBiome, currentSeason)
		else
			leafColor = BiomeConfig.GetRandomizedTintedLeafColor("Oak", "Plains", currentSeason)
		end
		
		if leafColor then
			fillColor = leafColor
		end
	end
	
	-- Check if filling with GrassBlock - apply biome/season/random coloring to grass part
	local isGrassBlockFill = (fillBlockId == "GrassBlock" or fillBlockId == "SnowyGrassBlock" or fillBlockId == "SnowGrassBlock" or fillBlockId == "TaigaGrassBlock")
	
	-- GrassBlock fill: use grass texture for the whole block with biome tint
	if isGrassBlockFill then
		fillMaterial = Enum.Material.Grass
		fillMaterialVariant = "PixelGrass"
		local currentBiome = buildArea:GetAttribute("CurrentBiome")
		local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
		local grassColor
		if currentBiome then
			local biomeColors = BiomeConfig.GetBiomeColors(currentBiome)
			if biomeColors and biomeColors.GrassColor then
				grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, currentSeason)
			end
		end
		if not grassColor then
			local plainsColors = BiomeConfig.GetBiomeColors("Plains")
			if plainsColors and plainsColors.GrassColor then
				grassColor = BiomeConfig.GetRandomizedGrassColor(plainsColors.GrassColor, currentSeason)
			end
		end
		if grassColor then
			fillColor = grassColor
		end
	end
	
	-- Log fill: use the bark (Union) color/material instead of the end-grain (Block)
	local isLogFill = string.find(fillBlockId, "Log") ~= nil
	if isLogFill then
		local blocksFolder = ReplicatedStorage:FindFirstChild("Blocks")
		if blocksFolder then
			local logModel = blocksFolder:FindFirstChild(fillBlockId)
			if logModel then
				local unionPart = logModel:FindFirstChild("Union")
				if unionPart and unionPart:IsA("BasePart") then
					fillColor = unionPart.Color
					fillMaterial = unionPart.Material
					fillMaterialVariant = unionPart.MaterialVariant or ""
				end
			end
		end
	end
	
	if newBlock:IsA("BasePart") then
		newBlock.Color = fillColor
		newBlock.Material = fillMaterial
		newBlock.MaterialVariant = fillMaterialVariant ~= "" and fillMaterialVariant or ""
	elseif newBlock:IsA("Model") then
		local isDoorFrame = (frameType == "FrameDoor")
		for _, part in ipairs(newBlock:GetDescendants()) do
			if part:IsA("BasePart") then
				-- Skip door hardware (hinges/knobs keep their metallic template look)
				if isDoorFrame and (part.Name == "Hinge" or part.Name == "Knob") then
					continue
				end
				part.Color = fillColor
				part.Material = fillMaterial
				part.MaterialVariant = fillMaterialVariant ~= "" and fillMaterialVariant or ""
			end
		end
	end
	
	-- For grass block fills, apply biome color to the "Grass" child part
	if isGrassBlockFill and newBlock:IsA("Model") then
		local grassPart = newBlock:FindFirstChild("Grass")
		if grassPart and grassPart:IsA("BasePart") then
			local currentBiome = buildArea:GetAttribute("CurrentBiome")
			local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
			local grassColor
			
			if currentBiome then
				local biomeColors = BiomeConfig.GetBiomeColors(currentBiome)
				if biomeColors and biomeColors.GrassColor then
					grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, currentSeason)
				else
					local plainsColors = BiomeConfig.GetBiomeColors("Plains")
					if plainsColors and plainsColors.GrassColor then
						grassColor = BiomeConfig.GetRandomizedGrassColor(plainsColors.GrassColor, currentSeason)
					end
				end
			else
				local defaultBiomeColors = BiomeConfig.GetBiomeColors("Plains")
				if defaultBiomeColors and defaultBiomeColors.GrassColor then
					grassColor = BiomeConfig.GetRandomizedGrassColor(defaultBiomeColors.GrassColor, currentSeason)
				end
			end
			
			if grassColor then
				grassPart.Color = grassColor
			end
		end
	end
	
	-- Store biome/season on leaf-filled or grass-filled frame blocks for save/load
	if isLeavesFill or isGrassBlockFill then
		local currentBiome = buildArea:GetAttribute("CurrentBiome")
		local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
		if currentBiome then
			newBlock:SetAttribute("Biome", currentBiome)
		end
		newBlock:SetAttribute("Season", currentSeason)
	end
	
	-- Position the new solid block
	local isArchFill = StairPlacement.IsArchType(frameType)
	local isStairFill = string.find(frameType, "Stair") ~= nil or isArchFill
	local isDoorFill = (frameType == "FrameDoor")
	
	if isFrameFence then
		-- For fences, use FencePlacement CFrame
		local storedRotation = targetBlock:GetAttribute("Rotation") or 0
		-- Frame fence models have rotation offsets vs solid templates, reverse them
		local connectionType = targetBlock:GetAttribute("FenceConnectionType") or "post"
		if connectionType == "corner" then
			storedRotation = (storedRotation + 90) % 360
		end
		local gridPos
		local bpx = targetBlock:GetAttribute("BlockPosX")
		local bpy = targetBlock:GetAttribute("BlockPosY")
		local bpz = targetBlock:GetAttribute("BlockPosZ")
		if bpx and bpy and bpz then
			gridPos = Vector3.new(bpx, bpy, bpz)
		elseif targetBlock:IsA("Model") then
			gridPos = targetBlock:GetPivot().Position
		else
			gridPos = targetBlock.Position
		end
		local newCFrame = FencePlacement.GetFenceCFrame(gridPos, storedRotation) -- solid replacement, no frame offset
		if newBlock:IsA("Model") then
			newBlock:PivotTo(newCFrame)
		else
			newBlock.CFrame = newCFrame
		end
	elseif isStairFill then
		-- For stairs, reconstruct CFrame from stored attributes since frame and solid
		-- templates have different base orientations
		local storedRotation = targetBlock:GetAttribute("Rotation") or 0
		local isUpsideDown = targetBlock:GetAttribute("IsUpsideDown")
		
		-- Reverse the frame outer corner rotation offset since the solid template doesn't need it
		if cornerType == "outer" and not isArchFill then
			if isUpsideDown then
				storedRotation = (storedRotation - 90) % 360
			else
				storedRotation = (storedRotation + 90) % 360
			end
		end
		-- Arch outer corner fills need a rotation offset
		if cornerType == "outer" and isArchFill then
			if isUpsideDown then
				storedRotation = (storedRotation - 90) % 360
			else
				storedRotation = (storedRotation + 90) % 360
			end
		end
		-- Arch INNER corner fills: reverse the placement-time offset that was baked into
		-- the stored rotation to make the frame template look correct. The solid inner
		-- template doesn't have that authoring offset, so we undo it here.
		-- (Upright inner placement added +90; upside-down inner placement added +270.)
		if cornerType == "inner" and isArchFill then
			if isUpsideDown then
				storedRotation = (storedRotation - 270) % 360
			else
				storedRotation = (storedRotation - 90) % 360
			end
		end
		local gridPos
		local bpx = targetBlock:GetAttribute("BlockPosX")
		local bpy = targetBlock:GetAttribute("BlockPosY")
		local bpz = targetBlock:GetAttribute("BlockPosZ")
		if bpx and bpy and bpz then
			gridPos = Vector3.new(bpx, bpy, bpz)
		elseif targetBlock:IsA("Model") then
			gridPos = targetBlock:GetPivot().Position
		else
			gridPos = targetBlock.Position
		end
		-- All unions now have consistent bottom-center pivots, so just use GetStairCFrame
		local originalStoredRotation = targetBlock:GetAttribute("Rotation") or 0
		local newCFrame = StairPlacement.GetStairCFrame(gridPos, storedRotation, isUpsideDown)
		-- Solid arch fills orientation fixes
		local archFinalAdjustment = "none"
		if isArchFill then
			if cornerType == "outer" then
				if isUpsideDown then
					newCFrame = newCFrame
						* CFrame.Angles(math.rad(-90), math.rad(-90), 0)
						* CFrame.Angles(0, 0, math.rad(180))
					archFinalAdjustment = "X(-90)*Y(-90)*Z(180)"
				else
					newCFrame = newCFrame * CFrame.Angles(math.rad(90), math.rad(-90), 0)
					archFinalAdjustment = "X(90)*Y(-90)"
				end
			elseif cornerType == "inner" then
				-- Inner solid template is authored on its side (like outer), needs tipping up.
				-- X tilt is opposite sign from outer (inner curve faces the other way).
				if isUpsideDown then
					-- Computed delta from observed (0, 0, -90) to desired (0, 180, 90) orientation = local Y(180).
					newCFrame = newCFrame
						* CFrame.Angles(math.rad(90), math.rad(-90), 0)
						* CFrame.Angles(math.rad(180), math.rad(180), 0)
						* CFrame.Angles(0, math.rad(180), 0)
					archFinalAdjustment = "X(90)*Y(-90)*X(180)*Y(180)*Y(180)"
				else
					newCFrame = newCFrame
						* CFrame.Angles(math.rad(-90), math.rad(-90), 0)
						* CFrame.Angles(math.rad(180), math.rad(180), 0)
						* CFrame.Angles(math.rad(90), 0, 0)
						* CFrame.Angles(math.rad(90), 0, 0)
					archFinalAdjustment = "X(-90)*Y(-90)*X(180)*Y(180)*X(90)*X(90)"
				end
			elseif not cornerType or cornerType == "normal" then
				newCFrame = newCFrame * CFrame.Angles(0, math.rad(180), 0)
				archFinalAdjustment = "Y(180)"
			end
		end
		if newBlock:IsA("Model") then
			newBlock:PivotTo(newCFrame)
		else
			newBlock.CFrame = newCFrame
		end
		-- [ARCH-FILL] Log inputs and final world orientation after CFrame applied.
		-- Lets us see, per case (upright/inverted x inner/outer/normal), exactly what
		-- rotation went in and what facing came out, so we can spot the broken case.
		if isArchFill and DEBUG_ARCH_FILL then
			local finalPivot = newBlock:GetPivot()
			local worldLook = finalPivot.LookVector
			local worldUp = finalPivot.UpVector
			print(string.format(
				"[ARCH-FILL] type=%s gridPos=%s cornerType=%s upsideDown=%s | storedRot: %d -> %d (compensated) | finalAdjust=%s",
				frameType, gridFmt(gridPos), tostring(cornerType), tostring(isUpsideDown),
				originalStoredRotation, storedRotation, archFinalAdjustment))
			print(string.format(
				"[ARCH-FILL] FINAL world: look=(%.2f,%.2f,%.2f) up=(%.2f,%.2f,%.2f) | facing %s | up %s",
				worldLook.X, worldLook.Y, worldLook.Z,
				worldUp.X, worldUp.Y, worldUp.Z,
				vectorToCompass(worldLook),
				worldUp.Y > 0.5 and "UP (normal)" or (worldUp.Y < -0.5 and "DOWN (upside-down)" or vectorToCompass(worldUp))
			))
		end
	elseif isDoorFill then
		-- For doors, reconstruct CFrame from stored door attributes
		-- The FrameDoor was positioned with special pivot/rotation compensation,
		-- but FramedDoorFilled uses standard door pivot (PivotOffset at bottom-center)
		local gridPos
		local gpx = targetBlock:GetAttribute("GridPosX")
		local gpy = targetBlock:GetAttribute("GridPosY")
		local gpz = targetBlock:GetAttribute("GridPosZ")
		if gpx and gpy and gpz then
			gridPos = Vector3.new(gpx, gpy, gpz)
		else
			-- Fallback: try BlockPos attributes
			local bpx = targetBlock:GetAttribute("BlockPosX")
			local bpy = targetBlock:GetAttribute("BlockPosY")
			local bpz = targetBlock:GetAttribute("BlockPosZ")
			if bpx and bpy and bpz then
				gridPos = Vector3.new(bpx, bpy, bpz)
			else
				-- Last resort: estimate from pivot
				gridPos = targetBlock:IsA("Model") and targetBlock:GetPivot().Position or targetBlock.Position
			end
		end
		
		local doorDirection = targetBlock:GetAttribute("DoorDirection") or 0
		local doorDepth = targetBlock:GetAttribute("DoorDepth") or "middle"
		local doorHingeSide = targetBlock:GetAttribute("DoorHingeSide") or "left"
		
		-- Rebuild the door CFrame using standard DoorPlacement (same as regular doors)
		local doorCFrame = DoorPlacement.GetDoorCFrame(gridPos, doorDirection, doorDepth, doorHingeSide)
		
		-- FramedDoorFilled has standard door pivot (PivotOffset at bottom-center),
		-- so use the same offset as regular door models
		if newBlock:IsA("Model") then
			local offsetCFrame = doorCFrame * CFrame.new(0, -BLOCK_SIZE / 2, 0)
			newBlock:PivotTo(offsetCFrame)
		else
			newBlock.CFrame = doorCFrame
		end
		
		print(string.format("[FrameFill] Door positioned at grid (%.1f,%.1f,%.1f) dir=%d depth=%s hinge=%s",
			gridPos.X, gridPos.Y, gridPos.Z, doorDirection, doorDepth, doorHingeSide))
	elseif frameType == "SignStandingFrame" or frameType == "SignFrame" then
		-- For sign frames, reconstruct CFrame from stored sign attributes
		-- (frame model has different pivot/orientation than the filled sign template)
		local gridPos
		local gpx = targetBlock:GetAttribute("GridPosX") or targetBlock:GetAttribute("BlockPosX")
		local gpy = targetBlock:GetAttribute("GridPosY") or targetBlock:GetAttribute("BlockPosY")
		local gpz = targetBlock:GetAttribute("GridPosZ") or targetBlock:GetAttribute("BlockPosZ")
		if gpx and gpy and gpz then
			gridPos = Vector3.new(gpx, gpy, gpz)
		else
			gridPos = targetBlock:IsA("Model") and targetBlock:GetPivot().Position or targetBlock.Position
		end
		
		if frameType == "SignStandingFrame" then
			local signRotation = targetBlock:GetAttribute("SignRotation") or 0
			local newCFrame = SignPlacement.GetStandingSignCFrame(gridPos, signRotation)
			if newBlock:IsA("Model") then
				newBlock:PivotTo(newCFrame)
			else
				newBlock.CFrame = newCFrame
			end
		else
			local signFace = targetBlock:GetAttribute("SignFace") or "North"
			local isOnFencePost = targetBlock:GetAttribute("IsOnFencePost") or false
			local newCFrame = SignPlacement.GetWallSignCFrame(gridPos, signFace, isOnFencePost)
			if newBlock:IsA("Model") then
				newBlock:PivotTo(newCFrame)
			else
				newBlock.CFrame = newCFrame
			end
		end
		print(string.format("[FrameFill] Sign frame filled at grid (%.1f,%.1f,%.1f) type=%s", gridPos.X, gridPos.Y, gridPos.Z, frameType))
	elseif frameType == "CarpetFrame" then
		-- For carpet frames, resize the solid block to carpet height and position at bottom of cell
		local gridPos
		local bpx = targetBlock:GetAttribute("BlockPosX")
		local bpy = targetBlock:GetAttribute("BlockPosY")
		local bpz = targetBlock:GetAttribute("BlockPosZ")
		if bpx and bpy and bpz then
			gridPos = Vector3.new(bpx, bpy, bpz)
		else
			gridPos = targetBlock:IsA("Model") and targetBlock:GetPivot().Position or targetBlock.Position
		end
		local carpetHeight = CarpetPlacement.CARPET_HEIGHT
		if newBlock:IsA("BasePart") then
			newBlock.Size = Vector3.new(BLOCK_SIZE, carpetHeight, BLOCK_SIZE)
		end
		local newCFrame = CarpetPlacement.GetCarpetCFrame(gridPos)
		if newBlock:IsA("Model") then
			newBlock:PivotTo(newCFrame)
		else
			newBlock.CFrame = newCFrame
		end
		print(string.format("[FrameFill] Carpet filled at grid (%.1f,%.1f,%.1f)", gridPos.X, gridPos.Y, gridPos.Z))
	else
		-- Non-stair frames: copy CFrame directly
		local oldCFrame
		if targetBlock:IsA("Model") then
			oldCFrame = targetBlock:GetPivot()
		else
			oldCFrame = targetBlock.CFrame
		end
		if newBlock:IsA("Model") then
			newBlock:PivotTo(oldCFrame)
		else
			newBlock.CFrame = oldCFrame
		end
	end
	
	-- Copy all attributes from old frame to new solid block
	for attrName, attrValue in pairs(targetBlock:GetAttributes()) do
		newBlock:SetAttribute(attrName, attrValue)
	end
	
	-- Remove frame identity so it behaves as a normal solid block now
	newBlock:SetAttribute("IsFrameBlock", nil)
	
	-- For filled frame fences: keep as a fence so it continues to auto-connect
	-- Use BlockType "FilledFence" so IsFence() = true but IsFrameFence() = false
	-- This ensures solid templates are used (not frame templates) during auto-connect updates
	if isFrameFence then
		-- IsFence = true was already copied from old fence's attributes
		newBlock:SetAttribute("IsFilledFence", true)
		newBlock:SetAttribute("BlockedDirections", nil)
		newBlock:SetAttribute("BlockType", "FilledFence")
		newBlock.Name = "FilledFence"
		-- Store grid position for spatial index accuracy
		local fenceGridPos = gridPos or targetBlock:GetPivot().Position
		newBlock:SetAttribute("BlockPosX", fenceGridPos.X)
		newBlock:SetAttribute("BlockPosY", fenceGridPos.Y)
		newBlock:SetAttribute("BlockPosZ", fenceGridPos.Z)
	end
	
	-- For filled stair outer corners, fix the stored Rotation to match solid template
	if isStairFill and not isArchFill and cornerType == "outer" then
		local isUpsideDown = targetBlock:GetAttribute("IsUpsideDown")
		local oldRot = newBlock:GetAttribute("Rotation") or 0
		if isUpsideDown then
			newBlock:SetAttribute("Rotation", (oldRot - 90) % 360)
		else
			newBlock:SetAttribute("Rotation", (oldRot + 90) % 360)
		end
		-- Mark as filled outer corner so save/load applies the extra X/Z rotation
		newBlock:SetAttribute("FilledOuterCorner", true)
	end
	
	-- For filled frame doors: keep door identity so open/close still works
	if isDoorFill then
		newBlock:SetAttribute("IsDoor", true)
		-- Ensure the hitbox exists for raycasting
		local doorGridPos
		local gpx = newBlock:GetAttribute("GridPosX")
		local gpy = newBlock:GetAttribute("GridPosY")
		local gpz = newBlock:GetAttribute("GridPosZ")
		if gpx and gpy and gpz then
			doorGridPos = Vector3.new(gpx, gpy, gpz)
		else
			doorGridPos = newBlock:IsA("Model") and newBlock:GetPivot().Position or newBlock.Position
		end
		addBlockHitbox(newBlock, doorGridPos)
		-- Thin hitbox matching door panel orientation
		local hitbox = newBlock:FindFirstChild("Hitbox")
		if hitbox then
			local DOOR_HITBOX_THICKNESS = 1.0
			local doorDir = newBlock:GetAttribute("DoorDirection") or 0
			if doorDir == 0 or doorDir == 2 then
				hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, DOOR_HITBOX_THICKNESS)
			else
				hitbox.Size = Vector3.new(DOOR_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
			end
			-- Position at door's actual visual location (includes depth offset)
			local doorVisualPos = newBlock:IsA("Model") and newBlock:GetPivot().Position or newBlock.Position
			hitbox.CFrame = CFrame.new(doorVisualPos)
		end
	end
	
	-- For filled sign frames: set sign attributes so sign editor can interact with them
	local isSignStandingFill = (frameType == "SignStandingFrame")
	local isSignFrameFill = (frameType == "SignFrame")
	if isSignStandingFill then
		newBlock:SetAttribute("IsSignStanding", true)
		newBlock:SetAttribute("SignType", "standing")
		-- Add hitbox for sign interaction raycasts
		local signGridPos
		local gpx = newBlock:GetAttribute("GridPosX") or newBlock:GetAttribute("BlockPosX")
		local gpy = newBlock:GetAttribute("GridPosY") or newBlock:GetAttribute("BlockPosY")
		local gpz = newBlock:GetAttribute("GridPosZ") or newBlock:GetAttribute("BlockPosZ")
		if gpx and gpy and gpz then
			signGridPos = Vector3.new(gpx, gpy, gpz)
		else
			signGridPos = newBlock:IsA("Model") and newBlock:GetPivot().Position or newBlock.Position
		end
		addBlockHitbox(newBlock, signGridPos)
		-- Thin hitbox for standing sign
		local hitbox = newBlock:FindFirstChild("Hitbox")
		if hitbox then
			local rot = (newBlock:GetAttribute("SignRotation") or 0) % 360
			if (rot >= 45 and rot < 135) or (rot >= 225 and rot < 315) then
				hitbox.Size = Vector3.new(1.0, BLOCK_SIZE, BLOCK_SIZE)
			else
				hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, 1.0)
			end
		end
	end
	if isSignFrameFill then
		newBlock:SetAttribute("IsWallSign", true)
		newBlock:SetAttribute("SignType", "wall")
		local signGridPos
		local gpx = newBlock:GetAttribute("GridPosX") or newBlock:GetAttribute("BlockPosX")
		local gpy = newBlock:GetAttribute("GridPosY") or newBlock:GetAttribute("BlockPosY")
		local gpz = newBlock:GetAttribute("GridPosZ") or newBlock:GetAttribute("BlockPosZ")
		if gpx and gpy and gpz then
			signGridPos = Vector3.new(gpx, gpy, gpz)
		else
			signGridPos = newBlock:IsA("Model") and newBlock:GetPivot().Position or newBlock.Position
		end
		addBlockHitbox(newBlock, signGridPos)
		-- Thin hitbox for wall sign (skip for fence post signs - they overlap the fence hitbox)
		if not newBlock:GetAttribute("IsOnFencePost") then
			local hitbox = newBlock:FindFirstChild("Hitbox")
			if hitbox then
				local sFace = newBlock:GetAttribute("SignFace") or "North"
				if sFace == "North" or sFace == "South" then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, 0.5)
				elseif sFace == "East" or sFace == "West" then
					hitbox.Size = Vector3.new(0.5, BLOCK_SIZE, BLOCK_SIZE)
				end
				local signVisualPos = newBlock:IsA("Model") and newBlock:GetPivot().Position or newBlock.Position
				hitbox.CFrame = CFrame.new(signVisualPos)
			end
		end
	end
	
	-- Add fill-specific attributes
	newBlock:SetAttribute("FrameFillBlockId", fillBlockId)
	newBlock:SetAttribute("FrameFillColorR", math.round(fillColor.R * 255))
	newBlock:SetAttribute("FrameFillColorG", math.round(fillColor.G * 255))
	newBlock:SetAttribute("FrameFillColorB", math.round(fillColor.B * 255))
	if fillMaterialVariant ~= "" then
		newBlock:SetAttribute("FrameFillMaterialVariant", fillMaterialVariant)
	else
		newBlock:SetAttribute("FrameFillMaterialVariant", nil)
	end
	
	-- Rainbow / ColorCycle fill: propagate ColorMode and phase so ColorCycleController animates the filled frame
	local fillCycleCfg = fillPreset.Behavior and fillPreset.Behavior.ColorCycle
	if fillCycleCfg or fillPreset.IsRainbow then
		newBlock:SetAttribute("ColorMode", "Rainbow")
		if (fillCycleCfg and fillCycleCfg.Light) or fillPreset.HasPointLight then
			newBlock:SetAttribute("HasPointLight", true)
		end
		-- Inherit phase from the old frame block if present, else random within the block's own cycle
		local phase = targetBlock:GetAttribute("RainbowPhase")
		if not phase then
			local duration = (fillCycleCfg and fillCycleCfg.Duration) or 6
			phase = math.random() * duration
		end
		newBlock:SetAttribute("RainbowPhase", phase)
	end
	
	-- Parent new block to same folder, then destroy old frame
	local parentFolder = targetBlock.Parent
	newBlock.Parent = parentFolder
	targetBlock:Destroy()
	
	print(string.format("[FrameFill] Swapped %s -> solid %s filled with %s (color=%s, material=%s, variant=%s)",
		frameType, solidTemplateName, fillBlockId,
		tostring(fillColor), tostring(fillMaterial), tostring(fillMaterialVariant)))
	
	-- After filling a frame fence, update adjacent fences
	-- The filled fence changed from IsFence to a solid block, so neighbors need to recalculate
	if isFrameFence then
		local fillGridPos
		local bpx = newBlock:GetAttribute("BlockPosX")
		local bpy = newBlock:GetAttribute("BlockPosY")
		local bpz = newBlock:GetAttribute("BlockPosZ")
		if bpx and bpy and bpz then
			fillGridPos = Vector3.new(bpx, bpy, bpz)
		else
			fillGridPos = newBlock:GetPivot().Position
		end
		
		task.defer(function()
			local function createFenceBlockForFill(tName, fenceType, fencePos, fenceRotation, placedBy, connectionType, oldColor, oldMaterial, oldMaterialVariant)
				local isFrameFence = FencePlacement.IsFrameFence(fenceType)
				local newFence
				if isFrameFence then
					newFence = createBlockFromTemplate(tName, fenceType, false, tName, "FrameBlocks")
				else
					newFence = createBlockFromTemplate(tName, nil)
				end
				if newFence then
					newFence.Name = fenceType
					local fenceCFrame = FencePlacement.GetFenceCFrame(fencePos, fenceRotation, isFrameFence)
					setBlockCFrame(newFence, fenceCFrame, false, fenceType)
					
					local fencePreset = BlockPresets and BlockPresets.GetPreset(fenceType)
					local finalColor = oldColor or (fencePreset and fencePreset.DefaultColor)
					local finalMaterial = oldMaterial or (fencePreset and fencePreset.Material)
					local finalMaterialVariant = (oldMaterialVariant and oldMaterialVariant ~= "") and oldMaterialVariant or (fencePreset and fencePreset.MaterialVariant or "")
					
					if not isFrameFence and finalColor and finalMaterial and newFence:IsA("BasePart") then
						newFence.Color = finalColor
						newFence.Material = finalMaterial
						if finalMaterialVariant and finalMaterialVariant ~= "" then
							newFence.MaterialVariant = finalMaterialVariant
						end
					end
					
					newFence:SetAttribute("BlockType", fenceType)
					newFence:SetAttribute("PlacedBy", placedBy)
					newFence:SetAttribute("Rotation", fenceRotation)
					newFence:SetAttribute("IsFence", true)
					newFence:SetAttribute("FenceConnectionType", connectionType)
					-- Store grid position for spatial index (fence unions have offset geometric centers)
					newFence:SetAttribute("BlockPosX", fencePos.X)
					newFence:SetAttribute("BlockPosY", fencePos.Y)
					newFence:SetAttribute("BlockPosZ", fencePos.Z)
					if isFrameFence then
						newFence:SetAttribute("IsFrameBlock", true)
					end
					
					newFence.Parent = parentFolder
					addBlockHitbox(newFence, fencePos)
					return newFence
				end
				return nil
			end
			
			-- Update adjacent fences (fence was removed from fence graph)
			local updated1 = FencePlacement.UpdateAdjacentFences(fillGridPos, parentFolder, BlockTemplates, createFenceBlockForFill)
			-- Also update as solid block (new solid appeared)
			local updated2 = FencePlacement.UpdateFencesNearSolidBlock(fillGridPos, parentFolder, BlockTemplates, createFenceBlockForFill)
			local totalUpdated = #updated1 + #updated2
			if totalUpdated > 0 then
				print(string.format("[FrameFill] Updated %d adjacent fences after fill", totalUpdated))
			end
		end)
	end
end)

-- print("BlockHandler initialized (Lazy terrain + Decorations)")
