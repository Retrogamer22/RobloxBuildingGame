--[[
	TreeStructures
	Text-based tree templates for procedural generation
	
	Legend:
	  . = air (empty)
	  L = log (vertical)
	  l = leaves
	  
	Each layer is a 2D grid viewed from above
	Layers go from bottom to top
	Center of bottom layer is where the tree base goes
]]

local TreeStructures = {}

-- ============================================
-- OAK TREES (4 variants)
-- ============================================

-- Small Oak Tree (5 blocks tall) - compact classic shape
TreeStructures.OakSmall = {
	-- Layer 1 (bottom - trunk base)
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 2
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 3
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 4 (leaves start)
	{
		"lll",
		"lLl",
		"lll",
	},
	-- Layer 5 (top)
	{
		".l.",
		"lll",
		".l.",
	},
}

-- Medium Oak Tree (6 blocks tall, wider canopy)
TreeStructures.OakMedium = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 4 (leaves start - big canopy)
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 5
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 6 (top)
	{
		"..l..",
		".lll.",
		"lllll",
		".lll.",
		"..l..",
	},
}

-- Tall Oak Tree (7 blocks tall) - taller trunk
TreeStructures.OakTall = {
	-- Layer 1
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 2
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 3
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 4
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 5 (leaves start)
	{
		"lll",
		"lLl",
		"lll",
	},
	-- Layer 6
	{
		"lll",
		"lLl",
		"lll",
	},
	-- Layer 7 (top)
	{
		".l.",
		"lll",
		".l.",
	},
}

-- Bushy Oak Tree (5 blocks tall) - short but very wide canopy
TreeStructures.OakBushy = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3 (leaves start low and wide)
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 4
	{
		"lllll",
		"lllll",
		"llLll",
		"lllll",
		"lllll",
	},
	-- Layer 5 (top - still wide)
	{
		".lll.",
		"lllll",
		"lllll",
		"lllll",
		".lll.",
	},
}

-- ============================================
-- SPRUCE TREES (4 variants) - Conifer, Christmas tree shape
-- ============================================

-- Spruce Tree Small (tall and narrow, conical shape)
TreeStructures.SpruceSmall = {
	-- Layer 1
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 2
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 3
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 4
	{
		"lll",
		"lLl",
		"lll",
	},
	-- Layer 5
	{
		".l.",
		"lLl",
		".l.",
	},
	-- Layer 6
	{
		"...",
		".l.",
		"...",
	},
}

-- Tall Spruce (7 blocks)
TreeStructures.SpruceTall = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 4
	{
		".....",
		".lll.",
		".lLl.",
		".lll.",
		".....",
	},
	-- Layer 5
	{
		".....",
		"..l..",
		".lLl.",
		"..l..",
		".....",
	},
	-- Layer 6
	{
		".....",
		"..l..",
		".lLl.",
		"..l..",
		".....",
	},
	-- Layer 7 (top)
	{
		".....",
		".....",
		"..l..",
		".....",
		".....",
	},
}

-- Medium Spruce (6 blocks) - classic Christmas tree shape
TreeStructures.SpruceMedium = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3 (leaves start - widest at bottom)
	{
		".....",
		".lll.",
		".lLl.",
		".lll.",
		".....",
	},
	-- Layer 4 (narrower)
	{
		".....",
		"..l..",
		".lLl.",
		"..l..",
		".....",
	},
	-- Layer 5 (even narrower)
	{
		".....",
		".....",
		".lLl.",
		".....",
		".....",
	},
	-- Layer 6 (top point)
	{
		".....",
		".....",
		"..l..",
		".....",
		".....",
	},
}

-- Wide Spruce (6 blocks) - wider conical shape
TreeStructures.SpruceWide = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3 (leaves start - very wide)
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 4 (still wide)
	{
		"..l..",
		".lll.",
		".lLl.",
		".lll.",
		"..l..",
	},
	-- Layer 5 (narrowing)
	{
		".....",
		"..l..",
		".lLl.",
		"..l..",
		".....",
	},
	-- Layer 6 (top point)
	{
		".....",
		".....",
		"..l..",
		".....",
		".....",
	},
}

-- ============================================
-- BIRCH TREES (4 variants) - Tall, slender, white bark
-- ============================================

-- Birch Tree Small (tall and slim like Minecraft)
TreeStructures.BirchSmall = {
	-- Layer 1
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 2
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 3
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 4
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 5
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 6 (leaves start)
	{
		"lll",
		"lLl",
		"lll",
	},
	-- Layer 7 (top)
	{
		".l.",
		"lll",
		".l.",
	},
}

-- Tall Birch (9 blocks, very slender)
TreeStructures.BirchTall = {
	-- Layer 1
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 2
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 3
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 4
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 5
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 6
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 7 (leaves start)
	{
		"lll",
		"lLl",
		"lll",
	},
	-- Layer 8
	{
		".l.",
		"lLl",
		".l.",
	},
	-- Layer 9 (top)
	{
		"...",
		".l.",
		"...",
	},
}

-- Medium Birch (7 blocks) - balanced height and canopy
TreeStructures.BirchMedium = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 4
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 5 (leaves start)
	{
		"..l..",
		".lll.",
		".lLl.",
		".lll.",
		"..l..",
	},
	-- Layer 6
	{
		".....",
		".lll.",
		".lLl.",
		".lll.",
		".....",
	},
	-- Layer 7 (top)
	{
		".....",
		"..l..",
		".lll.",
		"..l..",
		".....",
	},
}

-- Bushy Birch (6 blocks) - shorter with wider, rounded canopy
TreeStructures.BirchBushy = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 4 (leaves start - wide)
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 5 (still wide)
	{
		"..l..",
		".lll.",
		"lllll",
		".lll.",
		"..l..",
	},
	-- Layer 6 (top - rounded)
	{
		".....",
		".lll.",
		".lll.",
		".lll.",
		".....",
	},
}

-- ============================================
-- ACACIA TREES (4 variants) - Flat-topped umbrella canopy, savanna tree
-- Real acacias have distinctive DIAGONAL/BENT trunks and flat umbrella tops
-- Trunk goes straight for 2-3 blocks, THEN bends
-- ============================================

-- Small Acacia (7 blocks) - Straight trunk then bend
TreeStructures.AcaciaSmall = {
	-- Layer 1 (base - straight)
	{
		".......",
		".......",
		".......",
		"...L...",
		".......",
		".......",
		".......",
	},
	-- Layer 2 (straight)
	{
		".......",
		".......",
		".......",
		"...L...",
		".......",
		".......",
		".......",
	},
	-- Layer 3 (trunk bends diagonal)
	{
		".......",
		".......",
		".......",
		"....L..",
		".......",
		".......",
		".......",
	},
	-- Layer 4 (continues diagonal)
	{
		".......",
		".......",
		".......",
		".....L.",
		".......",
		".......",
		".......",
	},
	-- Layer 5 (flat canopy starts)
	{
		".......",
		"...lll.",
		"..lllll",
		"..lllLl",
		"..lllll",
		"...lll.",
		".......",
	},
	-- Layer 6 (flat canopy middle)
	{
		".......",
		"....l..",
		"...lll.",
		"..lllll",
		"...lll.",
		"....l..",
		".......",
	},
	-- Layer 7 (sparse flat top)
	{
		".......",
		".......",
		"....ll.",
		"...lll.",
		"....ll.",
		".......",
		".......",
	},
}

-- Medium Acacia (8 blocks) - Classic bent trunk umbrella tree
TreeStructures.AcaciaMedium = {
	-- Layer 1 (base - straight)
	{
		".........",
		".........",
		".........",
		".........",
		"....L....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 2 (straight)
	{
		".........",
		".........",
		".........",
		".........",
		"....L....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 3 (straight)
	{
		".........",
		".........",
		".........",
		".........",
		"....L....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 4 (trunk bends)
	{
		".........",
		".........",
		".........",
		".........",
		".....L...",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 5 (continues diagonal)
	{
		".........",
		".........",
		".........",
		".........",
		"......L..",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 6 (wide flat canopy starts)
	{
		".........",
		".........",
		"....lll..",
		"...lllll.",
		"..lllllLl",
		"...lllll.",
		"....lll..",
		".........",
		".........",
	},
	-- Layer 7 (flat middle)
	{
		".........",
		".........",
		".....l...",
		"....lll..",
		"...lllll.",
		"....lll..",
		".....l...",
		".........",
		".........",
	},
	-- Layer 8 (sparse flat top)
	{
		".........",
		".........",
		".........",
		".....l...",
		"....lll..",
		".....l...",
		".........",
		".........",
		".........",
	},
}

-- Tall Acacia (9 blocks) - Taller straight section, then bend
TreeStructures.AcaciaTall = {
	-- Layer 1 (base - straight)
	{
		".........",
		".........",
		".........",
		".........",
		"....L....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 2 (straight)
	{
		".........",
		".........",
		".........",
		".........",
		"....L....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 3 (straight)
	{
		".........",
		".........",
		".........",
		".........",
		"....L....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 4 (trunk bends)
	{
		".........",
		".........",
		".........",
		".........",
		".....L...",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 5 (continues diagonal)
	{
		".........",
		".........",
		".........",
		".........",
		"......L..",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 6 (vertical again)
	{
		".........",
		".........",
		".........",
		".........",
		"......L..",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 7 (canopy starts)
	{
		".........",
		".........",
		"....lll..",
		"...lllll.",
		"..lllllLl",
		"...lllll.",
		"....lll..",
		".........",
		".........",
	},
	-- Layer 8 (flat middle)
	{
		".........",
		".........",
		".....l...",
		"....lll..",
		"...lllll.",
		"....lll..",
		".....l...",
		".........",
		".........",
	},
	-- Layer 9 (sparse top)
	{
		".........",
		".........",
		".........",
		".....l...",
		"....lll..",
		".....l...",
		".........",
		".........",
		".........",
	},
}

-- Wide Acacia (8 blocks) - Straight trunk, bend, massive canopy
TreeStructures.AcaciaWide = {
	-- Layer 1 (base - straight)
	{
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
		".....L.....",
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
	},
	-- Layer 2 (straight)
	{
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
		".....L.....",
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
	},
	-- Layer 3 (trunk bends)
	{
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
		"......L....",
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
	},
	-- Layer 4 (continues diagonal)
	{
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
		".......L...",
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
	},
	-- Layer 5 (vertical)
	{
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
		".......L...",
		"...........",
		"...........",
		"...........",
		"...........",
		"...........",
	},
	-- Layer 6 (massive flat canopy)
	{
		"...........",
		"...........",
		".....lll...",
		"....lllll..",
		"...lllllll.",
		"..lllllllLl",
		"...lllllll.",
		"....lllll..",
		".....lll...",
		"...........",
		"...........",
	},
	-- Layer 7 (flat middle)
	{
		"...........",
		"...........",
		"......l....",
		".....lll...",
		"....lllll..",
		"...lllllll.",
		"....lllll..",
		".....lll...",
		"......l....",
		"...........",
		"...........",
	},
	-- Layer 8 (sparse flat top)
	{
		"...........",
		"...........",
		"...........",
		"......l....",
		".....lll...",
		"....lllll..",
		".....lll...",
		"......l....",
		"...........",
		"...........",
		"...........",
	},
}

-- ============================================
-- DARK OAK TREES (4 variants) - Massive, thick, dense canopy
-- Dark oaks are huge trees with thick trunks and dense dark foliage
-- ============================================

-- Small Dark Oak (6 blocks) - Compact but thick
TreeStructures.DarkOakSmall = {
	-- Layer 1 (2x2 trunk base)
	{
		".....",
		".LL..",
		".LL..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".LL..",
		".LL..",
		".....",
		".....",
	},
	-- Layer 3
	{
		".....",
		".LL..",
		".LL..",
		".....",
		".....",
	},
	-- Layer 4 (leaves start)
	{
		"lllll",
		"lLLll",
		"lLLll",
		"lllll",
		"lllll",
	},
	-- Layer 5
	{
		"lllll",
		"lllll",
		"lllll",
		"lllll",
		"lllll",
	},
	-- Layer 6 (top)
	{
		".lll.",
		"lllll",
		"lllll",
		"lllll",
		".lll.",
	},
}

-- Medium Dark Oak (7 blocks) - Classic thick dark oak
TreeStructures.DarkOakMedium = {
	-- Layer 1 (2x2 trunk)
	{
		".......",
		".......",
		"..LL...",
		"..LL...",
		".......",
		".......",
		".......",
	},
	-- Layer 2
	{
		".......",
		".......",
		"..LL...",
		"..LL...",
		".......",
		".......",
		".......",
	},
	-- Layer 3
	{
		".......",
		".......",
		"..LL...",
		"..LL...",
		".......",
		".......",
		".......",
	},
	-- Layer 4 (dense leaves start)
	{
		".lllll.",
		"lllllll",
		"llLLlll",
		"llLLlll",
		"lllllll",
		"lllllll",
		".lllll.",
	},
	-- Layer 5 (very dense)
	{
		".lllll.",
		"lllllll",
		"lllllll",
		"lllllll",
		"lllllll",
		"lllllll",
		".lllll.",
	},
	-- Layer 6
	{
		"..lll..",
		".lllll.",
		"lllllll",
		"lllllll",
		"lllllll",
		".lllll.",
		"..lll..",
	},
	-- Layer 7 (rounded top)
	{
		".......",
		"..lll..",
		".lllll.",
		".lllll.",
		".lllll.",
		"..lll..",
		".......",
	},
}

-- Tall Dark Oak (9 blocks) - Towering dark oak
TreeStructures.DarkOakTall = {
	-- Layer 1 (2x2 trunk)
	{
		".......",
		".......",
		"..LL...",
		"..LL...",
		".......",
		".......",
		".......",
	},
	-- Layer 2
	{
		".......",
		".......",
		"..LL...",
		"..LL...",
		".......",
		".......",
		".......",
	},
	-- Layer 3
	{
		".......",
		".......",
		"..LL...",
		"..LL...",
		".......",
		".......",
		".......",
	},
	-- Layer 4
	{
		".......",
		".......",
		"..LL...",
		"..LL...",
		".......",
		".......",
		".......",
	},
	-- Layer 5
	{
		".......",
		".......",
		"..LL...",
		"..LL...",
		".......",
		".......",
		".......",
	},
	-- Layer 6 (leaves start)
	{
		".lllll.",
		"lllllll",
		"llLLlll",
		"llLLlll",
		"lllllll",
		"lllllll",
		".lllll.",
	},
	-- Layer 7
	{
		".lllll.",
		"lllllll",
		"lllllll",
		"lllllll",
		"lllllll",
		"lllllll",
		".lllll.",
	},
	-- Layer 8
	{
		"..lll..",
		".lllll.",
		"lllllll",
		"lllllll",
		"lllllll",
		".lllll.",
		"..lll..",
	},
	-- Layer 9 (top)
	{
		".......",
		"..lll..",
		".lllll.",
		".lllll.",
		".lllll.",
		"..lll..",
		".......",
	},
}

-- Massive Dark Oak (8 blocks) - Huge spreading canopy
TreeStructures.DarkOakMassive = {
	-- Layer 1 (2x2 trunk)
	{
		".........",
		".........",
		".........",
		"...LL....",
		"...LL....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 2
	{
		".........",
		".........",
		".........",
		"...LL....",
		"...LL....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 3
	{
		".........",
		".........",
		".........",
		"...LL....",
		"...LL....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 4
	{
		".........",
		".........",
		".........",
		"...LL....",
		"...LL....",
		".........",
		".........",
		".........",
		".........",
	},
	-- Layer 5 (massive canopy starts)
	{
		"..lllll..",
		".lllllll.",
		"lllllllll",
		"lllLLllll",
		"lllLLllll",
		"lllllllll",
		"lllllllll",
		".lllllll.",
		"..lllll..",
	},
	-- Layer 6 (very dense)
	{
		".lllllll.",
		"lllllllll",
		"lllllllll",
		"lllllllll",
		"lllllllll",
		"lllllllll",
		"lllllllll",
		"lllllllll",
		".lllllll.",
	},
	-- Layer 7
	{
		"..lllll..",
		".lllllll.",
		"lllllllll",
		"lllllllll",
		"lllllllll",
		"lllllllll",
		"lllllllll",
		".lllllll.",
		"..lllll..",
	},
	-- Layer 8 (rounded top)
	{
		".........",
		"...lll...",
		"..lllll..",
		".lllllll.",
		".lllllll.",
		".lllllll.",
		"..lllll..",
		"...lll...",
		".........",
	},
}

-- ============================================
-- EBONY TREES (4 variants) - Tropical hardwood, dense rounded canopy
-- Ebony trees have very dark wood and dense, rounded foliage
-- ============================================

-- Small Ebony (5 blocks) - Compact rounded shape
TreeStructures.EbonySmall = {
	-- Layer 1
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 2
	{
		"...",
		".L.",
		"...",
	},
	-- Layer 3 (leaves start early - dense)
	{
		"lll",
		"lLl",
		"lll",
	},
	-- Layer 4 (dense middle)
	{
		"lll",
		"lLl",
		"lll",
	},
	-- Layer 5 (rounded top)
	{
		".l.",
		"lll",
		".l.",
	},
}

-- Medium Ebony (6 blocks) - Classic ebony shape
TreeStructures.EbonyMedium = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3 (dense leaves start)
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 4 (very dense)
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 5
	{
		"..l..",
		".lll.",
		"lllll",
		".lll.",
		"..l..",
	},
	-- Layer 6 (rounded top)
	{
		".....",
		".lll.",
		".lll.",
		".lll.",
		".....",
	},
}

-- Tall Ebony (8 blocks) - Taller tropical ebony
TreeStructures.EbonyTall = {
	-- Layer 1
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 2
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 3
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 4
	{
		".....",
		".....",
		"..L..",
		".....",
		".....",
	},
	-- Layer 5 (dense leaves)
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 6
	{
		".lll.",
		"lllll",
		"llLll",
		"lllll",
		".lll.",
	},
	-- Layer 7
	{
		"..l..",
		".lll.",
		"lllll",
		".lll.",
		"..l..",
	},
	-- Layer 8 (rounded top)
	{
		".....",
		".lll.",
		".lll.",
		".lll.",
		".....",
	},
}

-- Wide Ebony (6 blocks) - Spreading tropical canopy
TreeStructures.EbonyWide = {
	-- Layer 1
	{
		".......",
		".......",
		".......",
		"...L...",
		".......",
		".......",
		".......",
	},
	-- Layer 2
	{
		".......",
		".......",
		".......",
		"...L...",
		".......",
		".......",
		".......",
	},
	-- Layer 3 (wide dense canopy)
	{
		"..lll..",
		".lllll.",
		"lllllll",
		"lllLlll",
		"lllllll",
		".lllll.",
		"..lll..",
	},
	-- Layer 4
	{
		".lllll.",
		"lllllll",
		"lllllll",
		"lllLlll",
		"lllllll",
		"lllllll",
		".lllll.",
	},
	-- Layer 5
	{
		"..lll..",
		".lllll.",
		"lllllll",
		"lllllll",
		"lllllll",
		".lllll.",
		"..lll..",
	},
	-- Layer 6 (rounded top)
	{
		".......",
		"..lll..",
		".lllll.",
		".lllll.",
		".lllll.",
		"..lll..",
		".......",
	},
}

-- ============================================
-- REDWOOD TREES (4 variants) - MASSIVE conifers!
-- Requires 2x2 sapling placement, 2x2 trunk throughout
-- These are the TALLEST trees in the game!
-- ============================================

-- Build redwood structures programmatically for cleaner code
local function buildRedwood(trunkHeight, canopyTiers)
	local structure = {}
	
	-- 2x2 trunk layer
	local trunk = {
		"......",
		"......",
		"..LL..",
		"..LL..",
		"......",
		"......",
	}
	
	-- Wide leaf layer (with trunk)
	local leafWide = {
		".llll.",
		"llllll",
		"llLLll",
		"llLLll",
		"llllll",
		".llll.",
	}
	
	-- Narrow leaf layer (with trunk)
	local leafNarrow = {
		"......",
		"..ll..",
		".lLLl.",
		".lLLl.",
		"..ll..",
		"......",
	}
	
	-- Top spire
	local spire = {
		"......",
		"..ll..",
		"..ll..",
		"..ll..",
		"..ll..",
		"......",
	}
	
	-- Add trunk layers
	for i = 1, trunkHeight do
		table.insert(structure, trunk)
	end
	
	-- Add canopy tiers (alternating wide/narrow)
	for i = 1, canopyTiers do
		table.insert(structure, leafWide)
		table.insert(structure, leafNarrow)
	end
	
	-- Add narrow top layers
	for i = 1, 3 do
		table.insert(structure, leafNarrow)
	end
	
	-- Add spire
	table.insert(structure, spire)
	
	return structure
end

-- Small Redwood: 30 blocks tall (20 trunk + 10 canopy)
TreeStructures.RedwoodSmall = buildRedwood(20, 3)

-- Medium Redwood: 45 blocks tall (32 trunk + 13 canopy)
TreeStructures.RedwoodMedium = buildRedwood(32, 5)

-- Tall Redwood: 60 blocks tall (45 trunk + 15 canopy)
TreeStructures.RedwoodTall = buildRedwood(45, 6)

-- Massive Redwood: 50 blocks tall (35 trunk + 15 canopy)
TreeStructures.RedwoodMassive = buildRedwood(35, 6)

-- ============================================
-- VARIANT MAPPING
-- ============================================

-- Map tree types to their available structures
TreeStructures.TreeVariants = {
	Oak = {"OakSmall", "OakMedium", "OakTall", "OakBushy"},
	Spruce = {"SpruceSmall", "SpruceTall", "SpruceMedium", "SpruceWide"},
	Birch = {"BirchSmall", "BirchTall", "BirchMedium", "BirchBushy"},
	Acacia = {"AcaciaSmall", "AcaciaMedium", "AcaciaTall", "AcaciaWide"},
	DarkOak = {"DarkOakSmall", "DarkOakMedium", "DarkOakTall", "DarkOakMassive"},
	Ebony = {"EbonySmall", "EbonyMedium", "EbonyTall", "EbonyWide"},
	Redwood = {"RedwoodSmall", "RedwoodMedium", "RedwoodTall", "RedwoodMassive"},
}

-- Trees that require 2x2 sapling placement
TreeStructures.Requires2x2Saplings = {
	Redwood = true,
}

-- Get a random structure for a tree type
-- rngFunc: optional function(min, max) for deterministic selection (e.g. terrain RNG)
function TreeStructures.GetRandomStructure(treeType, rngFunc)
	local variants = TreeStructures.TreeVariants[treeType]
	if not variants or #variants == 0 then
		return nil
	end
	
	local randomFunc = rngFunc or math.random
	local structureName = variants[randomFunc(1, #variants)]
	return TreeStructures[structureName], structureName
end

-- Get structure dimensions
function TreeStructures.GetStructureDimensions(structure)
	if not structure or #structure == 0 then
		return 0, 0, 0
	end
	
	local height = #structure
	local width = #structure[1][1]  -- X dimension
	local depth = #structure[1]      -- Z dimension
	
	return width, height, depth
end

return TreeStructures
