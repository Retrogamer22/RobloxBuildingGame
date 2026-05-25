-- Script inside the Fire part
-- Animates through campfire frames at 0.1s intervals on both sides

local part = script.Parent
local surfaceGuiFront = part:WaitForChild("SurfaceGuiFront")
local surfaceGuiBack = part:WaitForChild("SurfaceGuiBack")
local imageLabelFront = surfaceGuiFront:WaitForChild("ImageLabel")
local imageLabelBack = surfaceGuiBack:WaitForChild("ImageLabel")

-- Your campfire frame asset IDs
local frames = {
	"rbxassetid://104477729534662", -- Frame 1
	"rbxassetid://140652547151411", -- Frame 2
	"rbxassetid://103383594087156", -- Frame 3
	"rbxassetid://87303781883558",  -- Frame 4
	"rbxassetid://96241542227380",  -- Frame 5
	"rbxassetid://108394388696766", -- Frame 6
	"rbxassetid://96720916046645",  -- Frame 7
	"rbxassetid://89249481377584",  -- Frame 8
	"rbxassetid://75644616473701",  -- Frame 9
	"rbxassetid://113861573469546", -- Frame 10
	"rbxassetid://114154707733329", -- Frame 11
	"rbxassetid://115376306601555", -- Frame 12
	"rbxassetid://105562044039834", -- Frame 13
	"rbxassetid://124080693162472", -- Frame 14
	"rbxassetid://98128562930475",  -- Frame 15
	"rbxassetid://118749462886422", -- Frame 16
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