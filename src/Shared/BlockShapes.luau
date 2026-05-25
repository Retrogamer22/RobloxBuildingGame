--[[
	BlockShapes
	Defines shapes using templates from ReplicatedStorage/BlockTemplates
]]

local BLOCK_SIZE = 3

-- Shape definitions - TemplateName matches the object in BlockTemplates folder
local Shapes = {
	{
		Id = "Block",
		Name = "Block",
		TemplateName = "Block",
		Offset = Vector3.new(0, 0, 0),
		CanRotate = false,
	},
	{
		Id = "Slab",
		Name = "Slab",
		TemplateName = "Slab",
		Offset = Vector3.new(0, -BLOCK_SIZE / 4, 0),
		CanRotate = false,
	},
	{
		Id = "Stair",
		Name = "Stair",
		TemplateName = "Stair",
		Offset = Vector3.new(0, 0, 0),
		CanRotate = true,
	},
	{
		Id = "StairInnerCorner",
		Name = "Inner Corner",
		TemplateName = "StairInnerCorner",
		Offset = Vector3.new(0, 0, 0),
		CanRotate = true,
	},
	{
		Id = "StairOuterCorner",
		Name = "Outer Corner",
		TemplateName = "StairOuterCorner",
		Offset = Vector3.new(0, 0, 0),
		CanRotate = true,
	},
}

-- Materials with display names
local Materials = {
	{ Name = "Plastic", Value = Enum.Material.Plastic },
	{ Name = "Wood", Value = Enum.Material.Wood },
	{ Name = "Planks", Value = Enum.Material.WoodPlanks },
	{ Name = "Brick", Value = Enum.Material.Brick },
	{ Name = "Cobble", Value = Enum.Material.Cobblestone },
	{ Name = "Concrete", Value = Enum.Material.Concrete },
	{ Name = "Granite", Value = Enum.Material.Granite },
	{ Name = "Marble", Value = Enum.Material.Marble },
	{ Name = "Metal", Value = Enum.Material.Metal },
	{ Name = "Glass", Value = Enum.Material.Glass },
	{ Name = "Neon", Value = Enum.Material.Neon },
	{ Name = "Grass", Value = Enum.Material.Grass },
	{ Name = "Sand", Value = Enum.Material.Sand },
}

-- Color palette
local Colors = {
	Color3.fromRGB(255, 255, 255), -- White
	Color3.fromRGB(200, 200, 200), -- Light Gray
	Color3.fromRGB(128, 128, 128), -- Gray
	Color3.fromRGB(64, 64, 64),    -- Dark Gray
	Color3.fromRGB(27, 42, 53),    -- Black
	Color3.fromRGB(255, 0, 0),     -- Red
	Color3.fromRGB(255, 85, 0),    -- Orange
	Color3.fromRGB(255, 255, 0),   -- Yellow
	Color3.fromRGB(0, 255, 0),     -- Green
	Color3.fromRGB(0, 255, 255),   -- Cyan
	Color3.fromRGB(0, 128, 255),   -- Light Blue
	Color3.fromRGB(0, 0, 255),     -- Blue
	Color3.fromRGB(128, 0, 255),   -- Purple
	Color3.fromRGB(255, 0, 255),   -- Magenta
	Color3.fromRGB(255, 128, 128), -- Pink
	Color3.fromRGB(139, 90, 43),   -- Brown
	Color3.fromRGB(255, 176, 128), -- Tan
	Color3.fromRGB(0, 128, 0),     -- Dark Green
	Color3.fromRGB(0, 64, 128),    -- Navy
	Color3.fromRGB(128, 0, 0),     -- Maroon
}

local function GetShape(id)
	for _, shape in ipairs(Shapes) do
		if shape.Id == id then
			return shape
		end
	end
	return nil
end

local function GetAllShapes()
	return Shapes
end

local function GetAllMaterials()
	return Materials
end

local function GetAllColors()
	return Colors
end

return {
	Shapes = Shapes,
	Materials = Materials,
	Colors = Colors,
	GetShape = GetShape,
	GetAllShapes = GetAllShapes,
	GetAllMaterials = GetAllMaterials,
	GetAllColors = GetAllColors,
	BLOCK_SIZE = BLOCK_SIZE,
}
