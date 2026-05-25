--[[
	BetaAdminCommands
	Chat commands for viewing beta tester information and managing the game
	
	Commands (owner only):
	- /betastatus - Show current beta mode status
	- /betalist - List all beta testers from this session
	- /betacount - Show count of beta testers
	- /update - Trigger an update notification for all players
	- /version - Show current server version info
	- /resetversion - Reset the stored version to match server (for testing)
	- /changelog - Force show the changelog popup (for testing)
	- /feedback - View recent player feedback
	- /clearfeedback - Clear all stored feedback
	- /urgentupdate [message] - Force shutdown all servers with countdown
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MessagingService = game:GetService("MessagingService")

local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

-- Get version management functions
local TriggerUpdate = ReplicatedStorage:WaitForChild("TriggerUpdate", 10)
local GetVersionInfo = ReplicatedStorage:WaitForChild("GetVersionInfo", 10)

-- Create urgent shutdown remote
local UrgentShutdown = Instance.new("RemoteEvent")
UrgentShutdown.Name = "UrgentShutdown"
UrgentShutdown.Parent = ReplicatedStorage

-- Shutdown state
local isShuttingDown = false
local SHUTDOWN_COUNTDOWN = 60 -- seconds
local SHUTDOWN_TOPIC = "UrgentGameShutdown"
local UPDATE_TOPIC = "GameUpdateNotification"

-- Function to start the shutdown process (called locally or from MessagingService)
local function startShutdownProcess(shutdownReason, initiatedBy, style)
	if isShuttingDown then
		print("[BetaAdmin] Shutdown already in progress on this server!")
		return
	end
	
	isShuttingDown = true
	print("[BetaAdmin] URGENT SHUTDOWN received!")
	print("[BetaAdmin] Reason:", shutdownReason)
	print("[BetaAdmin] Initiated by:", initiatedBy)
	print("[BetaAdmin] Countdown:", SHUTDOWN_COUNTDOWN, "seconds")
	
	-- Notify all clients on THIS server (style is optional; nil = default urgent UI)
	UrgentShutdown:FireAllClients({
		countdown = SHUTDOWN_COUNTDOWN,
		reason = shutdownReason,
		initiatedBy = initiatedBy,
		style = style,
	})
	
	-- Start countdown
	task.spawn(function()
		local remaining = SHUTDOWN_COUNTDOWN
		
		while remaining > 0 do
			-- Log at certain intervals
			if remaining == 30 or remaining == 10 or remaining <= 5 then
				print("[BetaAdmin] Shutdown in", remaining, "seconds...")
			end
			
			task.wait(1)
			remaining = remaining - 1
		end
		
		-- Save every still-connected player to their active slot (mirrors the
		-- normal PlayerRemoving save flow) so anyone who rode out the countdown
		-- doesn't lose their work. Each save is synchronous; we wrap in pcall +
		-- task.spawn so a slow save can't block the others or the kick.
		print("[BetaAdmin] Saving all connected players before shutdown...")
		local SavePlotSync = ReplicatedStorage:FindFirstChild("SavePlotSync")
		if SavePlotSync then
			local saveJobs = {}
			for _, p in ipairs(Players:GetPlayers()) do
				local done = false
				table.insert(saveJobs, function() return done end)
				task.spawn(function()
					local ok, success, blockCount = pcall(SavePlotSync.Invoke, SavePlotSync, p)
					if ok and success then
						print(string.format("[BetaAdmin] Pre-shutdown save OK for %s (%s blocks)",
							p.Name, tostring(blockCount or "?")))
					else
						warn(string.format("[BetaAdmin] Pre-shutdown save FAILED for %s: %s",
							p.Name, tostring(success)))
					end
					done = true
				end)
			end
			
			-- Wait up to 10 seconds for all saves to complete (typical save is <2s)
			local waitStart = os.clock()
			while os.clock() - waitStart < 10 do
				local allDone = true
				for _, isDone in ipairs(saveJobs) do
					if not isDone() then allDone = false; break end
				end
				if allDone then break end
				task.wait(0.1)
			end
			print(string.format("[BetaAdmin] Pre-shutdown saves finished (%.1fs)", os.clock() - waitStart))
		else
			warn("[BetaAdmin] SavePlotSync not found in ReplicatedStorage; skipping pre-shutdown save")
		end
		
		-- Kick all players
		print("[BetaAdmin] Shutting down server NOW!")
		for _, p in ipairs(Players:GetPlayers()) do
			p:Kick("Server is restarting for an urgent update. Please rejoin in a moment!\n\n" .. shutdownReason)
		end
	end)
end

-- Subscribe to cross-server shutdown messages
local subscribeSuccess, subscribeError = pcall(function()
	MessagingService:SubscribeAsync(SHUTDOWN_TOPIC, function(message)
		local data = message.Data
		if data and data.reason then
			print("[BetaAdmin] Received cross-server shutdown broadcast!")
			startShutdownProcess(data.reason, data.initiatedBy or "Unknown", data.style)
		end
	end)
end)

if subscribeSuccess then
	print("[BetaAdmin] Subscribed to cross-server shutdown topic")
else
	warn("[BetaAdmin] Failed to subscribe to shutdown topic:", subscribeError)
end

-- Subscribe to cross-server update notifications
local updateSubscribeSuccess, updateSubscribeError = pcall(function()
	MessagingService:SubscribeAsync(UPDATE_TOPIC, function(message)
		local data = message.Data
		if data and data.newVersion then
			print("[BetaAdmin] Received cross-server update notification!")
			print("[BetaAdmin] New version:", data.newVersion)
			
			-- Notify all players on THIS server
			local UpdateNotify = ReplicatedStorage:FindFirstChild("UpdateNotify")
			if UpdateNotify then
				local versionInfo = GetVersionInfo and GetVersionInfo:Invoke() or {serverVersion = 1}
				UpdateNotify:FireAllClients({
					currentVersion = versionInfo.serverVersion,
					newVersion = data.newVersion
				})
				print("[BetaAdmin] Update notification sent to", #Players:GetPlayers(), "players on this server")
			end
		end
	end)
end)

if updateSubscribeSuccess then
	print("[BetaAdmin] Subscribed to cross-server update topic")
else
	warn("[BetaAdmin] Failed to subscribe to update topic:", updateSubscribeError)
end

-- Wait for BetaPlayerManager
local BetaPlayerManager = nil
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local betaModule = modulesFolder:WaitForChild("BetaPlayerManager", 10)
		if betaModule then
			BetaPlayerManager = require(betaModule)
		end
	end
end)

local function isOwner(player)
	-- Always check game creator
	if player.UserId == game.CreatorId then
		return true
	end
	
	-- Check configured owner (if set, 0 means not configured)
	if BetaConfig.OWNER_USER_ID ~= 0 and player.UserId == BetaConfig.OWNER_USER_ID then
		return true
	end
	
	return false
end

local function handleChatCommand(player, message)
	if not isOwner(player) then return end
	if not BetaPlayerManager then return end
	
	local lowerMessage = string.lower(message)
	
	if lowerMessage == "/betastatus" then
		local status = BetaPlayerManager.IsBetaActive() and "ACTIVE" or "INACTIVE"
		local count = BetaPlayerManager.GetBetaPlayerCount()
		local pendingCount = BetaPlayerManager.GetPendingPlayerCount and BetaPlayerManager.GetPendingPlayerCount() or 0
		local threshold = BetaConfig.MINIMUM_BLOCKS_FOR_BETA or 10
		
		-- Send message to player's chat
		game:GetService("StarterGui"):SetCore("ChatMakeSystemMessage", {
			Text = string.format("[Beta] Status: %s | Qualified: %d | Pending: %d | Threshold: %d blocks", 
				status, count, pendingCount, threshold),
			Color = Color3.fromRGB(0, 255, 127),
			Font = Enum.Font.SourceSansBold,
		})
		
		print("[BetaAdmin] Status check by", player.Name)
		print("  - Beta mode:", status)
		print("  - Qualified beta testers (this session):", count)
		print("  - Pending players:", pendingCount)
		print("  - Block threshold:", threshold)
		
	elseif lowerMessage == "/betalist" then
		local betaPlayers = BetaPlayerManager.GetBetaPlayerList()
		
		print("[BetaAdmin] Beta tester list requested by", player.Name)
		print("========== BETA TESTERS (This Session) ==========")
		
		if #betaPlayers == 0 then
			print("  No beta testers registered this session")
		else
			for i, data in ipairs(betaPlayers) do
				local blockInfo = data.BlockCount and string.format(" - %d blocks", data.BlockCount) or ""
				print(string.format("  %d. %s (UserId: %d) - Joined: %s%s", 
					i, data.Name, data.UserId, data.JoinDate, blockInfo))
			end
		end
		
		print("=================================================")
		print("Total:", #betaPlayers, "qualified beta testers this session")
		
	elseif lowerMessage == "/betacount" then
		local count = BetaPlayerManager.GetBetaPlayerCount()
		print("[BetaAdmin] Beta count:", count)
		
	elseif lowerMessage == "/update" then
		-- Trigger update notification to ALL servers
		if TriggerUpdate then
			local versionInfo = GetVersionInfo and GetVersionInfo:Invoke() or {serverVersion = 1, storedVersion = 0}
			local newVersion = (versionInfo.storedVersion or versionInfo.serverVersion) + 1
			
			local success = TriggerUpdate:Invoke(newVersion)
			if success then
				print("[BetaAdmin] Update notification triggered! New version:", newVersion)
				print("[BetaAdmin] Broadcasting to ALL servers...")
				
				-- Broadcast to ALL servers via MessagingService
				local publishSuccess, publishError = pcall(function()
					MessagingService:PublishAsync(UPDATE_TOPIC, {
						newVersion = newVersion,
						initiatedBy = player.Name,
					})
				end)
				
				if publishSuccess then
					print("[BetaAdmin] Update broadcast sent to all servers!")
				else
					warn("[BetaAdmin] Failed to broadcast update:", publishError)
					-- Still notify this server at least
					print("[BetaAdmin] Falling back to local notification only")
					local UpdateNotify = ReplicatedStorage:FindFirstChild("UpdateNotify")
					if UpdateNotify then
						UpdateNotify:FireAllClients({
							currentVersion = versionInfo.serverVersion,
							newVersion = newVersion
						})
					end
				end
			else
				warn("[BetaAdmin] Failed to trigger update notification")
			end
		else
			warn("[BetaAdmin] UpdateChecker not initialized")
		end
		
	elseif lowerMessage == "/version" then
		-- Show version info
		if GetVersionInfo then
			local versionInfo = GetVersionInfo:Invoke()
			print("[BetaAdmin] Version Info:")
			print("  Server Version:", versionInfo.serverVersion)
			print("  Stored Version:", versionInfo.storedVersion or "Not set")
		else
			warn("[BetaAdmin] UpdateChecker not initialized")
		end
		
	elseif lowerMessage == "/resetversion" then
		-- Reset stored version to match server version (for testing)
		if TriggerUpdate and GetVersionInfo then
			local versionInfo = GetVersionInfo:Invoke()
			local serverVersion = versionInfo.serverVersion
			
			local success = TriggerUpdate:Invoke(serverVersion)
			if success then
				print("[BetaAdmin] Version reset to server version:", serverVersion)
			else
				warn("[BetaAdmin] Failed to reset version")
			end
		else
			warn("[BetaAdmin] UpdateChecker not initialized")
		end
		
	elseif lowerMessage == "/changelog" then
		-- Force show changelog popup
		local ShowChangelog = ReplicatedStorage:FindFirstChild("ShowChangelog")
		local ChangelogConfig = ReplicatedStorage:FindFirstChild("Config") and ReplicatedStorage.Config:FindFirstChild("ChangelogConfig")
		
		if ShowChangelog and ChangelogConfig then
			local config = require(ChangelogConfig)
			ShowChangelog:FireClient(player, {
				version = config.VERSION,
				versionName = config.VERSION_NAME,
				title = config.TITLE,
				subtitle = config.SUBTITLE,
				changes = config.CHANGES,
				footer = config.FOOTER
			})
			print("[BetaAdmin] Changelog popup shown to", player.Name)
		else
			warn("[BetaAdmin] Changelog system not initialized")
		end
		
	elseif lowerMessage == "/feedback" or string.match(lowerMessage, "^/feedback %d+$") then
		-- View recent feedback
		local GetFeedback = ReplicatedStorage:FindFirstChild("GetFeedback")
		
		if GetFeedback then
			-- Parse count from command (default 10)
			local count = tonumber(string.match(lowerMessage, "%d+")) or 10
			local feedbackList, totalCount = GetFeedback:Invoke(count)
			
			print("")
			print("========== PLAYER FEEDBACK ==========")
			print("Showing", #feedbackList, "of", totalCount, "total entries")
			print("")
			
			if #feedbackList == 0 then
				print("  No feedback yet!")
			else
				for i, entry in ipairs(feedbackList) do
					print(string.format("[%d] %s (@%s) - %s", i, entry.displayName, entry.username, entry.date))
					print("    " .. entry.feedback)
					print("")
				end
			end
			
			print("======================================")
			print("Tip: Use /feedback 20 to see more entries")
		else
			warn("[BetaAdmin] Feedback system not initialized")
		end
		
	elseif lowerMessage == "/clearfeedback" then
		-- Clear all feedback
		local ClearFeedback = ReplicatedStorage:FindFirstChild("ClearFeedback")
		
		if ClearFeedback then
			local success = ClearFeedback:Invoke()
			if success then
				print("[BetaAdmin] All feedback cleared!")
			else
				warn("[BetaAdmin] Failed to clear feedback")
			end
		else
			warn("[BetaAdmin] Feedback system not initialized")
		end
		
	elseif string.match(lowerMessage, "^/urgentupdate") then
		-- Urgent server shutdown with countdown (ALL SERVERS)
		if isShuttingDown then
			print("[BetaAdmin] Shutdown already in progress!")
			return
		end
		
		-- Parse optional message (everything after /urgentupdate )
		local customMessage = string.match(message, "^/[uU]rgent[uU]pdate%s+(.+)$")
		local shutdownReason = customMessage or "A critical update is being deployed."
		
		print("[BetaAdmin] URGENT SHUTDOWN initiated by", player.Name)
		print("[BetaAdmin] Broadcasting to ALL servers...")
		print("[BetaAdmin] Reason:", shutdownReason)
		
		-- Broadcast to ALL servers via MessagingService
		local publishSuccess, publishError = pcall(function()
			MessagingService:PublishAsync(SHUTDOWN_TOPIC, {
				reason = shutdownReason,
				initiatedBy = player.Name,
			})
		end)
		
		if publishSuccess then
			print("[BetaAdmin] Shutdown broadcast sent to all servers!")
		else
			warn("[BetaAdmin] Failed to broadcast shutdown:", publishError)
			-- Still shut down this server at least
			print("[BetaAdmin] Falling back to local shutdown only")
			startShutdownProcess(shutdownReason, player.Name)
		end
	end
end

-- Connect to chat
Players.PlayerAdded:Connect(function(player)
	player.Chatted:Connect(function(message)
		handleChatCommand(player, message)
	end)
end)

-- Handle existing players
for _, player in ipairs(Players:GetPlayers()) do
	player.Chatted:Connect(function(message)
		handleChatCommand(player, message)
	end)
end

print("[BetaAdminCommands] Initialized - Owner commands: /betastatus, /betalist, /betacount, /update, /version, /resetversion, /changelog, /feedback, /clearfeedback, /urgentupdate")
