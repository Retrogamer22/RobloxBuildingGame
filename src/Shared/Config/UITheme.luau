--[[
	UITheme.luau
	Centralized Minecraft-style UI theme for the entire game.
	All UI scripts should require this module instead of defining local colors.
]]

local UITheme = {}

-- ============================================
-- MINECRAFT-STYLE COLOR PALETTE
-- Dark stone backgrounds, green accents, blocky feel
-- ============================================
UITheme.Colors = {
	-- Backgrounds (Minecraft stone grey)
	Background = Color3.fromRGB(55, 55, 55),         -- Dark panel bg (like MC inventory)
	Surface = Color3.fromRGB(139, 139, 139),          -- Button/card surfaces (MC grey)
	SurfaceHover = Color3.fromRGB(160, 160, 160),     -- Hover state (lighter grey)
	SurfaceActive = Color3.fromRGB(120, 120, 120),    -- Active/pressed (darker grey)
	SurfaceLight = Color3.fromRGB(180, 180, 180),     -- Light grey surface
	
	-- Accents (Minecraft green)
	Accent = Color3.fromRGB(76, 175, 80),              -- Primary green
	AccentHover = Color3.fromRGB(100, 200, 104),       -- Lighter green
	AccentDark = Color3.fromRGB(56, 142, 60),          -- Darker green
	
	-- Text
	Text = Color3.fromRGB(255, 255, 255),               -- Primary white
	TextMuted = Color3.fromRGB(170, 170, 170),          -- Secondary light gray
	TextDark = Color3.fromRGB(63, 63, 63),              -- Dark text (on light bg)
	
	-- Borders (thick dark borders like MC)
	Border = Color3.fromRGB(0, 0, 0),                   -- Black borders
	BorderLight = Color3.fromRGB(55, 55, 55),            -- Darker inner borders
	
	-- Status colors
	Success = Color3.fromRGB(76, 175, 80),              -- Green
	Warning = Color3.fromRGB(255, 193, 7),              -- Amber/yellow
	Danger = Color3.fromRGB(220, 53, 53),               -- Red
	Info = Color3.fromRGB(70, 140, 200),                -- Blue info
	
	-- Special
	SlotBg = Color3.fromRGB(100, 100, 100),             -- Hotbar slot background (MC slot grey)
	HotbarBg = Color3.fromRGB(55, 55, 55),              -- Hotbar container
	Selected = Color3.fromRGB(255, 255, 255),            -- Selection highlight
	Overlay = Color3.fromRGB(0, 0, 0),                  -- Modal overlay
	
	-- Changelog/Notes (title screen)
	ComingSoon = Color3.fromRGB(255, 193, 7),            -- Yellow badge
	NotesWarning = Color3.fromRGB(180, 140, 40),
	NotesWarningBg = Color3.fromRGB(50, 42, 22),
	NotesInfo = Color3.fromRGB(70, 140, 200),
	NotesInfoBg = Color3.fromRGB(24, 38, 52),
	NotesSuccess = Color3.fromRGB(80, 180, 100),
	NotesSuccessBg = Color3.fromRGB(24, 46, 28),
	NotesError = Color3.fromRGB(200, 80, 80),
	NotesErrorBg = Color3.fromRGB(52, 24, 24),
}

-- ============================================
-- CORNER RADIUS (blocky = smaller values)
-- ============================================
UITheme.CornerRadius = {
	None = UDim.new(0, 0),
	Small = UDim.new(0, 0),        -- Buttons, slots (blocky!)
	Medium = UDim.new(0, 0),       -- Panels, cards (blocky!)
	Large = UDim.new(0, 0),        -- Main frames (blocky!)
}

-- ============================================
-- BORDER THICKNESS
-- ============================================
UITheme.BorderThickness = {
	Normal = 3,        -- Standard borders (thicker for MC look)
	Thick = 4,         -- Selected/active states
	Thin = 2,          -- Subtle borders
}

-- ============================================
-- FONTS
-- ============================================
UITheme.Fonts = {
	Title = Enum.Font.FredokaOne,
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.GothamMedium,
	Caption = Enum.Font.Gotham,
}

return UITheme
