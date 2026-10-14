--!strict
--[[
	Visuals.World.Ambience
	======================
	Positional ambient soundscapes and environmental audio for Sol's Sanctuary.
]]

local Ambience = {}

local SOUNDS = {
	IslandWind = "rbxasset://sounds/action_falling.mp3",
	WaterSplash = "rbxasset://sounds/water_splash.wav",
	CelestialDrone = "rbxassetid://9114223598",
}

function Ambience.CreatePositionalSound(parent: BasePart, soundId: string, volume: number, maxDist: number): Sound
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.Looped = true
	sound.RollOffMaxDistance = maxDist
	sound.RollOffMinDistance = 6
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.Parent = parent
	sound:Play()
	return sound
end

function Ambience.AttachWorldAudio(worldRoot: Folder): ()
	-- Altar Celestial Hum
	local monolith = worldRoot:FindFirstChild("HoveringMonolith", true)
	if monolith ~= nil and monolith:IsA("BasePart") then
		Ambience.CreatePositionalSound(monolith :: BasePart, SOUNDS.CelestialDrone, 0.35, 45)
	end

	-- Cauldron Mystic Bubbling
	local cauldron = worldRoot:FindFirstChild("CauldronLiquid", true)
	if cauldron ~= nil and cauldron:IsA("BasePart") then
		Ambience.CreatePositionalSound(cauldron :: BasePart, SOUNDS.WaterSplash, 0.3, 30)
	end

	-- Astral Waterfall Rush
	local waterfall = worldRoot:FindFirstChild("WaterfallStream", true)
	if waterfall ~= nil and waterfall:IsA("BasePart") then
		local fallSound = Ambience.CreatePositionalSound(waterfall :: BasePart, SOUNDS.WaterSplash, 0.25, 55)
		fallSound.PlaybackSpeed = 0.75
	end

	-- Stargazer's Spire High-Altitude Breeze
	local astrolabe = worldRoot:FindFirstChild("AstrolabeCore", true)
	if astrolabe ~= nil and astrolabe:IsA("BasePart") then
		local windSound = Ambience.CreatePositionalSound(astrolabe :: BasePart, SOUNDS.IslandWind, 0.2, 50)
		windSound.PlaybackSpeed = 0.65
	end
end

return Ambience
