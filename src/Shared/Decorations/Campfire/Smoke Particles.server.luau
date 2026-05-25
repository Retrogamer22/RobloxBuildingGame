-- CampfireSmoke.server.lua
-- Place inside the Campfire model
-- This simply tags the campfire so the SmokeManager picks it up

local CollectionService = game:GetService("CollectionService")

local Campfire = script.Parent

-- Tag this campfire so the central SmokeManager handles it
CollectionService:AddTag(Campfire, "Campfire")

-- Clean up tag when campfire is destroyed
Campfire.Destroying:Connect(function()
	CollectionService:RemoveTag(Campfire, "Campfire")
end)