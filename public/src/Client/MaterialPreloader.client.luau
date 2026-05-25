--[[
	MaterialPreloader
	Preloads all MaterialVariant textures (normal maps, roughness maps, etc.)
	so they're cached before players see any blocks.
	Prevents shiny hotspot fallback while textures load.
]]

local ContentProvider = game:GetService("ContentProvider")
local MaterialService = game:GetService("MaterialService")

local materials = {}

for _, mat in MaterialService:GetChildren() do
	if mat:IsA("MaterialVariant") then
		table.insert(materials, mat)
	end
end

if #materials > 0 then
	print("[MaterialPreloader] Preloading " .. #materials .. " material variants...")
	ContentProvider:PreloadAsync(materials)
	print("[MaterialPreloader] Done! All material textures cached.")
else
	print("[MaterialPreloader] No material variants found to preload.")
end
