-- Script inside the Fire part
-- Animates through campfire frames at 0.1s intervals on both sides

local part = script.Parent
local surfaceGuiFront = part:WaitForChild("SurfaceGuiFront")
local surfaceGuiBack = part:WaitForChild("SurfaceGuiBack")
local imageLabelFront = surfaceGuiFront:WaitForChild("ImageLabel")
local imageLabelBack = surfaceGuiBack:WaitForChild("ImageLabel")

-- Your campfire frame asset IDs
local frames = {
	"rbxassetid://114094651164808", -- Frame 1
	"rbxassetid://110918754975698", -- Frame 2
	"rbxassetid://125341592401119", -- Frame 3
	"rbxassetid://119217217400726", -- Frame 4
	"rbxassetid://85429254526302",  -- Frame 5
	"rbxassetid://101598123574840", -- Frame 6
	"rbxassetid://132296469655012", -- Frame 7
	"rbxassetid://118107038309141", -- Frame 8
}

local frameDelay = 0.1
local currentFrame = 1

-- Start animation loop
while true do
	local frameImage = frames[currentFrame]
	imageLabelFront.Image = frameImage
	imageLabelBack.Image = frameImage

	currentFrame = currentFrame % #frames + 1
	task.wait(frameDelay)
end