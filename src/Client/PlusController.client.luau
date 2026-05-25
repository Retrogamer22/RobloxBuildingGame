--[[
	PlusController.client.luau

	Client-side Roblox Plus state. Single source of truth for any UI that
	wants to ask "does this player have Plus?" or "what's their discount?".

	Exposes _G.PlusController:
	  - IsSubscribed()              → boolean
	  - GetDiscountPercent()        → 0 | 10 | 20
	  - GetDiscountedPrice(base)    → integer (BloxCoin price after discount)
	  - GetSubStartUnix()           → number? (unix timestamp, nil if not subbed)
	  - IsOriginExperience()        → boolean (true if subbed via THIS game)
	  - IsLoaded()                  → boolean (true once first sync arrives)
	  - OnChanged(fn)               → connection ({Disconnect = fn}); fn receives a status table
	  - PromptPurchase()            → fires server remote to trigger Roblox sub prompt
	  - GetStatus()                 → full status table (read-only)

	Status table shape (mirrors PlusManager.GetStatus on the server):
	  { hasPlus, discountPercent, subStartUnix, isOriginExperience, loaded }

	IMPORTANT: this controller is for DISPLAY logic only. Server is the
	authority on whether a player actually has Plus / how much they're charged.
	Never gate gameplay rewards on the client-side _G.PlusController value.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local LOG_PREFIX = "[BB-PLUS]"

-- ============================================
-- DEBUG
-- ============================================
-- Force a Plus state for testing ACROSS ALL Plus UIs (panel, title-screen
-- perks card, top-bar icon) from this ONE switch. Options:
--   nil     → normal (use real server status)
--   "none"  → not subscribed
--   "tier1" → subscribed, 10%
--   "tier2" → subscribed, 20%
-- SET BACK TO nil BEFORE SHIPPING.
local DEBUG_FORCE_STATE = "none"

local function debugStatus()
	if DEBUG_FORCE_STATE == "none" then
		return { hasPlus = false, discountPercent = 0, subStartUnix = nil, isOriginExperience = false, loaded = true }
	elseif DEBUG_FORCE_STATE == "tier1" then
		return { hasPlus = true, discountPercent = 10, subStartUnix = os.time() - 5 * 86400, isOriginExperience = false, loaded = true }
	elseif DEBUG_FORCE_STATE == "tier2" then
		return { hasPlus = true, discountPercent = 20, subStartUnix = os.time() - 90 * 86400, isOriginExperience = false, loaded = true }
	end
	return nil
end

-- ============================================
-- REMOTES
-- ============================================
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
local GetPlusStatus = Remotes:WaitForChild("GetPlusStatus", 15)
local PlusStatusChanged = Remotes:WaitForChild("PlusStatusChanged", 15)
local PromptPlusPurchase = Remotes:WaitForChild("PromptPlusPurchase", 15)
local PlusUIOpened = Remotes:WaitForChild("PlusUIOpened", 15)

-- ============================================
-- STATE
-- ============================================
local currentStatus = {
	hasPlus = false,
	discountPercent = 0,
	subStartUnix = nil,
	isOriginExperience = false,
	loaded = false,
}

local listeners = {}  -- array of fn(status)

-- Effective status = forced debug state if set, else the real synced status.
-- All public getters read through this so one DEBUG switch drives every UI.
local function eff()
	return debugStatus() or currentStatus
end

local function fireListeners()
	for _, fn in ipairs(listeners) do
		task.spawn(fn, currentStatus)
	end
end

local function applyStatus(newStatus)
	if type(newStatus) ~= "table" then return end
	currentStatus = {
		hasPlus = newStatus.hasPlus == true,
		discountPercent = tonumber(newStatus.discountPercent) or 0,
		subStartUnix = newStatus.subStartUnix,
		isOriginExperience = newStatus.isOriginExperience == true,
		loaded = newStatus.loaded == true,
	}
	fireListeners()
end

-- ============================================
-- PUBLIC API
-- ============================================
local PlusController = {}

function PlusController.IsSubscribed(): boolean
	return eff().hasPlus
end

function PlusController.GetDiscountPercent(): number
	return eff().discountPercent
end

-- Mirror of PlusManager.GetDiscountedPrice (server-side). Both round DOWN
-- the same way so the displayed price matches what the server will charge.
function PlusController.GetDiscountedPrice(basePrice: number): number
	local percent = eff().discountPercent
	if percent <= 0 then return basePrice end
	return math.floor(basePrice * (100 - percent) / 100)
end

function PlusController.GetSubStartUnix(): number?
	return eff().subStartUnix
end

function PlusController.IsOriginExperience(): boolean
	return eff().isOriginExperience
end

function PlusController.IsLoaded(): boolean
	return eff().loaded
end

function PlusController.GetStatus()
	-- Defensive copy so callers can't accidentally mutate our state table.
	local s = eff()
	return {
		hasPlus = s.hasPlus,
		discountPercent = s.discountPercent,
		subStartUnix = s.subStartUnix,
		isOriginExperience = s.isOriginExperience,
		loaded = s.loaded,
	}
end

-- Register a listener. Returns an object with :Disconnect() so callers can
-- clean up without keeping a stable function reference (matches typical
-- RBXScriptConnection ergonomics).
function PlusController.OnChanged(fn)
	if type(fn) ~= "function" then return end
	table.insert(listeners, fn)
	return {
		Disconnect = function()
			for i, listener in ipairs(listeners) do
				if listener == fn then
					table.remove(listeners, i)
					return
				end
			end
		end,
	}
end

function PlusController.PromptPurchase()
	PromptPlusPurchase:FireServer()
end

-- Tell the server PlusUI was opened (for funnel analytics only — the server
-- throttles + sanitizes this). `source` is an optional short string hint of
-- where it was opened from, e.g. "hud_button" or "title_screen".
function PlusController.ReportOpened(source: string?)
	if PlusUIOpened then
		PlusUIOpened:FireServer(source)
	end
end

_G.PlusController = PlusController

-- ============================================
-- SERVER PUSH HANDLER
-- ============================================
PlusStatusChanged.OnClientEvent:Connect(function(newStatus)
	applyStatus(newStatus)
	print(string.format("%s status updated: hasPlus=%s percent=%d origin=%s loaded=%s",
		LOG_PREFIX,
		tostring(currentStatus.hasPlus),
		currentStatus.discountPercent,
		tostring(currentStatus.isOriginExperience),
		tostring(currentStatus.loaded)))
end)

-- ============================================
-- INITIAL FETCH
-- ============================================
-- Server pushes status ~1s after PlayerAdded, but other scripts may query us
-- immediately on startup. Issue our own request to close that gap.
task.spawn(function()
	-- Wait a brief moment for the server's PlayerAdded handler to run so
	-- our query doesn't return a stale defaultEntry().
	task.wait(0.5)
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return GetPlusStatus:InvokeServer()
		end)
		if ok and result then
			applyStatus(result)
			if result.loaded then break end
		end
		task.wait(2)
	end
end)

print(LOG_PREFIX, "Loaded — _G.PlusController ready")
