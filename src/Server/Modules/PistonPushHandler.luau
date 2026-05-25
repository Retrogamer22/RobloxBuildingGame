--[[
	PistonPushHandler
	Handles block pushing logic for pistons
	
	Regular Piston:
	- Extends: pushes blocks in front (up to MAX_PUSH_BLOCKS)
	- Retracts: blocks stay where they are
	
	Sticky Piston:
	- Extends: pushes blocks in front (up to MAX_PUSH_BLOCKS)
	- Retracts: pulls blocks back with it (up to MAX_PUSH_BLOCKS)
	
	Pistons CAN be pushed/pulled by other pistons.
	When a sticky piston is moved, blocks attached to it move too.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))

local PistonPushHandler = {}

-- Configuration
local MAX_PUSH_BLOCKS = 6  -- Maximum blocks a piston can push/pull in a line
local BLOCK_SIZE = GridConfig.BLOCK_SIZE  -- 3 studs
local PUSH_TWEEN_TIME = 0.15  -- Match piston animation speed

-- Blacklist of block types that cannot be pushed (exact matches)
local PUSH_BLACKLIST = {
	-- Immovable blocks
	["Bedrock"] = true,
	["Obsidian"] = true,
}

-- Pattern blacklist (blocks containing these strings cannot be pushed)
-- NOTE: Pistons ARE pushable - they're not in this list!
local PUSH_BLACKLIST_PATTERNS = {
	"Button",        -- All button types (OakButton, StoneButton, etc.)
	"PressurePlate", -- All pressure plate types
	"Door",          -- Doors are complex multi-block structures
	"TrapDoor",      -- Trap doors
}

-- Check if a block type can be pushed/pulled
function PistonPushHandler.CanBePushed(blockType: string): boolean
	if not blockType then return false end
	
	-- Check exact match blacklist
	if PUSH_BLACKLIST[blockType] then
		return false
	end
	
	-- Check pattern blacklist
	for _, pattern in ipairs(PUSH_BLACKLIST_PATTERNS) do
		if string.find(blockType, pattern) then
			return false
		end
	end
	
	return true
end

-- Check if a block is a sticky piston
local function isStickyPiston(block: Instance): boolean
	local blockType = block:GetAttribute("BlockType") or ""
	return string.find(string.lower(blockType), "sticky") ~= nil and string.find(string.lower(blockType), "piston") ~= nil
end

-- Check if a block is any kind of piston
local function isPiston(block: Instance): boolean
	local blockType = block:GetAttribute("BlockType") or ""
	return string.find(string.lower(blockType), "piston") ~= nil
end

-- Add a block type to the exact match blacklist
function PistonPushHandler.AddToBlacklist(blockType: string)
	PUSH_BLACKLIST[blockType] = true
end

-- Remove a block type from the exact match blacklist
function PistonPushHandler.RemoveFromBlacklist(blockType: string)
	PUSH_BLACKLIST[blockType] = nil
end

-- Add a pattern to the pattern blacklist
function PistonPushHandler.AddBlacklistPattern(pattern: string)
	for _, existingPattern in ipairs(PUSH_BLACKLIST_PATTERNS) do
		if existingPattern == pattern then
			return
		end
	end
	table.insert(PUSH_BLACKLIST_PATTERNS, pattern)
end

-- Remove a pattern from the pattern blacklist
function PistonPushHandler.RemoveBlacklistPattern(pattern: string)
	for i, existingPattern in ipairs(PUSH_BLACKLIST_PATTERNS) do
		if existingPattern == pattern then
			table.remove(PUSH_BLACKLIST_PATTERNS, i)
			return
		end
	end
end

-- Get both blacklists (for debugging)
function PistonPushHandler.GetBlacklist(): {exact: {[string]: boolean}, patterns: {string}}
	return {
		exact = PUSH_BLACKLIST,
		patterns = PUSH_BLACKLIST_PATTERNS
	}
end

-- Get the position of a block (works for BasePart or Model)
-- Special handling for pistons which have different pivot structure
local function getBlockPosition(block: Instance): Vector3?
	if block:IsA("BasePart") then
		return block.Position
	elseif block:IsA("Model") then
		-- For piston models, use PistonBottom position as the block center
		local pistonBottom = block:FindFirstChild("PistonBottom")
		if pistonBottom then
			if pistonBottom:IsA("BasePart") then
				return pistonBottom.Position
			elseif pistonBottom:IsA("Model") then
				local part = pistonBottom:FindFirstChildWhichIsA("BasePart")
				if part then
					return part.Position
				end
			end
		end
		
		-- Fallback to pivot for other models
		local pivot = block:GetPivot()
		return pivot.Position
	end
	return nil
end

-- Get the facing direction of a piston (where it extends toward)
local function getPistonFacingDirection(pistonBlock: Instance): Vector3
	local pistonCFrame
	if pistonBlock:IsA("Model") then
		pistonCFrame = pistonBlock:GetPivot()
	else
		pistonCFrame = pistonBlock.CFrame
	end
	return pistonCFrame.UpVector
end

-- Set the position of a block with tweening
-- Special handling for piston models to move all parts correctly (including extended head)
local function tweenBlockToPosition(block: Instance, targetPosition: Vector3, tweenTime: number)
	local tweenInfo = TweenInfo.new(
		tweenTime,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	)
	
	if block:IsA("BasePart") then
		local tween = TweenService:Create(block, tweenInfo, {Position = targetPosition})
		tween:Play()
		return tween
	elseif block:IsA("Model") then
		-- Calculate offset from current position to target
		local currentPos = getBlockPosition(block)
		if not currentPos then return nil end
		local offset = targetPosition - currentPos
		
		-- For piston models, we need to move ALL parts including PistonTop (even if extended)
		local tweens = {}
		
		-- Move all BaseParts in the entire model hierarchy
		for _, part in ipairs(block:GetDescendants()) do
			if part:IsA("BasePart") then
				local targetPartCFrame = part.CFrame + offset
				local tween = TweenService:Create(part, tweenInfo, {CFrame = targetPartCFrame})
				tween:Play()
				table.insert(tweens, tween)
			end
		end
		
		return tweens[1]
	end
	return nil
end

-- Find a block at a specific grid position within a blocks folder
local function findBlockAtPosition(blocksFolder: Folder, position: Vector3, tolerance: number?): Instance?
	tolerance = tolerance or 2.5  -- Large tolerance for different pivot points
	
	local closestBlock = nil
	local closestDist = tolerance
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsDecoration") then
			continue
		end
		
		local blockPos = getBlockPosition(block)
		if blockPos then
			local distance = (blockPos - position).Magnitude
			if distance < closestDist then
				closestDist = distance
				closestBlock = block
			end
		end
	end
	
	return closestBlock
end

-- Get blocks attached to a sticky piston (blocks in front of its head)
-- Returns blocks in order from nearest to farthest
local function getAttachedBlocks(stickyPiston: Instance, blocksFolder: Folder, alreadyCollected: {[Instance]: boolean}): {Instance}
	local attached = {}
	
	local pistonPos = getBlockPosition(stickyPiston)
	if not pistonPos then return attached end
	
	-- Round to grid
	pistonPos = Vector3.new(
		math.round(pistonPos.X / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(pistonPos.Y / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(pistonPos.Z / BLOCK_SIZE) * BLOCK_SIZE
	)
	
	local facingDirection = getPistonFacingDirection(stickyPiston)
	
	-- Check blocks in front of the sticky piston
	local checkPos = pistonPos + (facingDirection * BLOCK_SIZE)
	
	for i = 1, MAX_PUSH_BLOCKS do
		local block = findBlockAtPosition(blocksFolder, checkPos)
		
		if block and not alreadyCollected[block] then
			local blockType = block:GetAttribute("BlockType")
			if not PistonPushHandler.CanBePushed(blockType) then
				-- Hit immovable block, stop here
				break
			end
			
			alreadyCollected[block] = true
			table.insert(attached, block)
			
			-- If this block is ALSO a sticky piston, get ITS attached blocks too
			if isStickyPiston(block) then
				local nestedAttached = getAttachedBlocks(block, blocksFolder, alreadyCollected)
				for _, nestedBlock in ipairs(nestedAttached) do
					table.insert(attached, nestedBlock)
				end
			end
		else
			-- No block or already collected, stop
			break
		end
		
		checkPos = checkPos + (facingDirection * BLOCK_SIZE)
	end
	
	return attached
end

-- Get all blocks in a line, including attached blocks from sticky pistons
-- Returns blocks in order from nearest to farthest
local function getBlocksInLineWithAttachments(blocksFolder: Folder, startPos: Vector3, direction: Vector3, maxBlocks: number): {Instance}
	local blocks = {}
	local collected = {} -- Track all collected blocks to avoid duplicates
	local checkPos = startPos
	
	for i = 1, maxBlocks do
		local block = findBlockAtPosition(blocksFolder, checkPos)
		
		if block and not collected[block] then
			local blockType = block:GetAttribute("BlockType")
			if not PistonPushHandler.CanBePushed(blockType) then
				return {} -- Hit immovable block, can't push anything
			end
			
			collected[block] = true
			table.insert(blocks, block)
			
			-- If this is a sticky piston, also collect its attached blocks
			if isStickyPiston(block) then
				local attachedBlocks = getAttachedBlocks(block, blocksFolder, collected)
				for _, attachedBlock in ipairs(attachedBlocks) do
					table.insert(blocks, attachedBlock)
				end
			end
		else
			break
		end
		
		checkPos = checkPos + (direction * BLOCK_SIZE)
	end
	
	return blocks
end

-- Check if the target position is clear (excluding specific blocks)
local function isTargetPositionClear(blocksFolder: Folder, position: Vector3, excludeBlocks: {Instance}?): boolean
	local tolerance = 2.5
	excludeBlocks = excludeBlocks or {}
	
	-- Create lookup table for excluded blocks
	local excluded = {}
	for _, block in ipairs(excludeBlocks) do
		excluded[block] = true
	end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsDecoration") then
			continue
		end
		
		-- Skip blocks we're pushing
		if excluded[block] then
			continue
		end
		
		local blockPos = getBlockPosition(block)
		if blockPos then
			local distance = (blockPos - position).Magnitude
			if distance < tolerance then
				return false
			end
		end
	end
	
	return true
end

-- Get piston body position and push direction
-- Uses PistonBottom position for consistent block detection
local function getPistonInfo(pistonBlock: Instance): (Vector3, Vector3)
	local pistonCFrame
	if pistonBlock:IsA("Model") then
		pistonCFrame = pistonBlock:GetPivot()
	else
		pistonCFrame = pistonBlock.CFrame
	end
	
	local pushDirection = pistonCFrame.UpVector
	
	-- Use PistonBottom position as the piston's block position (where it was placed)
	local bodyPos
	local pistonBottom = pistonBlock:FindFirstChild("PistonBottom")
	if pistonBottom then
		if pistonBottom:IsA("BasePart") then
			bodyPos = pistonBottom.Position
		elseif pistonBottom:IsA("Model") then
			local part = pistonBottom:FindFirstChildWhichIsA("BasePart")
			if part then
				bodyPos = part.Position
			end
		end
	end
	
	-- Fallback to pivot position
	if not bodyPos then
		bodyPos = pistonCFrame.Position
	end
	
	-- Round to grid
	bodyPos = Vector3.new(
		math.round(bodyPos.X / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(bodyPos.Y / BLOCK_SIZE) * BLOCK_SIZE,
		math.round(bodyPos.Z / BLOCK_SIZE) * BLOCK_SIZE
	)
	
	return bodyPos, pushDirection
end

--[[
	Push blocks in front of a piston when EXTENDING
	Includes attached blocks from any sticky pistons in the push line
	Also pushes blocks attached to extended sticky pistons
]]
function PistonPushHandler.PushBlocks(pistonBlock: Instance, blocksFolder: Folder): boolean
	local bodyPos, pushDirection = getPistonInfo(pistonBlock)
	
	-- Check from 1 block ahead of the piston body
	local firstCheckPosition = bodyPos + (pushDirection * BLOCK_SIZE)
	
	-- Get all blocks including sticky piston attachments
	local blocksToPush = getBlocksInLineWithAttachments(blocksFolder, firstCheckPosition, pushDirection, MAX_PUSH_BLOCKS)
	
	-- Also check for blocks attached to any EXTENDED sticky pistons we're pushing
	-- These blocks need to be pushed too, even if they're not directly in our line
	local additionalBlocks = {}
	local alreadyCollected = {}
	for _, block in ipairs(blocksToPush) do
		alreadyCollected[block] = true
	end
	
	for _, block in ipairs(blocksToPush) do
		if isStickyPiston(block) and block:GetAttribute("IsExtended") then
			-- This is an extended sticky piston - find blocks in front of its extended head
			local pistonBodyPos, pistonDir = getPistonInfo(block)
			-- Extended head is 1 block ahead of body
			local extendedHeadPos = pistonBodyPos + (pistonDir * BLOCK_SIZE)
			-- Check for blocks 1 block ahead of the extended head
			local checkPos = extendedHeadPos + (pistonDir * BLOCK_SIZE)
			
			-- Get blocks attached to this extended sticky piston
			for i = 1, MAX_PUSH_BLOCKS do
				local attachedBlock = findBlockAtPosition(blocksFolder, checkPos)
				if attachedBlock and not alreadyCollected[attachedBlock] then
					local blockType = attachedBlock:GetAttribute("BlockType")
					if PistonPushHandler.CanBePushed(blockType) then
						alreadyCollected[attachedBlock] = true
						table.insert(additionalBlocks, attachedBlock)
					else
						break
					end
				else
					break
				end
				checkPos = checkPos + (pistonDir * BLOCK_SIZE)
			end
		end
	end
	
	-- Add additional blocks to the push list
	for _, block in ipairs(additionalBlocks) do
		table.insert(blocksToPush, block)
	end
	
	if #blocksToPush == 0 then
		-- Debug: log position being checked and nearby blocks
		print(string.format("[PistonPush] Body at (%.1f, %.1f, %.1f), checking (%.1f, %.1f, %.1f) - no blocks found", 
			bodyPos.X, bodyPos.Y, bodyPos.Z,
			firstCheckPosition.X, firstCheckPosition.Y, firstCheckPosition.Z))
		-- Show nearby blocks for debugging
		for _, block in ipairs(blocksFolder:GetChildren()) do
			if not block:GetAttribute("IsDecoration") and block ~= pistonBlock then
				local pos = getBlockPosition(block)
				if pos then
					local dist = (pos - firstCheckPosition).Magnitude
					if dist < 10 then
						print(string.format("  Nearby: %s at (%.1f, %.1f, %.1f) dist=%.1f", 
							block.Name, pos.X, pos.Y, pos.Z, dist))
					end
				end
			end
		end
		return true
	end
	
	print(string.format("[PistonPush] Pushing %d block(s)", #blocksToPush))
	
	-- Mark any pistons being pushed so they don't try to extend this tick (Minecraft-style)
	for _, block in ipairs(blocksToPush) do
		if isPiston(block) then
			block:SetAttribute("BeingPushed", true)
		end
	end
	
	-- Check total block count
	if #blocksToPush > MAX_PUSH_BLOCKS then
		print("[PistonPush] Too many blocks to push (> " .. MAX_PUSH_BLOCKS .. " including attachments)")
		return false
	end
	
	-- Find the farthest block position to check if there's room
	local farthestPos = nil
	for _, block in ipairs(blocksToPush) do
		local pos = getBlockPosition(block)
		if pos then
			-- Project position onto push direction to find farthest
			if farthestPos == nil or pushDirection:Dot(pos - bodyPos) > pushDirection:Dot(farthestPos - bodyPos) then
				farthestPos = pos
			end
		end
	end
	
	if farthestPos then
		-- Round to grid
		farthestPos = Vector3.new(
			math.round(farthestPos.X / BLOCK_SIZE) * BLOCK_SIZE,
			math.round(farthestPos.Y / BLOCK_SIZE) * BLOCK_SIZE,
			math.round(farthestPos.Z / BLOCK_SIZE) * BLOCK_SIZE
		)
		
		local targetEndPosition = farthestPos + (pushDirection * BLOCK_SIZE)
		
		if not isTargetPositionClear(blocksFolder, targetEndPosition, blocksToPush) then
			print("[PistonPush] Target position blocked - cannot push")
			return false
		end
	end
	
	-- Sort blocks by distance from piston (farthest first) to avoid collisions
	table.sort(blocksToPush, function(a, b)
		local posA = getBlockPosition(a)
		local posB = getBlockPosition(b)
		if not posA or not posB then return false end
		local distA = pushDirection:Dot(posA - bodyPos)
		local distB = pushDirection:Dot(posB - bodyPos)
		return distA > distB -- Farthest first
	end)
	
	-- Push all blocks
	for i, block in ipairs(blocksToPush) do
		local currentPos = getBlockPosition(block)
		
		if currentPos then
			local targetPos = currentPos + (pushDirection * BLOCK_SIZE)
			tweenBlockToPosition(block, targetPos, PUSH_TWEEN_TIME)
		end
	end
	
	-- Clear BeingPushed flags after animation completes (cleanup for pistons not wired to same signal)
	task.delay(PUSH_TWEEN_TIME + 0.05, function()
		for _, block in ipairs(blocksToPush) do
			if block and block:GetAttribute("BeingPushed") then
				block:SetAttribute("BeingPushed", nil)
			end
		end
	end)
	
	return true
end

--[[
	Pull blocks back when a STICKY piston RETRACTS
	Includes attached blocks from any sticky pistons being pulled
	Also pulls blocks attached to extended sticky pistons
]]
function PistonPushHandler.PullBlocks(pistonBlock: Instance, blocksFolder: Folder): boolean
	local bodyPos, pushDirection = getPistonInfo(pistonBlock)
	
	-- When pulling, the piston is currently extended
	-- Head is 1 block ahead, blocks are 2 blocks ahead of body
	local firstCheckPosition = bodyPos + (pushDirection * BLOCK_SIZE * 2)
	
	-- Get all blocks including sticky piston attachments
	local blocksToPull = getBlocksInLineWithAttachments(blocksFolder, firstCheckPosition, pushDirection, MAX_PUSH_BLOCKS)
	
	-- Also check for blocks attached to any EXTENDED sticky pistons we're pulling
	-- These blocks need to be pulled too, even if they're not directly in our line
	local additionalBlocks = {}
	local alreadyCollected = {}
	for _, block in ipairs(blocksToPull) do
		alreadyCollected[block] = true
	end
	
	for _, block in ipairs(blocksToPull) do
		if isStickyPiston(block) and block:GetAttribute("IsExtended") then
			-- This is an extended sticky piston - find blocks in front of its extended head
			local pistonBodyPos, pistonDir = getPistonInfo(block)
			-- Extended head is 1 block ahead of body
			local extendedHeadPos = pistonBodyPos + (pistonDir * BLOCK_SIZE)
			-- Check for blocks 1 block ahead of the extended head
			local checkPos = extendedHeadPos + (pistonDir * BLOCK_SIZE)
			
			-- Get blocks attached to this extended sticky piston
			for i = 1, MAX_PUSH_BLOCKS do
				local attachedBlock = findBlockAtPosition(blocksFolder, checkPos)
				if attachedBlock and not alreadyCollected[attachedBlock] then
					local blockType = attachedBlock:GetAttribute("BlockType")
					if PistonPushHandler.CanBePushed(blockType) then
						alreadyCollected[attachedBlock] = true
						table.insert(additionalBlocks, attachedBlock)
					else
						break
					end
				else
					break
				end
				checkPos = checkPos + (pistonDir * BLOCK_SIZE)
			end
		end
	end
	
	-- Add additional blocks to the pull list
	for _, block in ipairs(additionalBlocks) do
		table.insert(blocksToPull, block)
	end
	
	if #blocksToPull == 0 then
		return true
	end
	
	print(string.format("[PistonPull] Pulling %d block(s)", #blocksToPull))
	
	-- Mark any pistons being pulled so they don't try to extend this tick (Minecraft-style)
	for _, block in ipairs(blocksToPull) do
		if isPiston(block) then
			block:SetAttribute("BeingPushed", true)
		end
	end
	
	-- Pull direction is opposite of push direction
	local pullDirection = -pushDirection
	
	-- Sort blocks by distance from piston (nearest first for pulling)
	table.sort(blocksToPull, function(a, b)
		local posA = getBlockPosition(a)
		local posB = getBlockPosition(b)
		if not posA or not posB then return false end
		local distA = pushDirection:Dot(posA - bodyPos)
		local distB = pushDirection:Dot(posB - bodyPos)
		return distA < distB -- Nearest first
	end)
	
	-- Pull all blocks
	for i, block in ipairs(blocksToPull) do
		local currentPos = getBlockPosition(block)
		
		if currentPos then
			local targetPos = currentPos + (pullDirection * BLOCK_SIZE)
			tweenBlockToPosition(block, targetPos, PUSH_TWEEN_TIME)
		end
	end
	
	-- Clear BeingPushed flags after animation completes
	task.delay(PUSH_TWEEN_TIME + 0.05, function()
		for _, block in ipairs(blocksToPull) do
			if block and block:GetAttribute("BeingPushed") then
				block:SetAttribute("BeingPushed", nil)
			end
		end
	end)
	
	return true
end

--[[
	Check if a piston CAN push (preview without actually pushing)
]]
function PistonPushHandler.CanPush(pistonBlock: Instance, blocksFolder: Folder): (boolean, number)
	local bodyPos, pushDirection = getPistonInfo(pistonBlock)
	local firstCheckPosition = bodyPos + (pushDirection * BLOCK_SIZE)
	
	local blocksToPush = getBlocksInLineWithAttachments(blocksFolder, firstCheckPosition, pushDirection, MAX_PUSH_BLOCKS)
	
	if #blocksToPush == 0 then
		return true, 0
	end
	
	-- Check total count
	if #blocksToPush > MAX_PUSH_BLOCKS then
		return false, #blocksToPush
	end
	
	-- Find farthest block and check if target is clear
	local farthestPos = nil
	for _, block in ipairs(blocksToPush) do
		local pos = getBlockPosition(block)
		if pos then
			if farthestPos == nil or pushDirection:Dot(pos - bodyPos) > pushDirection:Dot(farthestPos - bodyPos) then
				farthestPos = pos
			end
		end
	end
	
	if farthestPos then
		farthestPos = Vector3.new(
			math.round(farthestPos.X / BLOCK_SIZE) * BLOCK_SIZE,
			math.round(farthestPos.Y / BLOCK_SIZE) * BLOCK_SIZE,
			math.round(farthestPos.Z / BLOCK_SIZE) * BLOCK_SIZE
		)
		
		local targetEndPosition = farthestPos + (pushDirection * BLOCK_SIZE)
		
		if not isTargetPositionClear(blocksFolder, targetEndPosition, blocksToPush) then
			return false, #blocksToPush
		end
	end
	
	return true, #blocksToPush
end

--[[
	Check if a sticky piston CAN pull
]]
function PistonPushHandler.CanPull(pistonBlock: Instance, blocksFolder: Folder): (boolean, number)
	local bodyPos, pushDirection = getPistonInfo(pistonBlock)
	-- Blocks are 2 blocks ahead when extended
	local firstCheckPosition = bodyPos + (pushDirection * BLOCK_SIZE * 2)
	
	local blocksToPull = getBlocksInLineWithAttachments(blocksFolder, firstCheckPosition, pushDirection, MAX_PUSH_BLOCKS)
	
	return true, #blocksToPull
end

--[[
	Check if pistonA would push targetBlock when it extends
	Used to detect if a piston should defer its extension because another piston will push it
]]
function PistonPushHandler.WouldPushBlock(pistonA: Instance, targetBlock: Instance, blocksFolder: Folder): boolean
	local bodyPos, pushDirection = getPistonInfo(pistonA)
	local firstCheckPosition = bodyPos + (pushDirection * BLOCK_SIZE)
	
	-- Get all blocks that would be pushed
	local blocksToPush = getBlocksInLineWithAttachments(blocksFolder, firstCheckPosition, pushDirection, MAX_PUSH_BLOCKS)
	
	-- Check if targetBlock is in the list
	for _, block in ipairs(blocksToPush) do
		if block == targetBlock then
			return true
		end
	end
	
	return false
end

return PistonPushHandler
