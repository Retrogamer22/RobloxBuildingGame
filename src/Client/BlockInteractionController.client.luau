--[[
	BlockInteractionController
	Detects player interaction (right-click / tap) with special blocks
	and routes to the correct UI:
	  - Chests → ChestUI (+ lid animation via ChestController)
	  - Crafting Tables → CraftingTableUI
	  - Furnaces → FurnaceUI
	
	Replaces direct ChestController.TryInteract() calls in BuildingController.
	Exposed via _G.BlockInteractionController for BuildingController priority chain.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local BlockPresetsModule = ReplicatedStorage:WaitForChild("BlockPresets", 10)
local BlockPresets = BlockPresetsModule and require(BlockPresetsModule)

local REACH_DISTANCE = 15

-- ============================================
-- BLOCK DETECTION
-- ============================================

-- Walk up the hierarchy to find the block model with a BlockType attribute
local function findBlockModel(instance)
	if not instance then return nil end

	local current = instance
	for _ = 1, 5 do
		if current:GetAttribute("BlockType") then
			return current
		end
		current = current.Parent
		if not current or current == workspace then
			return nil
		end
	end
	return nil
end

-- Compute the interaction ray origin + unit direction. In first person, this
-- is the screen-center ray (from camera, full vertical aim). In third person,
-- the camera is angled down at the player so a screen-center ray would point
-- at the ground in front of the player; we use the head's horizontal forward
-- direction instead, so doors/chests/furnaces directly in front are hit.
local function getInteractionRay()
	local isFirstPerson = _G.CameraController and _G.CameraController.IsFirstPerson and _G.CameraController.IsFirstPerson()
	local character = LocalPlayer.Character
	local head = character and character:FindFirstChild("Head")
	
	if isFirstPerson or not head then
		local viewportSize = Camera.ViewportSize
		local ray = Camera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
		return ray.Origin, ray.Direction
	end
	
	-- Third person: head position + horizontal camera direction.
	local look = Camera.CFrame.LookVector
	local horizontalLook = Vector3.new(look.X, 0, look.Z)
	if horizontalLook.Magnitude < 0.01 then
		horizontalLook = Vector3.new(0, 0, -1)
	else
		horizontalLook = horizontalLook.Unit
	end
	return head.Position, horizontalLook
end

-- Raycast from screen center to find an interactable block
local function raycastForInteractable()
	local origin, direction = getInteractionRay()

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { LocalPlayer.Character }

	local result = workspace:Raycast(origin, direction * REACH_DISTANCE, raycastParams)
	if not result or not result.Instance then return nil, nil end

	local block = findBlockModel(result.Instance)
	if not block then return nil, nil end

	local blockType = block:GetAttribute("BlockType")
	if not blockType or not BlockPresets then return nil, nil end

	-- Determine what kind of interactable this is
	if BlockPresets.IsChest(blockType) then
		return block, "chest"
	elseif BlockPresets.IsCraftingTable(blockType) then
		return block, "crafting_table"
	elseif BlockPresets.IsFurnace(blockType) then
		return block, "furnace"
	elseif BlockPresets.IsBed and BlockPresets.IsBed(blockType) then
		return block, "bed"
	end

	return nil, nil
end

-- ============================================
-- CLOSE ANY OPEN BLOCK UI
-- ============================================

local function closeAllBlockUIs()
	local wasClosed = false
	if _G.ChestUI and _G.ChestUI.IsOpen() then
		_G.ChestUI.Close()
		wasClosed = true
	end
	if _G.CraftingTableUI and _G.CraftingTableUI.IsOpen() then
		_G.CraftingTableUI.Close()
		wasClosed = true
	end
	if _G.FurnaceUI and _G.FurnaceUI.IsOpen() then
		_G.FurnaceUI.Close()
		wasClosed = true
	end
	if wasClosed then
		lastBlockUICloseTime = tick()
	end
end

-- ============================================
-- CHEST LID MANAGEMENT
-- ============================================

-- Set up the chest close callback: when ChestUI closes, close the lid
task.defer(function()
	-- Wait for ChestUI to initialize
	local attempts = 0
	while not _G.ChestUI and attempts < 50 do
		task.wait(0.1)
		attempts += 1
	end

	if _G.ChestUI and _G.ChestUI.SetOnClose then
		_G.ChestUI.SetOnClose(function(chestBlock)
			-- Close the lid if the chest is currently open
			if chestBlock and chestBlock.Parent and chestBlock:GetAttribute("IsOpen") then
				if _G.ChestController and _G.ChestController.TryInteract then
					-- ChestController raycasts on its own, so we just call TryInteract
					-- which will toggle the chest closed if the player is still looking at it
					_G.ChestController.TryInteract()
				end
			end
		end)
	end
end)

-- ============================================
-- PUBLIC API
-- ============================================

local BlockInteractionController = {}

-- Track when a block UI was last closed to prevent race conditions
-- (E key closes block UI and opens inventory in the same frame)
local lastBlockUICloseTime = 0
local CLOSE_GUARD_TIME = 0.15 -- seconds to block other inputs after closing

-- Returns true if any block UI is currently open OR was JUST closed
-- The close guard prevents InventoryController from opening on the same frame
function BlockInteractionController.IsAnyBlockUIOpen()
	local chestOpen = _G.ChestUI and _G.ChestUI.IsOpen() or false
	local craftingOpen = _G.CraftingTableUI and _G.CraftingTableUI.IsOpen() or false
	local furnaceOpen = _G.FurnaceUI and _G.FurnaceUI.IsOpen() or false
	local justClosed = (tick() - lastBlockUICloseTime) < CLOSE_GUARD_TIME
	return chestOpen or craftingOpen or furnaceOpen or justClosed
end

-- Called by individual block UIs when they close (via E key, overlay click, etc.)
-- Prevents InventoryController from opening on the same frame
function BlockInteractionController.NotifyClosed()
	lastBlockUICloseTime = tick()
end

-- Try to interact with a block the player is looking at.
-- Returns true if an interaction was handled (blocks further processing).
function BlockInteractionController.TryInteract()
	-- Priority 0: if already laying down on a bed, stand up. This runs BEFORE
	-- raycasting because the bed is no longer under the cursor while the player
	-- is laying on it.
	if _G.BedController and _G.BedController.IsLayingDown() then
		_G.BedController.StandUp()
		return true
	end
	
	-- If any block UI is already open, close it and consume the input
	if BlockInteractionController.IsAnyBlockUIOpen() then
		closeAllBlockUIs()
		return true
	end

	local block, interactionType = raycastForInteractable()
	if not block then return false end

	if interactionType == "chest" then
		-- Open the chest lid if it's currently closed
		if not block:GetAttribute("IsOpen") then
			if _G.ChestController and _G.ChestController.TryInteract then
				_G.ChestController.TryInteract()
			end
		end
		-- Open the chest UI
		if _G.ChestUI then
			_G.ChestUI.Open(block)
		end
		return true

	elseif interactionType == "crafting_table" then
		if _G.CraftingTableUI then
			_G.CraftingTableUI.Open(block)
		end
		return true

	elseif interactionType == "furnace" then
		if _G.FurnaceUI then
			_G.FurnaceUI.Open(block)
		end
		return true

	elseif interactionType == "bed" then
		if _G.BedController then
			_G.BedController.LayDown(block)
		end
		return true
	end

	return false
end

-- ============================================
-- EXPOSE GLOBALLY
-- ============================================
_G.BlockInteractionController = BlockInteractionController

print("[BlockInteractionController] Initialized (chest, crafting table, furnace, bed interaction)")

return BlockInteractionController
