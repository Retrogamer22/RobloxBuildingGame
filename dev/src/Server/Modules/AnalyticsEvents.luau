--[[
	AnalyticsEvents (Server Module)

	One small, shared place to POST a single typed analytics event to the
	BuildBlox Cloudflare Worker. Extracted so that any server script can fire a
	one-off event without re-implementing the HttpService + IngestToken + target
	boilerplate that previously lived only inside AnalyticsReporter.

	Usage:
		local AnalyticsEvents = require(ServerScriptService.Modules.AnalyticsEvents)
		AnalyticsEvents.Post("plus_tap", {
			userId = player.UserId,
			username = player.Name,
			source = "hud_button",
		})

	Post() is fire-and-forget and fully pcall-guarded — it spawns its own task,
	never yields the caller, and never errors out into gameplay code. It posts to
	the same WorkerUrl .. "/events" endpoint that join/leave events use, so the
	Worker receives every event through one ingest path. The Worker is expected
	to switch on the `type` field; unknown types should be ignored Worker-side.

	The module auto-fills serverId, target, and timestamp on every event so
	callers only supply the event-specific fields. Any fields the caller passes
	are merged in (and win over nothing — type/serverId/target/timestamp are set
	last so callers can't accidentally clobber them).

	IMPORTANT: HttpService:RequestAsync must be enabled in Game Settings ->
	Security -> "Allow HTTP Requests", same as AnalyticsReporter. Without it,
	every Post() silently no-ops (pcall'd).

	Log prefix: [BB-ANALYTICS-EVT]
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnalyticsConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AnalyticsConfig"))

local AnalyticsEvents = {}

local LOG = "[BB-ANALYTICS-EVT]"

-- Resolve prod/dev exactly the way AnalyticsReporter does, so events from this
-- module land in the same universe bucket as join/leave/heartbeat.
local function resolveTarget()
	local target = AnalyticsConfig.UniverseTargets[game.GameId]
	if target then return target end
	return AnalyticsConfig.DefaultTarget
end

local TARGET = resolveTarget()
local SERVER_ID = game.JobId ~= "" and game.JobId or "studio-" .. tostring(os.time())

-- Low-level POST. Mirrors AnalyticsReporter.postJson so behavior (headers,
-- token, error logging) is identical. Returns ok, body|errorReason.
local function postJson(path, body)
	local url = AnalyticsConfig.WorkerUrl .. path

	local payload
	local encodeOk, encodeErr = pcall(function()
		payload = HttpService:JSONEncode(body)
	end)
	if not encodeOk then
		warn(string.format("%s JSON encode failed: %s", LOG, tostring(encodeErr)))
		return false, "encode failed"
	end

	local requestOk, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["X-Ingest-Token"] = AnalyticsConfig.IngestToken,
			},
			Body = payload,
		})
	end)

	if not requestOk then
		warn(string.format("%s POST %s failed: %s", LOG, path, tostring(response)))
		return false, tostring(response)
	end

	if not response.Success then
		warn(string.format("%s POST %s -> HTTP %d: %s",
			LOG, path, response.StatusCode, tostring(response.Body):sub(1, 200)))
		return false, response.StatusCode
	end

	if AnalyticsConfig.Debug then
		print(string.format("%s POST %s OK (%d)", LOG, path, response.StatusCode))
	end

	return true, response.Body
end

-- Public: fire a single typed event. Fire-and-forget; never yields the caller.
--   eventType : string  (e.g. "plus_tap", "plus_purchase")
--   fields    : table?  (event-specific fields; merged into the payload)
function AnalyticsEvents.Post(eventType: string, fields: { [string]: any }?)
	if type(eventType) ~= "string" or eventType == "" then
		warn(string.format("%s Post called with invalid eventType", LOG))
		return
	end

	-- Build the payload from caller fields, then stamp the standard fields
	-- LAST so they always reflect reality and can't be spoofed by the caller.
	local body = {}
	if type(fields) == "table" then
		for k, v in pairs(fields) do
			body[k] = v
		end
	end
	body.type = eventType
	body.serverId = SERVER_ID
	body.target = TARGET
	body.timestamp = os.time()

	task.spawn(function()
		local ok = postJson("/events", body)
		if ok and AnalyticsConfig.Debug then
			print(string.format("%s sent '%s'", LOG, eventType))
		end
	end)
end

print(string.format("%s Ready | target=%s | serverId=%s", LOG, TARGET, SERVER_ID:sub(1, 8)))

return AnalyticsEvents
