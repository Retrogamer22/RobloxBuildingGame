--[[
	VineHalfReconciler

	Single authority for converting a vine instance between the full "Vine" and the
	half-height "VineHalf" variant based on its host block's shape.

	A vine is "half" when the host face it grabs onto only has material in its bottom
	half (a bottom slab, or the open front of a normal stair) — see
	VinePlacement.HostIsBottomHalfOnly. Because Vine and VineHalf are distinct models,
	switching variants means swapping the instance (clone the right template, copy
	attributes, rebuild hitbox + climb sensor).

	Called from:
	  * VineHandler.createVine        — natural spread produces the correct variant
	  * VineHandler reconcile pass     — fixes loaded saves + host changes (convert-on-load)
	  * BlockHandler (player placement) — a just-placed vine snaps to half immediately

	Server-only in practice (it builds instances); harmless if required on the client.

	Trimmed vines (VineTrimmed / VineTrimmedEnd) are left untouched — there is no
	half-trimmed piece.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VinePlacement = require(ReplicatedStorage:WaitForChild("VinePlacement", 10))

local BLOCK_SIZE = VinePlacement.BLOCK_SIZE or 3
local HALF_HEIGHT = BLOCK_SIZE / 2 -- 1.5
local HITBOX_THICKNESS = 1.0

local VineHalfReconciler = {}

-- ============================================
-- TEMPLATES
-- ============================================

local function getDecoration(name)
	local decorations = ReplicatedStorage:FindFirstChild("Decorations")
	if not decorations then return nil end
	return decorations:FindFirstChild(name)
end

local function anchorNoCollide(model)
	if model:IsA("BasePart") then
		model.Anchored = true
		model.CanCollide = false
	else
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
	end
end

-- Face-oriented size, with vertical extent halved for half vines.
local function sizeForFace(face, thickness, isHalf)
	local height = isHalf and HALF_HEIGHT or BLOCK_SIZE
	if face == "East" or face == "West" then
		return Vector3.new(thickness, height, BLOCK_SIZE)
	end
	-- North / South (and any fallback)
	return Vector3.new(BLOCK_SIZE, height, thickness)
end

local function addHitbox(vine, cframe, face, isHalf)
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanQuery = true
	hitbox.CanTouch = false
	hitbox.CastShadow = false
	hitbox.Transparency = 1
	hitbox.Size = sizeForFace(face, HITBOX_THICKNESS, isHalf)
	hitbox.CFrame = CFrame.new(cframe.Position)
	hitbox.Parent = vine
end

local function addClimbSensor(vine, cframe, face, isHalf)
	local climbSensor = Instance.new("Part")
	climbSensor.Name = "ClimbSensor"
	climbSensor.Anchored = true
	climbSensor.CanCollide = false
	climbSensor.CanQuery = false
	climbSensor.CanTouch = true
	climbSensor.CastShadow = false
	climbSensor.Transparency = 1
	climbSensor.Size = sizeForFace(face, 1.0, isHalf)
	climbSensor.CFrame = cframe
	climbSensor:AddTag("VineClimbSensor")
	climbSensor.Parent = vine
end

-- Attributes carried over from the old instance when swapping variants.
local PRESERVED_ATTRS = { "PlacedBy", "IsNaturalVine" }

-- ============================================
-- PUBLIC API
-- ============================================

-- Returns true if `vine` should be a half vine right now (host is bottom-half-only).
function VineHalfReconciler.ShouldBeHalf(vine, blocksFolder)
	if not vine or not blocksFolder then return false end
	if not vine:GetAttribute("IsVine") then return false end
	if vine:GetAttribute("IsVineTrimmed") then return false end

	local face = vine:GetAttribute("VineFace")
	local px = vine:GetAttribute("BlockPosX")
	local py = vine:GetAttribute("BlockPosY")
	local pz = vine:GetAttribute("BlockPosZ")
	if not (face and px and py and pz) then return false end

	local desired = VinePlacement.ResolveVineType(Vector3.new(px, py, pz), face, blocksFolder)
	return desired == "VineHalf"
end

-- Ensure `vine` matches its host's shape. If it already does, returns the same
-- instance untouched. Otherwise swaps it for the correct variant and returns the
-- new instance (the old one is destroyed). Always returns a valid instance.
function VineHalfReconciler.Reconcile(vine, blocksFolder)
	if not vine or not blocksFolder then return vine end
	if not vine:GetAttribute("IsVine") then return vine end
	-- Trimmed vines have no half variant; never touch them.
	if vine:GetAttribute("IsVineTrimmed") then return vine end

	local face = vine:GetAttribute("VineFace")
	local px = vine:GetAttribute("BlockPosX")
	local py = vine:GetAttribute("BlockPosY")
	local pz = vine:GetAttribute("BlockPosZ")
	if not (face and px and py and pz) then return vine end

	local pos = Vector3.new(px, py, pz)
	local desiredHalf = VinePlacement.ResolveVineType(pos, face, blocksFolder) == "VineHalf"
	local currentlyHalf = vine:GetAttribute("IsVineHalf") == true
	if desiredHalf == currentlyHalf then
		return vine -- already correct
	end

	local templateName = desiredHalf and "VineHalf" or "Vine"
	local template = getDecoration(templateName)
	if not template then
		warn("[VineHalfReconciler] Missing Decorations template: " .. templateName)
		return vine
	end

	local newVine = template:Clone()
	newVine.Name = templateName
	anchorNoCollide(newVine)

	local cframe = desiredHalf
		and VinePlacement.GetVineHalfCFrame(pos, face)
		or VinePlacement.GetVineCFrame(pos, face)
	newVine:PivotTo(cframe)

	newVine:SetAttribute("BlockType", templateName)
	newVine:SetAttribute("IsVine", true)
	newVine:SetAttribute("IsVineHalf", desiredHalf or nil)
	newVine:SetAttribute("VineFace", face)
	newVine:SetAttribute("VineRotation", VinePlacement.GetVineRotation(face))
	newVine:SetAttribute("BlockPosX", px)
	newVine:SetAttribute("BlockPosY", py)
	newVine:SetAttribute("BlockPosZ", pz)
	for _, attr in ipairs(PRESERVED_ATTRS) do
		local v = vine:GetAttribute(attr)
		if v ~= nil then newVine:SetAttribute(attr, v) end
	end

	addHitbox(newVine, cframe, face, desiredHalf)
	addClimbSensor(newVine, cframe, face, desiredHalf)

	newVine.Parent = blocksFolder
	vine:Destroy()
	return newVine
end

return VineHalfReconciler
