--!strict
--[[
	Visuals.World.Foliage
	=====================
	High-detail procedural Sakura trees with softly illuminated blossom clouds,
	carved Japanese Tōrō stone lanterns, pointed crystal obelisk clusters,
	and bioluminescent sanctuary flora.
]]

local Decals = require(script.Parent.Parent:WaitForChild("Decals") :: ModuleScript)

local Foliage = {}

local function makePart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = if props.CanCollide ~= nil then props.CanCollide else true
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = if props.CastShadow ~= nil then props.CastShadow else true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	for k, v in pairs(props) do
		(part :: any)[k] = v
	end
	return part
end

-- =============================================================================
-- 1. Procedural Sakura Cherry Blossom Tree
-- =============================================================================

function Foliage.CreateSakuraTree(parent: Instance, pos: Vector3, scale: number?): Model
	local s = scale or 1.0
	local tree = Instance.new("Model")
	tree.Name = "SakuraTree"

	local barkColor = Color3.fromRGB(58, 38, 32)

	-- Flared Root Buttresses
	for r = 1, 4 do
		local ang = (r - 1) * (math.pi / 2) + math.rad(20)
		makePart({
			Name = string.format("Root_%d", r),
			Size = Vector3.new(1.2 * s, 2.6 * s, 2.2 * s),
			CFrame = CFrame.new(pos + Vector3.new(math.cos(ang) * 1.1 * s, 0.9 * s, math.sin(ang) * 1.1 * s))
				* CFrame.Angles(math.rad(28), ang, 0),
			Material = Enum.Material.Wood,
			Color = barkColor,
			Parent = tree,
		})
	end

	-- Tapered Multi-Segment Gnarled Trunk
	makePart({
		Name = "TrunkLower",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(5.5 * s, 2.5 * s, 2.5 * s),
		CFrame = CFrame.new(pos + Vector3.new(0, 2.6 * s, 0))
			* CFrame.Angles(math.rad(4), 0, math.pi / 2 + math.rad(5)),
		Material = Enum.Material.Wood,
		Color = barkColor,
		Parent = tree,
	})
	makePart({
		Name = "TrunkUpper",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(5.5 * s, 1.9 * s, 1.9 * s),
		CFrame = CFrame.new(pos + Vector3.new(-0.3 * s, 7.2 * s, 0.2 * s))
			* CFrame.Angles(math.rad(-6), 0, math.pi / 2 - math.rad(6)),
		Material = Enum.Material.Wood,
		Color = barkColor,
		Parent = tree,
	})

	-- 4 Connected Primary Limbs
	local branches = {
		{ off = Vector3.new(-2.2, 11.2, 1.0), rot = Vector3.new(18, 25, 34), len = 6.2 },
		{ off = Vector3.new(2.1, 11.4, -1.2), rot = Vector3.new(-20, -15, -32), len = 6.0 },
		{ off = Vector3.new(0.8, 11.8, 2.2), rot = Vector3.new(32, 0, -14), len = 5.5 },
		{ off = Vector3.new(-1.0, 11.6, -2.1), rot = Vector3.new(-30, 10, 16), len = 5.5 },
	}
	for i, b in ipairs(branches) do
		makePart({
			Name = string.format("Branch_%d", i),
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(b.len * s, 1.15 * s, 1.15 * s),
			CFrame = CFrame.new(pos + (b.off * s))
				* CFrame.Angles(math.rad(b.rot.X), math.rad(b.rot.Y), math.pi / 2 + math.rad(b.rot.Z)),
			Material = Enum.Material.Wood,
			Color = barkColor,
			Parent = tree,
		})
	end

	-- Multi-Layered Blossom Cloud Canopy (3 Pink Tones)
	local tones = {
		Color3.fromRGB(255, 190, 220),
		Color3.fromRGB(255, 215, 235),
		Color3.fromRGB(245, 155, 198),
	}

	local canopyLayers = {
		{ off = Vector3.new(0, 14.8, 0), sz = Vector3.new(10.5, 4.2, 10.5), tone = 1 },
		{ off = Vector3.new(0, 16.6, 0), sz = Vector3.new(7.5, 3.6, 7.5), tone = 2 },
		{ off = Vector3.new(-4.5, 13.6, 2.2), sz = Vector3.new(7.8, 3.5, 7.2), tone = 3 },
		{ off = Vector3.new(4.5, 13.8, -2.0), sz = Vector3.new(7.8, 3.5, 7.2), tone = 1 },
		{ off = Vector3.new(2.2, 14.2, 4.4), sz = Vector3.new(7.2, 3.4, 7.4), tone = 2 },
		{ off = Vector3.new(-2.4, 14.0, -4.2), sz = Vector3.new(7.4, 3.4, 7.2), tone = 1 },
		{ off = Vector3.new(-3.2, 15.6, -1.8), sz = Vector3.new(6.4, 3.2, 6.4), tone = 2 },
		{ off = Vector3.new(3.2, 15.5, 2.0), sz = Vector3.new(6.4, 3.2, 6.4), tone = 3 },
	}

	for i, c in ipairs(canopyLayers) do
		local puff = makePart({
			Name = string.format("BlossomPuff_%d", i),
			Shape = Enum.PartType.Ball,
			Size = c.sz * s,
			CFrame = CFrame.new(pos + (c.off * s))
				* CFrame.Angles(math.rad((i % 3 - 1) * 6), math.rad(i * 37), 0),
			Material = Enum.Material.SmoothPlastic,
			Color = tones[c.tone],
			CanCollide = false,
			CastShadow = false,
			Parent = tree,
		})

		if i == 1 then
			local glowCore = makePart({
				Name = "SakuraGlowCore",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(6.5, 2.8, 6.5) * s,
				CFrame = CFrame.new(pos + Vector3.new(0, 14.5 * s, 0)),
				Material = Enum.Material.Neon,
				Color = Color3.fromRGB(255, 165, 210),
				Transparency = 0.65,
				CanCollide = false,
				CastShadow = false,
				Parent = tree,
			})
			local canopyLight = Instance.new("PointLight")
			canopyLight.Color = Color3.fromRGB(255, 175, 215)
			canopyLight.Range = 18 * s
			canopyLight.Brightness = 0.85
			canopyLight.Parent = glowCore

			local emitter = Instance.new("ParticleEmitter")
			emitter.Name = "FallingPetals"
			emitter.Color = Decals.ColorSequenceGradient(
				Color3.fromRGB(255, 195, 225),
				Color3.fromRGB(255, 135, 185)
			)
			emitter.LightEmission = 0.45
			emitter.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.42 * s),
				NumberSequenceKeypoint.new(1, 0.22 * s),
			})
			emitter.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.05),
				NumberSequenceKeypoint.new(0.8, 0.25),
				NumberSequenceKeypoint.new(1, 1),
			})
			emitter.Speed = NumberRange.new(0.8, 2.0)
			emitter.Lifetime = NumberRange.new(4.0, 6.5)
			emitter.Rate = 9
			emitter.SpreadAngle = Vector2.new(180, 45)
			emitter.EmissionDirection = Enum.NormalId.Bottom
			emitter.Acceleration = Vector3.new(1.0, -1.5, 0.6)
			emitter.Drag = 1.1
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.RotSpeed = NumberRange.new(-55, 55)
			emitter.Texture = Decals.Textures.SakuraPetal
			emitter.Parent = puff
		end
	end

	tree.Parent = parent
	return tree
end

-- =============================================================================
-- 2. Traditional Carved Stone Lantern (Tōrō)
-- =============================================================================

function Foliage.CreateStoneLantern(parent: Instance, pos: Vector3): Model
	local lantern = Instance.new("Model")
	lantern.Name = "StoneLantern"

	local stoneCol = Color3.fromRGB(82, 88, 105)
	local darkStone = Color3.fromRGB(62, 68, 82)

	-- Tiered Base (Kiso) sitting flush on ground level
	makePart({
		Name = "BaseLower",
		Size = Vector3.new(1.8, 0.4, 1.8),
		CFrame = CFrame.new(pos + Vector3.new(0, 0.2, 0)),
		Material = Enum.Material.Slate,
		Color = darkStone,
		Parent = lantern,
	})
	makePart({
		Name = "Pedestal",
		Size = Vector3.new(1.3, 0.6, 1.3),
		CFrame = CFrame.new(pos + Vector3.new(0, 0.7, 0)),
		Material = Enum.Material.Slate,
		Color = stoneCol,
		Parent = lantern,
	})

	-- Cylindrical Shaft (Sao)
	makePart({
		Name = "Pillar",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.2, 0.85, 0.85),
		CFrame = CFrame.new(pos + Vector3.new(0, 2.1, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Slate,
		Color = stoneCol,
		Parent = lantern,
	})

	-- Mid Platform (Chūdai)
	makePart({
		Name = "ChamberBase",
		Size = Vector3.new(1.7, 0.35, 1.7),
		CFrame = CFrame.new(pos + Vector3.new(0, 3.35, 0)),
		Material = Enum.Material.Slate,
		Color = darkStone,
		Parent = lantern,
	})

	-- 4 Corner Posts around Fire Chamber
	local offsets = {
		Vector3.new(-0.55, 4.0, -0.55),
		Vector3.new(0.55, 4.0, -0.55),
		Vector3.new(-0.55, 4.0, 0.55),
		Vector3.new(0.55, 4.0, 0.55),
	}
	for i, off in ipairs(offsets) do
		makePart({
			Name = string.format("ChamberPost_%d", i),
			Size = Vector3.new(0.18, 0.95, 0.18),
			CFrame = CFrame.new(pos + off),
			Material = Enum.Material.Slate,
			Color = darkStone,
			Parent = lantern,
		})
	end

	-- Warm Glowing Candle Flame
	local flame = makePart({
		Name = "LanternFlame",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(0.7, 0.85, 0.7),
		CFrame = CFrame.new(pos + Vector3.new(0, 4.0, 0)),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 195, 90),
		Transparency = 0.1,
		CanCollide = false,
		Parent = lantern,
	})

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 185, 85)
	light.Range = 14
	light.Brightness = 1.0
	light.Shadows = false
	light.Parent = flame

	-- Tiered Pagoda Roof (Kasa) & Finial (Hōju)
	makePart({
		Name = "RoofLower",
		Size = Vector3.new(2.4, 0.35, 2.4),
		CFrame = CFrame.new(pos + Vector3.new(0, 4.65, 0)),
		Material = Enum.Material.Slate,
		Color = darkStone,
		Parent = lantern,
	})
	makePart({
		Name = "RoofUpper",
		Size = Vector3.new(1.5, 0.35, 1.5),
		CFrame = CFrame.new(pos + Vector3.new(0, 5.0, 0)),
		Material = Enum.Material.Slate,
		Color = stoneCol,
		Parent = lantern,
	})
	makePart({
		Name = "Finial",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(0.45, 0.55, 0.45),
		CFrame = CFrame.new(pos + Vector3.new(0, 5.4, 0)),
		Material = Enum.Material.Slate,
		Color = darkStone,
		Parent = lantern,
	})

	lantern.Parent = parent
	return lantern
end

-- =============================================================================
-- 3. Bioluminescent Crystal Cluster (Tapered Obelisks)
-- =============================================================================

function Foliage.CreateCrystalCluster(parent: Instance, pos: Vector3, color: Color3): Model
	local cluster = Instance.new("Model")
	cluster.Name = "CrystalCluster"

	makePart({
		Name = "MineralBase",
		Size = Vector3.new(2.8, 0.9, 2.8),
		CFrame = CFrame.new(pos + Vector3.new(0, 0.35, 0)) * CFrame.Angles(0, math.rad(25), 0),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(45, 50, 65),
		Parent = cluster,
	})

	local shards = {
		{ off = Vector3.new(0, 2.5, 0), sz = Vector3.new(1.1, 4.8, 1.1), rot = Vector3.new(4, 15, -6) },
		{ off = Vector3.new(-0.8, 1.8, 0.4), sz = Vector3.new(0.85, 3.4, 0.85), rot = Vector3.new(-14, -25, 18) },
		{ off = Vector3.new(0.7, 1.9, -0.6), sz = Vector3.new(0.9, 3.6, 0.9), rot = Vector3.new(18, 45, -12) },
		{ off = Vector3.new(0.5, 1.4, 0.7), sz = Vector3.new(0.75, 2.6, 0.75), rot = Vector3.new(-10, 80, -20) },
	}

	for i, sh in ipairs(shards) do
		local shard = makePart({
			Name = string.format("Shard_%d", i),
			Size = sh.sz,
			CFrame = CFrame.new(pos + sh.off)
				* CFrame.Angles(math.rad(sh.rot.X), math.rad(sh.rot.Y), math.rad(sh.rot.Z)),
			Material = Enum.Material.Neon,
			Color = color,
			Transparency = 0.12,
			CanCollide = false,
			Parent = cluster,
		})

		if i == 1 then
			local clusterLight = Instance.new("PointLight")
			clusterLight.Color = color
			clusterLight.Range = 14
			clusterLight.Brightness = 0.9
			clusterLight.Parent = shard
		end
	end

	cluster.Parent = parent
	return cluster
end

-- =============================================================================
-- 4. Complete Sanctuary Distribution (Zero Clipping & Harmonious Spacing)
-- =============================================================================

function Foliage.PopulateSanctuary(parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = "SanctuaryFoliage"

	-- Sakura Trees in dedicated garden lawn areas (elevated lawn Y is 0.3)
	local treeSpawns = {
		-- NW Grotto Grove
		{ pos = Vector3.new(-32, 0.3, -32), scale = 1.05 },
		{ pos = Vector3.new(-62, 0.3, -34), scale = 0.90 },
		{ pos = Vector3.new(-34, 0.3, -62), scale = 0.95 },
		-- SW Grove of Tranquility
		{ pos = Vector3.new(-48, 0.3, 38), scale = 1.15 },
		{ pos = Vector3.new(-34, 0.3, 58), scale = 0.95 },
		{ pos = Vector3.new(-62, 0.3, 58), scale = 1.00 },
		-- NE Mountain Foothill
		{ pos = Vector3.new(34, 0.3, -64), scale = 1.00 },
		{ pos = Vector3.new(66, 0.3, -32), scale = 0.90 },
		-- SE Waterfall Gardens
		{ pos = Vector3.new(32, 0.3, 34), scale = 1.05 },
		{ pos = Vector3.new(64, 0.3, 36), scale = 0.95 },
	}
	for _, item in ipairs(treeSpawns) do
		Foliage.CreateSakuraTree(folder, item.pos, item.scale)
	end

	-- Pathway Lanterns placed strictly along flat walkway curbs (Y = 0.12)
	-- Altar radius is 22; Plaza inner ring is R = 36.
	-- Walkways are 16-stud wide ([-8, +8]). Lanterns sit at offset +/- 10 on flat walkway curb edges!
	local lanternSpawns = {
		-- North Walkway (Z = -44 to -74)
		Vector3.new(-10, 0.12, -44),
		Vector3.new(10, 0.12, -44),
		Vector3.new(-10, 0.12, -68),
		Vector3.new(10, 0.12, -68),

		-- South Walkway (Z = 44 to 74)
		Vector3.new(-10, 0.12, 44),
		Vector3.new(10, 0.12, 44),
		Vector3.new(-10, 0.12, 68),
		Vector3.new(10, 0.12, 68),

		-- West Walkway (X = -44 to -74)
		Vector3.new(-44, 0.12, -10),
		Vector3.new(-44, 0.12, 10),
		Vector3.new(-68, 0.12, -10),
		Vector3.new(-68, 0.12, 10),

		-- East Walkway (X = 44 to 74)
		Vector3.new(44, 0.12, -10),
		Vector3.new(44, 0.12, 10),
		Vector3.new(68, 0.12, -10),
		Vector3.new(68, 0.12, 10),

		-- 4 Diagonal Plaza Lanterns placed radially at R = 28 on flat granite plaza (Y = 0.05)
		-- Perfectly outside the AltarStep1 rim (R = 22) with ZERO clipping!
		Vector3.new(19.8, 0.05, 19.8),
		Vector3.new(-19.8, 0.05, 19.8),
		Vector3.new(-19.8, 0.05, -19.8),
		Vector3.new(19.8, 0.05, -19.8),
	}
	for _, pos in ipairs(lanternSpawns) do
		Foliage.CreateStoneLantern(folder, pos)
	end

	-- Crystal Clusters around natural rock gardens
	local crystalSpawns = {
		{ pos = Vector3.new(28, 0.3, -28), col = Color3.fromRGB(95, 195, 255) },
		{ pos = Vector3.new(-28, 0.3, -28), col = Color3.fromRGB(255, 125, 215) },
		{ pos = Vector3.new(-28, 0.3, 28), col = Color3.fromRGB(110, 255, 175) },
		{ pos = Vector3.new(28, 0.3, 28), col = Color3.fromRGB(255, 205, 85) },
		{ pos = Vector3.new(-38, 0.3, -56), col = Color3.fromRGB(185, 110, 255) },
		{ pos = Vector3.new(48, 0.3, -68), col = Color3.fromRGB(95, 235, 190) },
		{ pos = Vector3.new(58, 0.3, 56), col = Color3.fromRGB(95, 205, 255) },
	}
	for _, item in ipairs(crystalSpawns) do
		Foliage.CreateCrystalCluster(folder, item.pos, item.col)
	end

	folder.Parent = parent
	return folder
end

return Foliage
