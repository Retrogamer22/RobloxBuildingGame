--[[
	DailyRewardLootConfig.luau
	Loot table configuration for daily rewards.
	
	Each day the player gets either COINS or a REWARD SET (never both).
	Streak doesn't reset on week 7 completion - it keeps counting up as long
	as the player logs in daily. Only missing days (StreakExpiryDays) breaks it.
	
	Week 1 uses a backloaded ramp so the first week feels safe-then-exciting.
	Week 2+ flattens out at a baseline rate so daily players have a steady drip.
]]

local DailyRewardLootConfig = {}

-- ============================================
-- SET DROP CHANCE BY WEEK AND DAY-IN-WEEK
-- ============================================
-- Indexed by week number, then by day-in-week (1-7).
-- Weeks not listed fall back to DefaultLateWeekChance below.
-- To tweak per-week chances (e.g. give a specific week its own curve), add a
-- new entry to this table.
DailyRewardLootConfig.SetChanceByWeek = {
	-- Week 1: backloaded - first TWO days are always coins, drama builds toward day 7
	[1] = { 0.00, 0.00, 0.025, 0.05, 0.075, 0.10, 0.15 },
	-- Week 2: flat baseline - the climb stops feeling rare
	[2] = { 0.075, 0.075, 0.075, 0.075, 0.075, 0.075, 0.075 },
}

-- Fallback for weeks beyond what's listed above (week 3, 4, 5, ... all use this)
DailyRewardLootConfig.DefaultLateWeekChance = 0.075

-- HARD CEILING on set drop chance. Even if a config entry above is set higher
-- (intentionally or by mistake), GetSetChance will never return more than this.
-- 0.75 = 75%. Coins must always remain at least a 1-in-4 outcome.
DailyRewardLootConfig.MaxSetChance = 0.75

-- Roblox Plus set-drop bonus. Added on top of the base day/week chance for
-- players who have Plus, giving them slightly better odds of a reward set.
-- 0.05 = +5 percentage points. Only applied AFTER day 3 in the week (days 4-7),
-- and only to days that ALREADY have a non-zero base chance (so Week 1's
-- always-coins opening days stay 0% even for Plus users). Clamped under MaxSetChance.
DailyRewardLootConfig.PlusSetChanceBonus = 0.05

-- The Plus set-drop bonus only kicks in once the player is past this day-in-week.
-- 3 = bonus applies on days 4, 5, 6, 7 of each week; days 1-3 use base odds.
DailyRewardLootConfig.PlusSetBonusAfterDay = 3

-- ============================================
-- HELPER: Set chance for a given day in a given week
-- hasPlus (optional): when true, adds PlusSetChanceBonus to days that are both
-- past PlusSetBonusAfterDay AND already have a non-zero base chance. Omit (or
-- false) for the standard non-Plus odds. Always clamped to [0, MaxSetChance].
-- ============================================
function DailyRewardLootConfig.GetSetChance(dayInWeek, weekNumber, hasPlus)
	weekNumber = weekNumber or 1
	local raw
	local weekTable = DailyRewardLootConfig.SetChanceByWeek[weekNumber]
	if weekTable then
		raw = weekTable[dayInWeek] or 0
	else
		raw = DailyRewardLootConfig.DefaultLateWeekChance or 0
	end

	-- Plus bonus: only after day 3 in the week, and only on days that can
	-- already drop a set (raw > 0) so the intentional always-coins days stay
	-- always-coins for everyone.
	local afterDay = DailyRewardLootConfig.PlusSetBonusAfterDay or 0
	if hasPlus == true and raw > 0 and dayInWeek > afterDay then
		raw = raw + (DailyRewardLootConfig.PlusSetChanceBonus or 0)
	end

	local ceiling = DailyRewardLootConfig.MaxSetChance or 0.75
	return math.max(0, math.min(raw, ceiling))
end

return DailyRewardLootConfig
