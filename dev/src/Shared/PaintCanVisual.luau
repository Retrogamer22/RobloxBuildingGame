--[[
	PaintCanVisual
	Paint Mod — shared helper for rendering a paint can's color/load state.

	There are two can models under ReplicatedStorage/Mods/PaintMod:
		PaintCan       - the held / inventory item. Parts: Can (body), PaintColor (paint
		                 swatch, tinted when filled), EmptyPart (shown when empty).
		PaintCanModel  - what gets PLACED on the ground. Parts: Can (body), Paint + Wrapper
		                 (both tinted to the paint color).

	This helper tints whichever color parts are present (Paint, Wrapper, PaintColor) and
	toggles EmptyPart if the model has one, so one function serves both models. It is
	material-agnostic: only sets Color/visibility, never Material. Unions need
	UsePartColor = true for .Color to take, which we set explicitly.

	Called from BlockHandler (on place) and both save managers (on load).
]]

local PaintCanVisual = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Parts that should be tinted to the paint color, across both can models.
local COLOR_PARTS = { "Paint", "Wrapper", "PaintColor" }

local function findPart(model: Instance?, name: string): BasePart?
	if not model then return nil end
	local direct = model:FindFirstChild(name)
	if direct and direct:IsA("BasePart") then return direct end
	for _, d in ipairs(model:GetDescendants()) do
		if d.Name == name and d:IsA("BasePart") then return d end
	end
	return nil
end

local function hide(part: BasePart?)
	if not part then return end
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false   -- don't let a hidden part intercept the brush's raycast
	part.CanTouch = false
end

local function tint(part: BasePart?, color: Color3?)
	if not part then return end
	part.Transparency = 0
	part.CanQuery = true
	if part:IsA("UnionOperation") then
		part.UsePartColor = true
	end
	if color then
		part.Color = color
	end
end

-- Render a can. color: Color3 for the paint. isEmpty: true => hide color parts, show EmptyPart.
function PaintCanVisual.ApplyCan(model: Instance?, color: Color3?, isEmpty: boolean?)
	if not model then return end
	local emptyPart = findPart(model, "EmptyPart")

	if isEmpty then
		for _, name in ipairs(COLOR_PARTS) do
			hide(findPart(model, name))
		end
		if emptyPart then
			emptyPart.Transparency = 0
			emptyPart.CanQuery = true
		end
	else
		hide(emptyPart)
		for _, name in ipairs(COLOR_PARTS) do
			tint(findPart(model, name), color)
		end
	end
end

-- Render the brush's load state. loaded => show Color (tinted), hide Brush.
-- empty => show Brush, hide Color. The Paintbrush body is left untouched.
function PaintCanVisual.ApplyBrush(model: Instance?, color: Color3?, loaded: boolean?)
	if not model then return end
	local colorPart = findPart(model, "Color")
	local brushPart = findPart(model, "Brush")
	if loaded then
		tint(colorPart, color)
		-- Also set any textures/surface appearance ON the color part to the same color, so the
		-- brush snaps straight to the new color instead of multiplying old texture color into it
		-- (which looked like the colors blending).
		if colorPart and color then
			for _, d in ipairs(colorPart:GetDescendants()) do
				if d:IsA("Texture") or d:IsA("Decal") then
					d.Color3 = color
				elseif d:IsA("SurfaceAppearance") then
					d.Color = color
				end
			end
		end
		hide(brushPart)
	else
		hide(colorPart)
		if brushPart then
			brushPart.Transparency = 0
			brushPart.CanQuery = true
		end
	end
end

-- Render the held swatch's captured color. The swatch is a single union with six Texture
-- children (one per face); we tint each to `color`. nil/empty = neutral grey (no capture yet).
-- Pure-white captures are clamped to (185,185,185) so the texture doesn't blow out to flat
-- white on the model.
local SWATCH_WHITE_CAP = Color3.fromRGB(185, 185, 185)
function PaintCanVisual.ApplySwatch(model: Instance?, color: Color3?)
	if not model then return end
	local tint = color
	if tint then
		local r = math.round(tint.R * 255)
		local g = math.round(tint.G * 255)
		local b = math.round(tint.B * 255)
		if r >= 250 and g >= 250 and b >= 250 then
			tint = SWATCH_WHITE_CAP
		end
	else
		tint = Color3.fromRGB(120, 120, 120)
	end
	-- Set the new color on BOTH the face textures AND the underlying part(s) in one pass, so
	-- the swatch snaps straight to the picked color. (Previously only the textures were tinted;
	-- the part kept its old color and showed through, which looked like the two colors blending.)
	local function tintInst(inst)
		if inst:IsA("Texture") or inst:IsA("Decal") then
			inst.Color3 = tint
		elseif inst:IsA("SurfaceAppearance") then
			inst.Color = tint
		elseif inst:IsA("BasePart") then
			if inst:IsA("UnionOperation") then inst.UsePartColor = true end
			inst.Color = tint
		end
	end
	tintInst(model)
	for _, d in ipairs(model:GetDescendants()) do
		tintInst(d)
	end
end

-- ===========================================================================
-- COAT-BASED PAINT  (blend + primer coverage)
-- ===========================================================================
-- Painting is modeled as a stack of COATS, capped at MAX_COATS. Every brush hit adds one
-- coat. Two paint types:
--     * Regular -> recolors only. Blends the block's Color toward the paint color.
--     * Primer  -> covers. Blends color AND fades in a concrete texture on all 6 faces.
--
-- Coverage = primerCoats / MAX_COATS. We render it with six Texture children (one per
-- face) whose Transparency steps 1 -> 0 as primer coats accumulate. Textures only exist
-- once the block has at least one primer coat; the sponge removes them when primer hits 0.
-- Regular-only blocks carry NO textures -- they just have a blended Color.
--
-- Why Textures: Roblox lets scripts set Texture.Transparency/Color at runtime (unlike a
-- MaterialVariant's texture maps), so this gives a true gradual cover with no extra parts
-- and no material swap -- the block keeps its real material/relief underneath.
--
-- Persistence: we DON'T save the six textures as instances. The save system stores the
-- coat state (total coats, primer coats, blended color) and calls ApplyCoats on load,
-- which rebuilds the textures from that state.

local MAX_COATS = 4
local FACES = { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Top,
	Enum.NormalId.Bottom, Enum.NormalId.Left, Enum.NormalId.Right }

-- Concrete cover texture (the user-provided template). Resolved lazily from the PaintMod
-- folder so this module doesn't hard-depend on a load order.
local COVER_TEXTURE_NAME = "PaintTexture"
local coverTextureId: string? = nil
local coverTextureResolved = false
local warnedMissingCover = false

local function getCoverTextureId(): string?
	if coverTextureResolved then return coverTextureId end
	coverTextureResolved = true
	local mods = ReplicatedStorage:FindFirstChild("Mods")
	local paintMod = mods and mods:FindFirstChild("PaintMod")
	local tmpl = paintMod and paintMod:FindFirstChild(COVER_TEXTURE_NAME, true)
	if tmpl then
		if tmpl:IsA("Texture") or tmpl:IsA("Decal") then
			coverTextureId = tmpl.Texture
		elseif tmpl:IsA("StringValue") then
			coverTextureId = tmpl.Value
		elseif tmpl:GetAttribute("TextureId") then
			coverTextureId = tmpl:GetAttribute("TextureId")
		end
	end
	if not coverTextureId and not warnedMissingCover then
		warnedMissingCover = true
		warn(string.format(
			"[BB-PAINT] cover texture '%s' not found in Mods/PaintMod -- primer coats will tint but not show the concrete cover.",
			COVER_TEXTURE_NAME))
	end
	return coverTextureId
end

-- ---- Original-look snapshot (so paint is fully reversible) ----------------
-- We snapshot each part's pristine Color the first time it's painted (and on load before
-- paint is re-applied). The sponge restores it once all coats are removed.

local ORIG_CAPTURED = "PaintOrigCaptured"

local function captureOriginalPart(part: BasePart)
	if part:GetAttribute(ORIG_CAPTURED) then return end
	part:SetAttribute("PaintOrigR", math.round(part.Color.R * 255))
	part:SetAttribute("PaintOrigG", math.round(part.Color.G * 255))
	part:SetAttribute("PaintOrigB", math.round(part.Color.B * 255))
	part:SetAttribute("PaintOrigT", part.Transparency)
	part:SetAttribute(ORIG_CAPTURED, true)
end

local function originalColorPart(part: BasePart): Color3?
	local r = part:GetAttribute("PaintOrigR")
	local g = part:GetAttribute("PaintOrigG")
	local b = part:GetAttribute("PaintOrigB")
	if r and g and b then return Color3.fromRGB(r, g, b) end
	return nil
end

local function clearOriginalPart(part: BasePart)
	part:SetAttribute("PaintOrigR", nil)
	part:SetAttribute("PaintOrigG", nil)
	part:SetAttribute("PaintOrigB", nil)
	part:SetAttribute("PaintOrigT", nil)
	part:SetAttribute(ORIG_CAPTURED, nil)
end

local function forEachPart(block: Instance, fn: (BasePart) -> ())
	if block:IsA("BasePart") then
		fn(block)
	else
		for _, p in ipairs(block:GetDescendants()) do
			if p:IsA("BasePart") then fn(p) end
		end
	end
end

-- ---- Cover textures (per face) --------------------------------------------

-- Ensure the six face textures exist on a part, tinted `color`, at the given transparency.
local function ensureCoverTextures(part: BasePart, color: Color3, transparency: number)
	local texId = getCoverTextureId()
	if not texId then return end
	for _, face in ipairs(FACES) do
		local name = "PaintCover_" .. face.Name
		local tex = part:FindFirstChild(name)
		if not tex then
			tex = Instance.new("Texture")
			tex.Name = name
			tex.Face = face
			tex.Texture = texId
			tex.StudsPerTileU = 1
			tex.StudsPerTileV = 1
			tex.Parent = part
		end
		tex.Color3 = color
		tex.Transparency = transparency
	end
end

local function removeCoverTextures(part: BasePart)
	for _, face in ipairs(FACES) do
		local tex = part:FindFirstChild("PaintCover_" .. face.Name)
		if tex then tex:Destroy() end
	end
end

-- ---- Core renderer --------------------------------------------------------
-- Render a block's paint state. color = current blended Color; primerCoats = how many
-- coats were primer (drives the cover transparency). Sets the block's Color and builds/
-- updates/removes the cover textures to match. Material/relief are left untouched.
local function applyCoatsPart(part: BasePart, color: Color3, primerCoats: number)
	if part:IsA("UnionOperation") then
		part.UsePartColor = true
	end
	part.Color = color
	if primerCoats and primerCoats > 0 then
		local coverage = math.clamp(primerCoats / MAX_COATS, 0, 1)
		ensureCoverTextures(part, color, 1 - coverage)
	else
		removeCoverTextures(part)
	end
end

-- ===========================================================================
-- GLASS PAINT  (tinted glass via blend, opaque cover via primer)
-- ===========================================================================
-- Glass is special: a clear pane is an (almost) invisible part whose look comes
-- from face textures, so just setting .Color does nothing visible. For glass we
-- instead drive the part's TRANSPARENCY and recolor its face textures:
--     * Blend (no primer) -> tints the glass but keeps it see-through ("tinted
--       glass at its fullest"); transparency holds at GLASS_TINT_TRANSPARENCY.
--     * Primer            -> fades transparency from that tint down to 0 as the
--       primer coats build, so a full primer coat fully covers the window.
-- Hitbox / ClimbSensor helper parts stay untouched so collision is unaffected.

local GLASS_TINT_TRANSPARENCY = 0.55

local glassPlacement: any = nil
local glassResolved = false
local function getGlassPlacement()
	if glassResolved then return glassPlacement end
	glassResolved = true
	local mod = ReplicatedStorage:FindFirstChild("GlassPlacement")
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok then glassPlacement = res end
	end
	return glassPlacement
end

local function isGlassBlock(block: Instance): boolean
	if block:GetAttribute("IsGlass") then return true end
	local gp = getGlassPlacement()
	if gp then
		if gp.IsGlassBlock then
			local ok, r = pcall(gp.IsGlassBlock, block)
			if ok and r then return true end
		end
		local bt = block:GetAttribute("BlockType")
		if bt and gp.IsAnyGlass then
			local ok, r = pcall(gp.IsAnyGlass, bt)
			if ok and r then return true end
		end
	end
	return false
end

-- Capture / restore the original Color3 of a glass block's face textures, so a
-- fully sponged glass block returns to its exact clear/tinted look.
local function captureTextureColors(block: Instance)
	for _, d in ipairs(block:GetDescendants()) do
		if (d:IsA("Texture") or d:IsA("Decal")) and not d:GetAttribute("PaintTexCaptured") then
			local c = d.Color3
			d:SetAttribute("PaintTexOrigR", math.round(c.R * 255))
			d:SetAttribute("PaintTexOrigG", math.round(c.G * 255))
			d:SetAttribute("PaintTexOrigB", math.round(c.B * 255))
			d:SetAttribute("PaintTexCaptured", true)
		end
	end
end

local function restoreTextureColors(block: Instance)
	for _, d in ipairs(block:GetDescendants()) do
		if (d:IsA("Texture") or d:IsA("Decal")) and d:GetAttribute("PaintTexCaptured") then
			local r = d:GetAttribute("PaintTexOrigR")
			local g = d:GetAttribute("PaintTexOrigG")
			local b = d:GetAttribute("PaintTexOrigB")
			if r and g and b then d.Color3 = Color3.fromRGB(r, g, b) end
			d:SetAttribute("PaintTexOrigR", nil)
			d:SetAttribute("PaintTexOrigG", nil)
			d:SetAttribute("PaintTexOrigB", nil)
			d:SetAttribute("PaintTexCaptured", nil)
		end
	end
end

local function styleGlassPart(part: BasePart, color: Color3, finalT: number)
	if part.Name == "Hitbox" or part.Name == "ClimbSensor" then return end
	if part:IsA("UnionOperation") then part.UsePartColor = true end
	part.Color = color
	part.Transparency = finalT
	part.CanQuery = true
	-- The refractive Glass material washes the tint out; match the colored-glass look.
	if part.Material == Enum.Material.Glass then part.Material = Enum.Material.SmoothPlastic end
end

-- Glass coat renderer: transparency is driven by primer coverage; the paint color
-- tints both the part and its face textures. No concrete cover is used on glass.
local function applyGlassCoats(block: Instance, color: Color3, primerCoats: number)
	local coverage = 0
	if primerCoats and primerCoats > 0 then
		coverage = math.clamp(primerCoats / MAX_COATS, 0, 1)
	end
	forEachPart(block, function(part)
		if part.Name == "Hitbox" or part.Name == "ClimbSensor" then return end
		local origT = part:GetAttribute("PaintOrigT")
		if origT == nil then origT = part.Transparency end
		-- Clear glass starts (almost) invisible; cap so painted glass reads as tinted
		-- glass, then fade to fully opaque (0) as primer coverage builds.
		local tintBase = math.min(origT, GLASS_TINT_TRANSPARENCY)
		styleGlassPart(part, color, tintBase * (1 - coverage))
		removeCoverTextures(part)  -- glass never uses the concrete cover
	end)
	for _, d in ipairs(block:GetDescendants()) do
		if d:IsA("Texture") or d:IsA("Decal") then
			d.Color3 = color
		end
	end
end

function PaintCanVisual.ApplyCoats(block: Instance, color: Color3, primerCoats: number)
	if isGlassBlock(block) then
		applyGlassCoats(block, color, primerCoats)
	else
		forEachPart(block, function(p) applyCoatsPart(p, color, primerCoats) end)
	end
end

-- Snapshot the block's original appearance. Call before the FIRST coat, and before
-- re-applying saved paint on load, while the block still looks default.
function PaintCanVisual.CaptureOriginal(block: Instance)
	forEachPart(block, captureOriginalPart)
	if isGlassBlock(block) then captureTextureColors(block) end
end

-- Fully restore a block to its pristine look (sponge -> last coat removed). Removes cover
-- textures, restores original color, clears the snapshot.
function PaintCanVisual.RestoreOriginal(block: Instance)
	local glass = isGlassBlock(block)
	forEachPart(block, function(p)
		removeCoverTextures(p)
		local orig = originalColorPart(p)
		if orig then p.Color = orig end
		local ot = p:GetAttribute("PaintOrigT")
		if ot ~= nil then p.Transparency = ot end
		clearOriginalPart(p)
	end)
	if glass then restoreTextureColors(block) end
end

return PaintCanVisual
