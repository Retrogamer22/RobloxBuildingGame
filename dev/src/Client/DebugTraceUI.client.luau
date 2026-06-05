--[[
	DebugTraceUI (client)
	-----------------------------------------------------------------------------
	Owner-only on-screen control for the DebugTrace system.

	What it shows (ONLY for the owner — the server tells us via DebugTraceStatus):
		- A small "🐞 TRACE" toggle button, bottom-right.
		- A log panel that fills with the server's trace lines in real time.
		- A "Copy" button: selects all log text into a TextBox so you can
		  Ctrl+A / Ctrl+C it straight out of the game (works on PC; on mobile,
		  long-press to select). This is the "copy logs to work it out" path.
		- A "Clear" button to wipe the panel between attempts.

	The button only ever appears for the owner. Non-owner clients build no UI.

	Styling follows BuildBlox conventions: blocky stone-grey palette, GothamBold,
	opaque bevels via raised/inset edges. No transparency on panels.
	-----------------------------------------------------------------------------
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ToggleDebugTrace = Remotes:WaitForChild("ToggleDebugTrace")
local DebugTraceLine = Remotes:WaitForChild("DebugTraceLine")
local DebugTraceStatus = Remotes:WaitForChild("DebugTraceStatus")

----------------------------------------------------------------
-- Palette (matches BuildBlox stone-grey UI)
----------------------------------------------------------------
local C = {
	panel = Color3.fromRGB(58, 58, 64),
	panelDark = Color3.fromRGB(38, 38, 42),
	bevelLight = Color3.fromRGB(96, 96, 104),
	bevelDark = Color3.fromRGB(24, 24, 28),
	text = Color3.fromRGB(235, 235, 235),
	accentOn = Color3.fromRGB(96, 200, 110), -- green when tracing
	accentOff = Color3.fromRGB(150, 150, 158),
	logBg = Color3.fromRGB(18, 18, 20),
	logText = Color3.fromRGB(210, 230, 210),
	reject = Color3.fromRGB(255, 120, 110),
}

local MAX_LINES = 400 -- ring-buffer cap so the panel never grows unbounded

----------------------------------------------------------------
-- Small bevel helpers (raised look) — opaque, no transparency.
----------------------------------------------------------------
local function addBevel(frame)
	local top = Instance.new("Frame")
	top.BorderSizePixel = 0
	top.BackgroundColor3 = C.bevelLight
	top.Size = UDim2.new(1, 0, 0, 2)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.ZIndex = frame.ZIndex + 1
	top.Parent = frame

	local left = Instance.new("Frame")
	left.BorderSizePixel = 0
	left.BackgroundColor3 = C.bevelLight
	left.Size = UDim2.new(0, 2, 1, 0)
	left.ZIndex = frame.ZIndex + 1
	left.Parent = frame

	local bottom = Instance.new("Frame")
	bottom.BorderSizePixel = 0
	bottom.BackgroundColor3 = C.bevelDark
	bottom.Size = UDim2.new(1, 0, 0, 2)
	bottom.Position = UDim2.new(0, 0, 1, -2)
	bottom.ZIndex = frame.ZIndex + 1
	bottom.Parent = frame

	local right = Instance.new("Frame")
	right.BorderSizePixel = 0
	right.BackgroundColor3 = C.bevelDark
	right.Size = UDim2.new(0, 2, 1, 0)
	right.Position = UDim2.new(1, -2, 0, 0)
	right.ZIndex = frame.ZIndex + 1
	right.Parent = frame
end

----------------------------------------------------------------
-- Build the UI (only called for the owner)
----------------------------------------------------------------
local built = false
local isTracing = false
local lineCount = 0
local rawLog = {} -- plain strings, for the copy box

local screenGui, toggleBtn, panel, logFrame, logLayout, copyBox
local doToggle -- forward declaration; defined in buildUI (needs panel/addLine)

local function setToggleVisual()
	if not toggleBtn then return end
	toggleBtn.Text = isTracing and "🐞 TRACE: ON" or "🐞 TRACE: OFF"
	toggleBtn.BackgroundColor3 = isTracing and C.accentOn or C.accentOff
end

local function rebuildCopyBox()
	if not copyBox then return end
	copyBox.Text = table.concat(rawLog, "\n")
end

local function addLine(line)
	-- ring-buffer the raw text
	table.insert(rawLog, line)
	if #rawLog > MAX_LINES then
		table.remove(rawLog, 1)
	end

	-- visual label
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.new(1, -8, 0, 16)
	lbl.AutomaticSize = Enum.AutomaticSize.Y
	lbl.Font = Enum.Font.Code
	lbl.TextSize = 13
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextWrapped = true
	lbl.Text = line
	lbl.TextColor3 = string.find(line, "REJECT", 1, true) and C.reject or C.logText
	lbl.LayoutOrder = lineCount
	lbl.ZIndex = 51
	lbl.Parent = logFrame

	lineCount += 1

	-- prune oldest visual labels to match the buffer
	if lineCount > MAX_LINES then
		for _, child in ipairs(logFrame:GetChildren()) do
			if child:IsA("TextLabel") and child.LayoutOrder <= (lineCount - MAX_LINES) then
				child:Destroy()
			end
		end
	end

	-- auto-scroll to bottom
	task.defer(function()
		if logFrame and logFrame.Parent then
			logFrame.CanvasPosition = Vector2.new(0, logFrame.AbsoluteCanvasSize.Y)
		end
	end)
end

local function buildUI()
	if built then return end
	built = true

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugTraceUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 180 -- above gameplay HUD, below daily-rewards spotlight (200)
	screenGui.Parent = playerGui

	-- Toggle button (bottom-right)
	toggleBtn = Instance.new("TextButton")
	toggleBtn.Name = "ToggleButton"
	toggleBtn.Size = UDim2.new(0, 150, 0, 34)
	toggleBtn.Position = UDim2.new(1, -160, 1, -44)
	toggleBtn.BorderSizePixel = 0
	toggleBtn.Font = Enum.Font.GothamBold
	toggleBtn.TextSize = 14
	toggleBtn.TextColor3 = Color3.fromRGB(20, 20, 20)
	toggleBtn.AutoButtonColor = true
	toggleBtn.ZIndex = 50
	toggleBtn.Parent = screenGui
	addBevel(toggleBtn)
	setToggleVisual()

	-- Log panel (hidden until first opened)
	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, 520, 0, 320)
	panel.Position = UDim2.new(1, -530, 1, -390)
	panel.BackgroundColor3 = C.panel
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 50
	panel.Parent = screenGui
	addBevel(panel)

	-- Title bar
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -8, 0, 22)
	title.Position = UDim2.new(0, 4, 0, 4)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextColor3 = C.text
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "BuildBlox Trace  —  do an action to capture its decision path"
	title.ZIndex = 52
	title.Parent = panel

	-- Buttons row (Copy / Clear / Hide)
	local function mkSmallBtn(txt, xOff)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, 70, 0, 22)
		b.Position = UDim2.new(1, xOff, 0, 4)
		b.BackgroundColor3 = C.panelDark
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.TextColor3 = C.text
		b.Text = txt
		b.ZIndex = 52
		b.Parent = panel
		addBevel(b)
		return b
	end
	local copyBtn = mkSmallBtn("Copy", -226)
	local clearBtn = mkSmallBtn("Clear", -150)
	local hideBtn = mkSmallBtn("Hide", -74)

	-- Scrolling log area
	logFrame = Instance.new("ScrollingFrame")
	logFrame.Name = "Log"
	logFrame.Size = UDim2.new(1, -12, 1, -62)
	logFrame.Position = UDim2.new(0, 6, 0, 32)
	logFrame.BackgroundColor3 = C.logBg
	logFrame.BorderSizePixel = 0
	logFrame.ScrollBarThickness = 8
	logFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	logFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	logFrame.ZIndex = 51
	logFrame.Parent = panel

	logLayout = Instance.new("UIListLayout")
	logLayout.SortOrder = Enum.SortOrder.LayoutOrder
	logLayout.Padding = UDim.new(0, 1)
	logLayout.Parent = logFrame

	local logPad = Instance.new("UIPadding")
	logPad.PaddingLeft = UDim.new(0, 4)
	logPad.PaddingTop = UDim.new(0, 2)
	logPad.Parent = logFrame

	-- Hidden TextBox used purely as a copy buffer.
	copyBox = Instance.new("TextBox")
	copyBox.Name = "CopyBuffer"
	copyBox.Size = UDim2.new(1, -12, 0, 22)
	copyBox.Position = UDim2.new(0, 6, 1, -28)
	copyBox.BackgroundColor3 = C.panelDark
	copyBox.BorderSizePixel = 0
	copyBox.Font = Enum.Font.Code
	copyBox.TextSize = 12
	copyBox.TextColor3 = C.text
	copyBox.TextXAlignment = Enum.TextXAlignment.Left
	copyBox.ClearTextOnFocus = false
	copyBox.TextEditable = true
	copyBox.MultiLine = true
	copyBox.Text = ""
	copyBox.PlaceholderText = "Press Copy, then Ctrl+A, Ctrl+C (long-press to select on mobile)"
	copyBox.ZIndex = 52
	copyBox.Parent = panel

	-- Behaviour
	-- Shared toggle logic used by BOTH the button and the Ctrl+T hotkey.
	-- Server is authoritative; we reflect whatever state it returns.
	doToggle = function()
		local ok, result = pcall(function()
			return ToggleDebugTrace:InvokeServer("toggle")
		end)
		if not ok then
			return
		end
		isTracing = result and true or false
		setToggleVisual()
		if isTracing then
			panel.Visible = true
			addLine("[BB-TRACE] tracing ENABLED — perform the action now.")
		else
			-- Tracing off: hide the panel along with it.
			panel.Visible = false
		end
	end

	toggleBtn.MouseButton1Click:Connect(function()
		doToggle()
	end)

	copyBtn.MouseButton1Click:Connect(function()
		rebuildCopyBox()
		copyBox:CaptureFocus()
		-- Select-all so the user can immediately Ctrl+C.
		task.defer(function()
			pcall(function()
				copyBox.SelectionStart = 1
				copyBox.CursorPosition = #copyBox.Text + 1
			end)
		end)
	end)

	clearBtn.MouseButton1Click:Connect(function()
		rawLog = {}
		lineCount = 0
		for _, child in ipairs(logFrame:GetChildren()) do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		copyBox.Text = ""
	end)

	hideBtn.MouseButton1Click:Connect(function()
		panel.Visible = false
	end)

	-- Re-show panel when toggling on; also long-press / right side reopen:
	-- double-clicking the toggle button reopens a hidden panel.
	toggleBtn.MouseButton2Click:Connect(function()
		panel.Visible = not panel.Visible
	end)
end

----------------------------------------------------------------
-- Wire incoming events
----------------------------------------------------------------

DebugTraceStatus.OnClientEvent:Connect(function(status)
	if not status or not status.isOwner then
		return -- non-owner: never build anything
	end
	if not built then
		buildUI()
	end
	isTracing = status.enabled and true or false
	setToggleVisual()
end)

DebugTraceLine.OnClientEvent:Connect(function(line)
	if not built then
		-- A line arrived before status (rare ordering): we only get lines if
		-- the server is tracing us, which only happens for the owner, so build.
		buildUI()
	end
	if panel and not panel.Visible then
		panel.Visible = true
	end
	addLine(line)
end)

----------------------------------------------------------------
-- Hotkey: Ctrl+T toggles tracing (mirrors the on-screen button).
-- Only does anything once the UI exists, which only happens for the owner.
----------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Ignore when the keystroke was consumed by a focused TextBox (e.g. the
	-- copy buffer) so toggling never fires while you're selecting/typing.
	if gameProcessed then
		return
	end
	if input.KeyCode ~= Enum.KeyCode.T then
		return
	end
	local ctrlHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	if not ctrlHeld then
		return
	end
	if built and doToggle then
		doToggle()
	end
end)
