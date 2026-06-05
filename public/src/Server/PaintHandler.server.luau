--[[
	PaintHandler — Paint Mod brush logic (server-authoritative).

	Client fires the PaintBlock RemoteEvent with the targeted block when the player
	right-clicks while holding the Paint Brush. The server decides what to do:

		• Target is a placed PaintCanModel (IsPaintCan)  -> LOAD that color onto the brush.
		• Anything else                                  -> PAINT it the loaded color.

	Painting sets .Color on every BasePart of the target and tags it IsPainted, so
	PlotSerializer saves the color (cr/cg/cb) and SaveManager / MegaPlotSaveManager
	restore it on reload. The brush's loaded color is per-player server state, mirrored
	to player attributes (PaintbrushColorR/G/B + PaintbrushLoaded) so the client can
	show the loaded swatch on the held brush.

	Logs: [BB-PAINT]
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local PaintCanVisual = require(ReplicatedStorage:WaitForChild("PaintCanVisual", 10))

-- Remote: created here if it doesn't exist yet (mirrors ToolHandler's pattern).
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local PaintBlock = Remotes:FindFirstChild("PaintBlock")
if not PaintBlock then
	PaintBlock = Instance.new("RemoteEvent")
	PaintBlock.Name = "PaintBlock"
	PaintBlock.Parent = Remotes
end

-- Sponge remote: the sponge tool steps a painted block backwards (flat -> painted -> default).
local SpongeBlock = Remotes:FindFirstChild("SpongeBlock")
if not SpongeBlock then
	SpongeBlock = Instance.new("RemoteEvent")
	SpongeBlock.Name = "SpongeBlock"
	SpongeBlock.Parent = Remotes
end

-- Swatch remote: the swatch captures a block's visible color onto the held swatch + player.
local SwatchBlock = Remotes:FindFirstChild("SwatchBlock")
if not SwatchBlock then
	SwatchBlock = Instance.new("RemoteEvent")
	SwatchBlock.Name = "SwatchBlock"
	SwatchBlock.Parent = Remotes
end

-- SetBrushState remote: paint is per-brush. The client fires this when the player selects a
-- brush slot so the server's active paint matches THAT brush -- a payload {r,g,b,isPrimer,mode}
-- loads it, a nil/false payload empties it (so an unpainted brush paints nothing). This is what
-- lets a fresh brush be blank instead of inheriting the last color.
local SetBrushState = Remotes:FindFirstChild("SetBrushState")
if not SetBrushState then
	SetBrushState = Instance.new("RemoteEvent")
	SetBrushState.Name = "SetBrushState"
	SetBrushState.Parent = Remotes
end

-- BrushLoadedFromCan remote: fired to the client ONLY when a brush is actually loaded from a
-- can (not on routine select-syncs). The client uses it to record the color onto the selected
-- brush's slot. Keeping this separate from the select-sync avoids a race where the select echo
-- stamps the wrong brush when scrolling quickly between brushes.
local BrushLoadedFromCan = Remotes:FindFirstChild("BrushLoadedFromCan")
if not BrushLoadedFromCan then
	BrushLoadedFromCan = Instance.new("RemoteEvent")
	BrushLoadedFromCan.Name = "BrushLoadedFromCan"
	BrushLoadedFromCan.Parent = Remotes
end

-- SwatchCapturedFromBlock remote: fired to the client when a swatch captures a color, so the
-- client can split one swatch off the held stack and color it (Minecraft-style), mirroring the
-- brush. Separate from the global Swatch* attributes (which the Paint Mixer still reads).
local SwatchCapturedFromBlock = Remotes:FindFirstChild("SwatchCapturedFromBlock")
if not SwatchCapturedFromBlock then
	SwatchCapturedFromBlock = Instance.new("RemoteEvent")
	SwatchCapturedFromBlock.Name = "SwatchCapturedFromBlock"
	SwatchCapturedFromBlock.Parent = Remotes
end

-- Per-player loaded brush state. nil color = empty brush.
local loadedColor: { [number]: Color3 } = {}
local loadedIsPrimer: { [number]: boolean } = {}
local loadedMode: { [number]: string } = {}  -- "match" | "blend"
Players.PlayerRemoving:Connect(function(p)
	loadedColor[p.UserId] = nil
	loadedIsPrimer[p.UserId] = nil
	loadedMode[p.UserId] = nil
end)

-- ---- Plot helpers (mirrors ToolHandler) -----------------------------------

local function getPlayerBuildArea(player)
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if modeValue and modeValue.Value == "MegaPlot" then
		local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then
			local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
			if megaBuildArea then
				return megaBuildArea
			end
		end
	end
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea and buildArea:GetAttribute("OwnerUserId") == player.UserId then
			return buildArea
		end
	end
	return nil
end

local function isPositionInPlot(player, position)
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return false end

	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if modeValue and modeValue.Value == "MegaPlot" then
		return true
	end

	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")

	local platePos, plateSize
	if posX and posZ and sizeX and sizeZ then
		platePos = Vector3.new(posX, buildArea:GetAttribute("BasePlatePositionY") or 0, posZ)
		plateSize = Vector3.new(sizeX, buildArea:GetAttribute("BasePlateSizeY") or 0, sizeZ)
	else
		local basePlate = buildArea:FindFirstChild("BasePlate")
		if not basePlate then return false end
		platePos = basePlate.Position
		plateSize = basePlate.Size
	end

	local halfX = plateSize.X / 2
	local halfZ = plateSize.Z / 2
	if position.X < platePos.X - halfX or position.X > platePos.X + halfX then return false end
	if position.Z < platePos.Z - halfZ or position.Z > platePos.Z + halfZ then return false end
	return true
end

-- ---- Color helpers ---------------------------------------------------------

local CAN_COLOR_PARTS = { "Paint", "Wrapper", "PaintColor" }

-- Read the paint color, primer flag, and mode off a placed can. Cans stamp PaintIsPrimer
-- and PaintMode attributes at the mixer; defaults are regular + blend.
local function readCanColor(canModel)
	for _, name in ipairs(CAN_COLOR_PARTS) do
		local part = canModel:FindFirstChild(name)
		if not (part and part:IsA("BasePart")) then
			for _, d in ipairs(canModel:GetDescendants()) do
				if d.Name == name and d:IsA("BasePart") then
					part = d
					break
				end
			end
		end
		if part and part:IsA("BasePart") then
			return part.Color
		end
	end
	return nil
end

local function setBrushState(player, color, isPrimer, mode)
	loadedColor[player.UserId] = color
	loadedIsPrimer[player.UserId] = isPrimer and true or false
	loadedMode[player.UserId] = (mode == "match") and "match" or "blend"
	player:SetAttribute("PaintbrushColorR", math.round(color.R * 255))
	player:SetAttribute("PaintbrushColorG", math.round(color.G * 255))
	player:SetAttribute("PaintbrushColorB", math.round(color.B * 255))
	player:SetAttribute("PaintbrushLoaded", true)
	player:SetAttribute("PaintbrushIsPrimer", loadedIsPrimer[player.UserId])
	player:SetAttribute("PaintbrushMode", loadedMode[player.UserId])
end

-- Empty the active brush (selecting an unpainted brush, or a brush with no stored paint).
-- With no loaded color, PaintBlock is a no-op, so an empty brush paints nothing.
local function clearBrushState(player)
	loadedColor[player.UserId] = nil
	loadedIsPrimer[player.UserId] = nil
	loadedMode[player.UserId] = nil
	player:SetAttribute("PaintbrushLoaded", false)
end

-- Client selects a brush slot -> sync the active paint to that brush (or empty it).
SetBrushState.OnServerEvent:Connect(function(player, payload)
	if type(payload) == "table"
		and type(payload.r) == "number" and type(payload.g) == "number" and type(payload.b) == "number" then
		local color = Color3.fromRGB(
			math.clamp(math.round(payload.r), 0, 255),
			math.clamp(math.round(payload.g), 0, 255),
			math.clamp(math.round(payload.b), 0, 255)
		)
		setBrushState(player, color, payload.isPrimer and true or false, payload.mode)
	else
		clearBrushState(player)
	end
end)

-- ---- Coat model ------------------------------------------------------------
-- A block's paint state lives in attributes:
--     PaintCoats        total coats applied (0..MAX_COATS)
--     PaintPrimerCoats  how many of those were primer (drives cover transparency)
--     cr/cg/cb          current blended color (CustomColor*, saved by the serializer)
--     IsPainted         tagged whenever coats > 0 (serializer restores cr/cg/cb)
-- Each brush hit adds one coat:
--     Blend mode -> lerp current color toward brush color by PAINT_BLEND_FACTOR.
--     Match mode -> same lerp, but the covering/final coat snaps to the EXACT brush color.
--     Primer     -> also increments PaintPrimerCoats so the concrete cover fades in.
-- PaintCanVisual.ApplyCoats renders color + cover from (color, primerCoats).

local MAX_COATS = 4
local PAINT_BLEND_FACTOR = 0.4  -- color shift per coat in blend mode (tunable)

local function getBlockColor(block): Color3
	local r = block:GetAttribute("CustomColorR")
	local g = block:GetAttribute("CustomColorG")
	local b = block:GetAttribute("CustomColorB")
	if r and g and b then return Color3.fromRGB(r, g, b) end
	-- Fall back to the first part's current color.
	if block:IsA("BasePart") then return block.Color end
	for _, p in ipairs(block:GetDescendants()) do
		if p:IsA("BasePart") then return p.Color end
	end
	return Color3.new(1, 1, 1)
end

local function storeBlockColor(block, color: Color3)
	block:SetAttribute("CustomColorR", math.round(color.R * 255))
	block:SetAttribute("CustomColorG", math.round(color.G * 255))
	block:SetAttribute("CustomColorB", math.round(color.B * 255))
end

-- Apply one coat of `color` to `block`. isPrimer adds coverage; mode selects blend vs match.
local function paintBlock(block, color, isPrimer, mode)
	local coats = block:GetAttribute("PaintCoats") or 0
	local primerCoats = block:GetAttribute("PaintPrimerCoats") or 0
	if coats >= MAX_COATS and (not isPrimer or primerCoats >= MAX_COATS) then
		-- Already at max coats; further coats of the same kind just keep blending color.
	end

	if coats == 0 then
		-- First coat: snapshot pristine look so the sponge can fully revert later.
		PaintCanVisual.CaptureOriginal(block)
		block:SetAttribute("IsPainted", true)
	end

	coats = math.min(coats + 1, MAX_COATS)
	if isPrimer then
		primerCoats = math.min(primerCoats + 1, MAX_COATS)
	end

	-- Compute the new blended color.
	local current = getBlockColor(block)
	local newColor
	if mode == "match" then
		-- Match: converge toward the exact color; snap exactly once fully coated.
		if coats >= MAX_COATS then
			newColor = color
		else
			newColor = current:Lerp(color, 0.6)
		end
	else
		newColor = current:Lerp(color, PAINT_BLEND_FACTOR)
	end

	storeBlockColor(block, newColor)
	block:SetAttribute("PaintCoats", coats)
	block:SetAttribute("PaintPrimerCoats", primerCoats)
	PaintCanVisual.ApplyCoats(block, newColor, primerCoats)
end

-- ---- Main handler ----------------------------------------------------------

PaintBlock.OnServerEvent:Connect(function(player, target)
	if typeof(target) ~= "Instance" then return end
	if not target:IsDescendantOf(workspace) then return end

	-- Must be an actual block (placed or terrain), not an arbitrary instance.
	if not target:GetAttribute("BlockType") then return end

	-- Resolve a position and confirm it's inside the player's plot.
	local pos
	local bx, by, bz = target:GetAttribute("BlockPosX"), target:GetAttribute("BlockPosY"), target:GetAttribute("BlockPosZ")
	if bx and by and bz then
		pos = Vector3.new(bx, by, bz)
	elseif target:IsA("BasePart") then
		pos = target.Position
	elseif target:IsA("Model") then
		pos = target:GetPivot().Position
	end
	if not pos or not isPositionInPlot(player, pos) then return end

	-- LOAD: right-clicking a placed can fills the brush with its color + type + mode.
	if target:GetAttribute("IsPaintCan") then
		if target:GetAttribute("IsEmptyCan") then return end  -- empty cans hold no paint
		local c = readCanColor(target)
		if c then
			local isPrimer = target:GetAttribute("PaintIsPrimer") and true or false
			local mode = target:GetAttribute("PaintMode") or "blend"
			setBrushState(player, c, isPrimer, mode)
			-- Tell the client to record this color onto the brush it just loaded (the selected
			-- one). Only fires on real can-loads, so select-syncs never trigger a (racy) stamp.
			BrushLoadedFromCan:FireClient(player, {
				r = math.round(c.R * 255),
				g = math.round(c.G * 255),
				b = math.round(c.B * 255),
				isPrimer = isPrimer,
				mode = mode,
			})
			print(string.format("[BB-PAINT] %s loaded brush (%s, %s) from can",
				player.Name, isPrimer and "primer" or "regular", mode))
		end
		return
	end

	-- PAINT: needs a loaded color.
	local c = loadedColor[player.UserId]
	if not c then return end
	paintBlock(target, c, loadedIsPrimer[player.UserId], loadedMode[player.UserId])
end)

-- ---- Sponge handler --------------------------------------------------------

-- Resolve a block's plot-space position (grid attrs first, else actual position).
local function resolveBlockPos(target)
	local bx, by, bz = target:GetAttribute("BlockPosX"), target:GetAttribute("BlockPosY"), target:GetAttribute("BlockPosZ")
	if bx and by and bz then return Vector3.new(bx, by, bz) end
	if target:IsA("BasePart") then return target.Position end
	if target:IsA("Model") then return target:GetPivot().Position end
	return nil
end

-- Step a block back by ONE coat. Primer (cover) coats peel first, then color coats. At zero
-- coats the block is fully restored to its pristine look. The remaining blended color is left
-- as-is between steps (you can't un-mix a color, only reduce coverage and finally clear it).
local function spongeBlock(block)
	local coats = block:GetAttribute("PaintCoats") or 0
	if coats <= 0 then return nil end

	local primerCoats = block:GetAttribute("PaintPrimerCoats") or 0
	coats = coats - 1
	if primerCoats > coats then
		-- Peel a primer (cover) coat first so the concrete fades back out before the tint.
		primerCoats = math.max(0, primerCoats - 1)
	end

	if coats <= 0 then
		PaintCanVisual.RestoreOriginal(block)
		block:SetAttribute("PaintCoats", nil)
		block:SetAttribute("PaintPrimerCoats", nil)
		block:SetAttribute("IsPainted", nil)
		block:SetAttribute("CustomColorR", nil)
		block:SetAttribute("CustomColorG", nil)
		block:SetAttribute("CustomColorB", nil)
		return "restored"
	end

	block:SetAttribute("PaintCoats", coats)
	block:SetAttribute("PaintPrimerCoats", primerCoats)
	local color = getBlockColor(block)
	PaintCanVisual.ApplyCoats(block, color, primerCoats)
	return "stepped"
end

SpongeBlock.OnServerEvent:Connect(function(player, target)
	if typeof(target) ~= "Instance" then return end
	if not target:IsDescendantOf(workspace) then return end
	if not target:GetAttribute("BlockType") then return end
	local pos = resolveBlockPos(target)
	if not pos or not isPositionInPlot(player, pos) then return end
	local result = spongeBlock(target)
	if result then
		print(string.format("[BB-PAINT] %s sponged a block (%s)", player.Name, result))
	end
end)

-- ---- Swatch handler --------------------------------------------------------
-- The swatch captures a block's VISIBLE color. If the block is primer-covered, the cover
-- textures are tinted to the block's blended color, so the block's .Color is the visible
-- surface either way -- we read that (preferring the saved CustomColor* if present). The
-- captured color is stamped on the player as SwatchColorR/G/B + SwatchLoaded so the Paint
-- Mixer can pre-fill its sliders; we also tint the held swatch model's six face-textures.

-- Find the swatch model the player is currently holding (if the held-item system spawned one).
-- Looks for a model/part named "PaintSwatch" under the character. Harmless no-op if absent.
local function findHeldSwatch(player)
	local char = player.Character
	if not char then return nil end
	local direct = char:FindFirstChild("PaintSwatch")
	if direct then return direct end
	for _, d in ipairs(char:GetDescendants()) do
		if d.Name == "PaintSwatch" and (d:IsA("Model") or d:IsA("BasePart")) then
			return d
		end
	end
	return nil
end

local function captureSwatchColor(block): Color3?
	-- Prefer the saved blended paint color (the true surface color of a painted block).
	local r = block:GetAttribute("CustomColorR")
	local g = block:GetAttribute("CustomColorG")
	local b = block:GetAttribute("CustomColorB")
	if r and g and b then return Color3.fromRGB(r, g, b) end
	-- Otherwise read the first visible BasePart's color (skip hidden/hitbox parts).
	if block:IsA("BasePart") then return block.Color end
	for _, p in ipairs(block:GetDescendants()) do
		if p:IsA("BasePart") and p.Transparency < 1 and p.Name ~= "Hitbox" then
			return p.Color
		end
	end
	return nil
end

SwatchBlock.OnServerEvent:Connect(function(player, target)
	if typeof(target) ~= "Instance" then return end
	if not target:IsDescendantOf(workspace) then return end
	if not target:GetAttribute("BlockType") then return end
	local pos = resolveBlockPos(target)
	if not pos or not isPositionInPlot(player, pos) then return end

	local color = captureSwatchColor(target)
	if not color then return end

	-- Stamp the captured color on the player for the Paint Mixer to read (true color, no cap).
	player:SetAttribute("SwatchColorR", math.round(color.R * 255))
	player:SetAttribute("SwatchColorG", math.round(color.G * 255))
	player:SetAttribute("SwatchColorB", math.round(color.B * 255))
	player:SetAttribute("SwatchLoaded", true)

	-- Tint the held swatch model's six textures (white-capped at 185 inside ApplySwatch).
	local held = findHeldSwatch(player)
	if held then
		PaintCanVisual.ApplySwatch(held, color)
	end

	-- Tell the client to split one swatch off the held stack and color it (per-swatch state).
	SwatchCapturedFromBlock:FireClient(player, {
		r = math.round(color.R * 255),
		g = math.round(color.G * 255),
		b = math.round(color.B * 255),
	})

	print(string.format("[BB-PAINT] %s captured swatch color (%d,%d,%d)",
		player.Name, math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)))
end)

print("[BB-PAINT] PaintHandler initialized")
