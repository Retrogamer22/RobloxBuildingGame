-- BreakFX.luau  (Shared → ReplicatedStorage)
-- Shared helper for the [BB-BREAK-FX] block-break particle burst.
--
-- BlockHandler keeps its own inline copy for the main break/dig/cascade paths;
-- this module lets OTHER server handlers (e.g. ToolHandler shears) fire the same
-- burst without duplicating the colour/size extraction + radius logic. The actual
-- animation lives in BlockBreakParticles.client.luau.
--
-- Only call this from player-initiated paths (a shear, a break, etc.), never from
-- bulk load/save, so it can't storm particles during world loads.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

local BREAK_FX_RADIUS = 90 -- only players within this many studs get the burst

local BreakFX = {}

-- Resolve the shared RemoteEvent. BlockHandler creates it at startup; we wait for
-- it and only fall back to creating it ourselves if it somehow isn't there yet.
local remote
local function getRemote()
	if remote and remote.Parent then return remote end
	local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not Remotes then return nil end
	remote = Remotes:FindFirstChild("BlockBreakFX") or Remotes:WaitForChild("BlockBreakFX", 5)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "BlockBreakFX"
		remote.Parent = Remotes
	end
	return remote
end

-- Pick the largest VISIBLE part of a model as the representative colour/material.
-- Skips invisible helper parts (Hitbox / ClimbSensor and anything fully
-- transparent) so vines, sugar cane, etc. don't sample their clear sensor cubes
-- and burst grey. Falls back to any BasePart if everything was filtered out.
local function representativePart(model)
	local best, bestVol
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "Hitbox" and d.Name ~= "ClimbSensor" and d.Transparency < 1 then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if not bestVol or v > bestVol then bestVol, best = v, d end
		end
	end
	if not best then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				local v = d.Size.X * d.Size.Y * d.Size.Z
				if not bestVol or v > bestVol then bestVol, best = v, d end
			end
		end
	end
	return best
end

-- Fire a break burst for `thing` (BasePart or Model) to nearby clients.
function BreakFX.Fire(thing)
	if not thing then return end

	local color, size, pos, material, materialVariant
	if thing:IsA("BasePart") then
		color, size, pos = thing.Color, thing.Size, thing.Position
		material, materialVariant = thing.Material, thing.MaterialVariant
	elseif thing:IsA("Model") then
		local best = representativePart(thing)
		color = best and best.Color or Color3.fromRGB(160, 160, 160)
		material = best and best.Material or Enum.Material.SmoothPlastic
		materialVariant = best and best.MaterialVariant or ""
		local ok, _, bsize = pcall(function() return thing:GetBoundingBox() end)
		size = (ok and bsize) or Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
		pos = thing:GetPivot().Position
	else
		return
	end

	-- Optional per-block override: set a BreakFXColor (Color3) attribute to force
	-- the burst colour (useful for textured things whose .Color reads off).
	local override = thing:GetAttribute("BreakFXColor")
	if typeof(override) == "Color3" then color = override end

	local r = getRemote()
	if not r then return end

	local data = { pos = pos, size = size, color = color, material = material, materialVariant = materialVariant }
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - pos).Magnitude <= BREAK_FX_RADIUS then
			r:FireClient(plr, data)
		end
	end
end

return BreakFX
