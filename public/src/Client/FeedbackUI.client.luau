--[[
	FeedbackUI
	- For regular players: A button that opens a feedback submission popup
	- For the owner: A button that opens an inbox showing all feedback
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Configuration
local COLORS = {
	buttonBg = Color3.fromRGB(70, 130, 200),
	buttonHover = Color3.fromRGB(90, 150, 220),
	overlay = Color3.fromRGB(0, 0, 0),
	modalBg = Color3.fromRGB(35, 35, 45),
	headerBg = Color3.fromRGB(45, 45, 58),
	inputBg = Color3.fromRGB(50, 50, 65),
	itemBg = Color3.fromRGB(50, 50, 65),
	itemHover = Color3.fromRGB(60, 60, 80),
	accent = Color3.fromRGB(80, 180, 120),
	accentHover = Color3.fromRGB(100, 200, 140),
	text = Color3.fromRGB(255, 255, 255),
	subtext = Color3.fromRGB(180, 180, 180),
	error = Color3.fromRGB(220, 80, 80),
	success = Color3.fromRGB(80, 200, 120),
	unreadDot = Color3.fromRGB(255, 90, 90),
}

local isOwner = false
local isPopupOpen = false
local unreadCount = 0

-- Wait for remotes
local GetUnreadCount = ReplicatedStorage:WaitForChild("GetUnreadCount", 10)
local RequestFeedbackList = ReplicatedStorage:WaitForChild("RequestFeedbackList", 10)
local MarkFeedbackRead = ReplicatedStorage:WaitForChild("MarkFeedbackRead", 10)
local SubmitFeedback = ReplicatedStorage:WaitForChild("SubmitFeedback", 10)
local FeedbackResult = ReplicatedStorage:WaitForChild("FeedbackResult", 10)
local DeleteFeedback = ReplicatedStorage:WaitForChild("DeleteFeedback", 10)

-- Check if owner and get unread count
if GetUnreadCount then
	local count, ownerStatus = GetUnreadCount:InvokeServer()
	unreadCount = count or 0
	isOwner = ownerStatus or false
end

-- Create the main ScreenGui
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "FeedbackUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 50
screenGui.Parent = playerGui

-- Mobile detection
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Create the feedback button (cleaner horizontal design)
local feedbackButton = Instance.new("TextButton")
feedbackButton.Name = "FeedbackButton"
feedbackButton.Size = UDim2.new(0, 40, 0, 40)
-- Position: On mobile, put it on the LEFT side to avoid game controls on right
if IsMobile then
	feedbackButton.Position = UDim2.new(0, 55, 0, 50) -- Left side, next to Roblox menu
else
	feedbackButton.Position = UDim2.new(1, -54, 0.5, -22)
	feedbackButton.Size = UDim2.new(0, 44, 0, 44)
end
feedbackButton.BackgroundColor3 = COLORS.buttonBg
feedbackButton.Text = "💬"
feedbackButton.TextSize = 22
feedbackButton.Font = Enum.Font.Arcade
feedbackButton.TextColor3 = COLORS.text
feedbackButton.AutoButtonColor = false
feedbackButton.BorderSizePixel = 0
feedbackButton.Parent = screenGui

local buttonCorner = Instance.new("UICorner")
buttonCorner.CornerRadius = UDim.new(0, 10)
buttonCorner.Parent = feedbackButton

-- Keybind label (desktop only)
local keybindLabel = Instance.new("TextLabel")
keybindLabel.Name = "KeybindLabel"
keybindLabel.Size = UDim2.new(0, 16, 0, 14)
keybindLabel.Position = UDim2.new(0.5, -8, 1, 2)
keybindLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
keybindLabel.Text = "F"
keybindLabel.TextColor3 = COLORS.subtext
keybindLabel.TextSize = 10
keybindLabel.Font = Enum.Font.Arcade
keybindLabel.BorderSizePixel = 0
keybindLabel.Visible = not IsMobile -- Hide on mobile
keybindLabel.Parent = feedbackButton

local keybindCorner = Instance.new("UICorner")
keybindCorner.CornerRadius = UDim.new(0, 4)
keybindCorner.Parent = keybindLabel

-- Notification dot (for owner)
local notificationDot = Instance.new("Frame")
notificationDot.Name = "NotificationDot"
notificationDot.Size = UDim2.new(0, 16, 0, 16)
notificationDot.Position = UDim2.new(1, -6, 0, -4)
notificationDot.BackgroundColor3 = COLORS.unreadDot
notificationDot.BorderSizePixel = 0
notificationDot.Visible = isOwner and unreadCount > 0
notificationDot.Parent = feedbackButton

local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = notificationDot

local dotLabel = Instance.new("TextLabel")
dotLabel.Size = UDim2.new(1, 0, 1, 0)
dotLabel.BackgroundTransparency = 1
dotLabel.Text = tostring(unreadCount)
dotLabel.TextColor3 = COLORS.text
dotLabel.TextSize = 10
dotLabel.Font = Enum.Font.Arcade
dotLabel.Parent = notificationDot

-- Button hover effects
feedbackButton.MouseEnter:Connect(function()
	TweenService:Create(feedbackButton, TweenInfo.new(0.15), {
		BackgroundColor3 = COLORS.buttonHover,
		Size = UDim2.new(0, 48, 0, 48),
		Position = UDim2.new(1, -56, 0.5, -24)
	}):Play()
end)

feedbackButton.MouseLeave:Connect(function()
	if not isPopupOpen then
		TweenService:Create(feedbackButton, TweenInfo.new(0.15), {
			BackgroundColor3 = COLORS.buttonBg,
			Size = UDim2.new(0, 44, 0, 44),
			Position = UDim2.new(1, -54, 0.5, -22)
		}):Play()
	end
end)

-- Overlay (shared by both popups)
local overlay = Instance.new("Frame")
overlay.Name = "Overlay"
overlay.Size = UDim2.new(1, 0, 1, 0)
overlay.BackgroundColor3 = COLORS.overlay
overlay.BackgroundTransparency = 1
overlay.BorderSizePixel = 0
overlay.Visible = false
overlay.ZIndex = 10
overlay.Parent = screenGui

--------------------------------------------------------------------------------
-- PLAYER FEEDBACK SUBMISSION POPUP
--------------------------------------------------------------------------------

local function createSubmitPopup()
	local modal = Instance.new("Frame")
	modal.Name = "SubmitModal"
	modal.Size = UDim2.new(0, 380, 0, 280)
	modal.Position = UDim2.new(0.5, 0, 0.5, 0)
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.BackgroundColor3 = COLORS.modalBg
	modal.BorderSizePixel = 0
	modal.Visible = false
	modal.ZIndex = 11
	modal.Parent = screenGui
	
	local modalCorner = Instance.new("UICorner")
	modalCorner.CornerRadius = UDim.new(0, 12)
	modalCorner.Parent = modal
	
	-- Title
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0, 30)
	title.Position = UDim2.new(0, 15, 0, 15)
	title.BackgroundTransparency = 1
	title.Text = "Send Feedback"
	title.TextColor3 = COLORS.text
	title.TextSize = 20
	title.Font = Enum.Font.Arcade
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 12
	title.Parent = modal
	
	-- Subtitle
	local subtitle = Instance.new("TextLabel")
	subtitle.Size = UDim2.new(1, -20, 0, 20)
	subtitle.Position = UDim2.new(0, 15, 0, 45)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Bugs, suggestions, or anything else!"
	subtitle.TextColor3 = COLORS.subtext
	subtitle.TextSize = 13
	subtitle.Font = Enum.Font.Arcade
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.ZIndex = 12
	subtitle.Parent = modal
	
	-- Text input frame
	local inputFrame = Instance.new("Frame")
	inputFrame.Size = UDim2.new(1, -30, 0, 100)
	inputFrame.Position = UDim2.new(0, 15, 0, 75)
	inputFrame.BackgroundColor3 = COLORS.inputBg
	inputFrame.BorderSizePixel = 0
	inputFrame.ZIndex = 12
	inputFrame.Parent = modal
	
	local inputCorner = Instance.new("UICorner")
	inputCorner.CornerRadius = UDim.new(0, 8)
	inputCorner.Parent = inputFrame
	
	local textBox = Instance.new("TextBox")
	textBox.Name = "TextBox"
	textBox.Size = UDim2.new(1, -16, 1, -16)
	textBox.Position = UDim2.new(0, 8, 0, 8)
	textBox.BackgroundTransparency = 1
	textBox.Text = ""
	textBox.PlaceholderText = "Type your feedback here..."
	textBox.PlaceholderColor3 = COLORS.subtext
	textBox.TextColor3 = COLORS.text
	textBox.TextSize = 14
	textBox.Font = Enum.Font.Arcade
	textBox.TextXAlignment = Enum.TextXAlignment.Left
	textBox.TextYAlignment = Enum.TextYAlignment.Top
	textBox.TextWrapped = true
	textBox.MultiLine = true
	textBox.ClearTextOnFocus = false
	textBox.ZIndex = 13
	textBox.Parent = inputFrame
	
	-- Character count
	local charCount = Instance.new("TextLabel")
	charCount.Size = UDim2.new(0, 60, 0, 16)
	charCount.Position = UDim2.new(1, -75, 1, -24)
	charCount.BackgroundTransparency = 1
	charCount.Text = "0/500"
	charCount.TextColor3 = COLORS.subtext
	charCount.TextSize = 11
	charCount.Font = Enum.Font.Arcade
	charCount.TextXAlignment = Enum.TextXAlignment.Right
	charCount.ZIndex = 12
	charCount.Parent = modal
	
	-- Status message
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.Size = UDim2.new(1, -150, 0, 20)
	statusLabel.Position = UDim2.new(0, 15, 1, -60)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = ""
	statusLabel.TextColor3 = COLORS.subtext
	statusLabel.TextSize = 13
	statusLabel.Font = Enum.Font.Arcade
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.ZIndex = 12
	statusLabel.Parent = modal
	
	-- Submit button
	local submitButton = Instance.new("TextButton")
	submitButton.Size = UDim2.new(0, 100, 0, 38)
	submitButton.Position = UDim2.new(1, -115, 1, -50)
	submitButton.BackgroundColor3 = COLORS.accent
	submitButton.Text = "Submit"
	submitButton.TextColor3 = COLORS.text
	submitButton.TextSize = 15
	submitButton.Font = Enum.Font.Arcade
	submitButton.BorderSizePixel = 0
	submitButton.AutoButtonColor = false
	submitButton.ZIndex = 12
	submitButton.Parent = modal
	
	local submitCorner = Instance.new("UICorner")
	submitCorner.CornerRadius = UDim.new(0, 8)
	submitCorner.Parent = submitButton
	
	-- Cancel button
	local cancelButton = Instance.new("TextButton")
	cancelButton.Size = UDim2.new(0, 80, 0, 38)
	cancelButton.Position = UDim2.new(1, -205, 1, -50)
	cancelButton.BackgroundColor3 = COLORS.inputBg
	cancelButton.Text = "Cancel"
	cancelButton.TextColor3 = COLORS.subtext
	cancelButton.TextSize = 15
	cancelButton.Font = Enum.Font.Arcade
	cancelButton.BorderSizePixel = 0
	cancelButton.AutoButtonColor = false
	cancelButton.ZIndex = 12
	cancelButton.Parent = modal
	
	local cancelCorner = Instance.new("UICorner")
	cancelCorner.CornerRadius = UDim.new(0, 8)
	cancelCorner.Parent = cancelButton
	
	-- Hover effects
	submitButton.MouseEnter:Connect(function()
		TweenService:Create(submitButton, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.accentHover}):Play()
	end)
	submitButton.MouseLeave:Connect(function()
		TweenService:Create(submitButton, TweenInfo.new(0.15), {BackgroundColor3 = COLORS.accent}):Play()
	end)
	cancelButton.MouseEnter:Connect(function()
		TweenService:Create(cancelButton, TweenInfo.new(0.15), {TextColor3 = COLORS.text}):Play()
	end)
	cancelButton.MouseLeave:Connect(function()
		TweenService:Create(cancelButton, TweenInfo.new(0.15), {TextColor3 = COLORS.subtext}):Play()
	end)
	
	-- Character count update
	textBox:GetPropertyChangedSignal("Text"):Connect(function()
		local len = #textBox.Text
		charCount.Text = len .. "/500"
		if len > 500 then
			textBox.Text = string.sub(textBox.Text, 1, 500)
			charCount.TextColor3 = COLORS.error
		elseif len > 400 then
			charCount.TextColor3 = Color3.fromRGB(220, 180, 80)
		else
			charCount.TextColor3 = COLORS.subtext
		end
	end)
	
	return modal, textBox, statusLabel, submitButton, cancelButton
end

--------------------------------------------------------------------------------
-- OWNER FEEDBACK INBOX POPUP
--------------------------------------------------------------------------------

local function createInboxPopup()
	local modal = Instance.new("Frame")
	modal.Name = "InboxModal"
	modal.Size = UDim2.new(0, 450, 0, 500)
	modal.Position = UDim2.new(0.5, 0, 0.5, 0)
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.BackgroundColor3 = COLORS.modalBg
	modal.BorderSizePixel = 0
	modal.Visible = false
	modal.ZIndex = 11
	modal.Parent = screenGui
	
	local modalCorner = Instance.new("UICorner")
	modalCorner.CornerRadius = UDim.new(0, 12)
	modalCorner.Parent = modal
	
	-- Header
	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 60)
	header.BackgroundColor3 = COLORS.headerBg
	header.BorderSizePixel = 0
	header.ZIndex = 12
	header.Parent = modal
	
	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 12)
	headerCorner.Parent = header
	
	local headerCover = Instance.new("Frame")
	headerCover.Size = UDim2.new(1, 0, 0, 15)
	headerCover.Position = UDim2.new(0, 0, 1, -15)
	headerCover.BackgroundColor3 = COLORS.headerBg
	headerCover.BorderSizePixel = 0
	headerCover.ZIndex = 12
	headerCover.Parent = header
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0, 30)
	title.Position = UDim2.new(0, 15, 0.5, -15)
	title.BackgroundTransparency = 1
	title.Text = "📬 Feedback Inbox"
	title.TextColor3 = COLORS.text
	title.TextSize = 20
	title.Font = Enum.Font.Arcade
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 13
	title.Parent = header
	
	-- Close button
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 30, 0, 30)
	closeButton.Position = UDim2.new(1, -40, 0.5, -15)
	closeButton.BackgroundTransparency = 1
	closeButton.Text = "✕"
	closeButton.TextColor3 = COLORS.subtext
	closeButton.TextSize = 18
	closeButton.Font = Enum.Font.Arcade
	closeButton.ZIndex = 13
	closeButton.Parent = header
	
	closeButton.MouseEnter:Connect(function()
		closeButton.TextColor3 = COLORS.text
	end)
	closeButton.MouseLeave:Connect(function()
		closeButton.TextColor3 = COLORS.subtext
	end)
	
	-- Content scroll frame
	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -20, 1, -80)
	content.Position = UDim2.new(0, 10, 0, 70)
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.ScrollBarThickness = 4
	content.ScrollBarImageColor3 = COLORS.accent
	content.CanvasSize = UDim2.new(0, 0, 0, 0)
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ZIndex = 12
	content.Parent = modal
	
	local contentLayout = Instance.new("UIListLayout")
	contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
	contentLayout.Padding = UDim.new(0, 8)
	contentLayout.Parent = content
	
	-- Empty state label
	local emptyLabel = Instance.new("TextLabel")
	emptyLabel.Name = "EmptyLabel"
	emptyLabel.Size = UDim2.new(1, 0, 0, 100)
	emptyLabel.BackgroundTransparency = 1
	emptyLabel.Text = "No feedback yet!"
	emptyLabel.TextColor3 = COLORS.subtext
	emptyLabel.TextSize = 16
	emptyLabel.Font = Enum.Font.Arcade
	emptyLabel.ZIndex = 12
	emptyLabel.Visible = false
	emptyLabel.Parent = content
	
	return modal, content, emptyLabel, closeButton
end

-- Create both popups
local submitModal, textBox, statusLabel, submitButton, cancelButton = createSubmitPopup()
local inboxModal, inboxContent, emptyLabel, inboxCloseButton = createInboxPopup()

--------------------------------------------------------------------------------
-- POPUP LOGIC
--------------------------------------------------------------------------------

local function closePopup()
	if not isPopupOpen then return end
	
	-- Re-enable E key
	ContextActionService:UnbindAction("BlockE")
	
	TweenService:Create(overlay, TweenInfo.new(0.2), {BackgroundTransparency = 1}):Play()
	
	if isOwner then
		TweenService:Create(inboxModal, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Size = UDim2.new(0, 450, 0, 0)
		}):Play()
	else
		TweenService:Create(submitModal, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Size = UDim2.new(0, 380, 0, 0)
		}):Play()
	end
	
	task.wait(0.2)
	overlay.Visible = false
	submitModal.Visible = false
	inboxModal.Visible = false
	isPopupOpen = false
	
	TweenService:Create(feedbackButton, TweenInfo.new(0.15), {
		BackgroundColor3 = COLORS.buttonBg,
		Size = UDim2.new(0, 44, 0, 44),
		Position = UDim2.new(1, -54, 0.5, -22)
	}):Play()
end

local function populateInbox()
	-- Clear existing items
	for _, child in ipairs(inboxContent:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	
	-- Get feedback from server
	local feedbackList = RequestFeedbackList:InvokeServer()
	
	if #feedbackList == 0 then
		emptyLabel.Visible = true
		return
	end
	
	emptyLabel.Visible = false
	
	for i, entry in ipairs(feedbackList) do
		local item = Instance.new("Frame")
		item.Name = "Item" .. i
		item.Size = UDim2.new(1, -10, 0, 80)
		item.BackgroundColor3 = COLORS.itemBg
		item.BorderSizePixel = 0
		item.LayoutOrder = i
		item.ZIndex = 12
		item.Parent = inboxContent
		
		local itemCorner = Instance.new("UICorner")
		itemCorner.CornerRadius = UDim.new(0, 8)
		itemCorner.Parent = item
		
		-- Username and date
		local header = Instance.new("TextLabel")
		header.Size = UDim2.new(1, -100, 0, 20) -- Leave room for delete button
		header.Position = UDim2.new(0, 10, 0, 8)
		header.BackgroundTransparency = 1
		header.Text = entry.displayName .. " (@" .. entry.username .. ")"
		header.TextColor3 = COLORS.accent
		header.TextSize = 13
		header.Font = Enum.Font.Arcade
		header.TextXAlignment = Enum.TextXAlignment.Left
		header.ZIndex = 13
		header.Parent = item
		
		local dateLabel = Instance.new("TextLabel")
		dateLabel.Size = UDim2.new(0, 100, 0, 16)
		dateLabel.Position = UDim2.new(1, -145, 0, 10)
		dateLabel.BackgroundTransparency = 1
		dateLabel.Text = entry.date or ""
		dateLabel.TextColor3 = COLORS.subtext
		dateLabel.TextSize = 11
		dateLabel.Font = Enum.Font.Arcade
		dateLabel.TextXAlignment = Enum.TextXAlignment.Right
		dateLabel.ZIndex = 13
		dateLabel.Parent = item
		
		-- Delete button
		local deleteButton = Instance.new("TextButton")
		deleteButton.Size = UDim2.new(0, 28, 0, 28)
		deleteButton.Position = UDim2.new(1, -38, 0, 6)
		deleteButton.BackgroundColor3 = Color3.fromRGB(80, 50, 50)
		deleteButton.Text = "🗑"
		deleteButton.TextSize = 14
		deleteButton.TextColor3 = COLORS.subtext
		deleteButton.BorderSizePixel = 0
		deleteButton.AutoButtonColor = false
		deleteButton.ZIndex = 14
		deleteButton.Parent = item
		
		local deleteCorner = Instance.new("UICorner")
		deleteCorner.CornerRadius = UDim.new(0, 6)
		deleteCorner.Parent = deleteButton
		
		-- Delete button hover
		deleteButton.MouseEnter:Connect(function()
			TweenService:Create(deleteButton, TweenInfo.new(0.15), {
				BackgroundColor3 = COLORS.error,
				TextColor3 = COLORS.text
			}):Play()
		end)
		deleteButton.MouseLeave:Connect(function()
			TweenService:Create(deleteButton, TweenInfo.new(0.15), {
				BackgroundColor3 = Color3.fromRGB(80, 50, 50),
				TextColor3 = COLORS.subtext
			}):Play()
		end)
		
		-- Delete click handler
		deleteButton.MouseButton1Click:Connect(function()
			-- Visual feedback
			deleteButton.Text = "..."
			
			local success, message = DeleteFeedback:InvokeServer(entry.id)
			
			if success then
				-- Animate out and remove
				TweenService:Create(item, TweenInfo.new(0.2), {
					BackgroundTransparency = 1,
					Size = UDim2.new(1, -10, 0, 0)
				}):Play()
				task.wait(0.2)
				item:Destroy()
				
				-- Check if list is now empty
				local remaining = 0
				for _, child in ipairs(inboxContent:GetChildren()) do
					if child:IsA("Frame") then
						remaining = remaining + 1
					end
				end
				if remaining == 0 then
					emptyLabel.Visible = true
				end
			else
				-- Show error
				deleteButton.Text = "❌"
				task.wait(1)
				deleteButton.Text = "🗑"
			end
		end)
		
		-- Feedback text
		local feedbackLabel = Instance.new("TextLabel")
		feedbackLabel.Size = UDim2.new(1, -20, 0, 45)
		feedbackLabel.Position = UDim2.new(0, 10, 0, 30)
		feedbackLabel.BackgroundTransparency = 1
		feedbackLabel.Text = entry.feedback or ""
		feedbackLabel.TextColor3 = COLORS.text
		feedbackLabel.TextSize = 13
		feedbackLabel.Font = Enum.Font.Arcade
		feedbackLabel.TextXAlignment = Enum.TextXAlignment.Left
		feedbackLabel.TextYAlignment = Enum.TextYAlignment.Top
		feedbackLabel.TextWrapped = true
		feedbackLabel.TextTruncate = Enum.TextTruncate.AtEnd
		feedbackLabel.ZIndex = 13
		feedbackLabel.Parent = item
	end
end

local function openPopup()
	if isPopupOpen then return end
	isPopupOpen = true
	
	-- Block E key (mouse is handled by CameraController detecting isPopupOpen)
	ContextActionService:BindAction("BlockE", function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.E)
	
	overlay.Visible = true
	overlay.BackgroundTransparency = 1
	TweenService:Create(overlay, TweenInfo.new(0.25), {BackgroundTransparency = 0.5}):Play()
	
	if isOwner then
		-- Show inbox
		populateInbox()
		inboxModal.Visible = true
		inboxModal.Size = UDim2.new(0, 450, 0, 0)
		TweenService:Create(inboxModal, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 450, 0, 500)
		}):Play()
		
		-- Mark as read
		MarkFeedbackRead:FireServer()
		unreadCount = 0
		notificationDot.Visible = false
	else
		-- Show submit popup
		textBox.Text = ""
		statusLabel.Text = ""
		submitModal.Visible = true
		submitModal.Size = UDim2.new(0, 380, 0, 0)
		TweenService:Create(submitModal, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 380, 0, 280)
		}):Play()
		
		task.wait(0.3)
		textBox:CaptureFocus()
	end
end

-- Submit feedback (for players)
local isSubmitting = false

local function submitFeedback()
	if isSubmitting then return end
	
	local feedback = textBox.Text
	if #feedback < 5 then
		statusLabel.Text = "Please write at least 5 characters"
		statusLabel.TextColor3 = COLORS.error
		return
	end
	
	isSubmitting = true
	submitButton.Text = "..."
	statusLabel.Text = "Sending..."
	statusLabel.TextColor3 = COLORS.subtext
	
	if SubmitFeedback then
		SubmitFeedback:FireServer(feedback)
	else
		statusLabel.Text = "Error: System not available"
		statusLabel.TextColor3 = COLORS.error
		isSubmitting = false
		submitButton.Text = "Submit"
	end
end

-- Handle server response
if FeedbackResult then
	FeedbackResult.OnClientEvent:Connect(function(success, message)
		isSubmitting = false
		submitButton.Text = "Submit"
		
		if success then
			statusLabel.Text = message
			statusLabel.TextColor3 = COLORS.success
			task.wait(1.5)
			closePopup()
		else
			statusLabel.Text = message
			statusLabel.TextColor3 = COLORS.error
		end
	end)
end

-- Connect buttons
feedbackButton.MouseButton1Click:Connect(openPopup)
cancelButton.MouseButton1Click:Connect(closePopup)
submitButton.MouseButton1Click:Connect(submitFeedback)
inboxCloseButton.MouseButton1Click:Connect(closePopup)

overlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		closePopup()
	end
end)

-- Keybind (F)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	
	-- Don't trigger while editing signs
	if _G.SignEditController and _G.SignEditController.IsEditing() then return end
	
	if input.KeyCode == Enum.KeyCode.F then
		if isPopupOpen then
			closePopup()
		else
			openPopup()
		end
	end
end)

-- Expose for camera controller
_G.FeedbackUI = {
	IsOpen = function() return isPopupOpen end
}

-- Periodically check for new feedback (owner only)
if isOwner then
	task.spawn(function()
		while true do
			task.wait(60) -- Check every minute
			if not isPopupOpen and GetUnreadCount then
				local count = GetUnreadCount:InvokeServer()
				unreadCount = count or 0
				notificationDot.Visible = unreadCount > 0
				dotLabel.Text = tostring(unreadCount)
			end
		end
	end)
end

print("[FeedbackUI] Initialized - Owner mode:", isOwner)
