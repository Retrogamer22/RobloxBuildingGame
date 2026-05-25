--[[
	PlusManager.luau (Server Module)

	Central authority for Roblox Plus subscription status and BuildBlox's
	Plus-tier discounts. Everything that needs to know whether a player has
	Plus, what discount they get, or how to prompt the sub flow goes through
	this module — server-side.

	Background (as of April 30, 2026): Roblox Plus replaces Roblox Premium.
	Subscribers get 10% off Robux purchases (dev products / gamepasses /
	subscriptions), which jumps to 20% after their third consecutive month.
	Roblox covers that discount themselves — creators still earn the same
	per-item amount. So we DO NOT manually lower Robux prices anywhere; the
	Roblox purchase prompt does it natively.

	What we DO is:
	  1. Detect who has Plus and what tier they're on (10% vs 20%).
	  2. Mirror that tier as a BuildBlox-side discount on BloxCoin purchases.
	     This is fully on us — Roblox doesn't subsidize BloxCoin discounts.
	  3. Expose a single API the rest of the codebase calls instead of
	     scattering Plus-check logic everywhere.

	Discount tier rule (mirrors Roblox's tier):
	  - 10% off for the first 2 months of an active subscription
	  - 20% off from month 3 onward
	  - Resets to 10% if a user cancels and resubscribes (Roblox's behaviour,
	    which GetRobloxSubscriptionDetailsAsync's StartTime reflects)

	Detection API:
	  - Player.HasRobloxSubscription (bool) — fastest check, replicated to client
	  - Player:GetPropertyChangedSignal("HasRobloxSubscription") — fires on
	    mid-session sub changes (e.g. after PromptRobloxSubscriptionPurchase
	    completes successfully)
	  - MarketplaceService:GetRobloxSubscriptionDetailsAsync(player) — yields,
	    returns { IsSubscribed, StartTime (DateTime|nil), IsOriginExperience }.
	    StartTime tells us how long they've been subscribed (for the 20% tier).
	    IsOriginExperience is true iff they subscribed via THIS game — we use
	    that to track in-game-acquired subs.

	Studio testing caveat: as of late April 2026, the in-Studio purchase
	prompt for PromptRobloxSubscriptionPurchase is a known no-op — clicking
	"Subscribe"/"Try it free" does nothing and PromptRobloxSubscriptionPurchaseFinished
	never fires. Detection (HasRobloxSubscription, GetRobloxSubscriptionDetailsAsync)
	works in Studio if you set HasRobloxSubscription via the Studio test UI;
	the live prompt has to be tested in a published place.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local PlusManager = {}

-- ============================================
-- CONFIG
-- ============================================
-- Tier thresholds. Tier 2 (20%) kicks in at the start of the subscriber's
-- 3rd month, matching Roblox's covered Robux discount. We use 60 days as the
-- threshold because Roblox's tier rule is "after two full months" and ~60
-- days approximates that without needing calendar-month arithmetic.
local TIER_2_THRESHOLD_SECONDS = 60 * 24 * 60 * 60  -- ~60 days

local TIER_1_PERCENT = 10  -- First two months
local TIER_2_PERCENT = 20  -- Month 3+

-- ============================================
-- STATE
-- ============================================
-- userId -> {
--     hasPlus: boolean,
--     discountPercent: number (0 if no plus, 10 or 20 otherwise),
--     subStartUnix: number? (unix timestamp from StartTime.UnixTimestamp, or nil),
--     isOriginExperience: boolean (true if they subbed via THIS game),
--     loaded: boolean (true after the first GetRobloxSubscriptionDetailsAsync resolves),
-- }
local PlayerPlus = {}

-- Tracks UserIds we've fired a PromptRobloxSubscriptionPurchase for but haven't
-- yet seen flip to HasRobloxSubscription=true. Used so we only credit a
-- "in-game acquired sub" once when the property change actually lands.
local PendingPrompts = {}

-- Callbacks: array of fn(userId, plusState) where plusState is the table above.
-- Fired on any status change (initial load, mid-session sub, mid-session
-- cancellation, tier upgrade from 10% -> 20%).
local OnStatusChangedCallbacks = {}

-- Callbacks: array of fn(userId, isOriginExperience). Fired only when a
-- player transitions from non-sub to sub via the in-game prompt.
-- Useful hook for analytics — Roblox credits the creator separately.
local OnNewSubscriberCallbacks = {}

-- ============================================
-- HELPERS
-- ============================================
local function defaultEntry()
	return {
		hasPlus = false,
		discountPercent = 0,
		subStartUnix = nil,
		isOriginExperience = false,
		loaded = false,
	}
end

-- Given a sub start timestamp (or nil), figure out which tier they're on.
-- Subscribers without a known StartTime fall back to tier 1 — better to
-- under-credit than to over-credit (we'll re-resolve on the next sync).
local function computeTier(hasPlus: boolean, subStartUnix: number?): number
	if not hasPlus then return 0 end
	if not subStartUnix then return TIER_1_PERCENT end
	local age = os.time() - subStartUnix
	if age >= TIER_2_THRESHOLD_SECONDS then
		return TIER_2_PERCENT
	end
	return TIER_1_PERCENT
end

local function fireStatusChanged(userId: number)
	local state = PlayerPlus[userId]
	if not state then return end
	for _, callback in ipairs(OnStatusChangedCallbacks) do
		task.spawn(callback, userId, state)
	end
end

-- ============================================
-- SUBSCRIPTION DETAIL SYNC
-- ============================================
-- Pulls the full GetRobloxSubscriptionDetailsAsync payload and writes the
-- result into PlayerPlus[userId]. Safe to call repeatedly. Yields.
local function syncDetails(player: Player)
	if not player or not player.Parent then return end
	local userId = player.UserId
	local entry = PlayerPlus[userId]
	if not entry then
		entry = defaultEntry()
		PlayerPlus[userId] = entry
	end

	-- Fast path from the replicated property. This is set immediately on
	-- PlayerAdded (Roblox does the heavy lifting before our script runs).
	local fastHasPlus = player.HasRobloxSubscription == true

	-- Slow path for the StartTime / IsOriginExperience fields. The fast bool
	-- is enough to award the discount; the details just refine the tier %.
	local ok, details = pcall(function()
		return MarketplaceService:GetRobloxSubscriptionDetailsAsync(player)
	end)

	local hasPlus, subStartUnix, isOriginExperience
	if ok and details then
		hasPlus = details.IsSubscribed == true
		if details.StartTime then
			-- StartTime is a DateTime; .UnixTimestamp is seconds since epoch.
			subStartUnix = details.StartTime.UnixTimestamp
		end
		isOriginExperience = details.IsOriginExperience == true
	else
		-- API failed (rare — usually means the user isn't subscribed and
		-- Roblox returned a sparse table, or we hit a transient error).
		-- Fall back to the fast property and assume tier 1.
		hasPlus = fastHasPlus
		subStartUnix = nil
		isOriginExperience = false
		if not ok then
			warn(string.format("[PlusManager] GetRobloxSubscriptionDetailsAsync failed for %d: %s",
				userId, tostring(details)))
		end
	end

	local prevHasPlus = entry.hasPlus
	local prevDiscount = entry.discountPercent

	entry.hasPlus = hasPlus
	entry.subStartUnix = subStartUnix
	entry.isOriginExperience = isOriginExperience
	entry.discountPercent = computeTier(hasPlus, subStartUnix)
	entry.loaded = true

	-- Detect "new in-game subscriber" transitions: was-not, now-is, and
	-- IsOriginExperience true (or we have a pending prompt for them).
	-- Pending-prompt flag covers a race where IsOriginExperience hasn't
	-- propagated yet but we know we just prompted them.
	if hasPlus and not prevHasPlus then
		local credited = isOriginExperience or PendingPrompts[userId] == true
		PendingPrompts[userId] = nil
		if credited then
			for _, callback in ipairs(OnNewSubscriberCallbacks) do
				task.spawn(callback, userId, isOriginExperience)
			end
		end
		print(string.format("[PlusManager] %s subscribed to Plus (tier=%d%%, originExperience=%s)",
			player.Name, entry.discountPercent, tostring(isOriginExperience)))
	elseif not hasPlus and prevHasPlus then
		print(string.format("[PlusManager] %s no longer has Plus", player.Name))
	elseif hasPlus and prevDiscount ~= entry.discountPercent then
		print(string.format("[PlusManager] %s tier change: %d%% -> %d%%",
			player.Name, prevDiscount, entry.discountPercent))
	end

	fireStatusChanged(userId)
end

-- ============================================
-- TIER REFRESH (background)
-- ============================================
-- Subscriber tier flips from 10% to 20% during a session if a player crosses
-- their 60-day anniversary while playing. Catch that without needing the
-- HasRobloxSubscription event to fire — we just recompute periodically.
-- Cheap: it's local-only, no API call.
task.spawn(function()
	while true do
		task.wait(60 * 30)  -- every 30 minutes
		for userId, entry in pairs(PlayerPlus) do
			if entry.hasPlus and entry.subStartUnix then
				local newTier = computeTier(true, entry.subStartUnix)
				if newTier ~= entry.discountPercent then
					local prev = entry.discountPercent
					entry.discountPercent = newTier
					local player = Players:GetPlayerByUserId(userId)
					if player then
						print(string.format("[PlusManager] %s tier upgrade in-session: %d%% -> %d%%",
							player.Name, prev, newTier))
					end
					fireStatusChanged(userId)
				end
			end
		end
	end
end)

-- ============================================
-- PLAYER LIFECYCLE
-- ============================================
function PlusManager.OnPlayerAdded(player: Player)
	if not player or not player.Parent then return end
	PlayerPlus[player.UserId] = defaultEntry()

	-- Run the initial detail sync in the background. We don't block PlayerAdded
	-- waiting for it — anything that needs Plus status before sync completes
	-- can use the HasRobloxSubscription fast-path via PlusManager.HasPlus.
	task.spawn(function()
		syncDetails(player)
	end)

	-- React to mid-session subscription changes. This fires for both
	-- subscribe (false -> true) and unsubscribe (true -> false).
	player:GetPropertyChangedSignal("HasRobloxSubscription"):Connect(function()
		-- Re-resolve details. Note: IsOriginExperience and StartTime may not
		-- be available immediately on the first event right after a successful
		-- prompt — Roblox sometimes flips the property before the details
		-- service catches up. syncDetails handles that gracefully.
		task.spawn(function()
			-- Small delay lets Roblox's details service catch up. Empirically
			-- syncing too eagerly returns a stale IsOriginExperience=false even
			-- when the user just subbed via our prompt.
			task.wait(1)
			syncDetails(player)
		end)
	end)
end

function PlusManager.OnPlayerRemoving(player: Player)
	if not player then return end
	PlayerPlus[player.UserId] = nil
	PendingPrompts[player.UserId] = nil
end

-- ============================================
-- PUBLIC API
-- ============================================

-- Lightweight bool check. Uses cached state, doesn't yield.
function PlusManager.HasPlus(userId: number): boolean
	local entry = PlayerPlus[userId]
	if not entry then return false end
	return entry.hasPlus == true
end

-- Returns 0 (no plus), 10 (tier 1), or 20 (tier 2).
function PlusManager.GetDiscountPercent(userId: number): number
	local entry = PlayerPlus[userId]
	if not entry then return 0 end
	return entry.discountPercent
end

-- Applies the BloxCoin discount tier to a base price. Returns the price the
-- player should actually be charged. Always rounds DOWN (player-friendly) so
-- a 100-coin item with 10% off costs 90, not 91.
--
-- CALLERS: use this on the SERVER before invoking CoinManager.SpendCoins. The
-- client-side mirror lives in PlusController.GetDiscountedPrice for display.
--
-- DO NOT apply this to Robux dev product / gamepass prices — those discounts
-- are owned by Roblox at the purchase-prompt level. For Robux display
-- preview, use MarketplaceService:GetProductInfoAsync's PriceInRobux field.
function PlusManager.GetDiscountedPrice(userId: number, basePrice: number): number
	local percent = PlusManager.GetDiscountPercent(userId)
	if percent <= 0 then return basePrice end
	local discounted = basePrice * (100 - percent) / 100
	return math.floor(discounted)
end

-- Returns the full state table (read-only — callers must not mutate).
-- Useful for the GetPlusStatus remote which needs the whole payload.
function PlusManager.GetStatus(userId: number)
	local entry = PlayerPlus[userId]
	if not entry then return defaultEntry() end
	return {
		hasPlus = entry.hasPlus,
		discountPercent = entry.discountPercent,
		subStartUnix = entry.subStartUnix,
		isOriginExperience = entry.isOriginExperience,
		loaded = entry.loaded,
	}
end

-- ============================================
-- PROMPT
-- ============================================
-- Trigger the in-game Plus subscription prompt for a player. If they subscribe
-- via this prompt, Roblox credits the creator 250 R$/month for 3 months (up
-- to 750 R$ total per subscriber). We also fire OnNewSubscriber callbacks for
-- in-game analytics/celebration.
function PlusManager.Prompt(player: Player)
	if not player or not player.Parent then return end

	-- Mark them as having been prompted by us. Used to credit in-game acquisition
	-- if Roblox's IsOriginExperience flag hasn't propagated by the time
	-- HasRobloxSubscription flips.
	PendingPrompts[player.UserId] = true
	-- Auto-clear after 5 minutes — if they didn't subscribe, the next sub
	-- they ever do shouldn't get falsely credited to this game.
	task.delay(300, function()
		PendingPrompts[player.UserId] = nil
	end)

	local ok, err = pcall(function()
		MarketplaceService:PromptRobloxSubscriptionPurchase(player)
	end)
	if not ok then
		warn(string.format("[PlusManager] PromptRobloxSubscriptionPurchase failed for %s: %s",
			player.Name, tostring(err)))
		PendingPrompts[player.UserId] = nil
	end
end

-- ============================================
-- PROMPT FINISHED EVENT
-- ============================================
-- Roblox fires this event when the purchase prompt closes. didTryPurchasing
-- means "user clicked subscribe/try-free" — it does NOT mean the sub
-- succeeded. The real source of truth is the HasRobloxSubscription property,
-- which we already listen to via GetPropertyChangedSignal above. We mostly
-- use this event for telemetry / closing any "loading…" client UI.
MarketplaceService.PromptRobloxSubscriptionPurchaseFinished:Connect(function(player, didTryPurchasing)
	if not player then return end
	if didTryPurchasing then
		print(string.format("[PlusManager] %s attempted Plus subscription", player.Name))
		-- Force a sync ~3s later in case HasRobloxSubscription doesn't flip
		-- on its own (it usually does, but belt-and-suspenders).
		task.delay(3, function()
			syncDetails(player)
		end)
	else
		print(string.format("[PlusManager] %s closed Plus prompt without subscribing", player.Name))
		PendingPrompts[player.UserId] = nil
	end
end)

-- ============================================
-- CALLBACK REGISTRATION
-- ============================================
function PlusManager.OnStatusChanged(callback)
	table.insert(OnStatusChangedCallbacks, callback)
end

function PlusManager.OnNewSubscriber(callback)
	table.insert(OnNewSubscriberCallbacks, callback)
end

print("[PlusManager] Module loaded")

return PlusManager
