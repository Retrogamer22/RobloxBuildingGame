--[[
	TextBlockHandler  (Server)
	------------------------------------------------------------------
	Server-side authority for the TextBlock mod.

	Each face of a TextBlock holds independent text. Text is rendered on a
	thin invisible "canvas" Part placed just outside that face, parented under
	the block, carrying a SurfaceGui. Per-block scope: one canvas per used face.

	Persistence: a face's text is stored on the block as a string attribute
	TBText_<Face>  (e.g. TBText_North). PlotSerializer saves all non-blacklisted
	attributes automatically, and SaveManager restores them via its generic
	attribute loop, so text survives save/load with NO save-manager changes.
	On load we re-derive canvases from the stored attributes — exactly like
	SignTextHandler rebuilds sign SurfaceGuis.

	Mirrors SignTextHandler's structure: remote + TextService filter + create/
	update canvas + folder-watch (individual plots + MegaPlot) + 5s safety
	rescan that self-heals any block missing its canvases.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local TextBlockPlacement = require(ReplicatedStorage:WaitForChild("TextBlockPlacement", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Remote: client -> server authoritative edit.
local UpdateTextBlockText = Instance.new("RemoteEvent")
UpdateTextBlockText.Name = "UpdateTextBlockText"
UpdateTextBlockText.Parent = Remotes

local MAX_CHARS = 200          -- per face, total
local CANVAS_NAME_PREFIX = "TextBlockCanvas_"  -- + face
local TEXT_COLOR = Color3.fromRGB(20, 20, 20)
local FACE_TEXTURE_PREFIX = "CanvasTex_"  -- + face (Texture object name on the block)

local function getIndex(blocksFolder)
	if not blocksFolder then return nil end
	return BlockSpatialIndex.GetOrCreate(blocksFolder)
end

-- Source 9-slice canvas textures live in ReplicatedStorage.Textures.CanvasBlockTextures.
-- Looked up lazily (the folder is Studio-synced and may not exist at require time).
local function getCanvasTextureFolder()
	local texturesFolder = ReplicatedStorage:FindFirstChild("Textures")
	if not texturesFolder then return nil end
	return texturesFolder:FindFirstChild("CanvasBlockTextures")
end

-- ============================================
-- CANVAS FACE TEXTURES (9-slice merge)
-- ============================================

-- Clone the correct slice Texture for each face onto the block, based on its
-- merged group (via the spatial index). Re-runnable: replaces existing
-- per-face Textures so the slice stays current as neighbours change. Normal
-- maps are unused (Texture objects don't support them).
local function applyCanvasTextures(block, index)
	local host = block
	if not host:IsA("BasePart") then
		if host:IsA("Model") and host.PrimaryPart then
			host = host.PrimaryPart
		else
			return
		end
	end

	local folder = getCanvasTextureFolder()
	if not folder then
		warn("[TextBlock] CanvasBlockTextures folder not found in ReplicatedStorage.Textures")
		return
	end

	local blocksFolder = block.Parent
	for _, face in ipairs(TextBlockPlacement.AllFaces) do
		local sliceName = TextBlockPlacement.GetSliceForFace(block, face, blocksFolder, index)
		local source = folder:FindFirstChild(sliceName)
		if source and source:IsA("Texture") then
			local normalId = TextBlockPlacement.FaceNormalId[face]
			local texName = FACE_TEXTURE_PREFIX .. face

			local old = host:FindFirstChild(texName)
			if old then old:Destroy() end

			local tex = source:Clone()
			tex.Name = texName
			tex.Face = normalId
			tex.Parent = host
		end
	end
end

-- ============================================
-- CANVAS (text) — lives on the GROUP ANCHOR only
-- ============================================

local function removeCanvas(block, face)
	local canvas = block:FindFirstChild(CANVAS_NAME_PREFIX .. face)
	if canvas then canvas:Destroy() end
end

-- Build/update the spanning canvas Part + SurfaceGui on `anchor` for `face`,
-- sized to the whole group's geometry, showing `text`.
local function buildAnchorCanvas(anchor, face, geometry, text)
	local canvasName = CANVAS_NAME_PREFIX .. face
	local canvas = anchor:FindFirstChild(canvasName)
	if not canvas then
		canvas = Instance.new("Part")
		canvas.Name = canvasName
		canvas.Anchored = true
		canvas.CanCollide = false
		canvas.CanQuery = false
		canvas.CanTouch = false
		canvas.Transparency = 1
		canvas.Size = Vector3.new(geometry.width, geometry.height, 0.05)
		canvas.Parent = anchor
	else
		canvas.Size = Vector3.new(geometry.width, geometry.height, 0.05)
	end
	canvas.CFrame = geometry.cframe

	local gui = canvas:FindFirstChild("TextBlockGui")
	if not gui then
		gui = Instance.new("SurfaceGui")
		gui.Name = "TextBlockGui"
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 100
		gui.LightInfluence = 0
		gui.MaxDistance = 75
		gui.ClipsDescendants = true
		gui.Parent = canvas

		local label = Instance.new("TextLabel")
		label.Name = "TextLabel"
		label.Size = UDim2.new(1, -12, 1, -12)
		label.Position = UDim2.new(0, 6, 0, 6)
		label.BackgroundTransparency = 1
		label.Text = ""
		label.TextColor3 = TEXT_COLOR
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.Parent = gui
	end

	local label = gui:FindFirstChild("TextLabel")
	if label then
		label.Text = text
	end
end

-- Render one face of the GROUP that `block` belongs to:
--   * compute the group (flood-fill) + anchor + spanning geometry
--   * the anchor owns the text (TBText_<face>); non-anchor members get their
--     TBText_<face> cleared and any stray canvas removed
--   * if the group's text is empty, no canvas is created
local function renderGroupFace(block, face, index)
	local members, anchor, geometry =
		TextBlockPlacement.Resolve(block, face, block.Parent, index)
	if not anchor or not geometry then return end

	local attr = "TBText_" .. face

	-- Gather the group's text: prefer the anchor's; if the anchor has none but
	-- some member does (e.g. just-merged blocks), adopt the first non-empty so
	-- text isn't lost when a written block becomes a non-anchor on merge.
	local text = anchor:GetAttribute(attr) or ""
	if text == "" then
		for _, m in ipairs(members) do
			local t = m:GetAttribute(attr)
			if t and t ~= "" then
				text = t
				break
			end
		end
		if text ~= "" then
			anchor:SetAttribute(attr, text)
		end
	end

	-- Non-anchor members: clear their text + remove any canvas they hold.
	for _, m in ipairs(members) do
		if m ~= anchor then
			if (m:GetAttribute(attr) or "") ~= "" then
				m:SetAttribute(attr, "")
			end
			removeCanvas(m, face)
		end
	end

	-- Anchor: build the spanning canvas (or remove it if no text).
	if text == "" then
		removeCanvas(anchor, face)
	else
		buildAnchorCanvas(anchor, face, geometry, text)
	end
end

-- Re-render every face of the group(s) `block` participates in, AND refresh
-- the 9-slice textures of the block and all its same-face neighbours. Called
-- on placement and (for survivors) on break.
local function refreshBlock(block, index)
	if not TextBlockPlacement.IsTextBlock(block) then return end
	applyCanvasTextures(block, index)
	for _, face in ipairs(TextBlockPlacement.AllFaces) do
		-- Re-texture same-face neighbours (their slice may have changed) and
		-- render the shared canvas via the anchor.
		local members = TextBlockPlacement.GetFaceGroup(block, face, block.Parent, index)
		for _, m in ipairs(members) do
			if m ~= block then
				applyCanvasTextures(m, index)
			end
		end
		renderGroupFace(block, face, index)
	end
end

-- ============================================
-- TEXT FILTER (same approach as SignTextHandler)
-- ============================================

local function filterText(text, player)
	if not text or text == "" then return "" end
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, player.UserId)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if ok then
		return result
	else
		warn("[TextBlock] Text filter failed:", result)
		return ""
	end
end

-- ============================================
-- BUILD AREA LOOKUP (same as SignTextHandler)
-- ============================================

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

-- ============================================
-- REMOTE HANDLER
-- ============================================

UpdateTextBlockText.OnServerEvent:Connect(function(player, block, face, text)
	if not block or typeof(block) ~= "Instance" then return end
	if not TextBlockPlacement.IsTextBlock(block) then return end
	if type(face) ~= "string" then return end

	-- Validate face name.
	local validFace = false
	for _, f in ipairs(TextBlockPlacement.AllFaces) do
		if f == face then validFace = true break end
	end
	if not validFace then return end

	-- Block must live in the editing player's own build area.
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return end
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder or not block:IsDescendantOf(blocksFolder) then return end

	-- Sanitize + filter.
	local clean = ""
	if type(text) == "string" then
		clean = string.sub(text, 1, MAX_CHARS)
		clean = string.gsub(clean, "[%z\1-\8\11\12\14-\31]", "") -- strip control chars (keep \n, \r, \t)
		if clean ~= "" then
			clean = filterText(clean, player)
		end
	end

	-- Text is owned by the group's ANCHOR. The player may have clicked any
	-- member; resolve the anchor and write there, then re-render the group.
	local index = getIndex(blocksFolder)
	local _, anchor = TextBlockPlacement.Resolve(block, face, blocksFolder, index)
	anchor = anchor or block

	local attr = "TBText_" .. face
	anchor:SetAttribute(attr, clean)
	renderGroupFace(anchor, face, index)

	print(string.format("[TextBlock] %s set %s face text (anchor)", player.Name, face))
end)

-- ============================================
-- INITIALIZE / WATCH (mirrors SignTextHandler)
-- ============================================

local function initializeBlock(block)
	if not TextBlockPlacement.IsTextBlock(block) then return end
	local blocksFolder = block.Parent
	-- During a bulk load, skip per-block work; one full pass runs when the
	-- bulk flag clears (avoids N redundant flood-fills + slice flicker).
	local buildArea = blocksFolder and blocksFolder.Parent
	if buildArea and BulkOperationFlags.IsBulkOperation(buildArea) then
		return
	end
	local index = getIndex(blocksFolder)
	refreshBlock(block, index)
end

-- One clean render pass over every text block in a folder. Used after a bulk
-- load completes, when all neighbours are finally present and indexed.
local function fullRenderPass(blocksFolder)
	if not blocksFolder then return end
	local index = getIndex(blocksFolder)
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if TextBlockPlacement.IsTextBlock(child) then
			refreshBlock(child, index)
		end
	end
end

-- When a text block is removed, its former same-face neighbours' groups change
-- (slice textures + which block is the anchor). Re-render those survivors.
-- The block is already out of the spatial index by the time ChildRemoved fires,
-- so we query the neighbour grid cells directly from the removed block's last
-- known center.
local function handleBlockRemoved(block, blocksFolder)
	if not TextBlockPlacement.IsTextBlock(block) then return end
	local index = getIndex(blocksFolder)
	if not index then return end

	local center = TextBlockPlacement.GetBlockCenter(block)
	local BLOCK_SIZE = GridConfig.BLOCK_SIZE

	-- All 6 axis-neighbour cells (covers every face's in-plane directions).
	local offsets = {
		Vector3.new(BLOCK_SIZE, 0, 0), Vector3.new(-BLOCK_SIZE, 0, 0),
		Vector3.new(0, BLOCK_SIZE, 0), Vector3.new(0, -BLOCK_SIZE, 0),
		Vector3.new(0, 0, BLOCK_SIZE), Vector3.new(0, 0, -BLOCK_SIZE),
	}
	local seen = {}
	for _, off in ipairs(offsets) do
		for _, neighbor in ipairs(index:GetBlocksAt(center + off)) do
			if not seen[neighbor] and neighbor ~= block
				and neighbor.Parent and TextBlockPlacement.IsTextBlock(neighbor) then
				seen[neighbor] = true
				refreshBlock(neighbor, index)
			end
		end
	end
end

local function watchBlocksFolder(blocksFolder)
	-- Prime the spatial index for this folder.
	getIndex(blocksFolder)
	for _, child in ipairs(blocksFolder:GetChildren()) do
		initializeBlock(child)
	end
	blocksFolder.ChildAdded:Connect(function(child)
		task.defer(function()
			initializeBlock(child)
		end)
	end)
	blocksFolder.ChildRemoved:Connect(function(child)
		-- Defer so the spatial index's own ChildRemoved handler runs first.
		task.defer(function()
			handleBlockRemoved(child, blocksFolder)
		end)
	end)
	-- After a bulk load completes (BulkOperationInProgress -> false), do one
	-- clean render pass now that all neighbours are present and indexed.
	blocksFolder:GetAttributeChangedSignal("BulkOperationInProgress"):Connect(function()
		if blocksFolder:GetAttribute("BulkOperationInProgress") == false then
			task.defer(function()
				fullRenderPass(blocksFolder)
			end)
		end
	end)
end

-- Individual plots.
for i = 1, GridConfig.TOTAL_PLOTS do
	local buildAreaName = GridConfig.BUILD_AREA_PREFIX .. i

	local function setupBuildArea(buildArea)
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if blocksFolder then
			watchBlocksFolder(blocksFolder)
		end
		buildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" then
				watchBlocksFolder(child)
			end
		end)
	end

	local buildArea = workspace:FindFirstChild(buildAreaName)
	if buildArea then
		setupBuildArea(buildArea)
	end
	workspace.ChildAdded:Connect(function(child)
		if child.Name == buildAreaName then
			setupBuildArea(child)
		end
	end)
end

-- MegaPlot.
local function setupMegaPlotMonitoring(megaPlotRoom)
	local function tryMonitor(megaBuildArea)
		local blocksFolder = megaBuildArea:FindFirstChild("Blocks")
		if blocksFolder then
			watchBlocksFolder(blocksFolder)
		end
		megaBuildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" then
				watchBlocksFolder(child)
			end
		end)
	end
	local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
	if megaBuildArea then
		tryMonitor(megaBuildArea)
	end
	megaPlotRoom.ChildAdded:Connect(function(child)
		if child.Name == "MegaPlotBuildArea" then
			task.wait(0.5)
			tryMonitor(child)
		end
	end)
end

local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
if megaPlotRoom then
	setupMegaPlotMonitoring(megaPlotRoom)
end
workspace.ChildAdded:Connect(function(child)
	if child.Name == "MegaPlotRoom" then
		setupMegaPlotMonitoring(child)
	end
end)

-- ============================================
-- SAFETY RESCAN (self-heals missing canvases)
-- ============================================

local function safetyScanBuildArea(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	local index = getIndex(blocksFolder)
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if TextBlockPlacement.IsTextBlock(child) then
			local texHost = child:IsA("Model") and child.PrimaryPart or child
			local missingTexture = texHost and not texHost:FindFirstChild(FACE_TEXTURE_PREFIX .. "Top")

			-- A canvas is "missing" only if THIS block is its group's anchor and
			-- the group has text but no canvas Part. We approximate cheaply: if the
			-- block holds non-empty text on any face but has no canvas for it.
			local missingCanvas = false
			for _, face in ipairs(TextBlockPlacement.AllFaces) do
				local text = child:GetAttribute("TBText_" .. face) or ""
				if text ~= "" and not child:FindFirstChild(CANVAS_NAME_PREFIX .. face) then
					missingCanvas = true
					break
				end
			end

			if missingTexture or missingCanvas then
				refreshBlock(child, index)
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(5)
		for i = 1, GridConfig.TOTAL_PLOTS do
			local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
			if buildArea then
				safetyScanBuildArea(buildArea)
			end
		end
		local megaRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaRoom then
			local megaBuildArea = megaRoom:FindFirstChild("MegaPlotBuildArea")
			if megaBuildArea then
				safetyScanBuildArea(megaBuildArea)
			end
		end
	end
end)

print("TextBlockHandler initialized")
