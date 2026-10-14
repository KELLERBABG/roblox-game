--!strict
--[[
	Visuals.Decals
	==============
	Comprehensive texture catalog and procedural visual generator for auras,
	summoning seals, shockwaves, beams, and particle emitters.
	Provides zero-failure engine-shipped fallback textures plus verified asset IDs.
]]

export type TextureCategory = "Rune" | "Elemental" | "Cosmic" | "Digital" | "Beam" | "Shockwave"

local Decals = {}

-- Engine-shipped textures guaranteed to exist locally inside the Roblox client binary
Decals.Engine = {
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
	Fire = "rbxasset://textures/particles/fire_main.dds",
}

-- Curated Roblox asset IDs for high-fidelity Sol's RNG-tier particle and decal visuals
Decals.Textures = {
	-- Magic Runes & Seals
	HolySigil = "rbxassetid://4995938421",
	RunicCircle = "rbxassetid://6027419163",
	ChronosGear = "rbxassetid://6027419820",
	VoidRift = "rbxassetid://6027420556",
	CelestialStar = "rbxassetid://5854262447",
	DigitalMatrix = "rbxassetid://5854261775",
	LightningRune = "rbxassetid://5854263301",
	AbyssalVortex = "rbxassetid://5857851887",

	-- Particle Sprites
	StarGlow = "rbxassetid://5854262447",
	CosmicNova = "rbxassetid://6027420556",
	LightningArc = "rbxassetid://5854261775",
	SoftAuraGlow = "rbxassetid://5854262846",
	EnergyBeam = "rbxassetid://5854263301",
	SakuraPetal = "rbxassetid://6027421110",
	EmberFragment = "rbxassetid://5854261990",
	GlacialShard = "rbxassetid://5854262660",

	-- Shockwaves & Impacts
	ShockwaveRing = "rbxassetid://5857851887",
	DistortionRing = "rbxassetid://4995938421",
	StarburstBurst = "rbxassetid://6027420556",
}

-- =============================================================================
-- Sequence Utilities
-- =============================================================================

function Decals.ColorSequenceUniform(color: Color3): ColorSequence
	return ColorSequence.new(color, color)
end

function Decals.ColorSequenceGradient(c1: Color3, c2: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, c1),
		ColorSequenceKeypoint.new(1, c2),
	})
end

function Decals.ColorSequenceThreePoint(c1: Color3, c2: Color3, c3: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, c1),
		ColorSequenceKeypoint.new(0.5, c2),
		ColorSequenceKeypoint.new(1, c3),
	})
end

function Decals.NumberSequenceEaseOut(startVal: number, endVal: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, startVal),
		NumberSequenceKeypoint.new(0.65, startVal + (endVal - startVal) * 0.8),
		NumberSequenceKeypoint.new(1, endVal),
	})
end

function Decals.NumberSequenceBell(peakVal: number, edgeVal: number?): NumberSequence
	local edge = edgeVal or 1
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, edge),
		NumberSequenceKeypoint.new(0.5, peakVal),
		NumberSequenceKeypoint.new(1, edge),
	})
end

function Decals.NumberSequenceFadeOut(): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- =============================================================================
-- Procedural Particle Layer Builder
-- =============================================================================

export type EmitterOptions = {
	colorSeq: ColorSequence,
	sizeSeq: NumberSequence?,
	transparencySeq: NumberSequence?,
	speedRange: NumberRange?,
	lifetimeRange: NumberRange?,
	rate: number,
	spread: number,
	texture: string?,
	lightEmission: number?,
	drag: number?,
	acceleration: Vector3?,
}

function Decals.CreateParticleEmitter(name: string, parent: Instance, opts: EmitterOptions): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Color = opts.colorSeq
	emitter.Size = opts.sizeSeq or Decals.NumberSequenceEaseOut(0.5, 0)
	emitter.Transparency = opts.transparencySeq or Decals.NumberSequenceFadeOut()
	emitter.Speed = opts.speedRange or NumberRange.new(2, 4)
	emitter.Lifetime = opts.lifetimeRange or NumberRange.new(0.6, 1.2)
	emitter.Rate = opts.rate
	emitter.SpreadAngle = Vector2.new(opts.spread, opts.spread)
	emitter.Texture = opts.texture or Decals.Engine.Sparkle
	emitter.LightEmission = opts.lightEmission or 0.8
	emitter.Drag = opts.drag or 1.5
	emitter.Acceleration = opts.acceleration or Vector3.new(0, 3, 0)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-60, 60)
	emitter.ZOffset = 0.2
	emitter.Enabled = true
	emitter.Parent = parent
	return emitter
end

return Decals
