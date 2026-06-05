-- Script inside the Fire part
-- Animates through blue campfire frames at 0.075s intervals on both sides
local part = script.Parent
local surfaceGuiFront = part:WaitForChild("SurfaceGuiFront")
local surfaceGuiBack = part:WaitForChild("SurfaceGuiBack")
local imageLabelFront = surfaceGuiFront:WaitForChild("ImageLabel")
local imageLabelBack = surfaceGuiBack:WaitForChild("ImageLabel")
-- Blue flame frame asset IDs
local frames = {
	"rbxassetid://77193345658148",  -- Frame 1
	"rbxassetid://125184680289078", -- Frame 2
	"rbxassetid://140560572269754", -- Frame 3
	"rbxassetid://119127371560568", -- Frame 4
	"rbxassetid://133831441880943", -- Frame 5
	"rbxassetid://109716954175774", -- Frame 6
	"rbxassetid://91749741101346",  -- Frame 7
	"rbxassetid://88160488632590",  -- Frame 8
	"rbxassetid://72577262739059",  -- Frame 9
	"rbxassetid://114985659809573", -- Frame 10
	"rbxassetid://100341458913243", -- Frame 11
	"rbxassetid://94167663219774",  -- Frame 12
	"rbxassetid://96887804179926",  -- Frame 13
	"rbxassetid://96273160412254",  -- Frame 14
	"rbxassetid://84804211318014",  -- Frame 15
	"rbxassetid://72982121865843",  -- Frame 16
}
local frameDelay = 0.075
local currentFrame = 1
-- Start animation loop
while true do
	local frameImage = frames[currentFrame]
	imageLabelFront.Image = frameImage
	imageLabelBack.Image = frameImage
	currentFrame = currentFrame % #frames + 1
	task.wait(frameDelay)
end