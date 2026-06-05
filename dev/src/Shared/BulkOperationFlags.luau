--[[
	BulkOperationFlags
	Shared module to coordinate bulk operations (terrain gen, save loading)
	Handlers should check these flags before processing ChildAdded/ChildRemoved events
]]

local BulkOperationFlags = {}

-- Track which build areas are in bulk operation mode
-- Key: buildArea instance or plot number
-- Value: { type = string, startedAt = os.clock() }
local ActiveOperations = {}

-- Safety net: any bulk operation older than this many seconds is treated as
-- stale and auto-cleared. Legitimate bulk operations (terrain gen / save load)
-- complete well under a minute; longer than this means an error in the caller
-- left the flag set. Without this, downstream systems (vine growth, lighting)
-- can silently freeze for the rest of the server's life.
local STALE_TIMEOUT_SECONDS = 90

local function isEntryStale(entry)
	return entry and entry.startedAt and (os.clock() - entry.startedAt) > STALE_TIMEOUT_SECONDS
end

local function purgeIfStale(buildArea, entry)
	if isEntryStale(entry) then
		warn(string.format("[BulkOperationFlags] Auto-clearing stale '%s' op (%.0fs old) on %s",
			entry.type or "unknown",
			os.clock() - entry.startedAt,
			typeof(buildArea) == "Instance" and buildArea.Name or tostring(buildArea)))
		ActiveOperations[buildArea] = nil
		if typeof(buildArea) == "Instance" then
			buildArea:SetAttribute("BulkOperationInProgress", false)
			buildArea:SetAttribute("BulkOperationType", nil)
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				blocksFolder:SetAttribute("BulkOperationInProgress", false)
			end
		end
		return true
	end
	return false
end

-- Check if a build area is in bulk operation mode
function BulkOperationFlags.IsBulkOperation(buildArea)
	if not buildArea then return false end
	local entry = ActiveOperations[buildArea]
	if not entry then return false end
	if purgeIfStale(buildArea, entry) then return false end
	return true
end

-- Check by plot number
function BulkOperationFlags.IsBulkOperationByPlot(plotNumber)
	for buildArea, entry in pairs(ActiveOperations) do
		if typeof(buildArea) == "Instance" then
			local areaPlotNum = tonumber(string.match(buildArea.Name, "%d+"))
			if areaPlotNum == plotNumber then
				if purgeIfStale(buildArea, entry) then
					return false
				end
				return true
			end
		end
	end
	return false
end

-- Start a bulk operation
function BulkOperationFlags.StartBulkOperation(buildArea, operationType)
	operationType = operationType or "unknown"
	ActiveOperations[buildArea] = {
		type = operationType,
		startedAt = os.clock(),
	}
	
	-- Also set attribute on buildArea for handlers that check attributes
	if typeof(buildArea) == "Instance" then
		buildArea:SetAttribute("BulkOperationInProgress", true)
		buildArea:SetAttribute("BulkOperationType", operationType)
		
		-- Set on Blocks folder too
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if blocksFolder then
			blocksFolder:SetAttribute("BulkOperationInProgress", true)
		end
	end
	
	-- print(string.format("[BulkOperationFlags] Started '%s' operation", operationType))
end

-- End a bulk operation
function BulkOperationFlags.EndBulkOperation(buildArea)
	local entry = ActiveOperations[buildArea]
	local operationType = entry and entry.type or "unknown"
	ActiveOperations[buildArea] = nil
	
	-- Clear attributes
	if typeof(buildArea) == "Instance" then
		buildArea:SetAttribute("BulkOperationInProgress", false)
		buildArea:SetAttribute("BulkOperationType", nil)
		
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if blocksFolder then
			blocksFolder:SetAttribute("BulkOperationInProgress", false)
		end
	end
	
	-- print(string.format("[BulkOperationFlags] Ended '%s' operation", operationType))
end

-- Check if ANY bulk operation is active (useful for global checks).
-- Also opportunistically purges stale entries during the scan so a leaked
-- flag doesn't keep this returning true forever.
function BulkOperationFlags.IsAnyBulkOperationActive()
	for buildArea, entry in pairs(ActiveOperations) do
		if not purgeIfStale(buildArea, entry) then
			return true
		end
	end
	return false
end

-- Get the operation type for a build area
function BulkOperationFlags.GetOperationType(buildArea)
	local entry = ActiveOperations[buildArea]
	return entry and entry.type or nil
end

-- Force-clear every active operation. Emergency tool for dev/admin commands
-- in case a leaked flag is suspected.
function BulkOperationFlags.ForceEndAll()
	local cleared = 0
	for buildArea, entry in pairs(ActiveOperations) do
		cleared = cleared + 1
		ActiveOperations[buildArea] = nil
		if typeof(buildArea) == "Instance" then
			buildArea:SetAttribute("BulkOperationInProgress", false)
			buildArea:SetAttribute("BulkOperationType", nil)
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				blocksFolder:SetAttribute("BulkOperationInProgress", false)
			end
		end
	end
	if cleared > 0 then
		warn(string.format("[BulkOperationFlags] ForceEndAll cleared %d active operation(s)", cleared))
	end
	return cleared
end

-- ============================================================================
-- SERVER SHUTDOWN GUARD
-- ============================================================================
-- On server stop the engine tears down the DataModel directly (not via our
-- managed ClearAllBlocks), firing ChildRemoved for every block at once. The
-- per-block handlers (Lighting/FallingBlock/PressurePlate/Water) would each do
-- O(n) work per removal, freezing the main thread and spamming script-timeout
-- warnings. BindToClose fires before that teardown, so we flip this flag there
-- and those handlers skip their block listeners while it's set.
local shuttingDown = false

function BulkOperationFlags.IsShuttingDown()
	return shuttingDown
end

function BulkOperationFlags.SetShuttingDown()
	shuttingDown = true
end

if game:GetService("RunService"):IsServer() then
	game:BindToClose(function()
		shuttingDown = true
	end)
end

return BulkOperationFlags
