--!strict
--[[
	Visuals.Shockwaves
	==================
	Procedural expanding impact shockwaves, ring blasts, and implosion bursts.
	Used during roll cutscenes and aura activation moments.
]]

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shockwaves = {}

-- Plays an expanding, fading procedural shockwave disc along a ground plane or CFrame
function Shockwaves.PlayExpandingRing(
	origin: CFrame,
	startRadius: number,
	endRadius: number,
	duration: number,
	color: Color3
): ()
	local disc = Instance.new("Part")
	disc.Name = "ShockwaveRing"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.1, startRadius * 2, startRadius * 2)
	disc.Material = Enum.Material.Neon
	disc.Color = color
	disc.Transparency = 0.2
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanTouch = false
	disc.CanQuery = false
	disc.CastShadow = false

	-- Rotate cylinder 90 deg around Z to lie flat horizontally
	disc.CFrame = origin * CFrame.Angles(0, 0, math.pi / 2)
	disc.Parent = Workspace

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	local tween = TweenService:Create(disc, tweenInfo, {
		Size = Vector3.new(0.04, endRadius * 2, endRadius * 2),
		Transparency = 1,
	})

	tween:Play()
	tween.Completed:Once(function()
		disc:Destroy()
	end)
end

-- Plays an explosive particle burst at a target CFrame
function Shockwaves.PlayBurstParticles(
	origin: CFrame,
	particleCount: number,
	colorA: Color3,
	colorB: Color3
): ()
	local emitterPart = Instance.new("Part")
	emitterPart.Name = "BurstEmitter"
	emitterPart.Size = Vector3.new(0.2, 0.2, 0.2)
	emitterPart.Transparency = 1
	emitterPart.Anchored = true
	emitterPart.CanCollide = false
	emitterPart.CanTouch = false
	emitterPart.CanQuery = false
	emitterPart.CFrame = origin
	emitterPart.Parent = Workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(colorA, colorB)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = NumberRange.new(12, 28)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Lifetime = NumberRange.new(0.4, 0.8)
	emitter.LightEmission = 1
	emitter.Drag = 4
	emitter.Rate = 0
	emitter.Parent = emitterPart

	emitter:Emit(particleCount)

	task.delay(1.0, function()
		emitterPart:Destroy()
	end)
end

return Shockwaves
