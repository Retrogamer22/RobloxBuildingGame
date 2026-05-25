--[[
	ColorPalette.luau
	Centralized color definitions for all colored blocks in the game.
	Used for: Concrete, Wool, Terracotta, Glass, Beds, Banners, etc.
	
	Usage:
		local ColorPalette = require(path.to.ColorPalette)
		
		-- Get a Color3 by name
		local redColor = ColorPalette.Colors.Red
		
		-- Get color name from a Color3 (nearest match)
		local colorName = ColorPalette.getColorName(someColor3)
		
		-- Get all color names (for UI dropdowns, etc.)
		local allNames = ColorPalette.getColorNames()
]]

local ColorPalette = {}

-- RGB values (0-255 scale for reference, converted to Color3)
local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Core color palette - all colored blocks should use these
ColorPalette.Colors = {
	-- Vibrant Colors
	Purple = rgb(133, 86, 198),
	Yellow = rgb(198, 166, 68),
	Orange = rgb(198, 122, 61),
	Pink = rgb(198, 160, 160),
	Red = rgb(198, 87, 87),
	LightBlue = rgb(109, 191, 198),
	Blue = rgb(54, 64, 198),
	LightGreen = rgb(115, 198, 77),
	Green = rgb(55, 140, 49),
	Cyan = rgb(90, 222, 185),
	Magenta = rgb(207, 101, 161),
	
	-- Neutral Colors
	Tan = rgb(211, 184, 138),
	Brown = rgb(100, 84, 58),
	White = rgb(211, 211, 211),
	Grey = rgb(135, 135, 135),
	DarkGrey = rgb(84, 84, 84),
	Black = rgb(11, 11, 11),
}

-- Ordered list for consistent UI display
ColorPalette.ColorOrder = {
	"White",
	"Grey",
	"DarkGrey",
	"Black",
	"Brown",
	"Tan",
	"Red",
	"Orange",
	"Yellow",
	"LightGreen",
	"Green",
	"Cyan",
	"LightBlue",
	"Blue",
	"Purple",
	"Magenta",
	"Pink",
}

-- Alternative name mappings (for flexibility in lookups)
local AliasMap = {
	["Light Blue"] = "LightBlue",
	["Light Green"] = "LightGreen",
	["Dark Grey"] = "DarkGrey",
	["Dark Gray"] = "DarkGrey",
	["Gray"] = "Grey",
	["Lime"] = "LightGreen",
	["Navy"] = "Blue",
	["Beige"] = "Tan",
	["Sand"] = "Tan",
}

-- Get a color by name (supports aliases)
function ColorPalette.getColor(name: string): Color3?
	-- Direct lookup
	if ColorPalette.Colors[name] then
		return ColorPalette.Colors[name]
	end
	
	-- Try alias
	local aliasName = AliasMap[name]
	if aliasName and ColorPalette.Colors[aliasName] then
		return ColorPalette.Colors[aliasName]
	end
	
	-- Case-insensitive search
	local lowerName = string.lower(name)
	for colorName, color in pairs(ColorPalette.Colors) do
		if string.lower(colorName) == lowerName then
			return color
		end
	end
	
	return nil
end

-- Get the canonical color name from a Color3 (finds nearest match)
function ColorPalette.getColorName(color: Color3): string?
	local bestMatch = nil
	local bestDistance = math.huge
	
	for name, paletteColor in pairs(ColorPalette.Colors) do
		-- Calculate color distance (simple RGB distance)
		local dr = color.R - paletteColor.R
		local dg = color.G - paletteColor.G
		local db = color.B - paletteColor.B
		local distance = dr*dr + dg*dg + db*db
		
		if distance < bestDistance then
			bestDistance = distance
			bestMatch = name
		end
		
		-- Exact match
		if distance == 0 then
			return name
		end
	end
	
	return bestMatch
end

-- Check if a Color3 exactly matches a palette color
function ColorPalette.isExactMatch(color: Color3): boolean
	for _, paletteColor in pairs(ColorPalette.Colors) do
		if color == paletteColor then
			return true
		end
	end
	return false
end

-- Get all color names in display order
function ColorPalette.getColorNames(): {string}
	return table.clone(ColorPalette.ColorOrder)
end

-- Get all colors as an array of {name, color} pairs in display order
function ColorPalette.getColorsOrdered(): {{name: string, color: Color3}}
	local result = {}
	for _, name in ipairs(ColorPalette.ColorOrder) do
		table.insert(result, {
			name = name,
			color = ColorPalette.Colors[name]
		})
	end
	return result
end

-- Utility: Get a slightly lighter version of a palette color (for highlights)
function ColorPalette.lighten(colorName: string, amount: number?): Color3?
	local color = ColorPalette.getColor(colorName)
	if not color then return nil end
	
	amount = amount or 0.2
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, s * (1 - amount), math.min(1, v + amount))
end

-- Utility: Get a slightly darker version of a palette color (for shadows)
function ColorPalette.darken(colorName: string, amount: number?): Color3?
	local color = ColorPalette.getColor(colorName)
	if not color then return nil end
	
	amount = amount or 0.2
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, math.min(1, s + amount * 0.5), v * (1 - amount))
end

-- Get the number of colors in the palette
function ColorPalette.getColorCount(): number
	return #ColorPalette.ColorOrder
end

-- Colors to exclude from light-emitting blocks (too dark to glow)
local DarkColors = {
	["Grey"] = true,
	["DarkGrey"] = true,
	["Black"] = true,
}

-- Get colors suitable for light-emitting blocks (excludes grey/darkgrey/black)
function ColorPalette.getLightColors(): {{name: string, color: Color3}}
	local result = {}
	for _, name in ipairs(ColorPalette.ColorOrder) do
		if not DarkColors[name] then
			table.insert(result, {
				name = name,
				color = ColorPalette.Colors[name]
			})
		end
	end
	return result
end

-- Check if a color name is a "dark" color (not suitable for glowing)
function ColorPalette.isDarkColor(colorName: string): boolean
	return DarkColors[colorName] == true
end

return ColorPalette
