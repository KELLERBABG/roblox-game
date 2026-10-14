--!strict
--[[
	Visuals
	=======
	Unified visual enhancement suite for the RNG Idle Aura Collector.
	Provides:
	  * 66 Comprehensive Sol's RNG-inspired Aura Mockups & Configurations
	  * Multi-layer procedural particle emitters and decals
	  * Seraph Wings, Matrix Cubes, Gimbal Rings, Orbital Belts, Crystal Crowns
	  * Procedural magic floor seals and terrain-projected runes
	  * Vertical ascension pillars, double-helices, and celestial god rays
	  * Expanding shockwave blast rings and radial particle explosions
	  * Tier-specific audio profiles (Common to Singularity)
]]

local AuraCatalog = require(script:WaitForChild("AuraCatalog") :: ModuleScript)
local Decals = require(script:WaitForChild("Decals") :: ModuleScript)
local ProceduralModels = require(script:WaitForChild("ProceduralModels") :: ModuleScript)
local FloorRings = require(script:WaitForChild("FloorRings") :: ModuleScript)
local Beams = require(script:WaitForChild("Beams") :: ModuleScript)
local Shockwaves = require(script:WaitForChild("Shockwaves") :: ModuleScript)
local Audio = require(script:WaitForChild("Audio") :: ModuleScript)
local HUD = require(script:WaitForChild("HUD") :: ModuleScript)
local World = require(script:WaitForChild("World") :: ModuleScript)

export type FullAuraVFX = {
	container: Folder,
	character: Model,
	rootPart: BasePart,
	auraConfig: AuraCatalog.AuraEntry,
	floorRing: FloorRings.FloorRing?,
	ascensionBeam: Beams.AscensionBeam?,
	structure: ProceduralModels.ProceduralStructure?,
	shards: { BasePart },
	spins: { number },
	primaryColor: Color3,
	secondaryColor: Color3,
}

local Visuals = {}

Visuals.Catalog = AuraCatalog
Visuals.Decals = Decals
Visuals.ProceduralModels = ProceduralModels
Visuals.FloorRings = FloorRings
Visuals.Beams = Beams
Visuals.Shockwaves = Shockwaves
Visuals.Audio = Audio
Visuals.HUD = HUD
Visuals.World = World

function Visuals.GetAura(id: string): AuraCatalog.AuraEntry?
	return AuraCatalog.Get(id)
end

function Visuals.GetAllAuras(): { [string]: AuraCatalog.AuraEntry }
	return AuraCatalog.All()
end

function Visuals.ToColor3(rgb: AuraCatalog.RGB): Color3
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

-- Builds a complete multi-layered visual effect set for a character based on its AuraEntry
function Visuals.CreateFullAuraVFX(
	character: Model,
	rootPart: BasePart,
	aura: AuraCatalog.AuraEntry
): FullAuraVFX
	local primary = Visuals.ToColor3(aura.primary)
	local secondary = Visuals.ToColor3(aura.secondary)
	local rim = Visuals.ToColor3(aura.rim)

	local container = Instance.new("Folder")
	container.Name = string.format("AuraVFX_%s", aura.id)
	container.Parent = character

	-- 1. Floor Rune
	local floorRing: FloorRings.FloorRing? = nil
	if aura.floorRuneStyle ~= "None" then
		floorRing = FloorRings.Create(container, aura.orbitRadius * 0.9, primary, secondary, aura.floorRuneStyle)
	end

	-- 2. Ascension Beam
	local ascensionBeam: Beams.AscensionBeam? = nil
	if aura.ascensionBeamStyle == "LightPillar" then
		ascensionBeam = Beams.CreateLightPillar(container, rootPart, 50, 1.8, primary, secondary)
	elseif aura.ascensionBeamStyle == "DoubleHelix" then
		ascensionBeam = Beams.CreateDoubleHelix(container, rootPart, 45, aura.orbitRadius * 0.8, primary, secondary)
	elseif aura.ascensionBeamStyle == "CosmicBeam" then
		ascensionBeam = Beams.CreateLightPillar(container, rootPart, 75, 2.8, primary, rim)
	elseif aura.ascensionBeamStyle == "GodRay" then
		ascensionBeam = Beams.CreateGodRays(container, rootPart, 65, 6, primary, secondary)
	end

	-- 3. High-Tier Structure (Wings, Gimbal, Halo, Belt, Cube)
	local structure: ProceduralModels.ProceduralStructure? = nil
	if aura.haloStyle == "SeraphWings" then
		structure = ProceduralModels.CreateSeraphWings(container, 5, primary, secondary)
	elseif aura.haloStyle == "GimbalRings" then
		structure = ProceduralModels.CreateGimbalRings(container, 3, aura.orbitRadius * 0.65, primary, secondary)
	elseif aura.haloStyle == "CrystalCrown" then
		structure = ProceduralModels.CreateCrystalCrown(container, 8, 1.6, 3.6, primary)
	elseif aura.haloStyle == "OrbitalBelt" then
		structure = ProceduralModels.CreateOrbitalBelt(container, 16, aura.orbitRadius * 0.8, aura.tiltDegrees, primary)
	elseif aura.haloStyle == "MatrixCube" then
		structure = ProceduralModels.CreateMatrixCube(container, 2.0, 3.8, primary)
	end

	-- 4. Procedural Orbiting Shards
	local shards: { BasePart } = {}
	local spins: { number } = {}
	local shardSizeVec = Vector3.new(aura.shardSize.x, aura.shardSize.y, aura.shardSize.z)

	for i = 1, aura.shardCount do
		local shard = ProceduralModels.CreateShard(
			aura.shardShape,
			shardSizeVec,
			if i % 2 == 0 then secondary else primary,
			0.1
		)
		shard.Name = string.format("AuraShard_%d", i)
		shard.Parent = container
		table.insert(shards, shard)
		table.insert(spins, aura.shardSpin * (0.8 + 0.4 * ((i % 4) / 3)))
	end

	return {
		container = container,
		character = character,
		rootPart = rootPart,
		auraConfig = aura,
		floorRing = floorRing,
		ascensionBeam = ascensionBeam,
		structure = structure,
		shards = shards,
		spins = spins,
		primaryColor = primary,
		secondaryColor = secondary,
	}
end

-- Centralized frame update for all active aura components
function Visuals.UpdateFullAuraVFX(vfx: FullAuraVFX, now: number): ()
	local rootCFrame = vfx.rootPart.CFrame
	local cfg = vfx.auraConfig

	-- Update Floor Rune
	if vfx.floorRing ~= nil then
		FloorRings.Update(vfx.floorRing, rootCFrame, vfx.character, now)
	end

	-- Update Ascension Beam
	if vfx.ascensionBeam ~= nil then
		vfx.ascensionBeam.update(rootCFrame, now)
	end

	-- Update High-tier Structure (Wings/Gimbal/Crown/Belt)
	if vfx.structure ~= nil then
		vfx.structure.update(rootCFrame, now)
	end

	-- Update Orbiting Shards
	local shardCount = #vfx.shards
	if shardCount > 0 then
		local ringCFrame = CFrame.Angles(math.rad(cfg.tiltDegrees), 0, 0)
			* CFrame.Angles(0, now * cfg.precessionSpeed, 0)
		local ringOrigin = rootCFrame * ringCFrame

		local baseAngle = now * cfg.orbitSpeed * cfg.harmonicRatioA
		local vertHarmonic = now * cfg.orbitSpeed * cfg.harmonicFrequency
		local breathHarmonic = now * cfg.orbitSpeed * cfg.harmonicFrequency * 0.5
		local step = (math.pi * 2) / shardCount

		for i = 1, shardCount do
			local offset = i - 1
			local angle = baseAngle + offset * step
			local r = cfg.orbitRadius * (1 + math.sin(breathHarmonic + offset * 0.9) * cfg.lissajousAmplitude)
			local x = math.cos(angle) * r
			local z = math.sin(angle) * r
			local y = math.sin(vertHarmonic + offset * step * 1.5) * cfg.orbitHeight

			local spin = now * vfx.spins[i]
			vfx.shards[i].CFrame = ringOrigin * CFrame.new(x, y, z) * CFrame.Angles(spin, spin * 1.3, spin * 0.8)
		end
	end
end

-- Destroys and cleans up an active aura effect bundle
function Visuals.DestroyFullAuraVFX(vfx: FullAuraVFX): ()
	if vfx.floorRing ~= nil then
		FloorRings.Destroy(vfx.floorRing)
	end
	if vfx.ascensionBeam ~= nil then
		Beams.Destroy(vfx.ascensionBeam)
	end
	vfx.container:Destroy()
end

-- Plays a cinematic roll cutscene using shockwaves, tier audio, and altar pulse
function Visuals.PlayCutscene(cframe: CFrame, aura: AuraCatalog.AuraEntry): ()
	local primary = Visuals.ToColor3(aura.primary)
	Audio.PlayRollReveal(aura.soundProfile, aura.rarity)

	if aura.rarity >= 50 then
		local rad = math.clamp(aura.rarity / 500 + 10, 10, 40)
		Shockwaves.PlayExpandingRing(cframe, 1.5, rad, 0.65, primary)
	end

	if aura.rarity >= 5000 then
		Shockwaves.PlayBurstParticles(cframe, 45, primary, Color3.fromRGB(255, 255, 255))
	end

	local sanctuary = game:GetService("Workspace"):FindFirstChild("SolSanctuary")
	if sanctuary ~= nil and sanctuary:IsA("Folder") then
		World.Interactive.PulseAltar(sanctuary :: Folder, primary)
	end
end

-- Auto-bootstrap world when Visuals is required
local RunService = game:GetService("RunService")
task.spawn(function()
	World.EnsureWorld()
	if RunService:IsClient() then
		World.StartClientAmbience()
	end
end)

return Visuals
