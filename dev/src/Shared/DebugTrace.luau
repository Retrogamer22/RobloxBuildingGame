--[[
	DebugTrace
	-----------------------------------------------------------------------------
	A universal, owner-only, toggleable diagnostic tracer for BuildBlox.

	Purpose:
		Intermittent bugs ("sometimes a block won't place next to a vertical slab",
		"frame blocks won't fill on certain hosts") are hard to reproduce. This
		module lets the OWNER toggle a detailed trace on, perform the action, and
		read back the EXACT decision path the server took - including the precise
		stage where an action was silently rejected and why.

	Design:
		- SERVER AUTHORITY. The owner check uses BetaConfig.OWNER_USER_ID and is
		  re-validated server-side. A non-owner can never enable tracing, even by
		  spoofing remotes.
		- PER-PLAYER ENABLE STATE. Tracing is keyed by player so it never affects
		  anyone else's session or performance.
		- ZERO COST WHEN OFF. Every Trace.* call early-returns the instant tracing
		  is disabled for that player, before any string formatting happens.
		- STREAMS TO CLIENT. Trace lines are buffered server-side and pushed to the
		  owner's client so they can be read and copied IN-GAME (no Studio Output
		  access needed when playtesting on a device).

	Usage (server, inside any handler):
		local DebugTrace = require(ReplicatedStorage.DebugTrace)
		...
		DebugTrace.begin(player, "PLACE", { type = data.BlockType, pos = position })
		...
		if not preset then
			DebugTrace.reject(player, "preset-lookup", "No preset for BlockType", { type = data.BlockType })
			return
		end
		...
		DebugTrace.step(player, "collision", "CanPlace returned", { ok = canPlace, reason = collisionReason })
		...
		DebugTrace.allow(player, "placed", { id = preset.Id })

	The matching DebugTraceService.server.luau wires the remotes and the owner
	toggle; DebugTraceUI.client.luau renders the on-screen button + log panel.
	-----------------------------------------------------------------------------
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

local DebugTrace = {}

-- The single source of truth for "who is allowed to trace".
-- Falls back to game.CreatorId only when OWNER_USER_ID is left at 0.
local OWNER_USER_ID = (BetaConfig.OWNER_USER_ID and BetaConfig.OWNER_USER_ID ~= 0)
	and BetaConfig.OWNER_USER_ID
	or game.CreatorId

DebugTrace.OWNER_USER_ID = OWNER_USER_ID

-- Per-player enable flag. [Player] = true when that player has tracing on.
-- Only ever set true for the owner (enforced in setEnabled / DebugTraceService).
local enabled = {}

-- Per-player current "transaction" id. Each begin() bumps this so a whole
-- place/break/etc. attempt shares one id and reads as one block in the UI.
local txnCounter = {}

-- Server-side push hook. DebugTraceService assigns this so the module stays
-- decoupled from the remote object. signature: function(player, lineString)
DebugTrace._push = nil

-- Master kill switch. If something ever goes wrong you can flip this to false
-- (or hot-edit it) and ALL tracing stops engine-wide, regardless of toggles.
DebugTrace.MASTER_ENABLED = true

----------------------------------------------------------------
-- Owner / enable management
----------------------------------------------------------------

function DebugTrace.isOwner(player)
	return player ~= nil and player.UserId == OWNER_USER_ID
end

function DebugTrace.isEnabled(player)
	if not DebugTrace.MASTER_ENABLED then
		return false
	end
	return player ~= nil and enabled[player] == true
end

-- Enables/disables tracing for a player. Silently refuses non-owners.
-- Returns the resulting boolean state.
function DebugTrace.setEnabled(player, on)
	if not DebugTrace.isOwner(player) then
		return false
	end
	enabled[player] = on and true or nil
	if not enabled[player] then
		txnCounter[player] = nil
	end
	return DebugTrace.isEnabled(player)
end

function DebugTrace.toggle(player)
	if not DebugTrace.isOwner(player) then
		return false
	end
	return DebugTrace.setEnabled(player, not DebugTrace.isEnabled(player))
end

-- Cleanup when a player leaves (call from a PlayerRemoving hook, done in service).
function DebugTrace.cleanup(player)
	enabled[player] = nil
	txnCounter[player] = nil
end

----------------------------------------------------------------
-- Formatting helpers
----------------------------------------------------------------

-- Compactly stringifies a small data table for a trace line. Keeps it to one
-- line; Vector3 / CFrame / Instance get friendly short forms. Not recursive
-- beyond one level on purpose (trace data should be flat & cheap).
local function fmtValue(v)
	local t = typeof(v)
	if t == "Vector3" then
		return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
	elseif t == "CFrame" then
		local p = v.Position
		return string.format("CFrame@(%.1f,%.1f,%.1f)", p.X, p.Y, p.Z)
	elseif t == "Instance" then
		return string.format("%s<%s>", v.Name, v.ClassName)
	elseif t == "boolean" then
		return v and "true" or "false"
	elseif t == "number" then
		-- show ints cleanly, floats with 2 dp
		if math.floor(v) == v then
			return tostring(v)
		end
		return string.format("%.2f", v)
	elseif v == nil then
		return "nil"
	else
		return tostring(v)
	end
end

local function fmtData(data)
	if data == nil then
		return ""
	end
	if typeof(data) ~= "table" then
		return " | " .. fmtValue(data)
	end
	local parts = {}
	-- Sort keys for stable, readable output.
	local keys = {}
	for k in pairs(data) do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	for _, k in ipairs(keys) do
		table.insert(parts, string.format("%s=%s", tostring(k), fmtValue(data[k])))
	end
	if #parts == 0 then
		return ""
	end
	return " | " .. table.concat(parts, " ")
end

-- Tag every line so the owner can filter Studio Output too. Mirrors your
-- existing [BB-*] log-prefix discipline.
local LOG_PREFIX = "[BB-TRACE]"

----------------------------------------------------------------
-- Core emit
----------------------------------------------------------------

-- Internal: build the line, print to Output, and push to the owner's client.
local function emit(player, txnId, kind, stage, msg, data)
	local line = string.format(
		"%s #%d %-7s %-22s %s%s",
		LOG_PREFIX,
		txnId,
		kind,
		stage or "",
		msg or "",
		fmtData(data)
	)

	-- Always echo to server Output (useful in Studio; harmless in production
	-- because we only reach here when the owner has tracing on).
	print(line)

	-- Push to the owner's client log panel if the service wired a pusher.
	if DebugTrace._push then
		-- Guard the push so a UI/remote error can never break gameplay logic.
		pcall(DebugTrace._push, player, line)
	end
end

----------------------------------------------------------------
-- Public trace API
--
-- All of these no-op instantly if tracing is off for the player, so they are
-- safe to leave permanently sprinkled through hot paths.
----------------------------------------------------------------

-- begin: opens a new traced transaction (one place/break/etc. attempt).
-- Returns the txn id (or nil if not tracing) so callers can correlate if they
-- want, though most won't need it.
function DebugTrace.begin(player, kind, data)
	if not DebugTrace.isEnabled(player) then
		return nil
	end
	local id = (txnCounter[player] or 0) + 1
	txnCounter[player] = id
	emit(player, id, "BEGIN", kind or "?", "----------------------------------------", data)
	return id
end

-- step: an informational checkpoint along the path. Use liberally.
function DebugTrace.step(player, stage, msg, data)
	if not DebugTrace.isEnabled(player) then
		return
	end
	emit(player, txnCounter[player] or 0, "step", stage, msg, data)
end

-- reject: the action was refused HERE. This is the line you care about most:
-- it names the exact stage and the reason the block/operation died.
function DebugTrace.reject(player, stage, reason, data)
	if not DebugTrace.isEnabled(player) then
		return
	end
	emit(player, txnCounter[player] or 0, "REJECT", stage, "✗ " .. tostring(reason), data)
end

-- allow: the action succeeded. Closes the transaction on a positive note.
function DebugTrace.allow(player, stage, data)
	if not DebugTrace.isEnabled(player) then
		return
	end
	emit(player, txnCounter[player] or 0, "ALLOW", stage or "done", "✓ success", data)
end

-- warn: something unexpected but non-fatal (e.g., fell back to a default).
function DebugTrace.warn(player, stage, msg, data)
	if not DebugTrace.isEnabled(player) then
		return
	end
	emit(player, txnCounter[player] or 0, "warn", stage, "! " .. tostring(msg), data)
end

return DebugTrace
