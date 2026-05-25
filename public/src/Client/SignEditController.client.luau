--[[
	SignEditController
	Live sign editing - camera moves to face the sign
	No UI panel - edit directly on the sign with keyboard input
	Shows a cursor/caret on the current line
	Mobile: Uses hidden TextBox to capture keyboard, same live preview
]]

print("[SignEdit] Script starting...")

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateSignText = nil

-- Try to get the remote, but don't block if it doesn't exist yet
task.spawn(function()
	UpdateSignText = Remotes:WaitForChild("UpdateSignText", 10)
	if UpdateSignText then
		print("[SignEdit] Found UpdateSignText remote")
	else
		warn("[SignEdit] UpdateSignText remote not found")
	end
end)

local REACH_DISTANCE = 50
local MAX_LINES = 5
local MAX_CHARS_PER_LINE = 20
local CAMERA_DISTANCE = 5
local CAMERA_TWEEN_TIME = 0.5

-- Mobile detection
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- State
local CurrentSign = nil
local IsEditing = false
local CurrentLineIndex = 1
local Lines = {"", "", "", "", ""}
local OriginalLines = {"", "", "", "", ""}
local OriginalCameraCFrame = nil
local TargetCameraCFrame = nil
local CameraConnection = nil
local CursorVisible = true
local CursorBlinkTime = 0
local EditStartTime = 0

-- Mobile input capture
local MobileInputGui = nil
local MobileTextBox = nil
local MobileButtonsFrame = nil
local LastTextBoxValue = ""

-- ============================================
-- FORWARD DECLARATIONS
-- ============================================

local saveAndClose
local closeEditor
local cancelEdit

-- ============================================
-- RAYCAST HELPERS
-- ============================================

local function raycastForSign()
	local viewportSize = Camera.ViewportSize
	local ray = Camera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
	
	local result = workspace:Raycast(ray.Origin, ray.Direction * REACH_DISTANCE, raycastParams)
	
	if result and result.Instance then
		local hit = result.Instance
		
		local function isSign(obj)
			local isSignBlock = obj:GetAttribute("IsSignStanding") or obj:GetAttribute("IsWallSign")
			if not isSignBlock then return false end
			-- Frame signs are only editable when filled
			if obj:GetAttribute("IsFrameBlock") then return false end -- unfilled frame
			return true
		end
		
		if isSign(hit) then
			return hit
		elseif hit.Parent and isSign(hit.Parent) then
			return hit.Parent
		elseif hit.Parent and hit.Parent.Parent and isSign(hit.Parent.Parent) then
			return hit.Parent.Parent
		end
	end
	
	return nil
end

-- ============================================
-- SIGN HELPERS
-- ============================================

local function getSignPart(sign)
	if sign:IsA("Model") then
		return sign:FindFirstChild("Sign") or sign.PrimaryPart or sign:FindFirstChildWhichIsA("BasePart")
	elseif sign:IsA("BasePart") then
		return sign
	end
	return nil
end

local function getSignFaceDirection(sign)
	local signPart = getSignPart(sign)
	if not signPart then return Vector3.new(0, 0, -1) end
	return signPart.CFrame.LookVector
end

local function getSignPosition(sign)
	local signPart = getSignPart(sign)
	if not signPart then return sign:GetPivot().Position end
	return signPart.Position
end

local function updateSignDisplay()
	if not CurrentSign then return end
	
	local signPart = getSignPart(CurrentSign)
	if not signPart then return end
	
	local gui = signPart:FindFirstChild("SignTextGui")
	if not gui then return end
	
	local container = gui:FindFirstChild("Container")
	if not container then return end
	
	-- Update each line with cursor on current line
	for i = 1, MAX_LINES do
		local label = container:FindFirstChild("Line" .. i)
		if label then
			local text = Lines[i] or ""
			
			if i == CurrentLineIndex and IsEditing then
				-- Show cursor on current line
				local cursor = CursorVisible and "|" or ""
				label.Text = text .. cursor
			else
				label.Text = text
			end
		end
	end
end

-- ============================================
-- CAMERA CONTROL
-- ============================================

local function startCameraControl()
	if CameraConnection then
		CameraConnection:Disconnect()
	end
	
	-- Store original camera position
	OriginalCameraCFrame = Camera.CFrame
	
	-- Calculate target position facing the sign
	local signPos = getSignPosition(CurrentSign)
	local signFaceDir = getSignFaceDirection(CurrentSign)
	local cameraPos = signPos + signFaceDir * CAMERA_DISTANCE
	TargetCameraCFrame = CFrame.lookAt(cameraPos, signPos)
	
	-- Take control of camera
	Camera.CameraType = Enum.CameraType.Scriptable
	
	-- Smoothly move to target and hold position
	local startCFrame = Camera.CFrame
	local elapsed = 0
	
	CameraConnection = RunService.RenderStepped:Connect(function(dt)
		if not IsEditing then
			return
		end
		
		if elapsed < CAMERA_TWEEN_TIME then
			-- Tweening to target
			elapsed = elapsed + dt
			local alpha = math.min(elapsed / CAMERA_TWEEN_TIME, 1)
			-- Smooth easing
			alpha = 1 - math.pow(1 - alpha, 3)
			Camera.CFrame = startCFrame:Lerp(TargetCameraCFrame, alpha)
		else
			-- Hold at target position
			Camera.CFrame = TargetCameraCFrame
		end
	end)
end

local function stopCameraControl()
	if CameraConnection then
		CameraConnection:Disconnect()
		CameraConnection = nil
	end
	
	if OriginalCameraCFrame then
		-- Store locally before clearing
		local targetCFrame = OriginalCameraCFrame
		local startCFrame = Camera.CFrame
		local elapsed = 0
		
		-- Clear state immediately
		OriginalCameraCFrame = nil
		TargetCameraCFrame = nil
		
		-- Smoothly return to original position
		local returnConnection
		returnConnection = RunService.RenderStepped:Connect(function(dt)
			elapsed = elapsed + dt
			local alpha = math.min(elapsed / CAMERA_TWEEN_TIME, 1)
			alpha = 1 - math.pow(1 - alpha, 3)
			Camera.CFrame = startCFrame:Lerp(targetCFrame, alpha)
			
			if alpha >= 1 then
				returnConnection:Disconnect()
				Camera.CameraType = Enum.CameraType.Custom
			end
		end)
	else
		Camera.CameraType = Enum.CameraType.Custom
		OriginalCameraCFrame = nil
		TargetCameraCFrame = nil
	end
end

-- ============================================
-- CURSOR BLINK
-- ============================================

local CursorConnection = nil

local function startCursorBlink()
	if CursorConnection then
		CursorConnection:Disconnect()
	end
	
	CursorBlinkTime = 0
	CursorVisible = true
	
	CursorConnection = RunService.Heartbeat:Connect(function(dt)
		if not IsEditing then return end
		
		CursorBlinkTime = CursorBlinkTime + dt
		if CursorBlinkTime >= 0.5 then
			CursorBlinkTime = 0
			CursorVisible = not CursorVisible
			updateSignDisplay()
		end
	end)
end

local function stopCursorBlink()
	if CursorConnection then
		CursorConnection:Disconnect()
		CursorConnection = nil
	end
	CursorVisible = false
end

-- ============================================
-- TEXT INPUT (Desktop)
-- ============================================

local function handleTextInput(text)
	if not IsEditing then return end
	
	local currentLine = Lines[CurrentLineIndex] or ""
	
	-- Add text if within limit
	if #currentLine + #text <= MAX_CHARS_PER_LINE then
		Lines[CurrentLineIndex] = currentLine .. text
		CursorVisible = true
		CursorBlinkTime = 0
		updateSignDisplay()
	end
end

local function handleBackspace()
	if not IsEditing then return end
	
	local currentLine = Lines[CurrentLineIndex] or ""
	
	if #currentLine > 0 then
		-- Remove last character
		Lines[CurrentLineIndex] = string.sub(currentLine, 1, -2)
	elseif CurrentLineIndex > 1 then
		-- Move to previous line if current is empty
		CurrentLineIndex = CurrentLineIndex - 1
	end
	
	CursorVisible = true
	CursorBlinkTime = 0
	updateSignDisplay()
end

local function handleEnter()
	if not IsEditing then return end
	
	if CurrentLineIndex < MAX_LINES then
		CurrentLineIndex = CurrentLineIndex + 1
		-- Sync mobile textbox to new line
		if IsMobile and MobileTextBox then
			MobileTextBox.Text = Lines[CurrentLineIndex] or ""
			LastTextBoxValue = MobileTextBox.Text
		end
	else
		-- Save and close on Enter from last line
		saveAndClose()
		return
	end
	
	CursorVisible = true
	CursorBlinkTime = 0
	updateSignDisplay()
end

local function handleArrowUp()
	if not IsEditing then return end
	
	if CurrentLineIndex > 1 then
		CurrentLineIndex = CurrentLineIndex - 1
		-- Sync mobile textbox to new line
		if IsMobile and MobileTextBox then
			MobileTextBox.Text = Lines[CurrentLineIndex] or ""
			LastTextBoxValue = MobileTextBox.Text
		end
		CursorVisible = true
		CursorBlinkTime = 0
		updateSignDisplay()
	end
end

local function handleArrowDown()
	if not IsEditing then return end
	
	if CurrentLineIndex < MAX_LINES then
		CurrentLineIndex = CurrentLineIndex + 1
		-- Sync mobile textbox to new line
		if IsMobile and MobileTextBox then
			MobileTextBox.Text = Lines[CurrentLineIndex] or ""
			LastTextBoxValue = MobileTextBox.Text
		end
		CursorVisible = true
		CursorBlinkTime = 0
		updateSignDisplay()
	end
end

-- ============================================
-- MOBILE INPUT CAPTURE
-- ============================================

local function createMobileInputUI()
	if MobileInputGui then return end
	
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MobileSignInputUI"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 100
	screenGui.Parent = PlayerGui
	
	-- Hidden TextBox to capture keyboard input (positioned off-screen but focusable)
	local textBox = Instance.new("TextBox")
	textBox.Name = "HiddenInput"
	textBox.Position = UDim2.new(0.5, -100, 0, -50) -- Above screen, invisible
	textBox.Size = UDim2.new(0, 200, 0, 40)
	textBox.BackgroundTransparency = 1
	textBox.TextTransparency = 1
	textBox.Text = ""
	textBox.ClearTextOnFocus = false
	textBox.MultiLine = false
	textBox.Parent = screenGui
	
	-- Track text changes to update sign
	textBox:GetPropertyChangedSignal("Text"):Connect(function()
		if not IsEditing then return end
		
		local newText = textBox.Text
		
		-- Check for newline (Enter key on mobile)
		if string.find(newText, "\n") or string.find(newText, "\r") then
			-- Remove newline and move to next line
			textBox.Text = string.gsub(newText, "[\n\r]", "")
			handleEnter()
			return
		end
		
		-- Limit to max chars
		if #newText > MAX_CHARS_PER_LINE then
			newText = string.sub(newText, 1, MAX_CHARS_PER_LINE)
			textBox.Text = newText
		end
		
		-- Update current line
		Lines[CurrentLineIndex] = newText
		LastTextBoxValue = newText
		CursorVisible = true
		CursorBlinkTime = 0
		updateSignDisplay()
	end)
	
	-- Handle focus lost (keyboard dismissed)
	textBox.FocusLost:Connect(function(enterPressed)
		if not IsEditing then return end
		
		if enterPressed then
			handleEnter()
			-- Re-focus to keep editing
			task.delay(0.1, function()
				if IsEditing and MobileTextBox then
					MobileTextBox:CaptureFocus()
				end
			end)
		end
	end)
	
	MobileTextBox = textBox
	
	-- Floating buttons at bottom of screen
	local buttonsFrame = Instance.new("Frame")
	buttonsFrame.Name = "EditButtons"
	buttonsFrame.AnchorPoint = Vector2.new(0.5, 1)
	buttonsFrame.Position = UDim2.new(0.5, 0, 1, -20)
	buttonsFrame.Size = UDim2.new(0, 220, 0, 44)
	buttonsFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	buttonsFrame.BackgroundTransparency = 0.3
	buttonsFrame.BorderSizePixel = 0
	buttonsFrame.Visible = false
	buttonsFrame.Parent = screenGui
	
	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 10)
	btnCorner.Parent = buttonsFrame
	
	local btnLayout = Instance.new("UIListLayout")
	btnLayout.FillDirection = Enum.FillDirection.Horizontal
	btnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	btnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	btnLayout.Padding = UDim.new(0, 10)
	btnLayout.Parent = buttonsFrame
	
	-- Line navigation buttons
	local upBtn = Instance.new("TextButton")
	upBtn.Name = "UpBtn"
	upBtn.Size = UDim2.new(0, 36, 0, 36)
	upBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	upBtn.Text = "▲"
	upBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	upBtn.TextSize = 18
	upBtn.Font = Enum.Font.GothamBold
	upBtn.Parent = buttonsFrame
	
	local upBtnCorner = Instance.new("UICorner")
	upBtnCorner.CornerRadius = UDim.new(0, 6)
	upBtnCorner.Parent = upBtn
	
	upBtn.MouseButton1Click:Connect(function()
		handleArrowUp()
		-- Re-focus textbox
		if MobileTextBox then
			MobileTextBox:CaptureFocus()
		end
	end)
	
	local downBtn = Instance.new("TextButton")
	downBtn.Name = "DownBtn"
	downBtn.Size = UDim2.new(0, 36, 0, 36)
	downBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	downBtn.Text = "▼"
	downBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	downBtn.TextSize = 18
	downBtn.Font = Enum.Font.GothamBold
	downBtn.Parent = buttonsFrame
	
	local downBtnCorner = Instance.new("UICorner")
	downBtnCorner.CornerRadius = UDim.new(0, 6)
	downBtnCorner.Parent = downBtn
	
	downBtn.MouseButton1Click:Connect(function()
		handleArrowDown()
		-- Re-focus textbox
		if MobileTextBox then
			MobileTextBox:CaptureFocus()
		end
	end)
	
	-- Cancel button
	local cancelBtn = Instance.new("TextButton")
	cancelBtn.Name = "CancelBtn"
	cancelBtn.Size = UDim2.new(0, 60, 0, 36)
	cancelBtn.BackgroundColor3 = Color3.fromRGB(140, 60, 60)
	cancelBtn.Text = "X"
	cancelBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	cancelBtn.TextSize = 20
	cancelBtn.Font = Enum.Font.GothamBold
	cancelBtn.Parent = buttonsFrame
	
	local cancelBtnCorner = Instance.new("UICorner")
	cancelBtnCorner.CornerRadius = UDim.new(0, 6)
	cancelBtnCorner.Parent = cancelBtn
	
	cancelBtn.MouseButton1Click:Connect(function()
		cancelEdit()
	end)
	
	-- Save button
	local saveBtn = Instance.new("TextButton")
	saveBtn.Name = "SaveBtn"
	saveBtn.Size = UDim2.new(0, 60, 0, 36)
	saveBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
	saveBtn.Text = "✓"
	saveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	saveBtn.TextSize = 20
	saveBtn.Font = Enum.Font.GothamBold
	saveBtn.Parent = buttonsFrame
	
	local saveBtnCorner = Instance.new("UICorner")
	saveBtnCorner.CornerRadius = UDim.new(0, 6)
	saveBtnCorner.Parent = saveBtn
	
	saveBtn.MouseButton1Click:Connect(function()
		saveAndClose()
	end)
	
	MobileButtonsFrame = buttonsFrame
	MobileInputGui = screenGui
	screenGui.Enabled = false
end

local function showMobileInput()
	if not MobileInputGui then
		createMobileInputUI()
	end
	
	MobileInputGui.Enabled = true
	MobileButtonsFrame.Visible = true
	
	-- Set textbox to current line content
	if MobileTextBox then
		MobileTextBox.Text = Lines[CurrentLineIndex] or ""
		LastTextBoxValue = MobileTextBox.Text
		-- Focus to bring up keyboard
		task.delay(0.1, function()
			if IsEditing and MobileTextBox then
				MobileTextBox:CaptureFocus()
			end
		end)
	end
end

local function hideMobileInput()
	if MobileInputGui then
		MobileInputGui.Enabled = false
	end
	if MobileButtonsFrame then
		MobileButtonsFrame.Visible = false
	end
	if MobileTextBox then
		MobileTextBox:ReleaseFocus()
		MobileTextBox.Text = ""
	end
end

-- ============================================
-- EDITING FUNCTIONS
-- ============================================

local function openEditor(sign)
	if IsEditing then return false end
	if not sign then return false end
	
	-- Check if we own this sign
	local plotData = _G.PlotClient and _G.PlotClient.GetMyPlot()
	if not plotData or not plotData.BuildArea then return false end
	
	local blocksFolder = plotData.BuildArea:FindFirstChild("Blocks")
	if not blocksFolder or not sign:IsDescendantOf(blocksFolder) then
		return false
	end
	
	CurrentSign = sign
	IsEditing = true
	CurrentLineIndex = 1
	
	-- Load existing text
	for i = 1, MAX_LINES do
		local text = sign:GetAttribute("SignLine" .. i) or ""
		Lines[i] = text
		OriginalLines[i] = text
	end
	
	-- Freeze player
	local character = LocalPlayer.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
		end
	end
	
	-- Track when editing started (to prevent double-activation)
	EditStartTime = tick()
	
	-- Start camera control and cursor for both desktop and mobile
	startCameraControl()
	startCursorBlink()
	updateSignDisplay()
	
	-- Mobile: show input capture and buttons
	if IsMobile then
		showMobileInput()
	end
	
	return true
end

saveAndClose = function()
	if not IsEditing then return end
	
	-- Send to server
	if CurrentSign and UpdateSignText then
		UpdateSignText:FireServer(CurrentSign, Lines)
	end
	
	closeEditor()
end

closeEditor = function()
	if not IsEditing then return end
	
	IsEditing = false
	
	-- Hide mobile input
	if IsMobile then
		hideMobileInput()
	end
	
	-- Stop camera and cursor
	stopCameraControl()
	stopCursorBlink()
	
	-- Clear cursor from display
	updateSignDisplay()
	
	-- Restore player movement
	local character = LocalPlayer.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = 16
			humanoid.JumpPower = 50
		end
	end
	
	CurrentSign = nil
	Lines = {"", "", "", "", ""}
	OriginalLines = {"", "", "", "", ""}
end

cancelEdit = function()
	if not IsEditing then return end
	
	-- Restore original text on sign
	for i = 1, MAX_LINES do
		Lines[i] = OriginalLines[i]
	end
	updateSignDisplay()
	
	closeEditor()
end

-- ============================================
-- INPUT HANDLING (Desktop)
-- ============================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Handle right-click to save and close while editing (desktop)
	if IsEditing and input.UserInputType == Enum.UserInputType.MouseButton2 then
		-- Prevent double-activation: only close if at least 0.3 seconds have passed
		if tick() - EditStartTime > 0.3 then
			saveAndClose()
		end
		return
	end
	
	-- Mobile tap anywhere (except buttons) to save
	if IsEditing and IsMobile and input.UserInputType == Enum.UserInputType.Touch then
		-- Check if tap is outside the buttons area (bottom of screen)
		local screenSize = Camera.ViewportSize
		if input.Position.Y < screenSize.Y - 80 then
			-- Tapped above the buttons - just refocus the textbox
			if MobileTextBox then
				task.delay(0.05, function()
					if IsEditing and MobileTextBox then
						MobileTextBox:CaptureFocus()
					end
				end)
			end
		end
	end
	
	if not IsEditing then return end
	
	-- Desktop keyboard handling (mobile uses TextBox)
	if not IsMobile then
		-- Handle special keys even if gameProcessed
		if input.KeyCode == Enum.KeyCode.Escape then
			cancelEdit()
			return
		end
		
		if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
			handleEnter()
			return
		end
		
		if input.KeyCode == Enum.KeyCode.Backspace then
			handleBackspace()
			return
		end
		
		if input.KeyCode == Enum.KeyCode.Up then
			handleArrowUp()
			return
		end
		
		if input.KeyCode == Enum.KeyCode.Down then
			handleArrowDown()
			return
		end
		
		-- Handle text input (letters, numbers, symbols)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local keyCode = input.KeyCode
			local char = nil
			
			-- Check if shift is held
			local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			
			-- Letters A-Z
			if keyCode.Value >= Enum.KeyCode.A.Value and keyCode.Value <= Enum.KeyCode.Z.Value then
				local letterIndex = keyCode.Value - Enum.KeyCode.A.Value
				if shiftHeld then
					char = string.char(65 + letterIndex) -- Uppercase A-Z
				else
					char = string.char(97 + letterIndex) -- Lowercase a-z
				end
			-- Numbers 0-9 (top row)
			elseif keyCode.Value >= Enum.KeyCode.Zero.Value and keyCode.Value <= Enum.KeyCode.Nine.Value then
				local numIndex = keyCode.Value - Enum.KeyCode.Zero.Value
				if shiftHeld then
					-- Shift + number = symbols
					local symbols = {")" , "!", "@", "#", "$", "%", "^", "&", "*", "("}
					char = symbols[numIndex + 1]
				else
					char = tostring(numIndex)
				end
			-- Numpad 0-9
			elseif keyCode.Value >= Enum.KeyCode.KeypadZero.Value and keyCode.Value <= Enum.KeyCode.KeypadNine.Value then
				local numIndex = keyCode.Value - Enum.KeyCode.KeypadZero.Value
				char = tostring(numIndex)
			-- Space
			elseif keyCode == Enum.KeyCode.Space then
				char = " "
			-- Common punctuation
			elseif keyCode == Enum.KeyCode.Period then
				char = shiftHeld and ">" or "."
			elseif keyCode == Enum.KeyCode.Comma then
				char = shiftHeld and "<" or ","
			elseif keyCode == Enum.KeyCode.Slash then
				char = shiftHeld and "?" or "/"
			elseif keyCode == Enum.KeyCode.Semicolon then
				char = shiftHeld and ":" or ";"
			elseif keyCode == Enum.KeyCode.Quote then
				char = shiftHeld and '"' or "'"
			elseif keyCode == Enum.KeyCode.Minus then
				char = shiftHeld and "_" or "-"
			elseif keyCode == Enum.KeyCode.Equals then
				char = shiftHeld and "+" or "="
			elseif keyCode == Enum.KeyCode.LeftBracket then
				char = shiftHeld and "{" or "["
			elseif keyCode == Enum.KeyCode.RightBracket then
				char = shiftHeld and "}" or "]"
			elseif keyCode == Enum.KeyCode.BackSlash then
				char = shiftHeld and "|" or "\\"
			elseif keyCode == Enum.KeyCode.Backquote then
				char = shiftHeld and "~" or "`"
			end
			
			if char then
				handleTextInput(char)
			end
		end
	end
end)

-- ============================================
-- EXPOSE FOR OTHER SCRIPTS
-- ============================================

_G.SignEditController = {
	IsEditing = function()
		return IsEditing
	end,
	TryEditSign = function()
		print("[SignEdit] TryEditSign called, IsEditing=", IsEditing)
		if IsEditing then return false end
		
		local sign = raycastForSign()
		print("[SignEdit] Raycast result:", sign)
		if sign then
			local result = openEditor(sign)
			print("[SignEdit] openEditor returned:", result)
			return result
		end
		return false
	end,
	CloseEditor = closeEditor,
	SaveAndClose = saveAndClose,
}

print("SignEditController initialized (live sign editing - desktop & mobile)")
