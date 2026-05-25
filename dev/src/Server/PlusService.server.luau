--[[
	PlusService.server.luau

	Wires Roblox Plus subscription data between PlusManager (server module)
	and the client. Mirrors the pattern used by CoinService.

	Remotes created (under ReplicatedStorage.Remotes):
	  - GetPlusStatus       (RemoteFunction) — client requests current status
	  - PlusStatusChanged   (RemoteEvent)    — server pushes updates to client
	  - PromptPlusPurchase  (RemoteEvent)    — client asks server to fire the prompt

	The client never tells the server "I have Plus" — the server is the only
	authority. The discount on BloxCoin purchases is applied server-side via
	PlusManager.GetDiscountedPrice; the client mirror is for display only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ServerScriptService:WaitForChild("Modules", 10)
local PlusManager = require(Modules:WaitForChild("PlusManager", 10))
local AnalyticsEvents = require(Modules:WaitForChild("AnalyticsEvents", 10))

-- ============================================
-- REMOTES
-- ============================================
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local GetPlusStatus = Instance.new("RemoteFunction")
GetPlusStatus.Name = "GetPlusStatus"
GetPlusStatus.Parent = Remotes

local PlusStatusChanged = Instance.new("RemoteEvent")
PlusStatusChanged.Name = "PlusStatusChanged"
PlusStatusChanged.Parent = Remotes

local PromptPlusPurchase = Instance.new("RemoteEvent")
PromptPlusPurchase.Name = "PromptPlusPurchase"
PromptPlusPurchase.Parent = Remotes

-- Client tells the server whenever PlusUI is opened (from any source: HUD
-- button, title screen, etc.) purely for funnel analytics. This is NOT trusted
-- for anything that grants value — it only increments a tap counter — so a
-- per-player rate-limit (below) is enough to stop a spoofed client inflating
-- the numbers.
local PlusUIOpened = Instance.new("RemoteEvent")
PlusUIOpened.Name = "PlusUIOpened"
PlusUIOpened.Parent = Remotes

-- ============================================
-- PLAYER LIFECYCLE
-- ============================================
Players.PlayerAdded:Connect(function(player)
	PlusManager.OnPlayerAdded(player)

	-- Push an initial status to the client. The status may not yet be fully
	-- resolved (the GetRobloxSubscriptionDetailsAsync call runs asynchronously
	-- in PlusManager.OnPlayerAdded) — that's fine. The client will get a
	-- second push via PlusStatusChanged once sync completes, and we always
	-- send the fast-path HasRobloxSubscription value here so the UI never
	-- starts in a wrong state for already-subscribed players.
	task.spawn(function()
		-- Tiny grace period so the player's PlayerGui has a chance to wire up
		-- listeners. The client also re-requests status on its end via
		-- GetPlusStatus on startup, so this is double-belt-and-suspenders.
		task.wait(1)
		if not player.Parent then return end
		PlusStatusChanged:FireClient(player, PlusManager.GetStatus(player.UserId))
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	PlusManager.OnPlayerRemoving(player)
end)

-- Already-in-server players (Studio play-test, hot reload, etc.) get their
-- lifecycle hook too. PlayerAdded only fires going forward.
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		PlusManager.OnPlayerAdded(player)
		task.wait(1)
		if player.Parent then
			PlusStatusChanged:FireClient(player, PlusManager.GetStatus(player.UserId))
		end
	end)
end

-- ============================================
-- STATUS CHANGE → CLIENT PUSH
-- ============================================
PlusManager.OnStatusChanged(function(userId, state)
	local player = Players:GetPlayerByUserId(userId)
	if not player then return end
	PlusStatusChanged:FireClient(player, state)
end)

-- ============================================
-- REMOTE HANDLERS
-- ============================================

-- Client requests current status (called on first opens of PlusUI / shop etc.)
GetPlusStatus.OnServerInvoke = function(player)
	return PlusManager.GetStatus(player.UserId)
end

-- Client asks the server to fire the subscription prompt. Anti-spam: 5s cooldown
-- per player so a misclick or rapid-fire UI bug can't pop the prompt repeatedly.
local PromptCooldown = {}
local PROMPT_COOLDOWN = 5

-- Per-player throttle for the plus_tap analytics event (declared here so the
-- shared PlayerRemoving cleanup below can see it).
local PlusTapThrottle = {}
local PLUS_TAP_MIN_GAP = 2

PromptPlusPurchase.OnServerEvent:Connect(function(player)
	if not player or not player.Parent then return end
	local now = os.clock()
	local last = PromptCooldown[player.UserId]
	if last and (now - last) < PROMPT_COOLDOWN then return end
	PromptCooldown[player.UserId] = now

	-- If they already have Plus, don't prompt — let the client UI handle the
	-- "already active" state instead of triggering Roblox's prompt which
	-- would just show them they're already subscribed.
	if PlusManager.HasPlus(player.UserId) then
		print(string.format("[PlusService] %s requested Plus prompt but already subscribed", player.Name))
		-- Push a fresh status anyway in case the client somehow desynced.
		PlusStatusChanged:FireClient(player, PlusManager.GetStatus(player.UserId))
		return
	end

	print(string.format("[PlusService] Prompting Plus subscription for %s", player.Name))
	PlusManager.Prompt(player)
end)

Players.PlayerRemoving:Connect(function(player)
	PromptCooldown[player.UserId] = nil
	PlusTapThrottle[player.UserId] = nil
end)

-- ============================================
-- PLUS UI OPENED → plus_tap analytics
-- ============================================
-- Fires a `plus_tap` analytics event each time the player opens PlusUI. We
-- throttle per player so a malicious/looping client can't inflate the funnel's
-- top number — at most one tap event per PLUS_TAP_MIN_GAP seconds per player.
-- (PlusTapThrottle / PLUS_TAP_MIN_GAP are declared up by PromptCooldown.)
PlusUIOpened.OnServerEvent:Connect(function(player, source)
	if not player or not player.Parent then return end

	local now = os.clock()
	local last = PlusTapThrottle[player.UserId]
	if last and (now - last) < PLUS_TAP_MIN_GAP then return end
	PlusTapThrottle[player.UserId] = now

	-- `source` is a client-supplied hint ("hud_button", "title_screen", ...).
	-- Sanitize: only accept a short string, else label it "unknown".
	local src = "unknown"
	if type(source) == "string" and #source > 0 and #source <= 32 then
		src = source
	end

	-- Whether they already have Plus when they open it — lets the dashboard
	-- separate "prospect opened the offer" from "existing subscriber peeked".
	local hasPlus = PlusManager.HasPlus(player.UserId)

	AnalyticsEvents.Post("plus_tap", {
		userId = player.UserId,
		username = player.Name,
		source = src,
		alreadyPlus = hasPlus,
	})
end)

-- ============================================
-- IN-GAME SUBSCRIBER HOOK
-- ============================================
-- When someone subscribes via OUR in-game prompt, log it loudly so we can
-- correlate analytics. Roblox credits the 250 R$/month bonus automatically
-- through PromptRobloxSubscriptionPurchase + IsOriginExperience — we don't
-- have to grant anything ourselves. This is purely for telemetry and
-- future-extensibility (e.g. if Ethan ever wants to grant a thank-you
-- BloxCoin bonus to in-game-acquired subscribers, the hook is right here).
PlusManager.OnNewSubscriber(function(userId, isOriginExperience)
	local player = Players:GetPlayerByUserId(userId)
	local name = player and player.Name or tostring(userId)
	print(string.format("[PlusService] NEW Plus subscriber: %s (originExperience=%s)",
		name, tostring(isOriginExperience)))

	-- Conversion event for the funnel. `originExperience` is the key field:
	-- TRUE means they subscribed THROUGH BuildBlox (our in-game prompt) — that's
	-- an attributed conversion. FALSE means Roblox told us they're subscribed but
	-- they bought it elsewhere. The dashboard divides plus_purchase(origin=true)
	-- by plus_tap to get the true tap→subscribe conversion rate for the game.
	AnalyticsEvents.Post("plus_purchase", {
		userId = userId,
		username = name,
		originExperience = isOriginExperience == true,
	})
end)

print("[PlusService] Initialized — Roblox Plus integration active")
