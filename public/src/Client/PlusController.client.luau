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
	  - PromptPurchase()            → opens Roblox Plus subscription prompt
	  - ReportOpened(source)        → reports Plus UI opens to the server
	  - GetStatus()                 → full status table copy

	Status table shape, mirrored from the server:
	  { hasPlus, discountPercent, subStartUnix, isOriginExperience, loaded }

	IMPORTANT:
	This controller is for DISPLAY logic only. Server is the authority on whether
	a player actually has Plus / how much they're charged. Never gate gameplay
	rewards only on this client-side value.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local LOG_PREFIX = "[BB-PLUS]"

-- ============================================
-- DEBUG
-- ============================================
-- Force a Plus state for testing ACROSS ALL Plus UIs.
--
-- Options:
--   nil     → normal, use real server status
--   "none"  → force not subscribed
--   "tier1" → force subscribed, 10%
--   "tier2" → force subscribed, 20%
--
-- Leave this as nil before shipping, unless you enjoy lying to yourself.
local DEBUG_FORCE_STATE = nil

local function debugStatus()
	if DEBUG_FORCE_STATE == "none" then
		return {
			hasPlus = false,
			discountPercent = 0,
			subStartUnix = nil,
			isOriginExperience = false,
			loaded = true,
		}
	elseif DEBUG_FORCE_STATE == "tier1" then
		return {
			hasPlus = true,
			discountPercent = 10,
			subStartUnix = os.time() - 5 * 86400,
			isOriginExperience = false,
			loaded = true,
		}
	elseif DEBUG_FORCE_STATE == "tier2" then
		return {
			hasPlus = true,
			discountPercent = 20,
			subStartUnix = os.time() - 90 * 86400,
			isOriginExperience = false,
			loaded = true,
		}
	end

	return nil
end

-- ============================================
-- REMOTES
-- ============================================
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)

local function waitRemote(name: string)
	if not Remotes then
		warn(LOG_PREFIX, "Remotes folder missing; could not load remote:", name)
		return nil
	end

	local remote = Remotes:WaitForChild(name, 15)

	if not remote then
		warn(LOG_PREFIX, "Missing remote:", name)
	end

	return remote
end

local GetPlusStatus = waitRemote("GetPlusStatus")
local PlusStatusChanged = waitRemote("PlusStatusChanged")
local PlusUIOpened = waitRemote("PlusUIOpened")

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

local listeners = {}

local function effectiveStatus()
	return debugStatus() or currentStatus
end

local function copyStatus(status)
	return {
		hasPlus = status.hasPlus == true,
		discountPercent = tonumber(status.discountPercent) or 0,
		subStartUnix = status.subStartUnix,
		isOriginExperience = status.isOriginExperience == true,
		loaded = status.loaded == true,
	}
end

local function getStatusCopy()
	return copyStatus(effectiveStatus())
end

local function fireListeners()
	local statusCopy = getStatusCopy()

	for _, fn in ipairs(listeners) do
		task.spawn(fn, statusCopy)
	end
end

local function applyStatus(newStatus)
	if type(newStatus) ~= "table" then
		warn(LOG_PREFIX, "Ignored invalid Plus status:", newStatus)
		return
	end

	currentStatus = copyStatus(newStatus)
	fireListeners()
end

local function requestStatus(reason: string?)
	if not GetPlusStatus then
		warn(LOG_PREFIX, "Cannot request Plus status; GetPlusStatus remote missing")
		return false
	end

	local ok, result = pcall(function()
		return GetPlusStatus:InvokeServer()
	end)

	if ok and type(result) == "table" then
		applyStatus(result)

		print(string.format(
			"%s status fetched%s: hasPlus=%s percent=%d origin=%s loaded=%s",
			LOG_PREFIX,
			reason and (" after " .. reason) or "",
			tostring(currentStatus.hasPlus),
			currentStatus.discountPercent,
			tostring(currentStatus.isOriginExperience),
			tostring(currentStatus.loaded)
			))

		return true
	end

	warn(LOG_PREFIX, "Failed to fetch Plus status:", result)
	return false
end

-- ============================================
-- PUBLIC API
-- ============================================
local PlusController = {}

function PlusController.IsSubscribed(): boolean
	return effectiveStatus().hasPlus == true
end

function PlusController.GetDiscountPercent(): number
	return tonumber(effectiveStatus().discountPercent) or 0
end

function PlusController.GetDiscountedPrice(basePrice: number): number
	local percent = PlusController.GetDiscountPercent()

	if percent <= 0 then
		return basePrice
	end

	return math.floor(basePrice * (100 - percent) / 100)
end

function PlusController.GetSubStartUnix(): number?
	return effectiveStatus().subStartUnix
end

function PlusController.IsOriginExperience(): boolean
	return effectiveStatus().isOriginExperience == true
end

function PlusController.IsLoaded(): boolean
	return effectiveStatus().loaded == true
end

function PlusController.GetStatus()
	return getStatusCopy()
end

function PlusController.OnChanged(fn)
	if type(fn) ~= "function" then
		warn(LOG_PREFIX, "OnChanged expected a function")
		return nil
	end

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
	print(LOG_PREFIX, "Prompting Roblox Plus purchase")

	local ok, err = pcall(function()
		MarketplaceService:PromptRobloxSubscriptionPurchase(LocalPlayer)
	end)

	if not ok then
		warn(LOG_PREFIX, "Failed to prompt Roblox Plus:", err)
		return false
	end

	return true
end

function PlusController.ReportOpened(source: string?)
	if not PlusUIOpened then
		warn(LOG_PREFIX, "Cannot report Plus UI opened; PlusUIOpened remote missing")
		return
	end

	PlusUIOpened:FireServer(source)
end

function PlusController.RefreshStatus(reason: string?)
	return requestStatus(reason or "manual refresh")
end

_G.PlusController = PlusController

-- ============================================
-- SERVER PUSH HANDLER
-- ============================================
if PlusStatusChanged then
	PlusStatusChanged.OnClientEvent:Connect(function(newStatus)
		applyStatus(newStatus)

		print(string.format(
			"%s status updated: hasPlus=%s percent=%d origin=%s loaded=%s",
			LOG_PREFIX,
			tostring(currentStatus.hasPlus),
			currentStatus.discountPercent,
			tostring(currentStatus.isOriginExperience),
			tostring(currentStatus.loaded)
			))
	end)
else
	warn(LOG_PREFIX, "PlusStatusChanged remote missing; live Plus updates disabled")
end

-- ============================================
-- ROBLOX PLUS PROMPT FINISHED HANDLER
-- ============================================
-- This fires when the Roblox Plus prompt closes. It does NOT prove the user
-- successfully subscribed, so we ask the server for the real status afterward.
if MarketplaceService.PromptRobloxSubscriptionPurchaseFinished then
	MarketplaceService.PromptRobloxSubscriptionPurchaseFinished:Connect(function(player, didTryPurchasing)
		if player ~= LocalPlayer then
			return
		end

		print(LOG_PREFIX, "Roblox Plus prompt closed. didTryPurchasing =", didTryPurchasing)

		task.delay(1, function()
			requestStatus("Roblox Plus prompt close")
		end)

		task.delay(4, function()
			requestStatus("Roblox Plus delayed recheck")
		end)
	end)
end

-- ============================================
-- INITIAL FETCH
-- ============================================
task.spawn(function()
	task.wait(0.5)

	for attempt = 1, 3 do
		local ok = requestStatus("initial fetch attempt " .. tostring(attempt))

		if ok and currentStatus.loaded then
			break
		end

		task.wait(2)
	end
end)

print(LOG_PREFIX, "Loaded — _G.PlusController ready")