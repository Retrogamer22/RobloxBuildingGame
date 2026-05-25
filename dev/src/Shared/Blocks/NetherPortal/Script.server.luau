local portalPart = script.Parent
local framesFolder = portalPart:WaitForChild("PortalFrames")

local FRAME_DELAY = 0.1
local FRAME_COUNT = 16

local frames = {}

for i = 1, FRAME_COUNT do
	local frameName = string.format("Frame%02d", i)
	local appearance = framesFolder:WaitForChild(frameName)

	if not appearance:IsA("SurfaceAppearance") then
		error(frameName .. " is not a SurfaceAppearance")
	end

	frames[i] = appearance
end

-- Put any direct SurfaceAppearance back into storage first
for _, child in ipairs(portalPart:GetChildren()) do
	if child:IsA("SurfaceAppearance") then
		child.Parent = framesFolder
	end
end

local currentIndex = 1
local currentAppearance = frames[currentIndex]
currentAppearance.Parent = portalPart

while true do
	task.wait(FRAME_DELAY)

	currentAppearance.Parent = framesFolder

	currentIndex += 1
	if currentIndex > FRAME_COUNT then
		currentIndex = 1
	end

	currentAppearance = frames[currentIndex]
	currentAppearance.Parent = portalPart
end