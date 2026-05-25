--[[
	AdminPanelHandler
	Server-side handler for admin panel actions
	
	Features:
	- Invisibility toggle
	- God mode (invincibility)
	- Noclip
	- Teleport to players
	- Speed boost
	- Kick players
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

-- Create RemoteEvents for admin actions
local AdminRemotes = Instance.new("Folder")
AdminRemotes.Name = "AdminRemotes"
AdminRemotes.Parent = ReplicatedStorage

local ToggleInvisibility = Instance.new("RemoteEvent")
ToggleInvisibility.Name = "ToggleInvisibility"
ToggleInvisibility.Parent = AdminRemotes

local InvisibilitySync = Instance.new("RemoteEvent")
InvisibilitySync.Name = "InvisibilitySync"
InvisibilitySync.Parent = AdminRemotes

local ToggleGodMode = Instance.new("RemoteEvent")
ToggleGodMode.Name = "ToggleGodMode"
ToggleGodMode.Parent = AdminRemotes

local ToggleNoclip = Instance.new("RemoteEvent")
ToggleNoclip.Name = "ToggleNoclip"
ToggleNoclip.Parent = AdminRemotes

local SetSpeed = Instance.new("RemoteEvent")
SetSpeed.Name = "SetSpeed"
SetSpeed.Parent = AdminRemotes

local TeleportToPlayer = Instance.new("RemoteEvent")
TeleportToPlayer.Name = "TeleportToPlayer"
TeleportToPlayer.Parent = AdminRemotes

local KickPlayer = Instance.new("RemoteEvent")
KickPlayer.Name = "KickPlayer"
KickPlayer.Parent = AdminRemotes

local GetPlayerList = Instance.new("RemoteFunction")
GetPlayerList.Name = "GetPlayerList"
GetPlayerList.Parent = AdminRemotes

local IsAdmin = Instance.new("RemoteFunction")
IsAdmin.Name = "IsAdmin"
IsAdmin.Parent = AdminRemotes

-- Admin state tracking
local adminStates = {} -- [userId] = {invisible = false, godMode = false, noclip = false, speed = 16}

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

local function getAdminState(player)
	if not adminStates[player.UserId] then
		adminStates[player.UserId] = {
			invisible = false,
			godMode = false,
			noclip = false,
			speed = 16, -- default walk speed
		}
	end
	return adminStates[player.UserId]
end

-- Invisibility toggle
ToggleInvisibility.OnServerEvent:Connect(function(player, enabled)
	if not isOwner(player) then
		warn("[AdminPanel] Non-admin tried to toggle invisibility:", player.Name)
		return
	end
	
	local state = getAdminState(player)
	state.invisible = enabled
	
	local character = player.Character
	if not character then return end
	
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			if enabled then
				-- Store original transparency
				if not part:GetAttribute("OriginalTransparency") then
					part:SetAttribute("OriginalTransparency", part.Transparency)
				end
				part.Transparency = 1
			else
				-- Restore original transparency
				local original = part:GetAttribute("OriginalTransparency") or 0
				part.Transparency = original
			end
		elseif part:IsA("Decal") or part:IsA("Texture") then
			if enabled then
				if not part:GetAttribute("OriginalTransparency") then
					part:SetAttribute("OriginalTransparency", part.Transparency)
				end
				part.Transparency = 1
			else
				local original = part:GetAttribute("OriginalTransparency") or 0
				part.Transparency = original
			end
		end
	end
	
	-- Handle face
	local head = character:FindFirstChild("Head")
	if head then
		local face = head:FindFirstChildOfClass("Decal")
		if face then
			if enabled then
				if not face:GetAttribute("OriginalTransparency") then
					face:SetAttribute("OriginalTransparency", face.Transparency)
				end
				face.Transparency = 1
			else
				local original = face:GetAttribute("OriginalTransparency") or 0
				face.Transparency = original
			end
		end
	end
	
	-- Hide name tag
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if enabled then
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		else
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
		end
	end
	
	print("[AdminPanel]", player.Name, "invisibility:", enabled and "ON" or "OFF")
	
	-- Tell client to apply ghost effect locally
	InvisibilitySync:FireClient(player, enabled)
end)

-- God mode toggle
ToggleGodMode.OnServerEvent:Connect(function(player, enabled)
	if not isOwner(player) then
		warn("[AdminPanel] Non-admin tried to toggle god mode:", player.Name)
		return
	end
	
	local state = getAdminState(player)
	state.godMode = enabled
	
	local character = player.Character
	if not character then return end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if enabled then
			humanoid.MaxHealth = math.huge
			humanoid.Health = math.huge
		else
			humanoid.MaxHealth = 100
			humanoid.Health = 100
		end
	end
	
	print("[AdminPanel]", player.Name, "god mode:", enabled and "ON" or "OFF")
end)

-- Noclip is handled client-side, but server tracks state
ToggleNoclip.OnServerEvent:Connect(function(player, enabled)
	if not isOwner(player) then
		warn("[AdminPanel] Non-admin tried to toggle noclip:", player.Name)
		return
	end
	
	local state = getAdminState(player)
	state.noclip = enabled
	
	print("[AdminPanel]", player.Name, "noclip:", enabled and "ON" or "OFF")
end)

-- Speed setting
SetSpeed.OnServerEvent:Connect(function(player, speed)
	if not isOwner(player) then
		warn("[AdminPanel] Non-admin tried to set speed:", player.Name)
		return
	end
	
	-- Clamp speed to reasonable values
	speed = math.clamp(speed, 0, 200)
	
	local state = getAdminState(player)
	state.speed = speed
	
	local character = player.Character
	if not character then return end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed
	end
	
	print("[AdminPanel]", player.Name, "speed set to:", speed)
end)

-- Teleport to player
TeleportToPlayer.OnServerEvent:Connect(function(player, targetName)
	if not isOwner(player) then
		warn("[AdminPanel] Non-admin tried to teleport:", player.Name)
		return
	end
	
	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer then
		warn("[AdminPanel] Target player not found:", targetName)
		return
	end
	
	local myCharacter = player.Character
	local targetCharacter = targetPlayer.Character
	
	if not myCharacter or not targetCharacter then
		warn("[AdminPanel] Character not found for teleport")
		return
	end
	
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	local myRoot = myCharacter:FindFirstChild("HumanoidRootPart")
	
	if targetRoot and myRoot then
		myRoot.CFrame = targetRoot.CFrame * CFrame.new(3, 0, 0) -- Offset slightly
		print("[AdminPanel]", player.Name, "teleported to", targetName)
	end
end)

-- Kick player
KickPlayer.OnServerEvent:Connect(function(player, targetName, reason)
	if not isOwner(player) then
		warn("[AdminPanel] Non-admin tried to kick player:", player.Name)
		return
	end
	
	local targetPlayer = Players:FindFirstChild(targetName)
	if not targetPlayer then
		warn("[AdminPanel] Target player not found:", targetName)
		return
	end
	
	-- Don't allow kicking yourself
	if targetPlayer == player then
		warn("[AdminPanel] Cannot kick yourself!")
		return
	end
	
	-- Format the kick message
	local kickMessage = "You have been kicked from the game."
	if reason and reason ~= "" then
		kickMessage = kickMessage .. "\n\nReason: " .. reason
	end
	kickMessage = kickMessage .. "\n\nKicked by: " .. player.DisplayName
	
	print("[AdminPanel]", player.Name, "kicked", targetPlayer.Name, "- Reason:", reason or "No reason given")
	
	-- Kick the player
	targetPlayer:Kick(kickMessage)
end)

-- Get player list for dropdown
GetPlayerList.OnServerInvoke = function(player)
	if not isOwner(player) then
		return {}
	end
	
	local playerList = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player then -- Don't include self
			table.insert(playerList, {
				name = p.Name,
				displayName = p.DisplayName,
				userId = p.UserId,
			})
		end
	end
	return playerList
end

-- Check if player is admin
IsAdmin.OnServerInvoke = function(player)
	return isOwner(player)
end

-- Re-apply states when character respawns
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		if not isOwner(player) then return end
		
		-- Wait for humanoid
		local humanoid = character:WaitForChild("Humanoid", 5)
		if not humanoid then return end
		
		task.wait(0.5) -- Wait for character to fully load
		
		local state = adminStates[player.UserId]
		if not state then return end
		
		-- Re-apply god mode
		if state.godMode then
			humanoid.MaxHealth = math.huge
			humanoid.Health = math.huge
		end
		
		-- Re-apply speed
		if state.speed ~= 16 then
			humanoid.WalkSpeed = state.speed
		end
		
		-- Re-apply invisibility
		if state.invisible then
			ToggleInvisibility:FireClient(player, true) -- Tell client to re-sync
			task.wait(0.2)
			-- Apply server-side invisibility
			for _, part in ipairs(character:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Transparency = 1
				elseif part:IsA("Decal") or part:IsA("Texture") then
					part.Transparency = 1
				end
			end
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end)
end)

-- Cleanup on player leave
Players.PlayerRemoving:Connect(function(player)
	adminStates[player.UserId] = nil
end)

-- print("[AdminPanelHandler] Initialized - Admin panel server handler ready")
