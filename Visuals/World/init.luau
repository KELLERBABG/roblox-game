--!strict
--[[
	Visuals.World
	=============
	Comprehensive procedural world generator and atmospheric environmental engine
	inspired by Sol's RNG.
	Generates:
	  * Floating Celestial Island ("The Celestial Sanctuary")
	  * Central Sacred Roll Altar with 4 Olympian Pillars
	  * Stargazer's Spire with rotating Armillary Sphere
	  * Mystic Grotto with crystal geodes and Alchemist's Cauldron (+0.5x Luck)
	  * Floating Stepping Stones Obby to Peak of Fortune (+1.0x Luck)
	  * Bioluminescent Sakura Trees, stone lanterns, and crystal clusters
	  * Cosmic midnight skybox, atmospheric haze, bloom, and shooting stars
]]

local Workspace = game:GetService("Workspace")

local Builder = require(script:WaitForChild("Builder") :: ModuleScript)
local Foliage = require(script:WaitForChild("Foliage") :: ModuleScript)
local Atmosphere = require(script:WaitForChild("Atmosphere") :: ModuleScript)
local Interactive = require(script:WaitForChild("Interactive") :: ModuleScript)
local Ambience = require(script:WaitForChild("Ambience") :: ModuleScript)

local World = {}

World.Builder = Builder
World.Foliage = Foliage
World.Atmosphere = Atmosphere
World.Interactive = Interactive
World.Ambience = Ambience

local cachedWorldRoot: Folder? = nil

-- Builds the entire physical floating world into targetParent (defaults to Workspace)
function World.Build(targetParent: Instance?): Folder
	local parent = targetParent or Workspace

	local existing = parent:FindFirstChild("SolSanctuary")
	if existing ~= nil and existing:IsA("Folder") then
		cachedWorldRoot = existing :: Folder
		return existing :: Folder
	end

	-- 1. Physical Island Geometry, Altar, Spire, Grotto, Obby, Spawn
	local worldRoot = Builder.Build(parent)

	-- 2. Procedural Sakura Trees, Lanterns, and Crystal Flora
	Foliage.PopulateSanctuary(worldRoot)

	-- 3. Interactive Shrines (Cauldron & Obby Luck Buffs)
	Interactive.WireTriggers(worldRoot)

	-- 4. 3D Positional Ambient Soundscapes
	Ambience.AttachWorldAudio(worldRoot)

	cachedWorldRoot = worldRoot
	return worldRoot
end

-- Initializes client-side environmental lighting, shooting stars, and atmospheric haze
function World.StartClientAmbience(): ()
	Atmosphere.ApplyLighting()
	Atmosphere.StartShootingStarCycle()
end

-- Idempotent check and build
function World.EnsureWorld(): Folder
	if cachedWorldRoot ~= nil and cachedWorldRoot.Parent ~= nil then
		return cachedWorldRoot :: Folder
	end
	return World.Build(Workspace)
end

return World
