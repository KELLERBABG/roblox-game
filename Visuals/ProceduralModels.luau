--!strict
--[[
	Visuals.ProceduralModels
	========================
	Constructs high-end procedural 3D models and geometric visual structures:
	  * Safe Shard Builder (handles Part, WedgePart, CornerWedgePart)
	  * Seraph Wings (radiant angelic wings for Divine/Transcendent auras)
	  * Gyroscopic Gimbal Rings (multi-axis rotating rings)
	  * Floating Crystal Crown (hovering halo for Legendary/Mythic auras)
	  * Orbital Dust Belt (Saturn-style planetary ring)
	  * Matrix Quantum Cube (digital wireframe tesseract)
]]

export type ShardShape = "Ball" | "Block" | "Cylinder" | "Wedge" | "CornerWedge"
export type HaloStyle = "None" | "CrystalCrown" | "GimbalRings" | "SeraphWings" | "OrbitalBelt" | "MatrixCube"

export type ProceduralStructure = {
	model: Model,
	parts: { BasePart },
	update: (rootCFrame: CFrame, now: number) -> (),
}

local ProceduralModels = {}

-- Safely creates a 3D shard part according to its requested shape.
-- Fully resolves the Roblox engine distinction where WedgePart and CornerWedgePart are distinct classes.
function ProceduralModels.CreateShard(
	shape: ShardShape,
	size: Vector3,
	color: Color3,
	transparency: number?
): BasePart
	local part: BasePart

	if shape == "Wedge" then
		local wedge = Instance.new("WedgePart")
		wedge.Size = size
		part = wedge
	elseif shape == "CornerWedge" then
		local corner = Instance.new("CornerWedgePart")
		corner.Size = size
		part = corner
	else
		local blockOrCyl = Instance.new("Part")
		if shape == "Ball" then
			blockOrCyl.Shape = Enum.PartType.Ball
		elseif shape == "Cylinder" then
			blockOrCyl.Shape = Enum.PartType.Cylinder
		else
			blockOrCyl.Shape = Enum.PartType.Block
		end
		blockOrCyl.Size = size
		part = blockOrCyl
	end

	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	return part
end

-- =============================================================================
-- Structure 1: Seraph Wings (Sol's RNG Archangel / Sovereign Style)
-- =============================================================================

function ProceduralModels.CreateSeraphWings(
	parent: Instance,
	wingCountPerSide: number,
	primaryColor: Color3,
	secondaryColor: Color3
): ProceduralStructure
	local model = Instance.new("Model")
	model.Name = "SeraphWings"

	local wingFeathers: { BasePart } = {}
	local leftOffsets: { { angle: number, length: number, width: number } } = {}
	local rightOffsets: { { angle: number, length: number, width: number } } = {}

	for i = 1, wingCountPerSide do
		local span = 1.6 + i * 0.5
		local thick = 0.18 + (wingCountPerSide - i) * 0.04
		local color = primaryColor:Lerp(secondaryColor, (i - 1) / math.max(1, wingCountPerSide - 1))

		-- Left feather
		local leftFeather = ProceduralModels.CreateShard("Wedge", Vector3.new(thick, span, 0.35), color, 0.15)
		leftFeather.Name = string.format("LeftWing_%d", i)
		leftFeather.Parent = model
		table.insert(wingFeathers, leftFeather)
		table.insert(leftOffsets, { angle = 20 + i * 16, length = span, width = thick })

		-- Right feather
		local rightFeather = ProceduralModels.CreateShard("Wedge", Vector3.new(thick, span, 0.35), color, 0.15)
		rightFeather.Name = string.format("RightWing_%d", i)
		rightFeather.Parent = model
		table.insert(wingFeathers, rightFeather)
		table.insert(rightOffsets, { angle = -(20 + i * 16), length = span, width = thick })
	end

	model.Parent = parent

	local function update(rootCFrame: CFrame, now: number)
		-- Gentle angelic breathing flap motion
		local flap = math.sin(now * 2.8) * math.rad(14)
		local backPos = rootCFrame * CFrame.new(0, 0.8, 0.7)

		for i = 1, wingCountPerSide do
			local leftIdx = (i - 1) * 2 + 1
			local rightIdx = (i - 1) * 2 + 2

			local lData = leftOffsets[i]
			local rData = rightOffsets[i]

			-- Left wing transform
			local lAngle = math.rad(lData.angle) + flap * 0.7
			local lCF = backPos
				* CFrame.Angles(0, math.rad(15) + flap, lAngle)
				* CFrame.new(-lData.length * 0.45, lData.length * 0.45, 0)
			wingFeathers[leftIdx].CFrame = lCF

			-- Right wing transform
			local rAngle = math.rad(rData.angle) - flap * 0.7
			local rCF = backPos
				* CFrame.Angles(0, -math.rad(15) - flap, rAngle)
				* CFrame.new(rData.length * 0.45, rData.length * 0.45, 0)
			wingFeathers[rightIdx].CFrame = rCF
		end
	end

	return {
		model = model,
		parts = wingFeathers,
		update = update,
	}
end

-- =============================================================================
-- Structure 2: Floating Crystal Crown
-- =============================================================================

function ProceduralModels.CreateCrystalCrown(
	parent: Instance,
	shardCount: number,
	radius: number,
	heightOffset: number,
	color: Color3
): ProceduralStructure
	local model = Instance.new("Model")
	model.Name = "CrystalCrown"

	local shards: { BasePart } = {}
	local angleStep = (math.pi * 2) / shardCount

	for i = 1, shardCount do
		local shard = ProceduralModels.CreateShard(
			"CornerWedge",
			Vector3.new(0.25, 0.65, 0.25),
			color,
			0.15
		)
		shard.Name = string.format("CrownShard_%d", i)
		shard.Parent = model
		table.insert(shards, shard)
	end

	model.Parent = parent

	local function update(rootCFrame: CFrame, now: number)
		local center = rootCFrame * CFrame.new(0, heightOffset, 0)
		local baseRot = now * 1.6

		for i, shard in ipairs(shards) do
			local angle = baseRot + (i - 1) * angleStep
			local bob = math.sin(now * 3 + (i - 1) * 0.7) * 0.12
			local x = math.cos(angle) * radius
			local z = math.sin(angle) * radius

			local pos = center * CFrame.new(x, bob, z)
			local lookToCenter = CFrame.lookAt(pos.Position, center.Position)
			local tilt = CFrame.Angles(math.rad(28), 0, 0)

			shard.CFrame = lookToCenter * tilt
		end
	end

	return {
		model = model,
		parts = shards,
		update = update,
	}
end

-- =============================================================================
-- Structure 3: Gyroscopic Gimbal Rings
-- =============================================================================

function ProceduralModels.CreateGimbalRings(
	parent: Instance,
	ringCount: number,
	baseRadius: number,
	colorA: Color3,
	colorB: Color3
): ProceduralStructure
	local model = Instance.new("Model")
	model.Name = "GimbalRings"

	local parts: { BasePart } = {}
	local segsPerRing = 14
	local ringRadii: { number } = {}
	local ringSpeeds: { Vector3 } = {}

	for ringIdx = 1, ringCount do
		local rad = baseRadius + (ringIdx - 1) * 0.65
		table.insert(ringRadii, rad)
		local color = colorA:Lerp(colorB, (ringIdx - 1) / math.max(1, ringCount - 1))

		local segAngle = (math.pi * 2) / segsPerRing
		local chord = 2 * rad * math.sin(segAngle / 2) * 1.08

		for seg = 1, segsPerRing do
			local p = ProceduralModels.CreateShard("Cylinder", Vector3.new(chord, 0.14, 0.14), color, 0.25)
			p.Name = string.format("Ring%d_Seg%d", ringIdx, seg)
			p.Parent = model
			table.insert(parts, p)
		end

		local speed = Vector3.new(
			(ringIdx % 2 == 0 and 1 or -1) * (1.0 + 0.3 * ringIdx),
			(ringIdx % 3 == 0 and -1 or 1) * (1.2 + 0.2 * ringIdx),
			(ringIdx % 2 == 1 and 0.8 or -0.8) * (0.6 + 0.4 * ringIdx)
		)
		table.insert(ringSpeeds, speed)
	end

	model.Parent = parent

	local function update(rootCFrame: CFrame, now: number)
		local center = rootCFrame.Position
		local partIdx = 1

		for ringIdx = 1, ringCount do
			local rad = ringRadii[ringIdx]
			local spd = ringSpeeds[ringIdx]
			local ringRot = CFrame.Angles(now * spd.X, now * spd.Y, now * spd.Z)
			local segAngle = (math.pi * 2) / segsPerRing

			for seg = 1, segsPerRing do
				local angle = (seg - 1) * segAngle + segAngle * 0.5
				local localPos = Vector3.new(math.cos(angle) * rad, 0, math.sin(angle) * rad)
				local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))

				local worldPos = center + ringRot:VectorToWorldSpace(localPos)
				local worldTang = ringRot:VectorToWorldSpace(tangent)

				local cf = CFrame.lookAlong(worldPos, worldTang) * CFrame.Angles(0, math.pi / 2, 0)
				parts[partIdx].CFrame = cf
				partIdx += 1
			end
		end
	end

	return {
		model = model,
		parts = parts,
		update = update,
	}
end

-- =============================================================================
-- Structure 4: Orbital Planetary Dust Belt
-- =============================================================================

function ProceduralModels.CreateOrbitalBelt(
	parent: Instance,
	particleCount: number,
	radius: number,
	tiltDegrees: number,
	color: Color3
): ProceduralStructure
	local model = Instance.new("Model")
	model.Name = "OrbitalBelt"

	local particles: { BasePart } = {}
	local step = (math.pi * 2) / particleCount

	for i = 1, particleCount do
		local size = 0.2 + (i % 3) * 0.1
		local p = ProceduralModels.CreateShard("Ball", Vector3.new(size, size, size), color, 0.2)
		p.Name = string.format("BeltDust_%d", i)
		p.Parent = model
		table.insert(particles, p)
	end

	model.Parent = parent

	local function update(rootCFrame: CFrame, now: number)
		local center = rootCFrame.Position
		local tiltCF = CFrame.Angles(math.rad(tiltDegrees), now * 0.5, 0)
		local rotSpeed = now * 1.8

		for i, p in ipairs(particles) do
			local angle = rotSpeed + (i - 1) * step
			local r = radius + math.sin(now * 2 + i) * 0.2
			local localPos = Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
			p.CFrame = CFrame.new(center + tiltCF:VectorToWorldSpace(localPos))
		end
	end

	return {
		model = model,
		parts = particles,
		update = update,
	}
end

-- =============================================================================
-- Structure 5: Matrix Quantum Cube (Wireframe Tesseract)
-- =============================================================================

function ProceduralModels.CreateMatrixCube(
	parent: Instance,
	cubeSize: number,
	heightOffset: number,
	color: Color3
): ProceduralStructure
	local model = Instance.new("Model")
	model.Name = "MatrixCube"

	-- 12 edge struts of a 3D wireframe cube
	local edges: { BasePart } = {}
	for i = 1, 12 do
		local edge = ProceduralModels.CreateShard("Cylinder", Vector3.new(cubeSize, 0.08, 0.08), color, 0.2)
		edge.Name = string.format("CubeEdge_%d", i)
		edge.Parent = model
		table.insert(edges, edge)
	end

	model.Parent = parent

	-- Local definitions of 12 edges between vertices [-1, 1]
	local hs = cubeSize * 0.5
	local edgePairs = {
		-- Bottom 4
		{ Vector3.new(-hs, -hs, -hs), Vector3.new(hs, -hs, -hs) },
		{ Vector3.new(hs, -hs, -hs), Vector3.new(hs, -hs, hs) },
		{ Vector3.new(hs, -hs, hs), Vector3.new(-hs, -hs, hs) },
		{ Vector3.new(-hs, -hs, hs), Vector3.new(-hs, -hs, -hs) },
		-- Top 4
		{ Vector3.new(-hs, hs, -hs), Vector3.new(hs, hs, -hs) },
		{ Vector3.new(hs, hs, -hs), Vector3.new(hs, hs, hs) },
		{ Vector3.new(hs, hs, hs), Vector3.new(-hs, hs, hs) },
		{ Vector3.new(-hs, hs, hs), Vector3.new(-hs, hs, -hs) },
		-- Vertical 4
		{ Vector3.new(-hs, -hs, -hs), Vector3.new(-hs, hs, -hs) },
		{ Vector3.new(hs, -hs, -hs), Vector3.new(hs, hs, -hs) },
		{ Vector3.new(hs, -hs, hs), Vector3.new(hs, hs, hs) },
		{ Vector3.new(-hs, -hs, hs), Vector3.new(-hs, hs, hs) },
	}

	local function update(rootCFrame: CFrame, now: number)
		local center = rootCFrame.Position + Vector3.new(0, heightOffset, 0)
		local rot = CFrame.Angles(now * 1.5, now * 2.1, now * 0.9)

		for i = 1, 12 do
			local p1 = center + rot:VectorToWorldSpace(edgePairs[i][1])
			local p2 = center + rot:VectorToWorldSpace(edgePairs[i][2])
			local mid = (p1 + p2) * 0.5
			local dir = (p2 - p1).Unit

			edges[i].CFrame = CFrame.lookAlong(mid, dir) * CFrame.Angles(0, math.pi / 2, 0)
		end
	end

	return {
		model = model,
		parts = edges,
		update = update,
	}
end

return ProceduralModels
