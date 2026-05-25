-- AvatarScaler.server.luau
-- Scales player avatars by 1.7x on spawn

local Players = game:GetService("Players")

local SCALE_MULTIPLIER = 1.25

local function scaleCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid then return end
	
	-- Scale the humanoid description values
	local bodyDepthScale = humanoid:FindFirstChild("BodyDepthScale")
	local bodyWidthScale = humanoid:FindFirstChild("BodyWidthScale")
	local bodyHeightScale = humanoid:FindFirstChild("BodyHeightScale")
	local headScale = humanoid:FindFirstChild("HeadScale")
	
	if bodyDepthScale then
		bodyDepthScale.Value *= SCALE_MULTIPLIER
	end
	
	if bodyWidthScale then
		bodyWidthScale.Value *= SCALE_MULTIPLIER
	end
	
	if bodyHeightScale then
		bodyHeightScale.Value *= SCALE_MULTIPLIER
	end
	
	if headScale then
		headScale.Value *= SCALE_MULTIPLIER
	end
end

local function onPlayerAdded(player: Player)
	-- Scale when character first loads
	player.CharacterAdded:Connect(function(character)
		scaleCharacter(character)
	end)
	
	-- Scale if character already exists
	if player.Character then
		scaleCharacter(player.Character)
	end
end

-- Connect to existing and future players
Players.PlayerAdded:Connect(onPlayerAdded)

for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
