--!strict
-- DevBlockRotator.client.luau
-- Studio-only dev tool for finding the correct rotation offsets for misoriented
-- templates (arch corners, future shop blocks, etc.) by trial-and-error in-game.
--
-- Usage:
--   1. Aim your mouse at a placed block (e.g., a filled arch inner corner).
--   2. Type a command in chat. The first command "locks" that block as the target.
--   3. Keep typing commands. Each one rotates the locked target by 90° on the
--      named axis. The cumulative offset is printed after each command.
--   4. When the block LOOKS RIGHT, copy the printed CFrame.Angles line and paste
--      it into the placement code (or send it to me to bake in).
--   5. Use /rclear to release the target and pick a different block.
--
-- Commands (90° is the default step; finer increments for tuning):
--   /rx+   /rx-     rotate target around X axis by ±90°
--   /ry+   /ry-     rotate target around Y axis by ±90°
--   /rz+   /rz-     rotate target around Z axis by ±90°
--   /rx+45 /rx-45   ±45° step on X (same suffixes work for Y, Z)
--   /rx+15 /rx-15   ±15° step on X
--   /rx+5  /rx-5    ±5°  step on X (fine tuning)
--   /rx 30          rotate X by an arbitrary signed integer (e.g. /rx -25, /ry 137)
--   /rreset         restore target to its original CFrame (offsets back to 0)
--   /rclear         release the current target; next rotate command grabs new one
--   /rprint         print the current cumulative offset without rotating
--   /rhelp          print this command list
--
-- NOTE: This is CLIENT-SIDE only. Rotations are visual on your screen only —
--       the server still has the block at its original CFrame. This is fine for
--       finding the right offset; once we bake it into placement code, the
--       server will produce the correct orientation on its own.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local LOG = "[BLOCK-ROT]"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
-- We compose rotations multiplicatively as the user issues them, in the EXACT
-- order they're pressed. This is what `block.CFrame * CFrame.Angles(...)` would
-- do at bake time -- the offset is applied in the block's LOCAL frame, after
-- whatever rotation it already had.
--
-- Why not rebuild from cumulative degrees each call?  Because CFrame.Angles(rx,ry,rz)
-- composes its three inputs in a fixed XYZ order. If the user did /ry+ then /rx+,
-- rebuilding as Angles(90,90,0) would silently do X-THEN-Y, a different rotation.
local target: Instance? = nil
local originalCFrame: CFrame? = nil
local accumRotation: CFrame = CFrame.identity
local history: {{axis: string, degrees: number}} = {}

-- ---------------------------------------------------------------------------
-- Target acquisition
-- ---------------------------------------------------------------------------
-- Walk up the ancestor chain from the moused-over part to find the actual
-- block (Model with pivot, or root Part). Block placements live under a
-- "Blocks" folder under each plot.
local function findBlockFromPart(part: Instance?): Instance?
	if not part then return nil end
	local node: Instance? = part
	while node and node.Parent do
		-- Block attributes added at placement time
		if node:GetAttribute("BlockType") or node:GetAttribute("BlockId")
			or node:GetAttribute("BlockPosX") then
			return node
		end
		-- Plot blocks folder
		if node.Parent.Name == "Blocks" then
			return node
		end
		node = node.Parent
	end
	return part  -- fallback: just use whatever we hit
end

local function getCurrentCFrame(inst: Instance): CFrame
	if inst:IsA("Model") then
		return inst:GetPivot()
	elseif inst:IsA("BasePart") then
		return inst.CFrame
	end
	return CFrame.new()
end

local function setCFrame(inst: Instance, cf: CFrame)
	if inst:IsA("Model") then
		inst:PivotTo(cf)
	elseif inst:IsA("BasePart") then
		inst.CFrame = cf
	end
end

-- Acquire target from current mouse position. If we already have a target,
-- keep it (don't auto-switch on every command).
local function acquireTarget(): boolean
	if target and target.Parent then
		return true
	end
	local block = findBlockFromPart(mouse.Target)
	if not block then
		print(LOG, "No block under cursor. Aim at a block and try again.")
		return false
	end
	target = block
	originalCFrame = getCurrentCFrame(block)
	accumRotation = CFrame.identity
	history = {}
	local label = block:GetAttribute("BlockType") or block.Name
	print(string.format("%s Locked target: %s (%s). Original CFrame stored.",
		LOG, tostring(label), block:GetFullName()))
	return true
end

-- ---------------------------------------------------------------------------
-- Rotation
-- ---------------------------------------------------------------------------
local function formatHistory(): string
	if #history == 0 then return "(none)" end
	local parts = {}
	for _, step in ipairs(history) do
		table.insert(parts, string.format("%s%+g", step.axis, step.degrees))
	end
	return table.concat(parts, " * ")
end

-- Extract the equivalent CFrame.Angles(rx, ry, rz) representation of the
-- accumulated rotation so the user has a single line they can paste into the
-- placement code. Returned values are in DEGREES.
local function extractEulerDegrees(): (number, number, number)
	local rx, ry, rz = accumRotation:ToEulerAnglesXYZ()
	return math.deg(rx), math.deg(ry), math.deg(rz)
end

local function applyRotation(dx: number, dy: number, dz: number)
	if not acquireTarget() then return end
	-- Record this step in history (one axis at a time)
	local axis, deg = "?", 0
	if dx ~= 0 then axis, deg = "X", dx
	elseif dy ~= 0 then axis, deg = "Y", dy
	elseif dz ~= 0 then axis, deg = "Z", dz
	end
	table.insert(history, {axis = axis, degrees = deg})
	-- Compose multiplicatively in LOCAL frame (right-multiply). This matches how
	-- the offset will be applied at bake time: newCFrame = base * CFrame.Angles(...)
	local step = CFrame.Angles(math.rad(dx), math.rad(dy), math.rad(dz))
	accumRotation = accumRotation * step
	setCFrame(target :: Instance, (originalCFrame :: CFrame) * accumRotation)
	-- Print the press history (faithful to what the user did)
	print(string.format("%s applied: %s", LOG, formatHistory()))
	-- Print equivalent Euler representation for direct copy-paste into bake code.
	-- Note: this is only "clean" 90s if the rotations happened to be in XYZ order.
	-- For arbitrary mixed-axis sequences, values may look unusual but they are
	-- mathematically equivalent.
	local ex, ey, ez = extractEulerDegrees()
	print(string.format("%s   equivalent: CFrame.Angles(math.rad(%g), math.rad(%g), math.rad(%g))",
		LOG, ex, ey, ez))
end

local function resetTarget()
	if not target or not originalCFrame then
		print(LOG, "No target to reset. Use a rotate command first to lock a target.")
		return
	end
	setCFrame(target, originalCFrame)
	accumRotation = CFrame.identity
	history = {}
	print(LOG, "Reset to original.")
end

local function clearTarget()
	if target then
		print(LOG, "Released target:", target:GetFullName())
	end
	target = nil
	originalCFrame = nil
	accumRotation = CFrame.identity
	history = {}
end

local function printOffset()
	if not target then
		print(LOG, "No target locked.")
		return
	end
	local ex, ey, ez = extractEulerDegrees()
	print(string.format("%s history: %s", LOG, formatHistory()))
	print(string.format("%s   equivalent: CFrame.Angles(math.rad(%g), math.rad(%g), math.rad(%g))",
		LOG, ex, ey, ez))
end

local function printHelp()
	print(LOG, "Dev block rotator commands (Studio only):")
	print("  /rx+ /rx-       rotate around X by +/-90°  (same for /ry, /rz)")
	print("  /rx+45 /rx-45   +/-45° step on X           (same for /ry, /rz)")
	print("  /rx+15 /rx-15   +/-15° step on X           (same for /ry, /rz)")
	print("  /rx+5  /rx-5    +/-5°  step on X           (same for /ry, /rz)")
	print("  /rx 30          rotate X by signed integer (e.g. /rx -25, /ry 137)")
	print("  /rreset         restore target to original orientation")
	print("  /rclear         release current target; next command picks a new one")
	print("  /rprint         print current cumulative offset")
	print("  /rhelp          this list")
	print("Aim mouse at a block, then type a rotate command to lock it in.")
end

-- ---------------------------------------------------------------------------
-- Command dispatch
-- ---------------------------------------------------------------------------
-- Build a rotation delta for the given axis ('x','y','z') by the given signed amount.
local function rotateAxis(axis: string, degrees: number)
	if axis == "x" then applyRotation(degrees, 0, 0)
	elseif axis == "y" then applyRotation(0, degrees, 0)
	elseif axis == "z" then applyRotation(0, 0, degrees)
	end
end

local function handleCommand(rawText: string): boolean
	local text = (rawText or ""):lower():gsub("%s+", "")
	-- Static commands first
	if text == "/rreset" then resetTarget(); return true
	elseif text == "/rclear" then clearTarget(); return true
	elseif text == "/rprint" then printOffset(); return true
	elseif text == "/rhelp" then printHelp(); return true
	end
	-- Suffixed step commands: /rx+, /rx-, /rx+45, /rx-15, /ry+5, etc.
	-- Pattern: /r<axis><sign><optional digits>  where axis is x|y|z, sign is + or -.
	-- Missing digits => default 90.
	local axis, sign, num = text:match("^/r([xyz])([%+%-])(%d*)$")
	if axis and sign then
		local degrees = (num == "" or num == nil) and 90 or tonumber(num)
		if sign == "-" then degrees = -degrees end
		rotateAxis(axis, degrees)
		return true
	end
	-- Also handle the no-whitespace arbitrary form: /rx30, /ry-45 (after gsub'ing spaces)
	-- /rx 30 becomes /rx30 after whitespace removal -- match a signed integer right after axis.
	local axis2, signedNum = text:match("^/r([xyz])(%-?%d+)$")
	if axis2 and signedNum then
		local degrees = tonumber(signedNum)
		if degrees then
			rotateAxis(axis2, degrees)
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Chat hookup (both modern TextChatService and legacy Chatted, for safety)
-- ---------------------------------------------------------------------------
-- Both events fire for the same message on modern Roblox, so we dedupe by
-- text+timestamp. Without this, every command runs twice (e.g. /rx+ rotates 180°
-- instead of 90°).
local lastText: string? = nil
local lastTime: number = 0

local function debouncedHandle(text: string)
	local now = os.clock()
	if text == lastText and (now - lastTime) < 0.25 then
		return  -- duplicate from the other event source
	end
	lastText = text
	lastTime = now
	handleCommand(text)
end

-- Modern: intercept locally-sent messages before they go to the server.
pcall(function()
	TextChatService.SendingMessage:Connect(function(textChatMessage)
		debouncedHandle(textChatMessage.Text)
	end)
end)

-- Legacy fallback: works if the experience has legacy chat enabled.
player.Chatted:Connect(debouncedHandle)

print(LOG, "Ready. Type /rhelp in chat for commands.")
