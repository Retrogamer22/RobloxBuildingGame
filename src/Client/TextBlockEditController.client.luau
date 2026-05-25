--[[
	TextBlockEditController  (Client)
	------------------------------------------------------------------
	Live editing for TextBlocks. Right-click (desktop) or tap (mobile) a face
	of a text block you own -> camera swings to face it, a blinking caret
	appears, and you type directly on the block with live preview. The face
	you clicked is the one you edit (each face is independent).

	Save: right-click again / tap (desktop & mobile), or Enter.
	Cancel: Escape (desktop) or the X button (mobile) -> restores original.

	Modeled on SignEditController (same camera-control + cursor-blink + mobile
	hidden-TextBox approach). Exposed as _G.TextBlockEditController so
	BuildingController can call TryEditTextBlock() in its interaction chain.
]]

print("[TextBlockEdit] Script starting...")

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

local TextBlockPlacement = require(ReplicatedStorage:WaitForChild("TextBlockPlacement", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local UpdateTextBlockText = nil
task.spawn(function()
	UpdateTextBlockText = Remotes:WaitForChild("UpdateTextBlockText", 10)
	if not UpdateTextBlockText then
		warn("[TextBlockEdit] UpdateTextBlockText remote not found")
	end
end)

local REACH_DISTANCE = 50
local MAX_CHARS = 200
local CAMERA_DISTANCE = 6
local CAMERA_TWEEN_TIME = 0.5

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- State
local CurrentBlock = nil
local CurrentAnchor = nil  -- group anchor (owns the canvas + text), resolved on open
local CurrentFace = nil
local IsEditing = false
local Text = ""
local OriginalText = ""
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

-- Forward declarations
local saveAndClose
local closeEditor
local cancelEdit

-- ============================================
-- RAYCAST
-- ============================================

-- Returns block, face (the text block + which face was hit), or nil.
local function raycastForTextBlock()
	local vp = Camera.ViewportSize
	local ray = Camera:ViewportPointToRay(vp.X / 2, vp.Y / 2)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }

	local result = workspace:Raycast(ray.Origin, ray.Direction * REACH_DISTANCE, params)
	if not result or not result.Instance then return nil, nil end

	local hit = result.Instance
	-- Walk up to find the text block (the hit may be a part inside a model).
	local block = nil
	local cur = hit
	while cur and cur ~= workspace do
		if TextBlockPlacement.IsTextBlock(cur) then
			block = cur
			break
		end
		cur = cur.Parent
	end
	if not block then return nil, nil end

	local face = TextBlockPlacement.GetFaceFromNormal(result.Normal)
	return block, face
end

-- ============================================
-- CANVAS / DISPLAY
-- ============================================

-- Resolve the group anchor (and spanning geometry) for a block+face using a
-- client-side spatial index over the same Blocks folder the server uses.
local function resolveAnchor(block, face)
	local blocksFolder = block.Parent
	local index = blocksFolder and BlockSpatialIndex.GetOrCreate(blocksFolder) or nil
	local _, anchor, geometry = TextBlockPlacement.Resolve(block, face, blocksFolder, index)
	return anchor or block, geometry
end

-- Find the live SurfaceGui label for the face we're editing. The canvas lives
-- on the group ANCHOR (server-authoritative), so look there, not on the block
-- the player happened to click.
local function getFaceLabel()
	local owner = CurrentAnchor or CurrentBlock
	if not owner or not CurrentFace then return nil end
	local canvas = owner:FindFirstChild("TextBlockCanvas_" .. CurrentFace)
	if not canvas then return nil end
	local gui = canvas:FindFirstChild("TextBlockGui")
	if not gui then return nil end
	return gui:FindFirstChild("TextLabel")
end

local function updateDisplay()
	local label = getFaceLabel()
	if not label then return end
	if IsEditing then
		local caret = CursorVisible and "|" or ""
		label.Text = Text .. caret
	else
		label.Text = Text
	end
end

-- Geometry for camera framing (spans the whole merged group).
local function getCanvasCFrame()
	local owner = CurrentAnchor or CurrentBlock
	local _, geometry = resolveAnchor(owner, CurrentFace)
	if geometry then return geometry.cframe end
	local c = TextBlockPlacement.GetBlockCenter(owner)
	return CFrame.new(c)
end

-- ============================================
-- CAMERA CONTROL (mirrors SignEditController)
-- ============================================

local function startCameraControl()
	if CameraConnection then CameraConnection:Disconnect() end

	OriginalCameraCFrame = Camera.CFrame

	local canvasCFrame = getCanvasCFrame()
	-- Canvas Front faces outward (+LookVector), so sit the camera out in front.
	local outward = canvasCFrame.LookVector
	local canvasPos = canvasCFrame.Position
	local cameraPos = canvasPos + outward * CAMERA_DISTANCE
	TargetCameraCFrame = CFrame.lookAt(cameraPos, canvasPos)

	Camera.CameraType = Enum.CameraType.Scriptable

	local startCFrame = Camera.CFrame
	local elapsed = 0
	CameraConnection = RunService.RenderStepped:Connect(function(dt)
		if not IsEditing then return end
		if elapsed < CAMERA_TWEEN_TIME then
			elapsed = elapsed + dt
			local alpha = math.min(elapsed / CAMERA_TWEEN_TIME, 1)
			alpha = 1 - math.pow(1 - alpha, 3)
			Camera.CFrame = startCFrame:Lerp(TargetCameraCFrame, alpha)
		else
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
		local target = OriginalCameraCFrame
		local startCFrame = Camera.CFrame
		local elapsed = 0
		OriginalCameraCFrame = nil
		TargetCameraCFrame = nil
		local conn
		conn = RunService.RenderStepped:Connect(function(dt)
			elapsed = elapsed + dt
			local alpha = math.min(elapsed / CAMERA_TWEEN_TIME, 1)
			alpha = 1 - math.pow(1 - alpha, 3)
			Camera.CFrame = startCFrame:Lerp(target, alpha)
			if alpha >= 1 then
				conn:Disconnect()
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
	if CursorConnection then CursorConnection:Disconnect() end
	CursorBlinkTime = 0
	CursorVisible = true
	CursorConnection = RunService.Heartbeat:Connect(function(dt)
		if not IsEditing then return end
		CursorBlinkTime = CursorBlinkTime + dt
		if CursorBlinkTime >= 0.5 then
			CursorBlinkTime = 0
			CursorVisible = not CursorVisible
			updateDisplay()
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
-- TEXT EDITING
-- ============================================

-- Server creates the canvas only once text is non-empty. To give immediate
-- feedback on the first keystroke, push the text to the server right away so
-- the canvas appears, then keep live-previewing locally.
local function pushToServer()
	if CurrentAnchor and CurrentFace and UpdateTextBlockText then
		-- Send the anchor; the server re-resolves and writes to the group owner.
		UpdateTextBlockText:FireServer(CurrentAnchor, CurrentFace, Text)
	end
end

local function handleTextInput(ch)
	if not IsEditing then return end
	if #Text + #ch <= MAX_CHARS then
		Text = Text .. ch
		CursorVisible = true
		CursorBlinkTime = 0
		-- Ensure the canvas exists for live preview; cheap and debounced by
		-- the fact that input events are user-paced.
		if not getFaceLabel() then
			pushToServer()
			task.delay(0.05, updateDisplay)
		else
			updateDisplay()
		end
	end
end

local function handleBackspace()
	if not IsEditing then return end
	if #Text > 0 then
		Text = string.sub(Text, 1, -2)
		CursorVisible = true
		CursorBlinkTime = 0
		updateDisplay()
	end
end

local function handleEnter()
	if not IsEditing then return end
	-- Manual line break (the label wraps anyway, but allow explicit breaks).
	if #Text + 1 <= MAX_CHARS then
		Text = Text .. "\n"
		CursorVisible = true
		CursorBlinkTime = 0
		updateDisplay()
	end
end

-- ============================================
-- MOBILE INPUT (mirrors SignEditController)
-- ============================================

local function createMobileInputUI()
	if MobileInputGui then return end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "MobileTextBlockInputUI"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 100
	screenGui.Parent = PlayerGui

	local textBox = Instance.new("TextBox")
	textBox.Name = "HiddenInput"
	textBox.Position = UDim2.new(0.5, -100, 0, -50)
	textBox.Size = UDim2.new(0, 200, 0, 40)
	textBox.BackgroundTransparency = 1
	textBox.TextTransparency = 1
	textBox.Text = ""
	textBox.ClearTextOnFocus = false
	textBox.MultiLine = true
	textBox.Parent = screenGui

	textBox:GetPropertyChangedSignal("Text"):Connect(function()
		if not IsEditing then return end
		local newText = textBox.Text
		if #newText > MAX_CHARS then
			newText = string.sub(newText, 1, MAX_CHARS)
			textBox.Text = newText
		end
		Text = newText
		CursorVisible = true
		CursorBlinkTime = 0
		if not getFaceLabel() then
			pushToServer()
			task.delay(0.05, updateDisplay)
		else
			updateDisplay()
		end
	end)

	MobileTextBox = textBox

	local buttonsFrame = Instance.new("Frame")
	buttonsFrame.Name = "EditButtons"
	buttonsFrame.AnchorPoint = Vector2.new(0.5, 1)
	buttonsFrame.Position = UDim2.new(0.5, 0, 1, -20)
	buttonsFrame.Size = UDim2.new(0, 150, 0, 44)
	buttonsFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	buttonsFrame.BackgroundTransparency = 0.3
	buttonsFrame.BorderSizePixel = 0
	buttonsFrame.Visible = false
	buttonsFrame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = buttonsFrame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 10)
	layout.Parent = buttonsFrame

	local cancelBtn = Instance.new("TextButton")
	cancelBtn.Name = "CancelBtn"
	cancelBtn.Size = UDim2.new(0, 60, 0, 36)
	cancelBtn.BackgroundColor3 = Color3.fromRGB(140, 60, 60)
	cancelBtn.Text = "X"
	cancelBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	cancelBtn.TextSize = 20
	cancelBtn.Font = Enum.Font.GothamBold
	cancelBtn.Parent = buttonsFrame
	local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, 6); cc.Parent = cancelBtn
	cancelBtn.MouseButton1Click:Connect(function() cancelEdit() end)

	local saveBtn = Instance.new("TextButton")
	saveBtn.Name = "SaveBtn"
	saveBtn.Size = UDim2.new(0, 60, 0, 36)
	saveBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 60)
	saveBtn.Text = "✓"
	saveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	saveBtn.TextSize = 20
	saveBtn.Font = Enum.Font.GothamBold
	saveBtn.Parent = buttonsFrame
	local sc = Instance.new("UICorner"); sc.CornerRadius = UDim.new(0, 6); sc.Parent = saveBtn
	saveBtn.MouseButton1Click:Connect(function() saveAndClose() end)

	MobileButtonsFrame = buttonsFrame
	MobileInputGui = screenGui
	screenGui.Enabled = false
end

local function showMobileInput()
	if not MobileInputGui then createMobileInputUI() end
	MobileInputGui.Enabled = true
	MobileButtonsFrame.Visible = true
	if MobileTextBox then
		MobileTextBox.Text = Text
		task.delay(0.1, function()
			if IsEditing and MobileTextBox then
				MobileTextBox:CaptureFocus()
			end
		end)
	end
end

local function hideMobileInput()
	if MobileInputGui then MobileInputGui.Enabled = false end
	if MobileButtonsFrame then MobileButtonsFrame.Visible = false end
	if MobileTextBox then
		MobileTextBox:ReleaseFocus()
		MobileTextBox.Text = ""
	end
end

-- ============================================
-- OPEN / SAVE / CLOSE
-- ============================================

local function openEditor(block, face)
	if IsEditing then return false end
	if not block or not face then return false end

	-- Must own the block (it must be in our plot's Blocks folder).
	local plotData = _G.PlotClient and _G.PlotClient.GetMyPlot()
	if not plotData or not plotData.BuildArea then return false end
	local blocksFolder = plotData.BuildArea:FindFirstChild("Blocks")
	if not blocksFolder or not block:IsDescendantOf(blocksFolder) then
		return false
	end

	CurrentBlock = block
	CurrentFace = face
	-- Resolve the group anchor: it owns the canvas + text for this face.
	CurrentAnchor = resolveAnchor(block, face)
	IsEditing = true

	Text = CurrentAnchor:GetAttribute("TBText_" .. face) or ""
	OriginalText = Text

	-- Freeze player.
	local character = LocalPlayer.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
		end
	end

	EditStartTime = tick()

	startCameraControl()
	startCursorBlink()
	updateDisplay()

	if IsMobile then
		showMobileInput()
	end

	return true
end

saveAndClose = function()
	if not IsEditing then return end
	pushToServer()
	closeEditor()
end

closeEditor = function()
	if not IsEditing then return end
	IsEditing = false

	if IsMobile then
		hideMobileInput()
	end

	stopCameraControl()
	stopCursorBlink()
	updateDisplay()  -- clears caret

	local character = LocalPlayer.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = 16
			humanoid.JumpPower = 50
		end
	end

	CurrentBlock = nil
	CurrentAnchor = nil
	CurrentFace = nil
	Text = ""
	OriginalText = ""
end

cancelEdit = function()
	if not IsEditing then return end
	Text = OriginalText
	-- Push the original back so the live-preview canvas reverts on screen.
	pushToServer()
	updateDisplay()
	closeEditor()
end

-- ============================================
-- DESKTOP INPUT
-- ============================================

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Right-click while editing = save & close (desktop).
	if IsEditing and input.UserInputType == Enum.UserInputType.MouseButton2 then
		if tick() - EditStartTime > 0.3 then
			saveAndClose()
		end
		return
	end

	if not IsEditing then return end
	if IsMobile then return end  -- mobile uses the TextBox

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

	if input.UserInputType == Enum.UserInputType.Keyboard then
		local keyCode = input.KeyCode
		local char = nil
		local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)

		if keyCode.Value >= Enum.KeyCode.A.Value and keyCode.Value <= Enum.KeyCode.Z.Value then
			local i = keyCode.Value - Enum.KeyCode.A.Value
			char = shiftHeld and string.char(65 + i) or string.char(97 + i)
		elseif keyCode.Value >= Enum.KeyCode.Zero.Value and keyCode.Value <= Enum.KeyCode.Nine.Value then
			local i = keyCode.Value - Enum.KeyCode.Zero.Value
			if shiftHeld then
				local symbols = {")", "!", "@", "#", "$", "%", "^", "&", "*", "("}
				char = symbols[i + 1]
			else
				char = tostring(i)
			end
		elseif keyCode.Value >= Enum.KeyCode.KeypadZero.Value and keyCode.Value <= Enum.KeyCode.KeypadNine.Value then
			char = tostring(keyCode.Value - Enum.KeyCode.KeypadZero.Value)
		elseif keyCode == Enum.KeyCode.Space then
			char = " "
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
end)

-- ============================================
-- EXPOSE
-- ============================================

_G.TextBlockEditController = {
	IsEditing = function()
		return IsEditing
	end,
	TryEditTextBlock = function()
		if IsEditing then return false end
		local block, face = raycastForTextBlock()
		if block and face then
			return openEditor(block, face)
		end
		return false
	end,
	CloseEditor = closeEditor,
	SaveAndClose = saveAndClose,
}

print("TextBlockEditController initialized (live per-face text editing - desktop & mobile)")
