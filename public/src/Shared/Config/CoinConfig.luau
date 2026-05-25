--[[
	CoinConfig.luau
	Configuration for the Build Coins economy system
	
	Economy based on: roblox_game_economy_plan.pdf
	Core loop: Build → Get Votes → Earn Coins → Unlock Packs → Build Better → Repeat
]]

local CoinConfig = {}

-- ============================================
-- DAILY REWARDS
-- Continuous streak system: streak counter never resets on week complete,
-- only on missed days. Coin amounts scale by week reached.
-- Max possible single-day base reward: 95 coins (day 7 of week 1-2).
-- Week 3+ doubles coin amounts so two-week streaks feel rewarding.
-- If streak breaks (miss StreakExpiryDays consecutive days), streak resets to 0.
-- ============================================
CoinConfig.DailyRewards = {
	-- Per-day-in-week base coin reward. Each entry can be:
	--   number      - fixed amount
	--   {min, max}  - random integer in [min, max]
	Rewards = {
		[1] = 5,            -- fixed teaser
		[2] = { 10, 15 },
		[3] = { 15, 25 },
		[4] = { 25, 40 },
		[5] = { 40, 55 },
		[6] = { 55, 75 },
		[7] = { 70, 95 },
	},
	
	-- Week-based coin multiplier. Final amount = base * multiplier (rounded).
	-- Hitting 2 full weeks of consecutive daily logins is impressive, so week 3+ doubles.
	-- Weeks beyond the table use DefaultLateWeekMultiplier.
	WeekMultipliers = {
		[1] = 1.0,
		[2] = 1.0,
		[3] = 2.0,
	},
	DefaultLateWeekMultiplier = 2.0,
	
	-- Streak expiry: miss this many full calendar days (UTC) and streak resets.
	-- 1 = you must claim every calendar day; skipping a whole UTC day resets the
	-- streak. (Previously 2, which gave ~24-48h of slack depending on claim time
	-- of day - that overlap is removed so it behaves like a true daily streak.)
	StreakExpiryDays = 2,

	-- Roblox Plus daily-reward bonus.
	-- The Rewards table above is the FULL (Plus) payout. Players WITHOUT Plus
	-- earn this fraction of it. 0.65 = non-Plus players get 35% less.
	-- Plus players always get the full amount (multiplier 1.0).
	-- Set to 1.0 to disable the Plus daily bonus entirely.
	NonPlusDailyMultiplier = 0.65,
}

-- ============================================
-- HELPER: Coin multiplier for a given week
-- ============================================
function CoinConfig.GetWeekMultiplier(weekNumber)
	local mult = CoinConfig.DailyRewards.WeekMultipliers[weekNumber]
	if mult then return mult end
	return CoinConfig.DailyRewards.DefaultLateWeekMultiplier or 1.0
end

-- ============================================
-- HELPER: Non-Plus daily multiplier (clamped to a sane range)
-- ============================================
function CoinConfig.GetNonPlusDailyMultiplier()
	local m = CoinConfig.DailyRewards.NonPlusDailyMultiplier
	if type(m) ~= "number" then return 1.0 end
	-- Never below 0, never above 1 (non-Plus should never out-earn Plus).
	return math.clamp(m, 0, 1)
end

-- ============================================
-- HELPER: Roll the coin reward for a given day-in-week and week number
--
-- hasPlus (optional, default true): when false, the final amount is scaled by
-- NonPlusDailyMultiplier so non-Plus players earn less. Defaults to the full
-- (Plus) payout when omitted, so existing callers and the Studio dev-preview
-- path keep showing the headline numbers unless they explicitly opt in.
-- ============================================
function CoinConfig.RollDailyReward(dayInWeek, weekNumber, rng, hasPlus)
	local entry = CoinConfig.DailyRewards.Rewards[dayInWeek]
	if not entry then return 25 end
	
	rng = rng or Random.new()
	local multiplier = CoinConfig.GetWeekMultiplier(weekNumber or 1)
	
	local base
	if type(entry) == "number" then
		base = entry
	else
		base = rng:NextInteger(entry[1], entry[2])
	end
	
	-- Apply the non-Plus reduction only when the caller explicitly says the
	-- player does NOT have Plus. (hasPlus == nil means "full amount".)
	if hasPlus == false then
		multiplier = multiplier * CoinConfig.GetNonPlusDailyMultiplier()
	end
	
	return math.floor(base * multiplier + 0.5)
end

-- ============================================
-- VOTE / LIKE REWARDS
-- ~3 coins per vote, capped per session
-- Milestone bonuses at vote thresholds
-- ============================================
CoinConfig.VoteReward = 3 -- Coins per like received

CoinConfig.VoteSessionCap = 30 -- Max vote coins earnable per session (10 votes worth)

CoinConfig.VoteMilestones = {
	{ threshold = 5,   reward = 25,  label = "5 Votes" },
	{ threshold = 10,  reward = 50,  label = "10 Votes" },
	{ threshold = 20,  reward = 100, label = "20 Votes" },
	{ threshold = 50,  reward = 200, label = "50 Votes" },
	{ threshold = 100, reward = 500, label = "100 Votes" },
}

-- ============================================
-- DAILY OBJECTIVES
-- Reset each day, 3 tiers of difficulty
-- ============================================
CoinConfig.DailyObjectives = {
	Easy = 30,   -- e.g. "Place 50 blocks"
	Medium = 50, -- e.g. "Visit 3 plots"
	Hard = 80,   -- e.g. "Get 5 votes today"
}

-- ============================================
-- ACHIEVEMENTS
-- One-time milestone rewards (50-500 coins)
-- ============================================
CoinConfig.Achievements = {
	{
		id = "likes_received",
		title = "Popular Builder",
		description = "Receive likes on your builds",
		icon = "rbxassetid://0",
		tiers = {
			{ threshold = 5,   reward = 50,   label = "5 Likes" },
			{ threshold = 10,  reward = 100,  label = "10 Likes" },
			{ threshold = 25,  reward = 200,  label = "25 Likes" },
			{ threshold = 50,  reward = 350,  label = "50 Likes" },
			{ threshold = 100, reward = 500,  label = "100 Likes" },
		},
	},
	{
		id = "blocks_placed",
		title = "Master Builder",
		description = "Place blocks in your builds",
		icon = "rbxassetid://0",
		tiers = {
			{ threshold = 100,   reward = 50,   label = "100 Blocks" },
			{ threshold = 500,   reward = 100,  label = "500 Blocks" },
			{ threshold = 1000,  reward = 200,  label = "1,000 Blocks" },
			{ threshold = 5000,  reward = 400,  label = "5,000 Blocks" },
			{ threshold = 10000, reward = 500,  label = "10,000 Blocks" },
		},
	},
	{
		id = "daily_streak",
		title = "Dedicated Player",
		description = "Complete daily reward streaks",
		icon = "rbxassetid://0",
		tiers = {
			{ threshold = 1,  reward = 50,  label = "1 Full Week" },
			{ threshold = 4,  reward = 150, label = "4 Full Weeks" },
			{ threshold = 10, reward = 300, label = "10 Full Weeks" },
			{ threshold = 25, reward = 500, label = "25 Full Weeks" },
		},
	},
	{
		id = "logins",
		title = "Regular",
		description = "Log in to BuildBlox",
		icon = "rbxassetid://0",
		tiers = {
			{ threshold = 7,   reward = 50,  label = "7 Days" },
			{ threshold = 30,  reward = 150, label = "30 Days" },
			{ threshold = 100, reward = 350, label = "100 Days" },
			{ threshold = 365, reward = 500, label = "365 Days" },
		},
	},
}

-- ============================================
-- ROBUX COIN PACKS (Developer Products)
-- Matches economy plan conversion rates
--
-- HOW TO WIRE UP:
--   1. In the Roblox Creator Dashboard, create one Developer Product per pack.
--   2. Set each product's price to the `robux` value below.
--   3. Paste the product's numeric ID into the matching `productId` field.
--   4. Save — the shop will start firing real purchase prompts immediately.
--      ProcessReceipt is wired up in CoinService.server.luau and grants the
--      coins server-side once the player completes the transaction.
--
-- A productId of 0 keeps the pack in "Soon!" mode (click does nothing).
-- ============================================
CoinConfig.CoinPacks = {
	{ id = "pack_small",  coins = 400,  robux = 50,  productId = 3564026297, label = "400 Coins",   bonus = nil },
	{ id = "pack_medium", coins = 900,  robux = 100, productId = 3564026509, label = "900 Coins",   bonus = "12% Bonus" },
	{ id = "pack_large",  coins = 2500, robux = 250, productId = 3564026698, label = "2,500 Coins",  bonus = "25% Bonus" },
	{ id = "pack_mega",   coins = 6000, robux = 500, productId = 3564026912, label = "6,000 Coins",  bonus = "Best Value" },
}

-- ============================================
-- SHOP PACK PRICING
-- What players spend coins on
-- ============================================
CoinConfig.PackPricing = {
	Starter = 300,   -- Simple block packs
	Standard = 500,  -- Most packs (Candy, Nature, Ice, etc.)
	Advanced = 800,  -- Packs with extra mechanics (Futuristic, Mechanical)
}

-- ============================================
-- SAVE SLOT COIN PRICE
-- ============================================
CoinConfig.SaveSlotCoinPrice = 1000

-- ============================================
-- STARTER COINS
-- ============================================
CoinConfig.StarterCoins = 100

-- ============================================
-- COMMUNITY GROUP
-- ============================================
-- Shared between TitleScreen (client check) and CoinService (server verify)
-- so both sides reference the same group + reward amount.
CoinConfig.CommunityGroupId = 618560924
CoinConfig.CommunityJoinReward = 150 -- One-time coin reward for joining the group
CoinConfig.CommunityGroupShareUrl = "https://www.roblox.com/share/g/618560924"

return CoinConfig
