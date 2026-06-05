--[[
	FireHandler
	Server-side handler for fire SPREAD + burn-away (Minecraft-style).

	Model (matches ToolHandler/SaveManager):
	- A Fire occupies the empty grid cell directly ABOVE a support block.
	- It stores HostBlockX/Y/Z = the support's grid center.

	Spread rules:
	- Fire only catches FLAMMABLE blocks (see FLAMMABLE config below). Stone,
	  dirt, glass, etc. are fireproof and act as firebreaks.
	- Each tick, every fire may:
	    1. Consume its host (if flammable): destroy the host block AND this fire,
	       leaving empty space.
	    2. Spread: ignite flammable blocks adjacent to the host (4 sides + below
	       + above) by placing a new Fire on top of each catching block.
	- A fire whose host has vanished extinguishes (no support).
	- "Burns out only if nothing flammable nearby": a fire on a NON-flammable
	  host with no flammable neighbours lingers, but we give it a short grace
	  countdown so stray fires (e.g. lit on stone) eventually fizzle instead of
	  burning forever. Set EXTINGUISH_STRAY = false to disable.

	This script is self-contained (no custom module requires beyond the shared
	spatial index + grid config) so a sync hiccup can only stop fire spread, not
	take down save/load.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local BulkOperationFlags = nil
pcall(function()
	BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 5))
end)

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local BlockTemplates = ReplicatedStorage:WaitForChild("BlockTemplates", 10)

-- Remote for the client-side blocky shatter particle burst (created if missing).
-- Fired (server->all clients) with a small table { pos, size, color } whenever a
-- burnt block breaks; the BurntShatterParticles client script spawns the voxels.
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end
local BurntShatterFX = Remotes:FindFirstChild("BurntShatterFX")
if not BurntShatterFX then
	BurntShatterFX = Instance.new("RemoteEvent")
	BurntShatterFX.Name = "BurntShatterFX"
	BurntShatterFX.Parent = Remotes
end
-- Remote for the periodic falling-ember "drip" under a hot, floating charred block
-- (the block is still glowing while it cools, suspended in the air, so embers
-- crumble off the bottom). Fired (server->all clients) with { pos, size, color }.
local BurntEmberDripFX = Remotes:FindFirstChild("BurntEmberDripFX")
if not BurntEmberDripFX then
	BurntEmberDripFX = Instance.new("RemoteEvent")
	BurntEmberDripFX.Name = "BurntEmberDripFX"
	BurntEmberDripFX.Parent = Remotes
end

-- ============================================
-- CONFIGURATION
-- ============================================

local CONFIG = {
	-- How often to run a fire tick (seconds)
	TICK_INTERVAL = 2.0,

	-- Per-tick chance that a fire ignites a given flammable neighbour (0-1). This
	-- is the BASE chance, scaled per block type by ENCOURAGEMENT and per direction
	-- by FIRE_DIRECTION_BIAS below (Minecraft-style).
	SPREAD_CHANCE = 0.55,

	-- ============================================
	-- MINECRAFT-STYLE TUNING (encouragement / flammability / direction / age)
	-- ============================================
	-- DIRECTION BIAS: Minecraft fire climbs UP fast, creeps sideways slower, and
	-- barely spreads DOWN. These multiply the spread chance by direction. 1.0 =
	-- full chance. Tuned so walls go up quickly while floors burn slowly.
	FIRE_DIRECTION_BIAS = {
		up = 1.0,    -- spreading to a block above (fast)
		side = 0.6,  -- spreading horizontally (medium)
		down = 0.25, -- spreading to a block below (slow)
	},

	-- FIRE AGE / NATURAL BURNOUT (Minecraft has fire age 0-15; it dies on its own
	-- at max age unless freshly fed). Each tick a fire's age increments; once it
	-- passes MAX_FIRE_AGE it has BURNOUT_CHANCE per tick to extinguish ITSELF even
	-- with fuel nearby -- so an accidental fire burns for a while then peters out
	-- instead of consuming an entire build. Successfully spreading or charring a
	-- fresh host RESETS age toward 0 (the fire is "fed"). Eternal hosts (netherrack)
	-- never age. Set MAX_FIRE_AGE = false to disable natural burnout entirely
	-- (fire then lives until its fuel is gone, the old behaviour).
	MAX_FIRE_AGE = 15,        -- ticks before a fire may start dying on its own
	BURNOUT_CHANCE = 0.25,    -- per-tick extinguish chance once past MAX_FIRE_AGE
	AGE_FED_RESET = 4,        -- when fed, age drops to this (not all the way to 0)

	-- VERTICAL REACH ("fire climbs / leaps upward"): besides the immediate
	-- neighbours, a fire also reaches UP a column of cells and can ignite a
	-- flammable block sitting up to MAX_VERTICAL_REACH cells above its host. The
	-- per-tick ignition chance falls off with height, so a block directly above
	-- catches fast while one near the top of the reach takes (on average) several
	-- more ticks. Set MAX_VERTICAL_REACH = 1 to disable the extra reach (the
	-- normal immediate-above spread in SPREAD_OFFSETS still applies).
	MAX_VERTICAL_REACH = 4,             -- how many cells up fire can leap (max)
	VERTICAL_BASE_CHANCE = 0.6,         -- ignition chance at height 1 (closest)
	VERTICAL_FALLOFF = 0.6,             -- chance is multiplied by this per extra cell of height
	-- A solid (non-flammable) block in the column blocks the leap above it, so
	-- fire can't jump THROUGH a stone ceiling to wood above. Set false to let
	-- fire reach past gaps/solids freely.
	VERTICAL_BLOCKED_BY_SOLID = true,

	-- Cap new fires created per plot per tick (performance + pacing)
	MAX_SPREADS_PER_TICK = 8,

	-- SELF-WRAP ("fire climbs around the same block toward the top"): when a block
	-- is burning on one face (a side or the bottom), the fire eventually catches the
	-- block's OTHER open faces too, working its way UP until the top is alight. Each
	-- tick a burning face has a chance to ignite each of its host's other EXPOSED,
	-- not-yet-lit faces, scaled by FIRE_DIRECTION_BIAS (up fast, side medium, the
	-- top being the natural finish). Set SELF_WRAP_ENABLED=false to disable.
	--   SELF_WRAP_CHANCE: base per-tick chance to wrap onto a given open face.
	SELF_WRAP_ENABLED = true,
	SELF_WRAP_CHANCE = 0.5,

	-- BURN-AWAY via progressive charring. Instead of vanishing instantly, a
	-- flammable host darkens toward black over several ticks, then breaks.
	-- CHAR_PER_TICK: how much char (0-1) is added each tick the host is burning.
	--   e.g. 0.11 => ~9 ticks (~18s at 2s/tick) from fresh to fully charred.
	-- CHAR_DARKEN: how dark the block gets at full char (0 = pure BLACK,
	--   0.15 = very dark but keeps a hint of its colour). Set to 0 for full-on black
	--   charcoal.
	CHAR_PER_TICK = 0.11,
	CHAR_DARKEN = 0,

	-- BURN COLOUR ARC: as a block burns its colour travels original -> hot RED ->
	-- very dark char. CHAR_HEAT_PEAK is the char level (0-1) at which the block is
	-- reddest/hottest; before it the colour lerps original->HEAT_COLOR, after it
	-- HEAT_COLOR->the darkened char colour. Then while COOLING the block desaturates
	-- toward grey by CHAR_COOL_DESAT (0 = no change, 1 = fully grey).
	CHAR_HEAT_COLOR = Color3.fromRGB(150, 30, 12), -- glowing-ember red the block heats to
	CHAR_HEAT_PEAK = 0.45,                          -- char level of peak red (then darkens)
	CHAR_COOL_DESAT = 0.5,                          -- how much the cooled char greys out

	-- EMBER OVERLAY: as a block chars, we lay a glowing ember TEXTURE on its faces
	-- (driven by char level). A Texture auto-scales to any face size via StudsPerTile.
	-- EMBER_FACES: which faces to cover. Fewer = better perf when fire spreads
	-- across many blocks. "Top", "Front", "Back", "Left", "Right", "Bottom".
	EMBER_FACES = { "Top", "Bottom", "Front", "Back", "Left", "Right" },
	-- The ember image asset. Leave "" to auto-pull the ColorMap from the
	-- BlockTemplates.BlockEmbers SurfaceAppearance (so you don't have to paste an id).
	EMBER_TEXTURE_ID = "rbxassetid://104462372294179",
	-- The COOLED ember image: a black-and-white version the embers swap to once the
	-- fire is out (cooling phase). Leave "" to keep using EMBER_TEXTURE_ID (just
	-- tinted) instead of swapping the image.
	COOL_EMBER_TEXTURE_ID = "rbxassetid://126699412124780",
	-- NORMAL MAP id (kept for reference). NOTE: although a `Texture` object HAS a
	-- NormalMapContent property, it can only be WRITTEN by a plugin -- a runtime
	-- game Script lacks the Plugin capability, so we can't apply this at runtime on
	-- script-created ember textures. To get a normal-mapped ember you'd pre-author
	-- the Texture (with both maps set) on a template in Studio and clone it.
	EMBER_NORMAL_MAP_ID = "rbxassetid://90143663586956",
	-- One ember tile spans this many studs (3 = one tile per standard block face).
	EMBER_STUDS_PER_TILE = 3,
	-- Embers stay invisible until char reaches EMBER_START, then fade in to fully
	-- visible by EMBER_FULL. Raising EMBER_START makes the block char/darken for a
	-- while BEFORE the embers begin appearing.
	EMBER_START = 0.4,
	EMBER_FULL = 0.85,

	-- SMOOTHING / ANIMATION (per-frame, independent of the 2s char tick).
	-- How fast the block colour & ember transparency ease toward their targets.
	-- Higher = snappier. ~3-5 feels smooth without lag.
	EASE_SPEED = 3.5,
	-- Ember pulse while burning: transparency oscillates +/- PULSE_AMOUNT around
	-- its target at PULSE_SPEED radians/sec (a slow breathing glow).
	PULSE_AMOUNT = 0.35,
	PULSE_SPEED = 5.0,
	-- PULSE RANDOMNESS: so embers don't all breathe in perfect unison.
	--   PULSE_PHASE_RANDOM: each block gets a random phase offset (radians) up to
	--     this, so their pulses are out of sync.
	--   PULSE_SPEED_VARY: each block's pulse speed is multiplied by a random factor
	--     in [1-VARY, 1+VARY], so they breathe at slightly different rates.
	--   PULSE_NONE_CHANCE: fraction (0-1) of blocks that DON'T pulse at all -- they
	--     just sit at a steady glow (0.25 = ~a quarter of blocks are steady).
	PULSE_PHASE_RANDOM = 6.28,  -- up to a full 2*pi offset
	PULSE_SPEED_VARY = 0.35,    -- +/- 35% speed variation per block
	PULSE_NONE_CHANCE = 0.25,   -- ~25% of blocks don't pulse
	-- COOLDOWN: once a block is fully out (NO fire on any face), embers swap to the
	-- COOL_EMBER_TEXTURE_ID (a black-and-white version) and tint toward COOL_COLOR
	-- over COOL_DURATION, keeping a slow faint pulse forever (never fully cold). The
	-- block stays glowing-hot for the whole COOL_DURATION before it finishes cooling
	-- -- set this long (e.g. 60s) so charred blocks smoulder for a while.
	-- COOL_PULSE_* control that lingering glow.
	COOL_DURATION = 30.0,
	COOL_COLOR = Color3.fromRGB(235, 235, 235), -- pale ash the embers cool to
	COOL_PULSE_AMOUNT = 0.15, -- gentler than the burning pulse
	COOL_PULSE_SPEED = 1.5,   -- slower breathing once the fire's out
	-- PERF: cooled blocks pulse slowly forever, so we don't need to update them
	-- every frame. Update them once every COOL_UPDATE_EVERY frames instead (the
	-- slow pulse hides the lower rate). Burning blocks always update every frame.
	COOL_UPDATE_EVERY = 3,

	-- Stray fires (non-flammable host, no flammable neighbours) fizzle after
	-- this many ticks. Set false to let them burn forever.
	EXTINGUISH_STRAY = true,
	STRAY_TICKS_TO_FIZZLE = 4,

	-- EMBER DRIP: a hot charred block that's still cooling AND floating in the air
	-- crumbles little embers off its underside that fall and fade (client VFX). Only
	-- while the block is hot (within COOL_DURATION of going out) and has empty space
	-- below it. EMBER_DRIP_INTERVAL throttles how often (seconds) a given block emits.
	-- Set EMBER_DRIP_ENABLED=false to disable.
	EMBER_DRIP_ENABLED = true,
	EMBER_DRIP_INTERVAL = 0.6,
	-- The block drips embers only during its HOT ember window -- the early part of
	-- cooling while it's still glowing -- NOT for the whole slow fade to ash. Once
	-- coolAge passes EMBER_HOT_DURATION the embers have cooled enough that dripping
	-- stops (the block keeps fading to B&W over the longer COOL_DURATION, then falls).
	-- Keep this well under COOL_DURATION so there's a visible "cooled, no longer
	-- dripping" phase before it drops.
	EMBER_HOT_DURATION = 8.0,

	-- ============================================
	-- BURNT-BLOCK COLLAPSE (charred blocks fall when unsupported)
	-- ============================================
	-- Once a block is fully charred and its flame is out, if it's FLOATING (nothing
	-- in the cell directly below) it gives way after a short delay and falls,
	-- grid-snapping down onto the first solid block (or plot floor) beneath it.
	--   FALL_ENABLED: master switch for the whole collapse feature.
	--   FALL_AFTER_COOLDOWN: wait for the ember cool-to-B&W (COOL_DURATION) to finish
	--     before the fall timer even starts, so a block visibly cools FIRST, then
	--     falls.
	--   A block that's ALONE in the air (no neighbours on any of the 6 sides) falls
	--     INSTANTLY once cooled. A block that still has neighbours "hangs on" for a
	--     random FALL_DELAY_MIN..FALL_DELAY_MAX seconds before giving way.
	--   FALL_DELAY: legacy flat delay (kept as a fallback / if min==max not set).
	--   FALL_TWEEN_TIME: how long the drop animation takes (visual only).
	--   FALL_BREAK_HEIGHT: if it fell at least this many cells, it SHATTERS on
	--     landing (with a particle burst). A shorter fall leaves it FRAGILE
	--     (survives, but breaks on touch / instant hand-break -- handled in
	--     BlockHandler in a later stage).
	--   FALL_MAX_SCAN: how many cells down to search for a landing surface before
	--     giving up (treats the plot floor as the backstop).
	FALL_ENABLED = true,
	FALL_AFTER_COOLDOWN = true,   -- wait FALL_COOLDOWN_WAIT before falling (NOT the full
	                             -- COOL_DURATION, which is now ~60s for the ember glow)
	FALL_COOLDOWN_WAIT = 3.0,    -- seconds after the fire's fully out before the fall timer starts
	FALL_DELAY = 1.0,            -- legacy flat delay (fallback)
	FALL_DELAY_MIN = 1.0,        -- min random hang time for a block WITH neighbours
	FALL_DELAY_MAX = 5.0,        -- max random hang time for a block WITH neighbours
	FALL_TWEEN_TIME = 0.35,
	FALL_BREAK_HEIGHT = 3,
	FALL_MAX_SCAN = 64,

	-- ============================================
	-- FIRE VARIANT PLACEMENT (Top / Side / Bottom)
	-- ============================================
	-- Three fire models, picked by which FACE of the host is burning:
	--   "Fire"       -> the cell ABOVE a block (top surface burning) -- 3x3x3 cube
	--   "FireSide"   -> mounted flat on one of the 4 vertical faces (Part)
	--   "FireBottom" -> hung under a block (underside burning) (Model)
	-- Pivots for FireSide/FireBottom sit ON the contact face that touches the
	-- block, so we place the pivot directly on the host's face (no centre offset).

	-- FireSide's default facing at identity orientation: which way its mounting
	-- BACK-FACE points before any rotation. Used to compute the rotation onto each
	-- wall. If side fires end up facing the wrong way / inside-out, change this to
	-- one of: "PosZ", "NegZ", "PosX", "NegX".
	FIRE_SIDE_DEFAULT_FACING = "PosZ",

	-- Fine-tune nudges (studs) along the face normal, in case a model's contact
	-- face isn't exactly on its pivot. 0 = flush. Positive = push outward off the
	-- block; negative = sink into it.
	FIRE_SIDE_NORMAL_NUDGE = 0,
	FIRE_BOTTOM_NORMAL_NUDGE = 0,

	-- FIREBOTTOM FINE-TUNING. The FireBottom model is authored with a built-in
	-- orientation (~89.94, 0, 0) so its flame planes lie flat. We PRESERVE that
	-- authored rotation (instead of forcing identity, which tipped it on its side)
	-- and only reposition it. Dial these in live -- no geometry math needed:
	--   FIRE_BOTTOM_LIFT: studs to push the model UP toward the block after its
	--     pivot lands on the bottom face. Its pivot is near the model CENTRE, so it
	--     starts hanging ~half its height too low; INCREASE LIFT until the top kisses
	--     the underside. Negative sinks it up into the block.
	--   FIRE_BOTTOM_EXTRA_ROT_X/_Y/_Z: extra rotation (DEGREES) ON TOP of the
	--     authored orientation. X=180 flips it upside-down (correct resting look);
	--     adjust only if the model art changes.
	FIRE_BOTTOM_LIFT = 0,
	FIRE_BOTTOM_EXTRA_ROT_X = 180,
	FIRE_BOTTOM_EXTRA_ROT_Y = 0,
	FIRE_BOTTOM_EXTRA_ROT_Z = 0,
}

-- Flammable block matcher.
local FLAMMABLE_EXACT = {
	["Wool"] = true,
	["Leaves"] = true,
	["HayBale"] = true,
	["Planks"] = true,
	["Log"] = true,
	["LogHollow"] = true,
	["Oak"] = true,
	["Birch"] = true,
	["Spruce"] = true,
	["DarkOak"] = true,
}
-- Name suffixes (catches OakPlanks, BirchLog, plank stairs/slabs if named *Planks*, etc.):
local FLAMMABLE_SUFFIXES = {
	"Planks", "Log", "LogHollow", "Leaves", "Wool", "HayBale",
}
-- Wood-family prefixes (catches OakStair, BirchSlab, SpruceFence, etc.):
local FLAMMABLE_PREFIXES = {
	"Oak", "Birch", "Spruce", "DarkOak",
}
-- Wood-prefixed types we DON'T want to burn (saplings are plants, not fuel).
local FLAMMABLE_BLACKLIST_SUFFIXES = {
	"Sapling",
}

-- String helpers (declared here so the ENCOURAGEMENT/FLAMMABILITY lookups below
-- can use them -- a local function isn't visible above its own declaration).
local function endsWith(s, suffix)
	return #s >= #suffix and string.sub(s, -#suffix) == suffix
end
local function startsWith(s, prefix)
	return string.sub(s, 1, #prefix) == prefix
end

-- ============================================
-- PER-BLOCK ENCOURAGEMENT + FLAMMABILITY (Minecraft-style)
-- ============================================
-- Minecraft gives every flammable block two stats:
--   ENCOURAGEMENT ("ignite odds"): how readily it CATCHES. Higher = catches
--     faster. We use it as a MULTIPLIER on CONFIG.SPREAD_CHANCE.
--   FLAMMABILITY  ("burn odds"): how fast it BURNS AWAY once lit. Higher = chars
--     faster. We use it as a MULTIPLIER on CONFIG.CHAR_PER_TICK.
-- Values are normalised around 1.0 (1.0 = the baseline plank). Wool/leaves catch
-- and burn fast; logs are stubborn. Matched by the same exact/suffix/prefix
-- logic as isFlammable, so "OakPlanks" picks up the "Planks" entry, etc.
-- Lookups fall back to 1.0 for any flammable block without an explicit entry.
local ENCOURAGEMENT = {        -- catch-speed multiplier
	Wool     = 2.5,  -- whooshes up almost instantly (MC encouragement 30)
	Leaves   = 2.0,  -- catches very fast (MC 30/60)
	HayBale  = 1.5,
	Planks   = 1.0,  -- baseline (MC encouragement 5)
	Log      = 0.5,  -- stubborn; solid wood catches slowly (MC 5 but high mass)
	LogHollow= 0.7,
}
local FLAMMABILITY = {         -- burn-away (char) speed multiplier
	Wool     = 1.8,  -- burns away fast (MC flammability 60)
	Leaves   = 1.6,
	HayBale  = 1.4,
	Planks   = 1.0,  -- baseline (MC flammability 20)
	Log      = 0.6,  -- thick wood takes a while to char through (MC 5)
	LogHollow= 0.8,
}

-- Resolve a per-block multiplier from one of the tables above, using the same
-- exact -> suffix -> prefix matching order as isFlammable. Defaults to 1.0.
local function lookupBlockStat(tableRef, blockType)
	if not blockType then return 1.0 end
	if tableRef[blockType] then return tableRef[blockType] end
	for key, val in pairs(tableRef) do
		if endsWith(blockType, key) or startsWith(blockType, key) then
			return val
		end
	end
	return 1.0
end
local function encouragementOf(blockType)
	return lookupBlockStat(ENCOURAGEMENT, blockType)
end
local function flammabilityOf(blockType)
	return lookupBlockStat(FLAMMABILITY, blockType)
end

-- ETERNAL-FIRE host types: blocks that, when lit, hold a fire FOREVER. The fire
-- never chars/consumes them and never goes out on its own (only manual
-- extinguish removes it), but it STILL ignites nearby flammable blocks. These
-- types are also never valid ignition targets themselves (so fire won't spread
-- between them). Netherrack is the classic example; SoulSand carries the blue
-- "soul fire" variant the same way.
local ETERNAL_FIRE_TYPES = {
	["Netherrack"] = true,
	["SoulSand"]   = true,
}

local function isEternalFireHost(blockType)
	return blockType ~= nil and ETERNAL_FIRE_TYPES[blockType] == true
end

local function isFlammable(blockType)
	if not blockType then return false end
	if blockType == "Fire" then return false end
	for _, suf in ipairs(FLAMMABLE_BLACKLIST_SUFFIXES) do
		if endsWith(blockType, suf) then return false end
	end
	if FLAMMABLE_EXACT[blockType] then return true end
	for _, suf in ipairs(FLAMMABLE_SUFFIXES) do
		if endsWith(blockType, suf) then return true end
	end
	for _, pre in ipairs(FLAMMABLE_PREFIXES) do
		if startsWith(blockType, pre) then return true end
	end
	return false
end

-- A block is "fuel" only if its type is flammable AND it isn't already fully
-- charred (spent). Spent blocks neither keep charring nor ignite neighbours.
local function blockIsFuel(block)
	if not block then return false end
	if block:GetAttribute("FullyCharred") then return false end
	return isFlammable(block:GetAttribute("BlockType") or block.Name)
end

local DEBUG_FIRE = true

local ActivePlots = {}
local IsRunning = false
local LastTickTime = 0

-- ============================================
-- FIRE FACES
-- ============================================
-- A fire's FireFace tells us which face of its host block is burning, which in
-- turn decides the variant model, where the fire sits, and (for sides) how it's
-- rotated. "Top" is the legacy/default (cube in the cell above).
--
-- FACE_NORMAL: outward unit normal of that face.
-- For each face, the fire's grid cell and host relationship differ:
--   Top    -> fire occupies cell ABOVE host; host = fire cell - up
--   Bottom -> fire hangs UNDER host (same column);  host = fire's host-center directly
--   Side   -> fire mounts on the wall of host;       host = the block it's stuck to
local FACE_NORMAL = {
	Top    = Vector3.new(0, 1, 0),
	Bottom = Vector3.new(0, -1, 0),
	PosX   = Vector3.new(1, 0, 0),
	NegX   = Vector3.new(-1, 0, 0),
	PosZ   = Vector3.new(0, 0, 1),
	NegZ   = Vector3.new(0, 0, -1),
}

-- Which faces are "sides" (use FireSide), vs top (Fire cube) / bottom (FireBottom).
local SIDE_FACES = {
	PosX = true, NegX = true, PosZ = true, NegZ = true,
}

-- Map a spread OFFSET (direction we spread from the source) to the face of the
-- NEIGHBOUR that should catch. When fire at the source moves +X to a neighbour,
-- it arrives on that neighbour's -X (NegX) face, etc. Vertical handled separately.
local function offsetToNeighbourFace(offset)
	if offset.X > 0 then return "NegX" end
	if offset.X < 0 then return "PosX" end
	if offset.Z > 0 then return "NegZ" end
	if offset.Z < 0 then return "PosZ" end
	if offset.Y > 0 then return "Bottom" end -- spread upward -> catches neighbour's underside
	if offset.Y < 0 then return "Top" end    -- spread downward -> catches neighbour's top
	return "Top"
end

-- Classify a spread offset into a direction kind for FIRE_DIRECTION_BIAS:
-- moving toward a higher cell = "up", lower = "down", same height = "side".
local function offsetDirKind(offset)
	if offset.Y > 0 then return "up" end
	if offset.Y < 0 then return "down" end
	return "side"
end

-- Yaw (radians) to rotate FireSide so its default-facing back-face points along
-- the GIVEN outward face normal. Computed from CONFIG.FIRE_SIDE_DEFAULT_FACING.
local function sideYawFor(face)
	local function yawOf(f)
		-- angle of the normal in the XZ plane (atan2(x, z)), matching Roblox Y-yaw
		local n = FACE_NORMAL[f]
		return math.atan2(n.X, n.Z)
	end
	local target = yawOf(face)
	local default = yawOf(CONFIG.FIRE_SIDE_DEFAULT_FACING)
	return target - default
end

-- ============================================
-- FIRE BUILD RECIPE (mirrors ToolHandler.buildFireBlock — Three-File Rule)
-- ============================================

-- Build a fire on a given FACE of a host block. `face` is one of:
--   "Top" (default, 3x3x3 cube in cell above), "Bottom" (hung underneath),
--   "PosX"/"NegX"/"PosZ"/"NegZ" (mounted flat on that wall).
-- hostCenter is the grid centre of the burning block. The fire records its host
-- and its face so the tick/extinguish logic can find its support correctly.
local function buildFireBlock(blocksFolder, hostCenter, placedByUserId, face, variant)
	face = face or "Top"
	variant = variant or "Normal"

	-- Pick the template family from the variant (mirrors ToolHandler -- Three-File Rule).
	local prefix = (variant == "Blue") and "FireBlue" or "Fire"

	-- Pick the variant template for this face.
	local templateName
	if face == "Top" then
		templateName = prefix
	elseif face == "Bottom" then
		templateName = prefix .. "Bottom"
	else
		templateName = prefix .. "Side"
	end

	local template = BlockTemplates:FindFirstChild(templateName)
	if not template then
		-- Try the same face on the normal family before falling back to the Top cube,
		-- so a missing FireBlue still spreads as a normal fire of the correct face.
		if variant == "Blue" then
			warn(string.format("[BB-FIRE] BlockTemplates.%s missing; falling back to normal Fire family", templateName))
			local normalName
			if face == "Top" then normalName = "Fire"
			elseif face == "Bottom" then normalName = "FireBottom"
			else normalName = "FireSide" end
			template = BlockTemplates:FindFirstChild(normalName)
		end
		-- Fall back to the top cube if a variant model isn't present yet (e.g. not
		-- synced from Studio), so spread never silently no-ops.
		if not template and templateName ~= "Fire" then
			warn(string.format("[BB-FIRE] BlockTemplates.%s missing; falling back to Fire cube", templateName))
			template = BlockTemplates:FindFirstChild("Fire")
			face = "Top"
		end
		if not template then
			warn("[BB-FIRE] BlockTemplates.Fire template not found")
			return nil
		end
	end

	local fire = template:Clone()
	fire.Name = template.Name
	if fire:IsA("BasePart") then
		fire.Anchored = true
		fire.CanCollide = false
		fire.CanQuery = true
	elseif fire:IsA("Model") then
		for _, d in ipairs(fire:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = true
			end
		end
	end

	-- ---- Position + orientation per face ----
	-- gridPos is the cell the fire is logically registered to (used for occupancy
	-- checks). For Top that's the cell above; for Side/Bottom we register the fire
	-- to the HOST's own cell offset so two fires don't claim the same coordinate.
	local normal = FACE_NORMAL[face] or FACE_NORMAL.Top
	local gridPos

	if face == "Top" then
		-- Legacy: 3x3x3 cube fills the cell ABOVE the support. Correct only the X/Z
		-- pivot offset (off-centre model) -- same as before.
		local visualPos = hostCenter + Vector3.new(0, BLOCK_SIZE, 0)
		gridPos = visualPos
		if fire:IsA("BasePart") then
			fire.Position = visualPos
		elseif fire:IsA("Model") then
			local pivotCF = fire:GetPivot()
			local boxCF = fire:GetBoundingBox()
			local off = pivotCF:ToObjectSpace(boxCF).Position
			fire:PivotTo(CFrame.new(visualPos - Vector3.new(off.X, 0, off.Z)))
		end
	elseif face == "Bottom" then
		-- FireBottom hangs under the host. The model is authored with a built-in
		-- orientation so its flame planes lie flat -- we PRESERVE that rotation
		-- (forcing identity tipped it on its side) and only set its position. Its
		-- pivot sits near the model centre, so FIRE_BOTTOM_LIFT pushes it up flush.
		local faceCenter = hostCenter + normal * (BLOCK_SIZE / 2)
			+ normal * CONFIG.FIRE_BOTTOM_NORMAL_NUDGE
			+ Vector3.new(0, CONFIG.FIRE_BOTTOM_LIFT, 0)
		gridPos = hostCenter + Vector3.new(0, -BLOCK_SIZE, 0) -- the empty cell below
		-- Authored rotation from the template's pivot (rotation part only).
		local authoredRot = fire:GetPivot().Rotation
		local extra = CFrame.Angles(
			math.rad(CONFIG.FIRE_BOTTOM_EXTRA_ROT_X),
			math.rad(CONFIG.FIRE_BOTTOM_EXTRA_ROT_Y),
			math.rad(CONFIG.FIRE_BOTTOM_EXTRA_ROT_Z))
		fire:PivotTo(CFrame.new(faceCenter) * authoredRot * extra)
	else
		-- FireSide mounts flat on a wall. Pivot sits ON the host's side face, and we
		-- yaw it so its default-facing back-face points along this face's normal.
		local faceCenter = hostCenter + normal * (BLOCK_SIZE / 2)
			+ normal * CONFIG.FIRE_SIDE_NORMAL_NUDGE
		gridPos = hostCenter + normal * BLOCK_SIZE -- the empty cell beside the host
		local yaw = sideYawFor(face)
		if fire:IsA("BasePart") then
			fire.CFrame = CFrame.new(faceCenter) * CFrame.Angles(0, yaw, 0)
		else
			fire:PivotTo(CFrame.new(faceCenter) * CFrame.Angles(0, yaw, 0))
		end
	end

	fire:SetAttribute("BlockType", "Fire")
	fire:SetAttribute("IsFire", true)
	fire:SetAttribute("FireFace", face)
	if variant == "Blue" then
		fire:SetAttribute("FireVariant", "Blue") -- preserved by save/load and used by spread
	end
	fire:SetAttribute("BlockPosX", gridPos.X)
	fire:SetAttribute("BlockPosY", gridPos.Y)
	fire:SetAttribute("BlockPosZ", gridPos.Z)
	fire:SetAttribute("HostBlockX", hostCenter.X)
	fire:SetAttribute("HostBlockY", hostCenter.Y)
	fire:SetAttribute("HostBlockZ", hostCenter.Z)
	fire:SetAttribute("IsNaturalFire", true) -- spread by the system, not player-lit
	if placedByUserId then
		fire:SetAttribute("PlacedBy", placedByUserId)
	end

	fire.Parent = blocksFolder
	return fire
end

-- ============================================
-- HELPERS
-- ============================================

local function getFireHostCenter(fire)
	local hx = fire:GetAttribute("HostBlockX")
	local hy = fire:GetAttribute("HostBlockY")
	local hz = fire:GetAttribute("HostBlockZ")
	if hx and hy and hz then
		return Vector3.new(hx, hy, hz)
	end
	-- Fallback for very old fires with no HostBlock* attributes: assume the legacy
	-- Top layout (host is one cell below the fire's grid position).
	local px = fire:GetAttribute("BlockPosX")
	local py = fire:GetAttribute("BlockPosY")
	local pz = fire:GetAttribute("BlockPosZ")
	if px and py and pz then
		return Vector3.new(px, py - BLOCK_SIZE, pz)
	end
	return nil
end

-- True if the given host already has a fire on the given FACE. We match on the
-- fire's HostBlock* + FireFace so a block can carry a Top fire AND a side fire
-- without them being confused for one another.
local function hostHasFireOnFace(hostCenter, face, index)
	-- The fire for this (host, face) registers its BlockPos at a known cell:
	--   Top    -> host + up
	--   Bottom -> host - up
	--   Side   -> host + faceNormal
	local normal = FACE_NORMAL[face] or FACE_NORMAL.Top
	local fireCell
	if face == "Top" then
		fireCell = hostCenter + Vector3.new(0, BLOCK_SIZE, 0)
	elseif face == "Bottom" then
		fireCell = hostCenter + Vector3.new(0, -BLOCK_SIZE, 0)
	else
		fireCell = hostCenter + normal * BLOCK_SIZE
	end
	for _, b in ipairs(index:GetBlocksAt(fireCell)) do
		if b:GetAttribute("IsFire") and (b:GetAttribute("FireFace") or "Top") == face then
			return true
		end
	end
	return false
end

-- Legacy helper kept for the top-cube path: is there a fire in the cell above
-- this center? (Equivalent to hostHasFireOnFace(center, "Top", index).)
local function hasFireOn(center, index)
	return hostHasFireOnFace(center, "Top", index)
end

-- True if the host block at `hostCenter` has ANY fire on ANY of its 6 faces. Used
-- to gate cooling + collapse: a block isn't "truly out" (and shouldn't cool its
-- embers to white or start falling) until every face it carries has gone out.
local function hostHasAnyFire(hostCenter, index)
	for face, _ in pairs(FACE_NORMAL) do
		if hostHasFireOnFace(hostCenter, face, index) then
			return true
		end
	end
	return false
end

-- ============================================
-- EMBER ANIMATION (smooth, per-frame)
-- ============================================
-- The 2s char tick only sets TARGETS (CharLevel target, phase). This registry +
-- Heartbeat loop does the smooth visual work: easing block colour toward its
-- char target, easing ember transparency in, pulsing embers while burning, and
-- cross-fading embers to white over COOL_DURATION once the fire is out.
local AnimatedBlocks = {}  -- [hostBlock] = { parts = {...}, embers = {...}, phase, coolStart }

local function snapshotOrigColor(part)
	local origR = part:GetAttribute("CharOrigR")
	if origR == nil then
		local c = part.Color
		part:SetAttribute("CharOrigR", c.R)
		part:SetAttribute("CharOrigG", c.G)
		part:SetAttribute("CharOrigB", c.B)
		return c.R, c.G, c.B
	end
	return origR, part:GetAttribute("CharOrigG"), part:GetAttribute("CharOrigB")
end

-- The biggest BasePart in a host (single part, or the main body of a model).
local function getLargestPart(hostBlock)
	if hostBlock:IsA("BasePart") then return hostBlock end
	local best, bestVol = nil, -1
	for _, d in ipairs(hostBlock:GetDescendants()) do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > bestVol then best, bestVol = d, v end
		end
	end
	return best
end

-- Collect all BaseParts of a host (for colour darkening).
local function getColorParts(hostBlock)
	local parts = {}
	if hostBlock:IsA("BasePart") then
		table.insert(parts, hostBlock)
	elseif hostBlock:IsA("Model") then
		for _, d in ipairs(hostBlock:GetDescendants()) do
			if d:IsA("BasePart") then table.insert(parts, d) end
		end
	end
	return parts
end

-- Map our face names to the Roblox NormalId used by Texture.Face.
local EMBER_FACE_NORMALID = {
	Top    = Enum.NormalId.Top,
	Bottom = Enum.NormalId.Bottom,
	Front  = Enum.NormalId.Front,
	Back   = Enum.NormalId.Back,
	Right  = Enum.NormalId.Right,
	Left   = Enum.NormalId.Left,
}

local _emberTextureId = nil
local function getEmberTextureId()
	if _emberTextureId ~= nil then return _emberTextureId end
	if CONFIG.EMBER_TEXTURE_ID ~= "" then
		_emberTextureId = CONFIG.EMBER_TEXTURE_ID
		return _emberTextureId
	end
	local template = BlockTemplates:FindFirstChild("BlockEmbers")
	if template then
		local sa = template:FindFirstChildWhichIsA("SurfaceAppearance")
		if sa and sa.ColorMap ~= "" then
			_emberTextureId = sa.ColorMap
			return _emberTextureId
		end
	end
	_emberTextureId = ""
	warn("[BB-FIRE] No ember texture id (set CONFIG.EMBER_TEXTURE_ID or give BlockEmbers a ColorMap)")
	return _emberTextureId
end

-- Ensure the ember textures exist on the host's largest part. Returns the list
-- of Texture instances (created transparent; the anim loop fades them in).
local function ensureEmberTextures(hostBlock)
	local textureId = getEmberTextureId()
	if textureId == "" then return {} end
	local targetPart = getLargestPart(hostBlock)
	if not targetPart then return {} end

	local embers = {}
	for _, faceName in ipairs(CONFIG.EMBER_FACES) do
		local normalId = EMBER_FACE_NORMALID[faceName]
		if normalId then
			local name = "Ember_" .. faceName
			local tex = targetPart:FindFirstChild(name)
			if not tex then
				tex = Instance.new("Texture")
				tex.Name = name
				-- NOTE: ColorMapContent/NormalMapContent (the PBR Texture maps) can only be
				-- WRITTEN by a plugin -- a runtime game Script lacks the Plugin capability
				-- and throws "cannot write 'NormalMapContent'". So at runtime we must use
				-- the legacy `Texture` string property (colour only; no normal map).
				tex.Texture = textureId
				tex.Face = normalId
				tex.StudsPerTileU = CONFIG.EMBER_STUDS_PER_TILE
				tex.StudsPerTileV = CONFIG.EMBER_STUDS_PER_TILE
				tex.Transparency = 1
				tex.Parent = targetPart
			end
			table.insert(embers, tex)
		end
	end
	return embers
end

-- Register/refresh a block in the animation system. `charTarget` is the desired
-- char level (0-1). `cooling` flips it into the cool-to-white phase.
local function registerAnimation(hostBlock, charTarget, cooling)
	local entry = AnimatedBlocks[hostBlock]
	if not entry then
		entry = {
			parts = getColorParts(hostBlock),
			embers = ensureEmberTextures(hostBlock),
			phase = "burning",
			coolStart = nil,
			-- Per-block pulse personality (so embers don't breathe in unison):
			--   pulsePhase: random starting offset on the sine wave.
			--   pulseSpeedMul: random per-block speed multiplier.
			--   pulses: false for a random fraction of blocks -> steady glow, no pulse.
			pulsePhase = math.random() * CONFIG.PULSE_PHASE_RANDOM,
			pulseSpeedMul = 1 + (math.random() * 2 - 1) * CONFIG.PULSE_SPEED_VARY,
			pulses = (math.random() >= CONFIG.PULSE_NONE_CHANCE),
		}
		-- Snapshot original colours up front.
		for _, p in ipairs(entry.parts) do snapshotOrigColor(p) end
		AnimatedBlocks[hostBlock] = entry
	end
	entry.charTarget = charTarget
	if cooling and entry.phase ~= "cooling" then
		entry.phase = "cooling"
		entry.coolStart = tick()
		-- Swap the ember image to the black-and-white cooled version (once). If no
		-- cool asset is configured, we keep the burning texture and just tint it.
		-- (Uses the legacy Texture string property -- ColorMapContent can't be written
		-- at runtime, only by a plugin.)
		if CONFIG.COOL_EMBER_TEXTURE_ID and CONFIG.COOL_EMBER_TEXTURE_ID ~= "" then
			for _, tex in ipairs(entry.embers) do
				if tex.Parent then
					tex.Texture = CONFIG.COOL_EMBER_TEXTURE_ID
				end
			end
		end
	end
end

-- Smoothly drive every animated block toward its targets, once per frame.
local _animFrame = 0
local function stepAnimations(dt)
	local alpha = 1 - math.exp(-CONFIG.EASE_SPEED * dt) -- frame-rate-independent ease
	local now = tick()
	_animFrame += 1

	for hostBlock, entry in pairs(AnimatedBlocks) do
		if not hostBlock.Parent then
			AnimatedBlocks[hostBlock] = nil
			continue
		end

		local cooling = entry.phase == "cooling"

		-- PERF: cooled blocks only need updating every COOL_UPDATE_EVERY frames
		-- (their pulse is slow). Skip them on other frames to keep the standing
		-- cost of many burned blocks low. Burning blocks always update.
		if cooling and (_animFrame % CONFIG.COOL_UPDATE_EVERY) ~= 0 then
			continue
		end

		-- ---- Block colour: ease toward the heat/char goal ----
		-- The goal colour travels along a TWO-STAGE arc by char level:
		--   0 .. HEAT_PEAK : original colour  -> hot RED   (the block heats up/glows)
		--   HEAT_PEAK .. 1 : hot RED          -> dark char (the red burns down to black)
		-- While COOLING we additionally desaturate the dark char toward grey, so the
		-- spent block reads as cold ash rather than a warm-tinted black.
		-- Once fully charred AND settled, the goal stops changing so we stop re-lerping.
		if not entry.colorSettled then
			local target = math.clamp(entry.charTarget or 0, 0, 1)
			local peak = math.clamp(CONFIG.CHAR_HEAT_PEAK, 0.001, 0.999)
			local heat = CONFIG.CHAR_HEAT_COLOR
			local maxDiff = 0
			for _, p in ipairs(entry.parts) do
				if p.Parent then
					local oR, oG, oB = snapshotOrigColor(p)
					local orig = Color3.new(oR, oG, oB)
					-- The fully-charred dark colour: the ORIGINAL darkened (keeps a faint
					-- hint of the block's own hue), same as before.
					local darkScale = CONFIG.CHAR_DARKEN
					local darkChar = Color3.new(oR * darkScale, oG * darkScale, oB * darkScale)
					-- Stage by char level.
					local goal
					if target <= peak then
						goal = orig:Lerp(heat, target / peak)
					else
						goal = heat:Lerp(darkChar, (target - peak) / (1 - peak))
					end
					-- Cooling desaturation: pull the goal toward its own greyscale luminance.
					if cooling and CONFIG.CHAR_COOL_DESAT > 0 then
						local lum = goal.R * 0.299 + goal.G * 0.587 + goal.B * 0.114
						goal = goal:Lerp(Color3.new(lum, lum, lum), CONFIG.CHAR_COOL_DESAT)
					end
					p.Color = p.Color:Lerp(goal, alpha)
					maxDiff = math.max(maxDiff,
						math.abs(p.Color.R - goal.R),
						math.abs(p.Color.G - goal.G),
						math.abs(p.Color.B - goal.B))
				end
			end
			-- When fully charred and the colour has essentially reached its goal,
			-- stop animating the block colour (the embers keep going).
			if cooling and maxDiff < 0.003 then
				entry.colorSettled = true
			end
		end

		-- ---- Embers ----
		-- Base transparency target from char progress (fade-in window).
		local target = math.clamp(entry.charTarget or 0, 0, 1)
		local range = math.max(CONFIG.EMBER_FULL - CONFIG.EMBER_START, 0.001)
		local progress = math.clamp((target - CONFIG.EMBER_START) / range, 0, 1)
		local baseTransparency = 1 - progress

		if cooling then
			-- Fire is out: tint embers from their current colour toward the pale ash
			-- COOL_COLOR over COOL_DURATION, but keep a SLOW, FAINT pulse going forever
			-- so the embers never look fully dead. We do NOT unregister the block.
			local t = math.clamp((now - (entry.coolStart or now)) / CONFIG.COOL_DURATION, 0, 1)
			local tint = Color3.new(1, 1, 1):Lerp(CONFIG.COOL_COLOR, t)

			-- Ease the visible base toward the fade-in target (stays fully visible).
			entry.emberBase = (entry.emberBase or 0)
			entry.emberBase = entry.emberBase + (baseTransparency - entry.emberBase) * alpha
			-- Slow, gentle breathing pulse on top (applied directly so it isn't damped),
			-- with this block's own random phase + speed. Some blocks don't pulse at all.
			local pulse = 0
			if entry.pulses then
				pulse = (math.sin(now * CONFIG.COOL_PULSE_SPEED * entry.pulseSpeedMul + entry.pulsePhase) * 0.5 + 0.5) * CONFIG.COOL_PULSE_AMOUNT
			end
			local finalTransparency = math.clamp(entry.emberBase + pulse, 0, 1)

			local tintDone = (t >= 1)
			for _, tex in ipairs(entry.embers) do
				if tex.Parent then
					if not tintDone then
						tex.Color3 = tex.Color3:Lerp(tint, alpha)
					end
					tex.Transparency = finalTransparency
				end
			end
			-- Stays registered: the slow pulse continues for the life of the block.
		else
			-- Burning: smoothly EASE the fade-in toward baseTransparency, but apply the
			-- pulse DIRECTLY on top (not eased) so the oscillation isn't damped out.
			-- We track the eased fade-in level per entry so the pulse rides on a stable
			-- base instead of fighting the easing.
			entry.emberBase = (entry.emberBase or 1)
			entry.emberBase = entry.emberBase + (baseTransparency - entry.emberBase) * alpha
			local pulse = 0
			if progress > 0 and entry.pulses then
				-- Once embers are visible at all, pulse at full configured strength (a
				-- steady breathing glow) rather than scaling by char progress -- otherwise
				-- the pulse is barely perceptible during the short burn window. Only adds
				-- transparency (darkens) so it breathes down from full brightness. Uses this
				-- block's own random phase + speed so embers don't pulse in unison; some
				-- blocks (entry.pulses == false) skip the pulse entirely for a steady glow.
				pulse = (math.sin(now * CONFIG.PULSE_SPEED * entry.pulseSpeedMul + entry.pulsePhase) * 0.5 + 0.5) * CONFIG.PULSE_AMOUNT
			end
			local finalTransparency = math.clamp(entry.emberBase + pulse, 0, 1)
			for _, tex in ipairs(entry.embers) do
				if tex.Parent then
					tex.Transparency = finalTransparency
				end
			end
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	if next(AnimatedBlocks) ~= nil then
		stepAnimations(dt)
	end
end)

-- ============================================
-- BURNT-BLOCK COLLAPSE (grid-snap fall when unsupported)
-- ============================================
-- When a block finishes charring and its flame goes out, if it's floating it
-- gives way and falls, grid-snapping down onto the first solid block (or the plot
-- floor) beneath it. We keep everything consistent with the grid/index/save
-- system: scan the column with the spatial index, tween the visuals down, update
-- the block's BlockPos* attributes, and Reindex it into its new cell.
--
-- Stage 1 (this): the fall + grid-snap + reindex, and we TAG the outcome:
--   * Tall fall (>= FALL_BREAK_HEIGHT cells) -> SetAttribute("BurntShatter", true)
--   * Short fall                              -> SetAttribute("Fragile", true)
-- The actual shatter VFX (stage 2) and fragile break behaviour (stage 3) read
-- those tags in BlockHandler; for now the fall just lands and tags.

-- Pivot a block (Part or Model) to a grid CENTER, honouring the same pivot rules
-- the rest of the system uses (models are bottom-centre unless fence/glass).
local function pivotBlockToCenter(block, center)
	if block:IsA("BasePart") then
		block.CFrame = CFrame.new(center) * (block.CFrame - block.CFrame.Position)
	elseif block:IsA("Model") then
		local targetPivotPos
		if block:GetAttribute("IsFence") or block:GetAttribute("IsGlass") then
			targetPivotPos = center
		else
			targetPivotPos = center - Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
		local rot = block:GetPivot() - block:GetPivot().Position
		block:PivotTo(CFrame.new(targetPivotPos) * rot)
	end
end

-- Tween a block's visuals from its current pose down to a target grid CENTER.
local function tweenBlockDown(block, targetCenter, onComplete)
	local info = TweenInfo.new(CONFIG.FALL_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	if block:IsA("BasePart") then
		local goalCF = CFrame.new(targetCenter) * (block.CFrame - block.CFrame.Position)
		local tween = TweenService:Create(block, info, { CFrame = goalCF })
		tween.Completed:Connect(function() if onComplete then onComplete() end end)
		tween:Play()
	elseif block:IsA("Model") then
		-- Models can't be tweened directly; drive a CFrameValue and PivotTo each step.
		local startPivot = block:GetPivot()
		local rot = startPivot - startPivot.Position
		local targetPivotPos
		if block:GetAttribute("IsFence") or block:GetAttribute("IsGlass") then
			targetPivotPos = targetCenter
		else
			targetPivotPos = targetCenter - Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
		local driver = Instance.new("CFrameValue")
		driver.Value = startPivot
		local conn
		conn = driver.Changed:Connect(function(v)
			if block.Parent then block:PivotTo(v) end
		end)
		local goal = CFrame.new(targetPivotPos) * rot
		local tween = TweenService:Create(driver, info, { Value = goal })
		tween.Completed:Connect(function()
			if conn then conn:Disconnect() end
			driver:Destroy()
			if block.Parent then block:PivotTo(goal) end
			if onComplete then onComplete() end
		end)
		tween:Play()
	end
end

-- Shatter a burnt block: emit the blocky particle burst (client VFX) and remove
-- the block. Reads the block's current charred colour + size so the particles
-- match what just broke. Safe to call from server.
local function shatterBurntBlock(block, center)
	-- Resolve a representative colour + size from the block's largest part.
	local part = getLargestPart(block)
	local color = part and part.Color or Color3.fromRGB(40, 30, 25)
	local size = part and part.Size or Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
	-- The block has cooled to an ashy look by the time it falls, so DESATURATE the
	-- particle colour the same way the cooling block does -- otherwise the shards
	-- come out warm/colored while the block reads as ash. Match CHAR_COOL_DESAT.
	if CONFIG.CHAR_COOL_DESAT and CONFIG.CHAR_COOL_DESAT > 0 then
		local lum = color.R * 0.299 + color.G * 0.587 + color.B * 0.114
		color = color:Lerp(Color3.new(lum, lum, lum), CONFIG.CHAR_COOL_DESAT)
	end
	-- Tell every client to spawn the voxel burst at this spot.
	BurntShatterFX:FireAllClients({
		pos = center,
		size = size,
		color = color,
	})
	if DEBUG_FIRE then
		print(string.format("[BB-FIRE] Burnt block shattered at (%.1f,%.1f,%.1f)",
			center.X, center.Y, center.Z))
	end
	block:Destroy()
end

-- True if a block has NO neighbours on any of the 6 sides (truly alone, floating
-- by itself in the air). Such a block falls instantly once cooled; a block that
-- still has neighbours "hangs on" for a random delay before giving way.
-- NOTE: iterates FACE_NORMAL (declared near the top) rather than SPREAD_OFFSETS,
-- because SPREAD_OFFSETS is declared LOWER in the file than this function -- a Lua
-- local isn't visible above its declaration, so referencing it here would be nil.
local function isAloneInAir(center, index)
	for _, normal in pairs(FACE_NORMAL) do
		if index:HasBlockAt(center + normal * BLOCK_SIZE) then
			return false
		end
	end
	return true
end

-- Make a charred block fall. `center` is its current grid center; `index` is the
-- plot spatial index. Scans down for a landing surface, animates the drop, snaps
-- attributes + reindexes, and tags shatter/fragile by fall distance.
-- Forward-declared so collapseBurntBlock can call it from its landing callback to
-- knock down the stack above the vacated cell.
local cascadeFallAbove
local function collapseBurntBlock(block, center, index, blocksFolder)
	if not CONFIG.FALL_ENABLED then return end
	if block:GetAttribute("HasFallen") then return end -- only fall once

	-- Must be floating: the cell directly below must be empty.
	local belowCenter = center - Vector3.new(0, BLOCK_SIZE, 0)
	if index:HasBlockAt(belowCenter) then return end

	-- Scan down for the first occupied cell; rest one cell above it. If we never
	-- find one within FALL_MAX_SCAN, land at the bottom of the scan (treat as floor).
	local restCenter = center
	local landed = false
	for step = 1, CONFIG.FALL_MAX_SCAN do
		local probe = center - Vector3.new(0, BLOCK_SIZE * step, 0)
		if index:HasBlockAt(probe) then
			restCenter = probe + Vector3.new(0, BLOCK_SIZE, 0)
			landed = true
			break
		end
	end
	if not landed then
		restCenter = center - Vector3.new(0, BLOCK_SIZE * CONFIG.FALL_MAX_SCAN, 0)
	end

	-- No actual drop (already resting)? bail.
	local fellCells = math.floor((center.Y - restCenter.Y) / BLOCK_SIZE + 0.5)
	if fellCells <= 0 then return end

	block:SetAttribute("HasFallen", true)

	-- Compute the pre-fall delay:
	--   1. Wait for the ember cool-to-B&W to finish (COOL_DURATION) if enabled, so
	--      the block visibly cools FIRST.
	--   2. THEN: if it's alone in the air, fall instantly (0 extra); otherwise hang
	--      on for a random FALL_DELAY_MIN..FALL_DELAY_MAX before giving way.
	local cooldownWait = (CONFIG.FALL_AFTER_COOLDOWN and CONFIG.FALL_COOLDOWN_WAIT) or 0
	local alone = isAloneInAir(center, index)
	local hangDelay
	if alone then
		hangDelay = 0
	else
		local lo = CONFIG.FALL_DELAY_MIN or CONFIG.FALL_DELAY or 1
		local hi = CONFIG.FALL_DELAY_MAX or lo
		if hi < lo then hi = lo end
		hangDelay = lo + math.random() * (hi - lo)
	end
	local totalDelay = cooldownWait + hangDelay
	if DEBUG_FIRE then
		print(string.format("[BB-FIRE] Burnt block scheduled to fall in %.2fs (cool %.2f + hang %.2f, alone=%s)",
			totalDelay, cooldownWait, hangDelay, tostring(alone)))
	end

	-- Schedule the drop after the computed delay.
	task.delay(totalDelay, function()
		if not block.Parent then return end
		-- Re-confirm it's still unsupported and the rest cell is still free, in case
		-- the world changed during the delay. Recompute the landing fresh.
		local curCenter = center
		local freshRest = curCenter
		local freshLanded = false
		for step = 1, CONFIG.FALL_MAX_SCAN do
			local probe = curCenter - Vector3.new(0, BLOCK_SIZE * step, 0)
			if index:HasBlockAt(probe) then
				freshRest = probe + Vector3.new(0, BLOCK_SIZE, 0)
				freshLanded = true
				break
			end
		end
		if not freshLanded then
			freshRest = curCenter - Vector3.new(0, BLOCK_SIZE * CONFIG.FALL_MAX_SCAN, 0)
		end
		local freshFell = math.floor((curCenter.Y - freshRest.Y) / BLOCK_SIZE + 0.5)
		if freshFell <= 0 then return end

		tweenBlockDown(block, freshRest, function()
			if not block.Parent then return end
			-- Snap attributes to the new cell and reindex so save/load + neighbour
			-- lookups stay correct.
			block:SetAttribute("BlockPosX", freshRest.X)
			block:SetAttribute("BlockPosY", freshRest.Y)
			block:SetAttribute("BlockPosZ", freshRest.Z)
			pivotBlockToCenter(block, freshRest)
			index:Reindex(block)

			-- Outcome by fall distance: a tall fall SHATTERS on impact (particle burst
			-- + removal); a short fall leaves the block FRAGILE (survives, but breaks on
			-- touch / instant hand-break -- handled in BlockHandler, Stage 3).
			if freshFell >= CONFIG.FALL_BREAK_HEIGHT then
				if DEBUG_FIRE then
					print(string.format("[BB-FIRE] Burnt block fell %d cell(s) -> SHATTER at (%.1f,%.1f,%.1f)",
						freshFell, freshRest.X, freshRest.Y, freshRest.Z))
				end
				shatterBurntBlock(block, freshRest)
			else
				block:SetAttribute("Fragile", true)
				block:SetAttribute("FallCompleted", true)
				if DEBUG_FIRE then
					print(string.format("[BB-FIRE] Burnt block fell %d cell(s) -> fragile at (%.1f,%.1f,%.1f)",
						freshFell, freshRest.X, freshRest.Y, freshRest.Z))
				end
			end

			-- CASCADE: this block just vacated `curCenter`. Any charred block stacked
			-- directly above that cell is now unsupported, so knock the whole column down
			-- immediately instead of making each wait out its own timer.
			if cascadeFallAbove then
				cascadeFallAbove(curCenter, index, blocksFolder)
			end
		end)
	end)
end

local SPREAD_OFFSETS = {
	Vector3.new(BLOCK_SIZE, 0, 0),
	Vector3.new(-BLOCK_SIZE, 0, 0),
	Vector3.new(0, 0, BLOCK_SIZE),
	Vector3.new(0, 0, -BLOCK_SIZE),
	Vector3.new(0, -BLOCK_SIZE, 0), -- block below the host
	Vector3.new(0, BLOCK_SIZE, 0),  -- block above the host (burning up a wall)
}

-- DIAGONAL-UP offsets: one step UP and one over in each cardinal direction. This
-- is the geometry of a staircase tread -- the next step sits up-and-over, so it's
-- never a direct 6-axis neighbour and the normal spread misses it. Fire uses the
-- "up" direction bias for these (climbing is fast), letting it walk up stairs and
-- over the lip of a wall. We deliberately DON'T include diagonal-down/-sideways
-- offsets: fire shouldn't leap across diagonal air gaps on the flat or downward.
local DIAGONAL_UP_OFFSETS = {
	Vector3.new(BLOCK_SIZE, BLOCK_SIZE, 0),
	Vector3.new(-BLOCK_SIZE, BLOCK_SIZE, 0),
	Vector3.new(0, BLOCK_SIZE, BLOCK_SIZE),
	Vector3.new(0, BLOCK_SIZE, -BLOCK_SIZE),
}

-- Knock down the stack ABOVE a just-vacated cell. When a charred block falls out
-- of `vacatedCenter`, the charred block directly above it is now unsupported and
-- should give way at once (and so on up the column) rather than each waiting out
-- its own per-tick timer. We walk straight up and collapseBurntBlock each charred
-- block; collapseBurntBlock's own landing callback re-invokes this, so the whole
-- column unzips in one chain. Non-charred or non-floating blocks stop the walk
-- (a solid intact block still supports whatever's above it).
function cascadeFallAbove(vacatedCenter, index, blocksFolder)
	if not CONFIG.FALL_ENABLED then return end
	local aboveCenter = vacatedCenter + Vector3.new(0, BLOCK_SIZE, 0)
	local above = index:GetBlockAt(aboveCenter)
	if not above then return end
	-- Only cascade charred/spent blocks (an intact block isn't part of the burnt
	-- collapse; leave normal structural blocks alone).
	if not above:GetAttribute("FullyCharred") then return end
	if above:GetAttribute("HasFallen") then return end
	-- Resolve its center (it may store BlockPos* or not, same as the charred pass).
	local acx = above:GetAttribute("BlockPosX")
	local acy = above:GetAttribute("BlockPosY")
	local acz = above:GetAttribute("BlockPosZ")
	local aCenter
	if acx and acy and acz then
		aCenter = Vector3.new(acx, acy, acz)
	else
		aCenter = aboveCenter
	end
	if DEBUG_FIRE then
		print(string.format("[BB-FIRE] cascade: knocking down stack above (%.1f,%.1f,%.1f)",
			vacatedCenter.X, vacatedCenter.Y, vacatedCenter.Z))
	end
	-- collapseBurntBlock re-invokes cascadeFallAbove from its landing callback, so
	-- this single call unzips the rest of the column above too.
	collapseBurntBlock(above, aCenter, index, blocksFolder)
end

-- ============================================
-- SPREAD TICK
-- ============================================

-- Spread fire from a single source cell to its flammable neighbours. For each
-- flammable neighbour we choose which FACE it catches on, preferring to spread
-- ALONG the surface the source is burning on:
--   1. If the source fire is on a face F and the neighbour's same face F is
--      EXPOSED (touching cell empty), light the neighbour on F. This is how fire
--      creeps across a flat floor (Top->Top), along a wall (side->same side),
--      or across a ceiling (Bottom->Bottom).
--   2. Otherwise, try the face of the neighbour pointing back toward the source
--      (fire wrapping around an edge), if that face is exposed.
-- A face is only lightable if its touching cell is empty and not already lit.
-- `sourceFace` is the FireFace of the source fire (defaults to "Top").
local function tryLightFace(blocksFolder, index, neighbourCenter, neighbour, face, placedBy, dirKind)
	local nType = neighbour:GetAttribute("BlockType") or neighbour.Name
	local fireCell = neighbourCenter + (FACE_NORMAL[face] or FACE_NORMAL.Top) * BLOCK_SIZE
	if index:HasBlockAt(fireCell) then                            -- face blocked (not exposed)
		if DEBUG_FIRE then
			print(string.format("[BB-FIRE]   no-light %s face=%s: BLOCKED (cell above face occupied) at (%.1f,%.1f,%.1f)",
				nType, face, neighbourCenter.X, neighbourCenter.Y, neighbourCenter.Z))
		end
		return false
	end
	if hostHasFireOnFace(neighbourCenter, face, index) then       -- already lit
		if DEBUG_FIRE then
			print(string.format("[BB-FIRE]   no-light %s face=%s: ALREADY LIT at (%.1f,%.1f,%.1f)",
				nType, face, neighbourCenter.X, neighbourCenter.Y, neighbourCenter.Z))
		end
		return false
	end
	-- Effective ignite chance = base * block encouragement * direction bias
	-- (Minecraft-style: easy-catch blocks + upward spread light faster).
	local bias = 1.0
	if dirKind then bias = CONFIG.FIRE_DIRECTION_BIAS[dirKind] or 1.0 end
	local chance = CONFIG.SPREAD_CHANCE * encouragementOf(nType) * bias
	if math.random() > chance then
		if DEBUG_FIRE then
			print(string.format("[BB-FIRE]   no-light %s face=%s: ROLL FAILED (p=%.2f) at (%.1f,%.1f,%.1f)",
				nType, face, chance, neighbourCenter.X, neighbourCenter.Y, neighbourCenter.Z))
		end
		return false
	end
	local newFire = buildFireBlock(blocksFolder, neighbourCenter, placedBy, face)
	if not newFire then return false end
	if DEBUG_FIRE then
		print(string.format("[BB-FIRE] Spread to %s (face=%s, p=%.2f) at (%.1f,%.1f,%.1f)",
			nType, face, chance, neighbourCenter.X, neighbourCenter.Y, neighbourCenter.Z))
	end
	return true
end

local function spreadFromCell(blocksFolder, index, hostCenter, placedBy, spreadCount, sourceFace)
	sourceFace = sourceFace or "Top"
	local anyFlammableNearby = false
	for _, offset in ipairs(SPREAD_OFFSETS) do
		if spreadCount >= CONFIG.MAX_SPREADS_PER_TICK then break end
		local neighbourCenter = hostCenter + offset
		local neighbour = index:GetBlockAt(neighbourCenter)
		if DEBUG_FIRE then
			local what = "empty"
			if neighbour then
				what = (neighbour:GetAttribute("BlockType") or neighbour.Name)
					.. (blockIsFuel(neighbour) and " (FUEL)" or " (not fuel)")
			end
			print(string.format("[BB-FIRE]  neighbour off=(%d,%d,%d) -> %s at (%.1f,%.1f,%.1f)",
				offset.X / BLOCK_SIZE, offset.Y / BLOCK_SIZE, offset.Z / BLOCK_SIZE,
				what, neighbourCenter.X, neighbourCenter.Y, neighbourCenter.Z))
		end
		if neighbour and blockIsFuel(neighbour) then
			anyFlammableNearby = true
			-- Build the ordered list of faces to try for this neighbour:
			-- (1) the source's own face (spread along the burning surface), then
			-- (2) the face pointing back toward the source (wrap around an edge).
			local backFace = offsetToNeighbourFace(offset)
			local dirKind = offsetDirKind(offset)
			local tried = {}
			local function attempt(face)
				if not face or tried[face] then return false end
				tried[face] = true
				return tryLightFace(blocksFolder, index, neighbourCenter, neighbour, face, placedBy, dirKind)
			end
			local lit = attempt(sourceFace) or attempt(backFace)
			if lit then spreadCount += 1 end
		end
	end
	return spreadCount, anyFlammableNearby
end

-- DIAGONAL-UP spread: catch the flammable block sitting one step UP and one over
-- (a staircase tread, or the block just over the lip of a wall). These cells are
-- never direct 6-axis neighbours, so without this fire stalls at the bottom of a
-- staircase. We light the step's TOP face (fire climbs onto the tread), falling
-- back to the face pointing back toward the source if the top is covered. Always
-- treated as an "up" direction for the bias (climbing is fast). Returns the
-- (possibly increased) spreadCount.
local function spreadDiagonalUp(blocksFolder, index, hostCenter, placedBy, spreadCount)
	for _, offset in ipairs(DIAGONAL_UP_OFFSETS) do
		if spreadCount >= CONFIG.MAX_SPREADS_PER_TICK then break end
		local neighbourCenter = hostCenter + offset
		local neighbour = index:GetBlockAt(neighbourCenter)
		if neighbour and blockIsFuel(neighbour) then
			-- Prefer lighting the tread's TOP; fall back to the horizontal face that
			-- points back toward the source (the riser face of the step).
			local horizOffset = Vector3.new(offset.X, 0, offset.Z)
			local backFace = offsetToNeighbourFace(horizOffset)
			local tried = {}
			local function attempt(face)
				if not face or tried[face] then return false end
				tried[face] = true
				-- "up" bias: climbing a staircase is the fast direction.
				return tryLightFace(blocksFolder, index, neighbourCenter, neighbour, face, placedBy, "up")
			end
			if attempt("Top") or attempt(backFace) then
				spreadCount += 1
			end
		end
	end
	return spreadCount
end

-- Vertical "leap": scan UP the column above the host and try to ignite flammable
-- blocks up to CONFIG.MAX_VERTICAL_REACH cells high. The per-tick ignition chance
-- decays with height (VERTICAL_BASE_CHANCE * VERTICAL_FALLOFF^(height-1)), so a
-- block 1 above lights quickly and one 4 above takes (on average) many more
-- ticks. A solid non-flammable block in the column stops the leap above it (so
-- fire can't jump through a stone ceiling) unless VERTICAL_BLOCKED_BY_SOLID=false.
--
-- Note: height 1 (the cell directly above the host) is ALSO covered by the
-- normal SPREAD_OFFSETS up-vector. That's fine -- two independent rolls just make
-- the closest block catch a touch faster, which matches "directly above lights
-- fast". We start this scan at height 1 anyway for a clean falloff curve.
local function spreadVertical(blocksFolder, index, hostCenter, placedBy, spreadCount)
	for height = 1, CONFIG.MAX_VERTICAL_REACH do
		if spreadCount >= CONFIG.MAX_SPREADS_PER_TICK then break end
		local cellCenter = hostCenter + Vector3.new(0, BLOCK_SIZE * height, 0)
		local block = index:GetBlockAt(cellCenter)

		if block then
			if blockIsFuel(block) then
				-- Flammable block in the column: roll a height-decaying chance to ignite
				-- it (place a fire on the cell above it), if not already on fire/occupied.
				local chance = CONFIG.VERTICAL_BASE_CHANCE * (CONFIG.VERTICAL_FALLOFF ^ (height - 1))
				if not hasFireOn(cellCenter, index)
					and not index:HasBlockAt(cellCenter + Vector3.new(0, BLOCK_SIZE, 0)) then
					if math.random() <= chance then
						local newFire = buildFireBlock(blocksFolder, cellCenter, placedBy)
						if newFire then
							spreadCount += 1
							if DEBUG_FIRE then
								local nType = block:GetAttribute("BlockType") or block.Name
								print(string.format("[BB-FIRE] Vertical leap (h=%d, p=%.2f) to %s at (%.1f,%.1f,%.1f)",
									height, chance, nType, cellCenter.X, cellCenter.Y, cellCenter.Z))
							end
						end
					end
				end
			elseif CONFIG.VERTICAL_BLOCKED_BY_SOLID then
				-- A non-flammable solid block blocks the leap to anything above it.
				break
			end
		end
		-- Empty cell: keep scanning up (fire can leap across an air gap).
	end
	return spreadCount
end

-- Spread from the fire's OWN cell to the flammable blocks that form the WALLS of
-- that cell. A fire sitting in an empty cell is physically touching whatever
-- flammable blocks border it -- the block right next to a FireSide, and (in an
-- inside corner) the blocks on the other walls too. Each such bordering block is
-- lit on the face that points back INTO the fire's cell (the face it shares with
-- the fire). This is what makes fire jump to the block it's touching and wrap
-- into inside corners (one fire per exposed face, multiple per cell allowed).
--
-- We skip the wall the fire's own host is on (that block is the source's host,
-- already burning) -- actually we don't need to skip it; hostHasFireOnFace and
-- the occupancy check naturally prevent re-lighting it.
local function spreadFromFireCell(blocksFolder, index, fireCellCenter, placedBy, spreadCount)
	local anyFlammableNearby = false
	for _, offset in ipairs(SPREAD_OFFSETS) do
		if spreadCount >= CONFIG.MAX_SPREADS_PER_TICK then break end
		-- The block forming this wall of the fire's cell.
		local wallCenter = fireCellCenter + offset
		local wallBlock = index:GetBlockAt(wallCenter)
		if wallBlock and blockIsFuel(wallBlock) then
			anyFlammableNearby = true
			-- That block catches on the face pointing back toward the fire's cell.
			-- offset goes fire->wall, so the wall's catching face normal is -offset.
			local face = offsetToNeighbourFace(offset)
			local dirKind = offsetDirKind(offset)
			if tryLightFace(blocksFolder, index, wallCenter, wallBlock, face, placedBy, dirKind) then
				spreadCount += 1
			end
		end
	end
	return spreadCount, anyFlammableNearby
end

-- SELF-WRAP: ignite the OTHER open faces of a burning block's OWN host, so a fire
-- that started on a side or the bottom climbs around the block toward the top.
-- For each of the host's 6 faces we light it if: the face is EXPOSED (the cell
-- just beyond it is empty), it isn't already lit, and a per-tick roll passes. The
-- roll is SELF_WRAP_CHANCE scaled by FIRE_DIRECTION_BIAS for that face's direction
-- (Top uses the "up" bias so it catches fastest; sides medium; Bottom rarely),
-- giving the natural bottom->sides->top climb. The host must still be live fuel.
-- Returns the (possibly increased) spreadCount.
local function wrapFireOnHost(blocksFolder, index, hostBlock, hostCenter, placedBy, spreadCount)
	if not CONFIG.SELF_WRAP_ENABLED then return spreadCount end
	if not blockIsFuel(hostBlock) then return spreadCount end

	-- Face -> the direction-bias kind to use for the wrap roll.
	local FACE_DIRKIND = {
		Top = "up", Bottom = "down",
		PosX = "side", NegX = "side", PosZ = "side", NegZ = "side",
	}
	for face, normal in pairs(FACE_NORMAL) do
		if spreadCount >= CONFIG.MAX_SPREADS_PER_TICK then break end
		-- Exposed? the cell just beyond this face must be empty.
		local beyond = hostCenter + normal * BLOCK_SIZE
		if not index:HasBlockAt(beyond) and not hostHasFireOnFace(hostCenter, face, index) then
			local bias = CONFIG.FIRE_DIRECTION_BIAS[FACE_DIRKIND[face] or "side"] or 1.0
			local chance = CONFIG.SELF_WRAP_CHANCE * bias
			if math.random() <= chance then
				local newFire = buildFireBlock(blocksFolder, hostCenter, placedBy, face)
				if newFire then
					spreadCount += 1
					if DEBUG_FIRE then
						print(string.format("[BB-FIRE] Self-wrap lit face=%s (p=%.2f) at (%.1f,%.1f,%.1f)",
							face, chance, hostCenter.X, hostCenter.Y, hostCenter.Z))
					end
				end
			end
		end
	end
	return spreadCount
end

local function processPlotFires(blocksFolder)
	if not blocksFolder then return end
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return end

	-- Collect spread SOURCES: live fires, plus fully-charred ember blocks (which
	-- keep spreading even though their flame has gone out -- the embers are hot).
	local fires = {}
	local charredSources = {}
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsFire") then
			table.insert(fires, block)
		elseif block:GetAttribute("FullyCharred") then
			table.insert(charredSources, block)
		end
	end
	if #fires == 0 and #charredSources == 0 then return end

	for i = #fires, 2, -1 do
		local j = math.random(1, i)
		fires[i], fires[j] = fires[j], fires[i]
	end

	local spreadCount = 0

	for _, fire in ipairs(fires) do
		if not fire.Parent then continue end -- destroyed earlier this tick

		local hostCenter = getFireHostCenter(fire)
		if not hostCenter then continue end

		local hostBlock = index:GetBlockAt(hostCenter)

		if not hostBlock then
			if DEBUG_FIRE then
				print(string.format("[BB-FIRE] Fire at host (%.1f,%.1f,%.1f) lost support -> out",
					hostCenter.X, hostCenter.Y, hostCenter.Z))
			end
			fire:Destroy()
			continue
		end

		local hostType = hostBlock:GetAttribute("BlockType") or hostBlock.Name
		local hostFlammable = blockIsFuel(hostBlock)
		local hostEternal = isEternalFireHost(hostType)

		if DEBUG_FIRE then
			print(string.format("[BB-FIRE] tick fire host=%s flammable=%s eternal=%s at (%.1f,%.1f,%.1f)",
				tostring(hostType), tostring(hostFlammable), tostring(hostEternal),
				hostCenter.X, hostCenter.Y, hostCenter.Z))
		end

		-- ---- SPREAD to flammable neighbours (cap per tick) ----
		local anyFlammableNearby = false
		local spreadCountBefore = spreadCount
		if spreadCount < CONFIG.MAX_SPREADS_PER_TICK then
			local sourceFace = fire:GetAttribute("FireFace") or "Top"
			spreadCount, anyFlammableNearby = spreadFromCell(
				blocksFolder, index, hostCenter, fire:GetAttribute("PlacedBy"), spreadCount, sourceFace)

			-- Spread from the fire's OWN cell to the flammable blocks it touches (the
			-- block right next to a FireSide, plus inside-corner walls). This is what
			-- catches the block beside the fire and wraps fire into inside corners.
			local fcx = fire:GetAttribute("BlockPosX")
			local fcy = fire:GetAttribute("BlockPosY")
			local fcz = fire:GetAttribute("BlockPosZ")
			if fcx and fcy and fcz and spreadCount < CONFIG.MAX_SPREADS_PER_TICK then
				local cellFlammable
				spreadCount, cellFlammable = spreadFromFireCell(
					blocksFolder, index, Vector3.new(fcx, fcy, fcz), fire:GetAttribute("PlacedBy"), spreadCount)
				anyFlammableNearby = anyFlammableNearby or cellFlammable
			end

			-- Vertical leap: try to ignite flammable blocks stacked above the host,
			-- with a height-decaying chance (closer = faster). Only when there's reach
			-- configured beyond the immediate neighbour.
			if CONFIG.MAX_VERTICAL_REACH > 1 then
				spreadCount = spreadVertical(
					blocksFolder, index, hostCenter, fire:GetAttribute("PlacedBy"), spreadCount)
			end

			-- Diagonal-up climb: catch the next staircase tread / block over a wall lip
			-- (one step up + one over), which the axis-aligned spread can't reach.
			if spreadCount < CONFIG.MAX_SPREADS_PER_TICK then
				spreadCount = spreadDiagonalUp(
					blocksFolder, index, hostCenter, fire:GetAttribute("PlacedBy"), spreadCount)
			end

			-- Self-wrap: the fire climbs around its OWN host to the block's other open
			-- faces, working upward (a side/bottom fire eventually lights the top). Only
			-- while the host is still live fuel.
			if spreadCount < CONFIG.MAX_SPREADS_PER_TICK then
				spreadCount = wrapFireOnHost(
					blocksFolder, index, hostBlock, hostCenter, fire:GetAttribute("PlacedBy"), spreadCount)
			end

			-- Stray-fire fizzle: non-flammable host + no flammable neighbours. Eternal
			-- hosts (e.g. Netherrack) are EXEMPT -- their fire burns forever until
			-- manually extinguished, even with nothing flammable nearby.
			if CONFIG.EXTINGUISH_STRAY and not hostFlammable and not hostEternal
				and not anyFlammableNearby then
				local strikes = (fire:GetAttribute("StrayTicks") or 0) + 1
				if strikes >= CONFIG.STRAY_TICKS_TO_FIZZLE then
					if DEBUG_FIRE then print("[BB-FIRE] Stray fire fizzled out") end
					fire:Destroy()
					continue
				else
					fire:SetAttribute("StrayTicks", strikes)
				end
			elseif fire:GetAttribute("StrayTicks") then
				fire:SetAttribute("StrayTicks", nil) -- reset; it has fuel again
			end
		end

		-- ---- AGE / NATURAL BURNOUT (Minecraft-style) ----
		-- The fire ages each tick. If it was "fed" this tick -- it spread to a new
		-- block, or it's actively charring a flammable host -- its age resets toward
		-- AGE_FED_RESET (a fed fire stays young and lively). Otherwise age climbs, and
		-- once past MAX_FIRE_AGE the fire has BURNOUT_CHANCE per tick to die on its own
		-- even with fuel nearby, so accidental fires peter out instead of consuming a
		-- whole build. Eternal hosts (netherrack) never age. Disabled if
		-- MAX_FIRE_AGE is falsy.
		if CONFIG.MAX_FIRE_AGE and not hostEternal then
			local fedThisTick = (spreadCount > spreadCountBefore) or hostFlammable
			local age = fire:GetAttribute("FireAge") or 0
			if fedThisTick then
				age = math.min(age, CONFIG.AGE_FED_RESET)
			else
				age += 1
			end
			fire:SetAttribute("FireAge", age)
			if age >= CONFIG.MAX_FIRE_AGE and math.random() <= CONFIG.BURNOUT_CHANCE then
				if DEBUG_FIRE then
					print(string.format("[BB-FIRE] Fire burned out (age=%d) at (%.1f,%.1f,%.1f)",
						age, hostCenter.X, hostCenter.Y, hostCenter.Z))
				end
				fire:Destroy()
				continue
			end
		end

		-- ---- CHAR the host progressively (if flammable & not already spent) ----
		if hostFlammable then
			-- Burn speed scales with the block's flammability (wool burns away fast,
			-- logs slowly) -- Minecraft "burn odds".
			local charStep = CONFIG.CHAR_PER_TICK * flammabilityOf(hostType)
			local charLevel = (hostBlock:GetAttribute("CharLevel") or 0) + charStep
			hostBlock:SetAttribute("CharLevel", charLevel)
			-- Set the TARGET; the per-frame animation loop smoothly eases colour +
			-- ember fade-in toward it (no steppy jumps).
			registerAnimation(hostBlock, charLevel, false)

			if charLevel >= 1 then
				-- This FACE is done burning: the flame goes out here. Mark the block spent
				-- so it can't re-ignite/char further, and destroy THIS fire. But DON'T cool
				-- the embers to white or schedule the fall yet -- the block may still have
				-- fire on OTHER faces (side/self-wrap). The charred-sources pass below waits
				-- until NO fire remains on the block, then flips it to cooling and tries the
				-- collapse. (Embers keep their burning look until then.)
				hostBlock:SetAttribute("FullyCharred", true)
				hostBlock:SetAttribute("CharredTime", tick()) -- when embers began (for the drip hot window)
				if DEBUG_FIRE then
					print(string.format("[BB-FIRE] %s face charred (waiting for other faces to go out) at (%.1f,%.1f,%.1f)",
						hostType, hostCenter.X, hostCenter.Y, hostCenter.Z))
				end
				fire:Destroy()
				continue
			end
		end
	end

	-- ---- CHARRED EMBER BLOCKS: keep spreading (no flame, no further char) ----
	-- A FullyCharred block may STILL have flame on some of its faces (other faces
	-- that are mid-burn or self-wrapped). We only:
	--   * flip it to the COOLING phase (embers -> B&W) once NO fire remains on ANY
	--     of its faces -- so embers never turn white while flame is still visible;
	--   * THEN try its collapse, retried every tick until it actually falls (the
	--     block below may not have cleared on the first attempt).
	if DEBUG_FIRE and #charredSources > 0 then
		print(string.format("[BB-FIRE] charredSources this tick: %d", #charredSources))
	end
	for _, charred in ipairs(charredSources) do
		if not charred.Parent then continue end
		-- Resolve the block's grid CENTER. Fire blocks store BlockPosX/Y/Z, but regular
		-- placed blocks (OakPlanks etc.) usually DON'T -- their position comes from the
		-- part/pivot. So fall back to the geometry the same way BlockSpatialIndex's
		-- getBlockCenter does. (Previously we required the attributes and silently
		-- skipped every charred block that lacked them -> no cooling, no drip.)
		local cx = charred:GetAttribute("BlockPosX")
		local cy = charred:GetAttribute("BlockPosY")
		local cz = charred:GetAttribute("BlockPosZ")
		local center
		if cx and cy and cz then
			center = Vector3.new(cx, cy, cz)
		elseif charred:IsA("BasePart") then
			center = charred.Position
		elseif charred:IsA("Model") then
			local pivot = charred:GetPivot().Position
			if charred:GetAttribute("IsFence") or charred:GetAttribute("IsGlass") then
				center = pivot
			else
				center = pivot + Vector3.new(0, BLOCK_SIZE / 2, 0)
			end
		end
		if DEBUG_FIRE then
			print(string.format("[BB-FIRE] charred pass: %s center=%s",
				charred:GetAttribute("BlockType") or charred.Name, center and tostring(center) or "nil"))
		end
		if center then
			local cx, cy, cz = center.X, center.Y, center.Z
			local stillBurning = hostHasAnyFire(center, index)

			-- EMBER DRIP: this is the EMBER stage -- the block is charred + glowing-hot,
			-- whether or not a stray flame is still finishing on one of its faces. A
			-- floating ember block crumbles glowing embers off its underside (client VFX).
			-- We measure "hot" from CharredTime (when the block first charred), so the drip
			-- begins as soon as it's an ember block and stops after EMBER_HOT_DURATION -- it
			-- does NOT wait for the flame to be fully out. Cooling/collapse below DO wait.
			if CONFIG.EMBER_DRIP_ENABLED and not charred:GetAttribute("FallCompleted") then
				local charredTime = charred:GetAttribute("CharredTime")
				local stillHot = true
				if charredTime then
					stillHot = (tick() - charredTime) < CONFIG.EMBER_HOT_DURATION
				end
				local belowEmpty = not index:HasBlockAt(center - Vector3.new(0, BLOCK_SIZE, 0))
				if DEBUG_FIRE then
					print(string.format("[BB-FIRE] drip check: hot=%s belowEmpty=%s burning=%s at (%.1f,%.1f,%.1f)",
						tostring(stillHot), tostring(belowEmpty), tostring(stillBurning), cx, cy, cz))
				end
				if stillHot and belowEmpty then
					local lastDrip = charred:GetAttribute("LastEmberDrip") or 0
					if tick() - lastDrip >= CONFIG.EMBER_DRIP_INTERVAL then
						charred:SetAttribute("LastEmberDrip", tick())
						local part = getLargestPart(charred)
						local dripColor = part and part.Color or Color3.fromRGB(150, 60, 20)
						local dripSize = part and part.Size or Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
						local emitPos = center - Vector3.new(0, dripSize.Y * 0.5, 0)
						BurntEmberDripFX:FireAllClients({
							pos = emitPos,
							size = dripSize,
							color = dripColor,
						})
						if DEBUG_FIRE then
							print(string.format("[BB-FIRE] EMBER DRIP fired at (%.1f,%.1f,%.1f)", emitPos.X, emitPos.Y, emitPos.Z))
						end
					end
				end
			end

			-- COOL + COLLAPSE: once the block is past its hot-ember window (EMBER_HOT_DURATION
			-- since it charred), begin the cool-to-B&W tint and let it fall. We use the same
			-- CharredTime reference as the drip rather than waiting for the block's flame to be
			-- fully out -- on a connected structure a charred block can keep getting flame
			-- self-wrapped onto its faces, so "no fire anywhere" may never be true and the
			-- block would never cool. So: drip during 0..EMBER_HOT_DURATION, then cool after.
			local charredTime = charred:GetAttribute("CharredTime")
			local pastHot = charredTime and (tick() - charredTime) >= CONFIG.EMBER_HOT_DURATION
			if pastHot then
				if not charred:GetAttribute("CoolStarted") then
					charred:SetAttribute("CoolStarted", true)
					charred:SetAttribute("CoolStartTime", tick())
					registerAnimation(charred, 1, true)
					if DEBUG_FIRE then
						print(string.format("[BB-FIRE] %s embers cooled -> fading to ash at (%.1f,%.1f,%.1f)",
							charred:GetAttribute("BlockType") or charred.Name, cx, cy, cz))
					end
				end
				collapseBurntBlock(charred, center, index, blocksFolder)
			end

			-- Keep spreading from the hot embers regardless of flame state (capped per tick).
			if spreadCount < CONFIG.MAX_SPREADS_PER_TICK then
				spreadCount = spreadFromCell(
					blocksFolder, index, center, charred:GetAttribute("PlacedBy"), spreadCount)
				if CONFIG.MAX_VERTICAL_REACH > 1 then
					spreadCount = spreadVertical(
						blocksFolder, index, center, charred:GetAttribute("PlacedBy"), spreadCount)
				end
				-- Diagonal-up climb from the embers too (so a charred step at the bottom
				-- of a staircase still ignites the next tread up).
				if spreadCount < CONFIG.MAX_SPREADS_PER_TICK then
					spreadCount = spreadDiagonalUp(
						blocksFolder, index, center, charred:GetAttribute("PlacedBy"), spreadCount)
				end
			end
		end
	end

	if DEBUG_FIRE and spreadCount > 0 then
		print(string.format("[BB-FIRE] %d new fire(s) this tick", spreadCount))
	end
end

-- ============================================
-- PLOT TRACKING
-- ============================================

local function registerPlot(blocksFolder)
	if not blocksFolder then return end
	ActivePlots[blocksFolder] = true
	if DEBUG_FIRE then
		local area = blocksFolder.Parent
		print(string.format("[BB-FIRE] Registered plot: %s (children=%d)",
			area and area.Name or "?", #blocksFolder:GetChildren()))
	end
	if not IsRunning then
		IsRunning = true
		LastTickTime = tick()
	end
end

local function unregisterPlot(blocksFolder)
	ActivePlots[blocksFolder] = nil
	local hasAny = false
	for _ in pairs(ActivePlots) do hasAny = true break end
	if not hasAny then IsRunning = false end
end

-- ============================================
-- MAIN LOOP
-- ============================================

RunService.Heartbeat:Connect(function()
	if not IsRunning then return end
	local now = tick()
	if now - LastTickTime < CONFIG.TICK_INTERVAL then return end
	LastTickTime = now

	for blocksFolder in pairs(ActivePlots) do
		if blocksFolder and blocksFolder.Parent then
			local buildArea = blocksFolder.Parent
			local busy = BulkOperationFlags and BulkOperationFlags.IsBulkOperation(buildArea)
			if not busy then
				processPlotFires(blocksFolder)
			end
		else
			ActivePlots[blocksFolder] = nil
		end
	end
end)

-- ============================================
-- AUTO-REGISTER EXISTING PLOTS
-- ============================================

task.spawn(function()
	task.wait(5)
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				registerPlot(blocksFolder)
			end
		end
	end

	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			local blocksFolder = megaBuildArea:FindFirstChild("Blocks")
			if blocksFolder then
				registerPlot(blocksFolder)
			end
		end
	end

	print("[FireHandler] Initialized, tracking " .. tostring(next(ActivePlots) and "active" or "no") .. " plots")
end)

workspace.ChildAdded:Connect(function(child)
	task.wait(1)
	if child.Name:find(GridConfig.BUILD_AREA_PREFIX) then
		local blocksFolder = child:FindFirstChild("Blocks")
		if blocksFolder then
			registerPlot(blocksFolder)
		end
	end
end)

-- ============================================
-- PUBLIC API (_G.FireHandler)
-- ============================================
-- Exposed so other server scripts (notably LavaHandler) can ask whether a
-- block type burns and start fires on specific faces of a host block. We keep
-- this MINIMAL on purpose — the FireHandler still owns spread, charring,
-- cooling, collapse, etc. Callers just hand us a hostBlock + face and we drop
-- a Fire on it; the normal tick takes over from there.
--
-- IsFlammable(blockType: string) -> bool
--   Mirrors the internal isFlammable() so callers get the SAME flammability
--   rules without duplicating the FLAMMABLE_EXACT/SUFFIXES/PREFIXES lists.
--
-- IgniteBlock(hostBlock: Instance, face: string?, placedBy: number?) -> Fire?
--   Light hostBlock on the given face ("Top"|"Bottom"|"PosX"|"NegX"|"PosZ"|
--   "NegZ"). face defaults to "Top". Returns the created Fire instance, or nil
--   if the host wasn't flammable / the face was already lit / templates were
--   missing. The fire's PlacedBy attribute is set so save/load + permissions
--   stay consistent (0 = system-spawned, like natural spread).
_G.FireHandler = _G.FireHandler or {}

_G.FireHandler.IsFlammable = function(blockType)
	return isFlammable(blockType)
end

_G.FireHandler.IgniteBlock = function(hostBlock, face, placedBy)
	if not hostBlock or not hostBlock.Parent then return nil end
	face = face or "Top"
	if not FACE_NORMAL[face] then
		warn(string.format("[BB-FIRE] IgniteBlock: invalid face %q", tostring(face)))
		return nil
	end
	
	-- Only ignite flammable hosts. (Eternal-fire hosts like Netherrack are NOT
	-- valid ignition targets here either — they're meant for fire that was lit
	-- by other means and burns forever; lava-ignition should target real fuel.)
	local hostType = hostBlock:GetAttribute("BlockType") or hostBlock.Name
	if not isFlammable(hostType) then return nil end
	if hostBlock:GetAttribute("FullyCharred") then return nil end
	
	-- Resolve the host's grid center using the same fallback chain as the
	-- charred-sources pass (some placed blocks lack BlockPosX/Y/Z attributes).
	local cx = hostBlock:GetAttribute("BlockPosX")
	local cy = hostBlock:GetAttribute("BlockPosY")
	local cz = hostBlock:GetAttribute("BlockPosZ")
	local hostCenter
	if cx and cy and cz then
		hostCenter = Vector3.new(cx, cy, cz)
	elseif hostBlock:IsA("BasePart") then
		hostCenter = hostBlock.Position
	elseif hostBlock:IsA("Model") then
		local pivot = hostBlock:GetPivot().Position
		if hostBlock:GetAttribute("IsFence") or hostBlock:GetAttribute("IsGlass") then
			hostCenter = pivot
		else
			hostCenter = pivot + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
	end
	if not hostCenter then return nil end
	
	-- Locate the plot the host lives in via the blocks folder (the host's parent).
	local blocksFolder = hostBlock.Parent
	if not blocksFolder then return nil end
	
	-- Make sure the spatial index knows this folder, and check the face isn't
	-- already lit + the fire-cell isn't occupied (mirrors tryLightFace's guards).
	local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not index then return nil end
	if hostHasFireOnFace(hostCenter, face, index) then return nil end
	local fireCell = hostCenter + FACE_NORMAL[face] * BLOCK_SIZE
	if index:HasBlockAt(fireCell) then return nil end
	
	local fire = buildFireBlock(blocksFolder, hostCenter, placedBy or 0, face)
	if fire and DEBUG_FIRE then
		print(string.format("[BB-FIRE] External ignite (lava?) lit %s face=%s at (%.1f,%.1f,%.1f)",
			tostring(hostType), face, hostCenter.X, hostCenter.Y, hostCenter.Z))
	end
	return fire
end

print("[FireHandler] Fire spread system loaded")
