--!strict
--[[
	Visuals.Beams
	=============
	Procedural light pillars, double-helices, and celestial god rays.
	Supports multiple architectural styles:
	  * LightPillar (classic vertical column with scrolling beam)
	  * DoubleHelix (interlocking dual-strand spiral ascending upward)
	  * CosmicBeam (massive sky-piercing super-pillar with dual cores)
	  * GodRay (radial converging celestial shafts from the heavens)
]]

local Decals = require(script.Parent:WaitForChild("Decals") :: ModuleScript)

export type AscensionBeamStyle = "None" | "LightPillar" | "DoubleHelix" | "CosmicBeam" | "GodRay"

export type AscensionBeam = {
	container: Folder,
	attachments: { Attachment },
	beams: { Beam },
	coreParts: { Part },
	height: number,
	style: AscensionBeamStyle,
	update: (rootCFrame: CFrame, now: number) -> (),
}

local Beams = {}

-- Creates a vertical light pillar shooting into the sky from the character
function Beams.CreateLightPillar(
	parent: Instance,
	rootPart: BasePart,
	height: number,
	width: number,
	colorA: Color3,
	colorB: Color3
): AscensionBeam
	local container = Instance.new("Folder")
	container.Name = "AscensionBeam"

	local attBottom = Instance.new("Attachment")
	attBottom.Name = "BeamBottom"
	attBottom.Position = Vector3.new(0, -2, 0)
	attBottom.Parent = rootPart

	local attTop = Instance.new("Attachment")
	attTop.Name = "BeamTop"
	attTop.Position = Vector3.new(0, height, 0)
	attTop.Parent = rootPart

	local beam = Instance.new("Beam")
	beam.Name = "PillarBeam"
	beam.Attachment0 = attBottom
	beam.Attachment1 = attTop
	beam.Width0 = width
	beam.Width1 = width * 1.5
	beam.Color = Decals.ColorSequenceGradient(colorA, colorB)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.7, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Texture = Decals.Textures.EnergyBeam
	beam.TextureSpeed = 1.8
	beam.TextureLength = 12
	beam.TextureMode = Enum.TextureMode.Wrap
	beam.Parent = container

	local cylinder = Instance.new("Part")
	cylinder.Name = "CoreCylinder"
	cylinder.Shape = Enum.PartType.Cylinder
	cylinder.Size = Vector3.new(height, width * 0.4, width * 0.4)
	cylinder.Material = Enum.Material.Neon
	cylinder.Color = colorA
	cylinder.Transparency = 0.8
	cylinder.Anchored = true
	cylinder.CanCollide = false
	cylinder.CanTouch = false
	cylinder.CanQuery = false
	cylinder.CastShadow = false
	cylinder.Massless = true
	cylinder.Parent = container

	container.Parent = parent

	local function update(rootCFrame: CFrame, _now: number)
		local centerPos = rootCFrame.Position + Vector3.new(0, height * 0.5 - 2, 0)
		cylinder.CFrame = CFrame.new(centerPos) * CFrame.Angles(0, 0, math.pi / 2)
	end

	return {
		container = container,
		attachments = { attBottom, attTop },
		beams = { beam },
		coreParts = { cylinder },
		height = height,
		style = "LightPillar",
		update = update,
	}
end

-- Creates an interlocking spiraling Double-Helix ascending around the player
function Beams.CreateDoubleHelix(
	parent: Instance,
	rootPart: BasePart,
	height: number,
	radius: number,
	colorA: Color3,
	colorB: Color3
): AscensionBeam
	local container = Instance.new("Folder")
	container.Name = "DoubleHelixBeam"

	local segmentCount = 12
	local strandParts: { Part } = {}

	for i = 1, segmentCount do
		-- Strand A
		local segA = Instance.new("Part")
		segA.Name = string.format("StrandA_%d", i)
		segA.Size = Vector3.new(0.2, 0.2, 1.2)
		segA.Material = Enum.Material.Neon
		segA.Color = colorA
		segA.Transparency = 0.25
		segA.Anchored = true
		segA.CanCollide = false
		segA.CanTouch = false
		segA.CanQuery = false
		segA.CastShadow = false
		segA.Parent = container
		table.insert(strandParts, segA)

		-- Strand B
		local segB = Instance.new("Part")
		segB.Name = string.format("StrandB_%d", i)
		segB.Size = Vector3.new(0.2, 0.2, 1.2)
		segB.Material = Enum.Material.Neon
		segB.Color = colorB
		segB.Transparency = 0.25
		segB.Anchored = true
		segB.CanCollide = false
		segB.CanTouch = false
		segB.CanQuery = false
		segB.CastShadow = false
		segB.Parent = container
		table.insert(strandParts, segB)
	end

	container.Parent = parent

	local function update(rootCFrame: CFrame, now: number)
		local center = rootCFrame.Position
		local heightStep = height / segmentCount
		local rotSpeed = now * 2.2

		for i = 1, segmentCount do
			local y = (i - 1) * heightStep
			local angleA = rotSpeed + i * 0.55
			local angleB = angleA + math.pi

			local posA = center + Vector3.new(math.cos(angleA) * radius, y, math.sin(angleA) * radius)
			local posB = center + Vector3.new(math.cos(angleB) * radius, y, math.sin(angleB) * radius)

			local idxA = (i - 1) * 2 + 1
			local idxB = (i - 1) * 2 + 2

			strandParts[idxA].CFrame = CFrame.new(posA) * CFrame.Angles(0, angleA, 0)
			strandParts[idxB].CFrame = CFrame.new(posB) * CFrame.Angles(0, angleB, 0)
		end
	end

	return {
		container = container,
		attachments = {},
		beams = {},
		coreParts = strandParts,
		height = height,
		style = "DoubleHelix",
		update = update,
	}
end

-- Creates celestial God Rays converging from the sky down onto the character
function Beams.CreateGodRays(
	parent: Instance,
	rootPart: BasePart,
	height: number,
	rayCount: number,
	colorA: Color3,
	colorB: Color3
): AscensionBeam
	local container = Instance.new("Folder")
	container.Name = "GodRays"

	local rays: { Part } = {}

	for i = 1, rayCount do
		local ray = Instance.new("Part")
		ray.Name = string.format("GodRay_%d", i)
		ray.Shape = Enum.PartType.Cylinder
		ray.Size = Vector3.new(height * 1.1, 0.45, 0.45)
		ray.Material = Enum.Material.Neon
		ray.Color = colorA:Lerp(colorB, (i - 1) / math.max(1, rayCount - 1))
		ray.Transparency = 0.72
		ray.Anchored = true
		ray.CanCollide = false
		ray.CanTouch = false
		ray.CanQuery = false
		ray.CastShadow = false
		ray.Parent = container
		table.insert(rays, ray)
	end

	container.Parent = parent

	local function update(rootCFrame: CFrame, now: number)
		local groundTarget = rootCFrame.Position
		local angleStep = (math.pi * 2) / rayCount

		for i = 1, rayCount do
			local angle = (i - 1) * angleStep + now * 0.2
			local skyOrigin = groundTarget + Vector3.new(math.cos(angle) * 14, height, math.sin(angle) * 14)
			local mid = (skyOrigin + groundTarget) * 0.5
			local dir = (skyOrigin - groundTarget).Unit

			rays[i].CFrame = CFrame.lookAlong(mid, dir) * CFrame.Angles(0, 0, math.pi / 2)
			rays[i].Transparency = 0.7 + 0.15 * math.sin(now * 3 + i)
		end
	end

	return {
		container = container,
		attachments = {},
		beams = {},
		coreParts = rays,
		height = height,
		style = "GodRay",
		update = update,
	}
end

function Beams.Destroy(pillar: AscensionBeam): ()
	for _, att in ipairs(pillar.attachments) do
		att:Destroy()
	end
	pillar.container:Destroy()
end

return Beams
