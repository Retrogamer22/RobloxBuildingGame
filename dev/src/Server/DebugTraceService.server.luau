--[[
	DebugTraceService (server)
	-----------------------------------------------------------------------------
	Wires the remotes for the owner-only DebugTrace system and enforces the
	owner check server-side (the client UI is just a convenience; this is the
	real gate).

	Remotes created under ReplicatedStorage/Remotes:
		ToggleDebugTrace   (RemoteFunction) client -> server: ask to toggle/set.
		                   Invoke args: (mode)  mode = "toggle" | true | false
		                   Returns: boolean (resulting enabled state) — false for
		                   non-owners, always.
		DebugTraceLine     (RemoteEvent) server -> client: one formatted log line.
		DebugTraceStatus   (RemoteEvent) server -> client: pushes {enabled=bool,
		                   isOwner=bool} so the client can show/hide its button
		                   and reflect state (e.g. on respawn / rejoin).

	Nothing here runs for non-owners beyond returning false, so it is safe in
	production.
	-----------------------------------------------------------------------------
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DebugTrace = require(ReplicatedStorage:WaitForChild("DebugTrace"))

local LOG = "[BB-TRACE]"

----------------------------------------------------------------
-- Remote setup (create-if-missing, matching BlockHandler's pattern)
----------------------------------------------------------------

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end

local function ensureRemote(className, name)
	local existing = Remotes:FindFirstChild(name)
	if existing then
		return existing
	end
	local r = Instance.new(className)
	r.Name = name
	r.Parent = Remotes
	return r
end

local ToggleDebugTrace = ensureRemote("RemoteFunction", "ToggleDebugTrace")
local DebugTraceLine = ensureRemote("RemoteEvent", "DebugTraceLine")
local DebugTraceStatus = ensureRemote("RemoteEvent", "DebugTraceStatus")

----------------------------------------------------------------
-- Wire the module's push hook to fire lines at the owning client.
----------------------------------------------------------------

DebugTrace._push = function(player, line)
	if player and player.Parent then
		DebugTraceLine:FireClient(player, line)
	end
end

----------------------------------------------------------------
-- Toggle handler (server-authoritative owner check)
----------------------------------------------------------------

ToggleDebugTrace.OnServerInvoke = function(player, mode)
	if not DebugTrace.isOwner(player) then
		-- Never reveal capability to non-owners; just say "off".
		return false
	end

	local newState
	if mode == "toggle" or mode == nil then
		newState = DebugTrace.toggle(player)
	else
		newState = DebugTrace.setEnabled(player, mode and true or false)
	end

	print(string.format("%s tracing %s for %s", LOG, newState and "ENABLED" or "disabled", player.Name))

	-- Echo authoritative status back via the status event too (keeps any
	-- other client listeners in sync).
	DebugTraceStatus:FireClient(player, { enabled = newState, isOwner = true })
	return newState
end

----------------------------------------------------------------
-- On join: tell the owner their client they're allowed to see the button.
-- Non-owners get isOwner=false so their UI script can simply never build.
----------------------------------------------------------------

local function onPlayerAdded(player)
	-- Small wait so the client UI script has connected its listener.
	task.delay(2, function()
		if player and player.Parent then
			DebugTraceStatus:FireClient(player, {
				enabled = DebugTrace.isEnabled(player),
				isOwner = DebugTrace.isOwner(player),
			})
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do
	onPlayerAdded(p)
end

Players.PlayerRemoving:Connect(function(player)
	DebugTrace.cleanup(player)
end)

print(string.format("%s service ready (owner=%d)", LOG, DebugTrace.OWNER_USER_ID))
