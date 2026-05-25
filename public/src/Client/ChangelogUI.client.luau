--[[
	ChangelogUI
	Shows a "What's New" popup when there's a new version the player hasn't seen.
	
	NOTE: Popup is now disabled - changelog is shown on the title screen instead.
	Keeping this code for potential future use or manual triggering.
]]

-- Set to false to disable the automatic popup (now shown on title screen instead)
local POPUP_ENABLED = false

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local isChangelogOpen = false

-- Expose for camera controller immediately
_G.ChangelogUI = {
	IsOpen = function() return isChangelogOpen end
}

-- Configuration
local COLORS = {
	overlay = Color3.fromRGB(0, 0, 0),
	background = Color3.fromRGB(35, 35, 45),
	header = Color3.fromRGB(45, 45, 58),
	accent = Color3.fromRGB(80, 180, 120),
	text = Color3.fromRGB(255, 255, 255),
	subtext = Color3.fromRGB(180, 180, 180),
	itemBg = Color3.fromRGB(50, 50, 65),
	buttonHover = Color3.fromRGB(100, 200, 140),
	-- Notes styles
	notesWarning = Color3.fromRGB(180, 140, 40),
	notesWarningBg = Color3.fromRGB(60, 50, 30),
	notesInfo = Color3.fromRGB(70, 140, 200),
	notesInfoBg = Color3.fromRGB(30, 45, 60),
	notesSuccess = Color3.fromRGB(80, 180, 100),
	notesSuccessBg = Color3.fromRGB(30, 55, 35),
	notesError = Color3.fromRGB(200, 80, 80),
	notesErrorBg = Color3.fromRGB(60, 30, 30),
}

-- Helper function to calculate text height
local function getTextHeight(text, font, textSize, maxWidth)
	local params = Instance.new("GetTextBoundsParams")
	params.Text = text
	params.Font = font
	params.Size = textSize
	params.Width = maxWidth
	
	local success, result = pcall(function()
		return TextService:GetTextBoundsAsync(params)
	end)
	
	if success then
		return result.Y
	else
		-- Fallback: estimate based on character count and line wrapping
		local charsPerLine = math.floor(maxWidth / (textSize * 0.5))
		local lines = math.ceil(#text / charsPerLine)
		return lines * (textSize * 1.4)
	end
end

local function createChangelogUI(data)
	isChangelogOpen = true
	-- Show mouse cursor
	UserInputService.MouseIconEnabled = true
	
	-- Create ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ChangelogUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 150
	screenGui.Parent = playerGui
	
	-- Dark overlay
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = COLORS.overlay
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Parent = screenGui
	
	-- Main modal container
	-- Calculate modal height based on whether notes exist
	local hasNotesForHeight = data.notes and data.notes ~= ""
	local modalHeight = hasNotesForHeight and 520 or 450
	
	local modal = Instance.new("Frame")
	modal.Name = "Modal"
	modal.Size = UDim2.new(0, 420, 0, modalHeight)
	modal.Position = UDim2.new(0.5, 0, 0.5, 0)
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.BackgroundColor3 = COLORS.background
	modal.BorderSizePixel = 0
	modal.BackgroundTransparency = 1
	modal.Parent = screenGui
	
	local modalCorner = Instance.new("UICorner")
	modalCorner.CornerRadius = UDim.new(0, 12)
	modalCorner.Parent = modal
	
	-- Header section
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 80)
	header.BackgroundColor3 = COLORS.header
	header.BorderSizePixel = 0
	header.Parent = modal
	
	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 12)
	headerCorner.Parent = header
	
	-- Cover bottom corners of header
	local headerCover = Instance.new("Frame")
	headerCover.Size = UDim2.new(1, 0, 0, 15)
	headerCover.Position = UDim2.new(0, 0, 1, -15)
	headerCover.BackgroundColor3 = COLORS.header
	headerCover.BorderSizePixel = 0
	headerCover.Parent = header
	
	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -20, 0, 30)
	title.Position = UDim2.new(0, 10, 0, 15)
	title.BackgroundTransparency = 1
	title.Text = data.title or "What's New"
	title.TextColor3 = COLORS.text
	title.TextSize = 24
	title.Font = Enum.Font.Arcade
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = header
	
	-- Version badge
	local versionBadge = Instance.new("TextLabel")
	versionBadge.Name = "VersionBadge"
	versionBadge.Size = UDim2.new(0, 70, 0, 22)
	versionBadge.Position = UDim2.new(1, -80, 0, 18)
	versionBadge.BackgroundColor3 = COLORS.accent
	versionBadge.Text = data.versionName or "v1.0.0"
	versionBadge.TextColor3 = COLORS.text
	versionBadge.TextSize = 12
	versionBadge.Font = Enum.Font.Arcade
	versionBadge.Parent = header
	
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 6)
	badgeCorner.Parent = versionBadge
	
	-- Subtitle
	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(1, -20, 0, 20)
	subtitle.Position = UDim2.new(0, 10, 0, 48)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = data.subtitle or ""
	subtitle.TextColor3 = COLORS.subtext
	subtitle.TextSize = 14
	subtitle.Font = Enum.Font.Arcade
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Parent = header
	
	-- Content area (scrolling frame for changes)
	-- Calculate content position based on whether notes exist
	local hasNotes = data.notes and data.notes ~= ""
	local notesHeight = hasNotes and 70 or 0
	local contentTopOffset = 90 + notesHeight
	
	-- Developer Notes section (if present)
	if hasNotes then
		-- Get colors based on notes style
		local notesStyle = data.notesStyle or "info"
		local notesBorderColor, notesBgColor
		
		if notesStyle == "warning" then
			notesBorderColor = COLORS.notesWarning
			notesBgColor = COLORS.notesWarningBg
		elseif notesStyle == "success" then
			notesBorderColor = COLORS.notesSuccess
			notesBgColor = COLORS.notesSuccessBg
		elseif notesStyle == "error" then
			notesBorderColor = COLORS.notesError
			notesBgColor = COLORS.notesErrorBg
		else -- "info" or default
			notesBorderColor = COLORS.notesInfo
			notesBgColor = COLORS.notesInfoBg
		end
		
		local notesFrame = Instance.new("Frame")
		notesFrame.Name = "Notes"
		notesFrame.Size = UDim2.new(1, -20, 0, 60)
		notesFrame.Position = UDim2.new(0, 10, 0, 88)
		notesFrame.BackgroundColor3 = notesBgColor
		notesFrame.BorderSizePixel = 0
		notesFrame.AutomaticSize = Enum.AutomaticSize.Y
		notesFrame.Parent = modal
		
		local notesCorner = Instance.new("UICorner")
		notesCorner.CornerRadius = UDim.new(0, 8)
		notesCorner.Parent = notesFrame
		
		-- Left accent bar
		local notesAccent = Instance.new("Frame")
		notesAccent.Name = "Accent"
		notesAccent.Size = UDim2.new(0, 4, 1, -8)
		notesAccent.Position = UDim2.new(0, 4, 0, 4)
		notesAccent.BackgroundColor3 = notesBorderColor
		notesAccent.BorderSizePixel = 0
		notesAccent.Parent = notesFrame
		
		local accentCorner = Instance.new("UICorner")
		accentCorner.CornerRadius = UDim.new(0, 2)
		accentCorner.Parent = notesAccent
		
		-- Notes text
		local notesText = Instance.new("TextLabel")
		notesText.Name = "Text"
		notesText.Size = UDim2.new(1, -25, 0, 0)
		notesText.Position = UDim2.new(0, 18, 0, 10)
		notesText.BackgroundTransparency = 1
		notesText.Text = data.notes
		notesText.TextColor3 = COLORS.text
		notesText.TextSize = 13
		notesText.Font = Enum.Font.Arcade
		notesText.TextXAlignment = Enum.TextXAlignment.Left
		notesText.TextYAlignment = Enum.TextYAlignment.Top
		notesText.TextWrapped = true
		notesText.AutomaticSize = Enum.AutomaticSize.Y
		notesText.Parent = notesFrame
		
		-- Add padding at bottom of notes
		local notesPadding = Instance.new("UIPadding")
		notesPadding.PaddingBottom = UDim.new(0, 10)
		notesPadding.Parent = notesFrame
		
		-- Update notesHeight for positioning (use approximate)
		task.defer(function()
			notesHeight = notesFrame.AbsoluteSize.Y
		end)
	end
	
	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -20, 1, -190 - notesHeight)
	content.Position = UDim2.new(0, 10, 0, contentTopOffset)
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.ScrollBarThickness = 4
	content.ScrollBarImageColor3 = COLORS.accent
	content.CanvasSize = UDim2.new(0, 0, 0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.Parent = modal
	
	local contentLayout = Instance.new("UIListLayout")
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Padding = UDim.new(0, 8)
	contentLayout.Parent = content
	
	-- Create change entries with dynamic height
	local itemWidth = 400 - 20 - 10 - 45 -- modal width - padding - item padding - text offset
	
	for i, change in ipairs(data.changes or {}) do
		local changeText = change.text or ""
		
		-- Calculate the height needed for this text
		local textHeight = getTextHeight(changeText, Font.fromEnum(Enum.Font.Arcade), 14, itemWidth)
		local itemHeight = math.max(44, textHeight + 20) -- Minimum 44, or text height + padding
		
		local item = Instance.new("Frame")
		item.Name = "Item" .. i
		item.Size = UDim2.new(1, -10, 0, itemHeight)
		item.BackgroundColor3 = COLORS.itemBg
		item.BorderSizePixel = 0
		item.LayoutOrder = i
		item.AutomaticSize = Enum.AutomaticSize.Y
		item.Parent = content
		
		local itemCorner = Instance.new("UICorner")
		itemCorner.CornerRadius = UDim.new(0, 8)
		itemCorner.Parent = item
		
		-- Bullet point
		local bullet = Instance.new("TextLabel")
		bullet.Name = "Bullet"
		bullet.Size = UDim2.new(0, 20, 0, 20)
		bullet.Position = UDim2.new(0, 12, 0, 10)
		bullet.BackgroundTransparency = 1
		bullet.Text = "•"
		bullet.TextSize = 18
		bullet.Font = Enum.Font.Arcade
		bullet.TextColor3 = COLORS.accent
		bullet.Parent = item
		
		-- Text label with auto-size
		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.Size = UDim2.new(1, -50, 0, 0) -- Width only, height auto
		text.Position = UDim2.new(0, 35, 0, 10)
		text.BackgroundTransparency = 1
		text.Text = changeText
		text.TextColor3 = COLORS.text
		text.TextSize = 14
		text.Font = Enum.Font.Arcade
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.TextYAlignment = Enum.TextYAlignment.Top
		text.TextWrapped = true
		text.AutomaticSize = Enum.AutomaticSize.Y
		text.Parent = item
		
		-- Add bottom padding to item via a spacer (to ensure auto-size includes padding)
		local spacer = Instance.new("Frame")
		spacer.Name = "Spacer"
		spacer.Size = UDim2.new(1, 0, 0, 10)
		spacer.Position = UDim2.new(0, 0, 1, -10)
		spacer.BackgroundTransparency = 1
		spacer.Parent = item
	end
	
	-- Footer text
	local footer = Instance.new("TextLabel")
	footer.Name = "Footer"
	footer.Size = UDim2.new(1, -20, 0, 25)
	footer.Position = UDim2.new(0, 10, 1, -85)
	footer.BackgroundTransparency = 1
	footer.Text = data.footer or ""
	footer.TextColor3 = COLORS.subtext
	footer.TextSize = 14
	footer.Font = Enum.Font.Arcade
	footer.TextXAlignment = Enum.TextXAlignment.Center
	footer.Parent = modal
	
	-- Close button
	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.Size = UDim2.new(1, -20, 0, 45)
	closeButton.Position = UDim2.new(0, 10, 1, -55)
	closeButton.BackgroundColor3 = COLORS.accent
	closeButton.Text = "Got it!"
	closeButton.TextColor3 = COLORS.text
	closeButton.TextSize = 16
	closeButton.Font = Enum.Font.Arcade
	closeButton.BorderSizePixel = 0
	closeButton.AutoButtonColor = false
	closeButton.Parent = modal
	
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeButton
	
	-- Button hover effects
	closeButton.MouseEnter:Connect(function()
		TweenService:Create(closeButton, TweenInfo.new(0.15), {
			BackgroundColor3 = COLORS.buttonHover
		}):Play()
	end)
	
	closeButton.MouseLeave:Connect(function()
		TweenService:Create(closeButton, TweenInfo.new(0.15), {
			BackgroundColor3 = COLORS.accent
		}):Play()
	end)
	
	-- Animate in
	local fadeOverlay = TweenService:Create(overlay, TweenInfo.new(0.3), {
		BackgroundTransparency = 0.5
	})
	
	modal.Size = UDim2.new(0, 420, 0, 0)
	modal.BackgroundTransparency = 0
	
	local expandModal = TweenService:Create(modal, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.new(0, 420, 0, modalHeight)
	})
	
	fadeOverlay:Play()
	expandModal:Play()
	
	-- Close functionality
	local function closeChangelog()
		isChangelogOpen = false
		
		-- Notify server that we've seen this version
		local ChangelogSeen = ReplicatedStorage:FindFirstChild("ChangelogSeen")
		if ChangelogSeen then
			ChangelogSeen:FireServer(data.version)
		end
		
		-- Animate out
		local shrinkModal = TweenService:Create(modal, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Size = UDim2.new(0, 420, 0, 0)
		})
		
		local fadeOutOverlay = TweenService:Create(overlay, TweenInfo.new(0.25), {
			BackgroundTransparency = 1
		})
		
		shrinkModal:Play()
		fadeOutOverlay:Play()
		
		shrinkModal.Completed:Connect(function()
			screenGui:Destroy()
		end)
	end
	
	closeButton.MouseButton1Click:Connect(closeChangelog)
	
	-- Also close when clicking overlay
	overlay.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			closeChangelog()
		end
	end)
	
	return screenGui
end

-- Listen for changelog show request from server
local ShowChangelog = ReplicatedStorage:WaitForChild("ShowChangelog", 30)
if ShowChangelog then
	ShowChangelog.OnClientEvent:Connect(function(data)
		if not POPUP_ENABLED then
			-- Popup disabled - changelog is now shown on title screen
			-- Still mark as seen so server doesn't keep trying
			local ChangelogSeen = ReplicatedStorage:FindFirstChild("ChangelogSeen")
			if ChangelogSeen then
				ChangelogSeen:FireServer(data.version)
			end
			print("[ChangelogUI] Popup disabled - changelog shown on title screen")
			return
		end
		
		print("[ChangelogUI] Showing changelog for", data.versionName)
		createChangelogUI(data)
	end)
	print("[ChangelogUI] Listening for changelog...")
else
	warn("[ChangelogUI] Could not find ShowChangelog RemoteEvent")
end
