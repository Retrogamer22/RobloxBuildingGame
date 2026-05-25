--[[
	PerformanceDebugger.client.luau
	TEMPORARY: Place in StarterPlayerScripts to diagnose BUFFERSFULL issues
	Tracks event firing rates and identifies performance bottlenecks
	DELETE AFTER DEBUGGING
]]

-- MASTER TOGGLE: Set to false to disable all debug output
local ENABLED = false
if not ENABLED then return end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

-- Track event counts
local EventCounts = {
	RenderStepped = 0,
	Heartbeat = 0,
	RemoteEvent = 0,
}

-- Track ChildAdded per folder
local ChildAddedByFolder = {}
local ChildRemovedByFolder = {}

local LastReportTime = tick()
local REPORT_INTERVAL = 3 -- Report every 3 seconds

-- Hook into all existing connections we can find
local function countEvent(eventType)
	EventCounts[eventType] = (EventCounts[eventType] or 0) + 1
end

local function countChildAdded(folderName)
	ChildAddedByFolder[folderName] = (ChildAddedByFolder[folderName] or 0) + 1
end

local function countChildRemoved(folderName)
	ChildRemovedByFolder[folderName] = (ChildRemovedByFolder[folderName] or 0) + 1
end

-- Track render stepped
RunService.RenderStepped:Connect(function(dt)
	countEvent("RenderStepped")
end)

-- Track heartbeat
RunService.Heartbeat:Connect(function(dt)
	countEvent("Heartbeat")
end)

-- Track children events on workspace descendants
local trackedFolders = {}

local function trackFolder(folder, label)
	if trackedFolders[folder] then return end
	trackedFolders[folder] = true
	
	local folderLabel = label or folder:GetFullName()
	
	folder.ChildAdded:Connect(function(child)
		countChildAdded(folderLabel)
	end)
	
	folder.ChildRemoved:Connect(function(child)
		countChildRemoved(folderLabel)
	end)
	
	print("[PerfDebug] Now tracking: " .. folderLabel)
end

-- Track workspace directly
trackFolder(Workspace, "Workspace (root)")

-- Track Workspace.Terrain
if Workspace:FindFirstChild("Terrain") then
	trackFolder(Workspace.Terrain, "Workspace.Terrain")
end

-- Track common folders
local function trackCommonFolders()
	-- Track build area blocks folders
	for i = 1, 20 do
		local buildArea = Workspace:FindFirstChild("BuildArea" .. i)
		if buildArea then
			trackFolder(buildArea, "BuildArea" .. i)
			
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				trackFolder(blocksFolder, "BuildArea" .. i .. "/Blocks")
			end
			
			-- Track other subfolders
			for _, child in ipairs(buildArea:GetChildren()) do
				if child:IsA("Folder") or child:IsA("Model") then
					trackFolder(child, "BuildArea" .. i .. "/" .. child.Name)
				end
			end
		end
	end
	
	-- Track weather/particle folders
	local weatherFolder = Workspace:FindFirstChild("ClientWeatherEffects")
	if weatherFolder then
		trackFolder(weatherFolder, "ClientWeatherEffects")
	end
	
	local fallingLeaves = Workspace:FindFirstChild("FallingLeaves")
	if not fallingLeaves then
		fallingLeaves = Workspace.Terrain:FindFirstChild("FallingLeaves")
	end
	if fallingLeaves then
		trackFolder(fallingLeaves, "FallingLeaves")
	end
	
	-- Track ReplicatedStorage folders
	local blocksRS = ReplicatedStorage:FindFirstChild("Blocks")
	if blocksRS then
		trackFolder(blocksRS, "ReplicatedStorage/Blocks")
	end
end

-- Initial tracking
trackCommonFolders()

-- Re-scan periodically for new folders
task.spawn(function()
	while true do
		task.wait(5)
		trackCommonFolders()
	end
end)

-- Track remote events
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if Remotes then
	for _, remote in ipairs(Remotes:GetChildren()) do
		if remote:IsA("RemoteEvent") then
			remote.OnClientEvent:Connect(function()
				countEvent("RemoteEvent")
			end)
		end
	end
end

-- Report function
local function report()
	local now = tick()
	local elapsed = now - LastReportTime
	LastReportTime = now
	
	print("\n========== PERFORMANCE DEBUG REPORT ==========")
	print(string.format("Elapsed: %.2f seconds", elapsed))
	
	-- General events
	print("\n--- General Events ---")
	for eventType, count in pairs(EventCounts) do
		local perSecond = count / elapsed
		local status = ""
		if perSecond > 100 then
			status = " ⚠️ HIGH!"
		end
		print(string.format("  %s: %d (%.1f/sec)%s", eventType, count, perSecond, status))
	end
	
	-- ChildAdded by folder (sorted by count)
	local sortedAdded = {}
	for folder, count in pairs(ChildAddedByFolder) do
		table.insert(sortedAdded, {folder = folder, count = count})
	end
	table.sort(sortedAdded, function(a, b) return a.count > b.count end)
	
	if #sortedAdded > 0 then
		print("\n--- ChildAdded by Folder ---")
		for i, data in ipairs(sortedAdded) do
			if i > 10 then break end -- Top 10 only
			local perSecond = data.count / elapsed
			local status = ""
			if perSecond > 50 then
				status = " ⚠️ HIGH!"
			elseif perSecond > 20 then
				status = " (moderate)"
			end
			if data.count > 0 then
				print(string.format("  %s: %d (%.1f/sec)%s", data.folder, data.count, perSecond, status))
			end
		end
	end
	
	-- ChildRemoved by folder
	local sortedRemoved = {}
	for folder, count in pairs(ChildRemovedByFolder) do
		table.insert(sortedRemoved, {folder = folder, count = count})
	end
	table.sort(sortedRemoved, function(a, b) return a.count > b.count end)
	
	if #sortedRemoved > 0 then
		print("\n--- ChildRemoved by Folder ---")
		for i, data in ipairs(sortedRemoved) do
			if i > 10 then break end
			local perSecond = data.count / elapsed
			local status = ""
			if perSecond > 50 then
				status = " ⚠️ HIGH!"
			end
			if data.count > 0 then
				print(string.format("  %s: %d (%.1f/sec)%s", data.folder, data.count, perSecond, status))
			end
		end
	end
	
	-- Memory info
	local memoryUsage = Stats:GetTotalMemoryUsageMb()
	print(string.format("\nMemory: %.1f MB", memoryUsage))
	
	-- Reset counts
	for eventType in pairs(EventCounts) do
		EventCounts[eventType] = 0
	end
	ChildAddedByFolder = {}
	ChildRemovedByFolder = {}
	
	print("================================================\n")
end

-- Report periodically
task.spawn(function()
	while true do
		task.wait(REPORT_INTERVAL)
		report()
	end
end)

print("[PerformanceDebugger] Started - will report every " .. REPORT_INTERVAL .. " seconds")
print("[PerformanceDebugger] Tracking ChildAdded/Removed by folder to find the source!")
