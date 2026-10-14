--!strict
--[[
	Visuals.Audio
	=============
	Comprehensive audio engine for the RNG Aura Collector inspired by Sol's RNG.
	Supports dynamic roll roulette ticking, tier-specific fanfare reveals, sub-bass
	impacts, and ambient aura looping soundscapes.
]]

local SoundService = game:GetService("SoundService")

export type SoundProfile = "Common" | "Rare" | "Epic" | "Legendary" | "Mythic" | "Divine" | "Singularity"

local Audio = {}

-- Curated Roblox library and engine audio asset IDs
local SOUND_LIBRARY = {
	RollTick = "rbxasset://sounds/uiclick.wav",
	EquipShimmer = "rbxassetid://9114223598",

	-- Reveal Profiles
	CommonPop = "rbxassetid://9114223177",
	RareChime = "rbxassetid://9114221580",
	EpicSwell = "rbxassetid://9114222019",
	LegendaryFanfare = "rbxassetid://9114222019",
	MythicChoir = "rbxassetid://9114222019",
	DivineShatter = "rbxassetid://9114222383",
	SingularityCollapse = "rbxassetid://9114222383",

	-- Sub Bass Impacts
	BassDropLight = "rbxassetid://9114222383",
	BassDropHeavy = "rbxassetid://9114222383",
}

local function playOneShot(soundId: string, volume: number, playbackSpeed: number?): ()
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = playbackSpeed or 1.0
	sound.RollOffMaxDistance = 150
	sound.Parent = SoundService

	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
end

-- Rapid roulette tick during roll animation
function Audio.PlayRollTick(pitchMod: number?): ()
	local speed = 0.95 + (math.random() * 0.25 - 0.12) + (pitchMod or 0)
	playOneShot(SOUND_LIBRARY.RollTick, 0.35, speed)
end

-- Plays an aura reveal sound based on its sound profile or rarity
function Audio.PlayRollReveal(profile: SoundProfile, rarity: number): ()
	if profile == "Singularity" or rarity >= 15000000 then
		playOneShot(SOUND_LIBRARY.SingularityCollapse, 1.0, 0.75)
		playOneShot(SOUND_LIBRARY.DivineShatter, 0.9, 1.0)
		playOneShot(SOUND_LIBRARY.LegendaryFanfare, 0.8, 0.9)
	elseif profile == "Divine" or rarity >= 1000000 then
		playOneShot(SOUND_LIBRARY.DivineShatter, 0.9, 0.9)
		playOneShot(SOUND_LIBRARY.LegendaryFanfare, 0.85, 1.0)
		playOneShot(SOUND_LIBRARY.BassDropHeavy, 0.75, 0.95)
	elseif profile == "Mythic" or rarity >= 10000 then
		playOneShot(SOUND_LIBRARY.MythicChoir, 0.85, 1.05)
		playOneShot(SOUND_LIBRARY.BassDropHeavy, 0.7, 1.0)
	elseif profile == "Legendary" or rarity >= 1000 then
		playOneShot(SOUND_LIBRARY.LegendaryFanfare, 0.8, 1.1)
		playOneShot(SOUND_LIBRARY.BassDropLight, 0.5, 1.1)
	elseif profile == "Epic" or rarity >= 300 then
		playOneShot(SOUND_LIBRARY.EpicSwell, 0.65, 1.15)
	elseif profile == "Rare" or rarity >= 50 then
		playOneShot(SOUND_LIBRARY.RareChime, 0.55, 1.2)
	else
		playOneShot(SOUND_LIBRARY.CommonPop, 0.45, 1.0)
	end
end

-- Sound played when an aura is equipped
function Audio.PlayEquipSound(): ()
	playOneShot(SOUND_LIBRARY.EquipShimmer, 0.65, 1.0)
end

return Audio
