--[[
	CarpetPlacement
	Handles placement of CarpetFrame blocks (thin 0.38 stud carpet)
	- Can ONLY be placed on top of: blocks, stairs, or fences
	- Placing carpet on carpet moves up to the next grid level
	- Sits at the bottom of its grid cell, flush with the top of the block below
]]

local BLOCK_SIZE = 3
local CARPET_HEIGHT = 0.38

local CarpetPlacement = {}

-- ============================================
-- DETECTION
-- ============================================

function CarpetPlacement.IsCarpet(blockId)
	if not blockId or type(blockId) ~= "string" then return false end
	return blockId == "CarpetFrame"
end

function CarpetPlacement.IsCarpetInstance(block)
	if not block then return false end
	return block:GetAttribute("IsCarpet") == true
end

-- ============================================
-- VALIDATION
-- ============================================

-- Check if the block below is a valid support for carpet (block, stair, fence, or carpet)
function CarpetPlacement.IsValidSupport(block)
	if not block then return false end
	
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return false end
	
	-- Allow placing on another carpet (stacks to next grid level)
	if CarpetPlacement.IsCarpetInstance(block) then return true end
	
	-- Reject non-solid/decorative blocks
	if block:GetAttribute("IsDecoration") then return false end
	if block:GetAttribute("IsTorch") then return false end
	if block:GetAttribute("IsLantern") then return false end
	if block:GetAttribute("IsCampfire") then return false end
	if block:GetAttribute("IsLadder") then return false end
	if block:GetAttribute("IsGlass") then return false end
	if block:GetAttribute("IsWallpaperFrame") then return false end
	if block:GetAttribute("IsSignStanding") then return false end
	if block:GetAttribute("IsWallSign") then return false end
	
	-- Reject surface blocks (buttons, pressure plates)
	if string.find(blockType, "Button") or string.find(blockType, "PressurePlate") then return false end
	
	-- Reject snow layers, doors
	if blockType == "SnowLayer" then return false end
	if block:GetAttribute("IsDoor") then return false end
	
	-- Allow blocks, stairs, fences, slabs, and other solid types
	return true
end

-- ============================================
-- CFRAME CALCULATION
-- ============================================

-- Get CFrame for carpet positioned at bottom of grid cell
function CarpetPlacement.GetCarpetCFrame(gridPosition)
	local bottomOfCell = gridPosition.Y - BLOCK_SIZE / 2
	local centerY = bottomOfCell + CARPET_HEIGHT / 2
	return CFrame.new(gridPosition.X, centerY, gridPosition.Z)
end

-- ============================================
-- CONSTANTS
-- ============================================

CarpetPlacement.CARPET_HEIGHT = CARPET_HEIGHT

return CarpetPlacement
