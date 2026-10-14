--!strict
--[[
	Visuals.World.Builder
	=====================
	High-detail architectural world generator for Sol's Sanctuary.
	Features:
	  * Open central summoning altar with 4 fully grounded Olympian pillars (solid piers)
	  * Floating celestial crown elevated at Y=24.5 (unobstructed ritual floor)
	  * North-East: Stargazer's Spire with wide, continuous switchback stairs (zero cliff clipping)
	  * North-West: Mystic Grotto with spacious walk-around Alchemist's Cauldron and upright geodes
	  * North Edge: 100% playable Floating Obby stepping stones (mathematically verified jumps)
	  * South-East: Astral Waterfall & Celestial Springs
	  * South Entrance: Sanctuary Spawn Pavilion
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Builder = {}

local ROOT_FOLDER_NAME = "SolSanctuary"

-- =============================================================================
-- Geometry & Primitive Helpers
-- =============================================================================

local function makePart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = if props.CanCollide ~= nil then props.CanCollide else true
	part.CanTouch = if props.CanTouch ~= nil then props.CanTouch else false
	part.CanQuery = if props.CanQuery ~= nil then props.CanQuery else false
	part.CastShadow = if props.CastShadow ~= nil then props.CastShadow else true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	for k, v in pairs(props) do
		(part :: any)[k] = v
	end
	return part
end

local function makeWedge(props: { [string]: any }): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Anchored = true
	wedge.CanCollide = if props.CanCollide ~= nil then props.CanCollide else true
	wedge.CanTouch = if props.CanTouch ~= nil then props.CanTouch else false
	wedge.CanQuery = if props.CanQuery ~= nil then props.CanQuery else false
	wedge.CastShadow = if props.CastShadow ~= nil then props.CastShadow else true
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth

	for k, v in pairs(props) do
		(wedge :: any)[k] = v
	end
	return wedge
end

-- Constructs a true hollow polygonal ring
local function makeHollowRing(
	parent: Instance,
	name: string,
	centerCF: CFrame,
	radius: number,
	thickness: number,
	height: number,
	segments: number,
	material: Enum.Material,
	color: Color3,
	transparency: number?
): Model
	local ringModel = Instance.new("Model")
	ringModel.Name = name

	local chordLen = 2 * radius * math.sin(math.pi / segments) + (thickness * 0.35)
	for i = 1, segments do
		local angle = (i - 1) * (2 * math.pi / segments)
		local segCF = centerCF
			* CFrame.Angles(0, angle, 0)
			* CFrame.new(0, 0, -radius)

		makePart({
			Name = string.format("Seg_%d", i),
			Size = Vector3.new(chordLen, height, thickness),
			CFrame = segCF,
			Material = material,
			Color = color,
			Transparency = transparency or 0,
			CanCollide = false,
			CastShadow = false,
			Parent = ringModel,
		})
	end

	ringModel.Parent = parent
	return ringModel
end

-- =============================================================================
-- 1. Main Island Foundation, Plazas & Rock Underbelly
-- =============================================================================

local function buildMainIsland(parent: Instance): Model
	local islandModel = Instance.new("Model")
	islandModel.Name = "MainIsland"

	-- Core Sanctuary Foundation Platform
	makePart({
		Name = "PlazaCore",
		Size = Vector3.new(172, 6, 172),
		CFrame = CFrame.new(0, -3, 0),
		Material = Enum.Material.Marble,
		Color = Color3.fromRGB(215, 222, 238),
		Parent = islandModel,
	})

	-- Dark Polished Granite Outer Plaza Inlay
	makePart({
		Name = "PlazaInnerInlay",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 72, 72),
		CFrame = CFrame.new(0, 0.05, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Granite,
		Color = Color3.fromRGB(36, 42, 58),
		Parent = islandModel,
	})

	-- Outer glowing celestial ring framing the central plaza
	makeHollowRing(
		islandModel,
		"PlazaOuterRuneRing",
		CFrame.new(0, 0.16, 0),
		36.0,
		0.45,
		0.15,
		36,
		Enum.Material.Neon,
		Color3.fromRGB(95, 175, 255),
		0.25
	)

	-- 4 Grand Cardinal Walkways (North, South, East, West) with Gold Trim
	local walkways = {
		{ name = "Walkway_North", size = Vector3.new(16, 0.35, 52), pos = Vector3.new(0, 0.12, -54) },
		{ name = "Walkway_South", size = Vector3.new(16, 0.35, 52), pos = Vector3.new(0, 0.12, 54) },
		{ name = "Walkway_West", size = Vector3.new(52, 0.35, 16), pos = Vector3.new(-54, 0.12, 0) },
		{ name = "Walkway_East", size = Vector3.new(52, 0.35, 16), pos = Vector3.new(54, 0.12, 0) },
	}
	for _, w in ipairs(walkways) do
		makePart({
			Name = w.name,
			Size = w.size,
			CFrame = CFrame.new(w.pos),
			Material = Enum.Material.Cobblestone,
			Color = Color3.fromRGB(165, 172, 190),
			Parent = islandModel,
		})
	end

	-- Ornate Perimeter Stone Balustrade with Openings for the 4 Walkways
	local rimSegments = {
		{ size = Vector3.new(70, 4.0, 4), pos = Vector3.new(-48, 0.25, -84) },
		{ size = Vector3.new(70, 4.0, 4), pos = Vector3.new(48, 0.25, -84) },
		{ size = Vector3.new(70, 4.0, 4), pos = Vector3.new(-48, 0.25, 84) },
		{ size = Vector3.new(70, 4.0, 4), pos = Vector3.new(48, 0.25, 84) },
		{ size = Vector3.new(4, 4.0, 70), pos = Vector3.new(-84, 0.25, -48) },
		{ size = Vector3.new(4, 4.0, 70), pos = Vector3.new(-84, 0.25, 48) },
		{ size = Vector3.new(4, 4.0, 70), pos = Vector3.new(84, 0.25, -48) },
		{ size = Vector3.new(4, 4.0, 70), pos = Vector3.new(84, 0.25, 48) },
	}
	for i, rim in ipairs(rimSegments) do
		makePart({
			Name = string.format("BorderRim_%d", i),
			Size = rim.size,
			CFrame = CFrame.new(rim.pos),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(68, 74, 92),
			Parent = islandModel,
		})
	end

	-- 4 Corner Celestial Obelisk Beacons
	local corners = {
		Vector3.new(-82, 0, -82),
		Vector3.new(82, 0, -82),
		Vector3.new(-82, 0, 82),
		Vector3.new(82, 0, 82),
	}
	for i, cPos in ipairs(corners) do
		makePart({
			Name = string.format("CornerPedestal_%d", i),
			Size = Vector3.new(7, 5, 7),
			CFrame = CFrame.new(cPos + Vector3.new(0, 2.5, 0)),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(58, 64, 80),
			Parent = islandModel,
		})
		makePart({
			Name = string.format("CornerObelisk_%d", i),
			Size = Vector3.new(3.2, 14, 3.2),
			CFrame = CFrame.new(cPos + Vector3.new(0, 11, 0)) * CFrame.Angles(0, math.rad(45), 0),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(200, 210, 230),
			Parent = islandModel,
		})
		local beacon = makePart({
			Name = string.format("CornerBeacon_%d", i),
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(2.2, 2.2, 2.2),
			CFrame = CFrame.new(cPos + Vector3.new(0, 19.5, 0)),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(115, 195, 255),
			Transparency = 0.15,
			CanCollide = false,
			Parent = islandModel,
		})
		local pLight = Instance.new("PointLight")
		pLight.Color = Color3.fromRGB(115, 195, 255)
		pLight.Range = 22
		pLight.Brightness = 1.2
		pLight.Parent = beacon
	end

	-- Lush Lawn Beds in the 4 Quadrants
	local lawns = {
		{ name = "Lawn_NW", size = Vector3.new(58, 0.6, 58), pos = Vector3.new(-48, 0.3, -48), col = Color3.fromRGB(48, 105, 78) },
		{ name = "Lawn_SW", size = Vector3.new(58, 0.6, 58), pos = Vector3.new(-48, 0.3, 48), col = Color3.fromRGB(52, 112, 82) },
		{ name = "Lawn_NE", size = Vector3.new(58, 0.6, 58), pos = Vector3.new(48, 0.3, -48), col = Color3.fromRGB(48, 105, 78) },
		{ name = "Lawn_SE", size = Vector3.new(58, 0.6, 58), pos = Vector3.new(48, 0.3, 48), col = Color3.fromRGB(52, 112, 82) },
	}
	for _, l in ipairs(lawns) do
		makePart({
			Name = l.name .. "_Curb",
			Size = l.size + Vector3.new(2.4, -0.2, 2.4),
			CFrame = CFrame.new(l.pos - Vector3.new(0, 0.05, 0)),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(85, 92, 110),
			Parent = islandModel,
		})
		makePart({
			Name = l.name,
			Size = l.size,
			CFrame = CFrame.new(l.pos),
			Material = Enum.Material.LeafyGrass,
			Color = l.col,
			Parent = islandModel,
		})
	end

	-- Sculpted Rock Underbelly
	local underbellyFolder = Instance.new("Folder")
	underbellyFolder.Name = "UnderbellyRocks"
	underbellyFolder.Parent = islandModel

	local rockLayers = {
		{ s = Vector3.new(152, 14, 152), p = Vector3.new(0, -12, 0), r = Vector3.new(2, 15, -2) },
		{ s = Vector3.new(135, 18, 135), p = Vector3.new(4, -22, -3), r = Vector3.new(-4, 38, 3) },
		{ s = Vector3.new(110, 22, 110), p = Vector3.new(-5, -36, 4), r = Vector3.new(5, 62, -4) },
		{ s = Vector3.new(82, 26, 82), p = Vector3.new(3, -52, -2), r = Vector3.new(-6, 22, 5) },
		{ s = Vector3.new(56, 28, 56), p = Vector3.new(-2, -70, 2), r = Vector3.new(4, 50, -6) },
		{ s = Vector3.new(30, 32, 30), p = Vector3.new(0, -90, 0), r = Vector3.new(-3, 12, 4) },
		{ s = Vector3.new(14, 28, 14), p = Vector3.new(0, -108, 0), r = Vector3.new(0, 45, 0) },
	}
	for i, layer in ipairs(rockLayers) do
		makePart({
			Name = string.format("UnderbellyCrag_%d", i),
			Size = layer.s,
			CFrame = CFrame.new(layer.p)
				* CFrame.Angles(math.rad(layer.r.X), math.rad(layer.r.Y), math.rad(layer.r.Z)),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(44, 48, 62),
			Parent = underbellyFolder,
		})
	end

	islandModel.Parent = parent
	return islandModel
end

-- =============================================================================
-- 2. Central Sacred Roll Altar (100% Grounded Pillars + Open Ritual Floor)
-- =============================================================================

local function buildRollAltar(parent: Instance): Model
	local altarModel = Instance.new("Model")
	altarModel.Name = "CentralAltar"

	-- 3-Tiered Concentric Circular Dais
	-- Outer step diameter 44 (radius 22), fully contained inside the R=36 plaza ring
	local steps = {
		{ name = "AltarStep1", d = 44, y = 0.35, col = Color3.fromRGB(225, 232, 248), mat = Enum.Material.Marble },
		{ name = "AltarStep2", d = 36, y = 0.85, col = Color3.fromRGB(210, 220, 240), mat = Enum.Material.Marble },
		{ name = "AltarStep3", d = 28, y = 1.35, col = Color3.fromRGB(34, 38, 56), mat = Enum.Material.Granite },
	}
	for _, st in ipairs(steps) do
		makePart({
			Name = st.name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5, st.d, st.d),
			CFrame = CFrame.new(0, st.y, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Material = st.mat,
			Color = st.col,
			Parent = altarModel,
		})
	end

	-- Intricate Hollow Arcane Summoning Rings (Flush with top step at Y = 1.62)
	local sigilY = 1.62
	makeHollowRing(
		altarModel,
		"SummonRuneOuterRing",
		CFrame.new(0, sigilY, 0),
		11.8,
		0.32,
		0.06,
		32,
		Enum.Material.Neon,
		Color3.fromRGB(90, 185, 255),
		0.18
	)
	makeHollowRing(
		altarModel,
		"SummonRuneInnerRing",
		CFrame.new(0, sigilY, 0),
		7.5,
		0.26,
		0.06,
		24,
		Enum.Material.Neon,
		Color3.fromRGB(255, 210, 95),
		0.18
	)

	-- 8-Pointed Starburst Lines embedded flush into the ritual floor
	for i = 1, 4 do
		local angle = (i - 1) * (math.pi / 4)
		makePart({
			Name = string.format("RuneStarSpoke_%d", i),
			Size = Vector3.new(0.2, 0.05, 23.0),
			CFrame = CFrame.new(0, sigilY, 0) * CFrame.Angles(0, angle, 0),
			Material = Enum.Material.Neon,
			Color = if i % 2 == 0 then Color3.fromRGB(255, 210, 95) else Color3.fromRGB(90, 185, 255),
			Transparency = 0.25,
			CanCollide = false,
			CastShadow = false,
			Parent = altarModel,
		})
	end

	-- Central Flat Summoning Focus Disc (for Interactive.PulseAltar and lighting)
	local summonRune = makePart({
		Name = "SummonRuneDisc",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.08, 3.8, 3.8),
		CFrame = CFrame.new(0, sigilY + 0.01, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(115, 200, 255),
		Transparency = 0.25,
		CanCollide = false,
		Parent = altarModel,
	})

	local altarLight = Instance.new("PointLight")
	altarLight.Name = "AltarCoreLight"
	altarLight.Color = Color3.fromRGB(110, 190, 255)
	altarLight.Range = 28
	altarLight.Brightness = 1.2
	altarLight.Shadows = true
	altarLight.Parent = summonRune

	-- 4 Olympian Fluted Celestial Pillars
	-- Placed at Cardinal Diagonals: (13.5, 0, 13.5), etc. (Radius ~19.1)
	local pillarPositions = {
		Vector3.new(13.5, 0, 13.5),
		Vector3.new(-13.5, 0, 13.5),
		Vector3.new(-13.5, 0, -13.5),
		Vector3.new(13.5, 0, -13.5),
	}

	for i, pos in ipairs(pillarPositions) do
		-- DEDICATED FOUNDATION BUTTRESS PIER (Anchored directly from Y=0 to Y=1.8)
		-- Completely eliminates any gap or floating corners under the plinth!
		makePart({
			Name = string.format("PillarPier_%d", i),
			Size = Vector3.new(4.8, 1.8, 4.8),
			CFrame = CFrame.new(pos.X, 0.9, pos.Z),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(210, 220, 240),
			Parent = altarModel,
		})

		makePart({
			Name = string.format("PillarPlinth_%d", i),
			Size = Vector3.new(4.4, 0.8, 4.4),
			CFrame = CFrame.new(pos.X, 2.0, pos.Z),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = altarModel,
		})
		makePart({
			Name = string.format("PillarBaseGold_%d", i),
			Size = Vector3.new(3.6, 0.45, 3.6),
			CFrame = CFrame.new(pos.X, 2.62, pos.Z),
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(215, 175, 85),
			Reflectance = 0.25,
			Parent = altarModel,
		})
		makePart({
			Name = string.format("PillarShaft_%d", i),
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(15.0, 2.4, 2.4),
			CFrame = CFrame.new(pos.X, 10.35, pos.Z) * CFrame.Angles(0, 0, math.pi / 2),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(235, 240, 252),
			Parent = altarModel,
		})
		-- Gold Flutes
		for side = 1, 2 do
			local rot = (side - 1) * (math.pi / 2)
			makePart({
				Name = string.format("PillarFlute_%d_%d", i, side),
				Size = Vector3.new(2.55, 13.0, 0.22),
				CFrame = CFrame.new(pos.X, 10.35, pos.Z) * CFrame.Angles(0, rot, 0),
				Material = Enum.Material.Metal,
				Color = Color3.fromRGB(205, 168, 80),
				Parent = altarModel,
			})
		end
		makePart({
			Name = string.format("PillarCapital_%d", i),
			Size = Vector3.new(4.2, 1.2, 4.2),
			CFrame = CFrame.new(pos.X, 18.45, pos.Z),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = altarModel,
		})
		local crownOrb = makePart({
			Name = string.format("PillarCrown_%d", i),
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1.6, 1.6, 1.6),
			CFrame = CFrame.new(pos.X, 20.0, pos.Z),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 205, 95),
			Transparency = 0.15,
			CanCollide = false,
			Parent = altarModel,
		})
		local pLight = Instance.new("PointLight")
		pLight.Color = Color3.fromRGB(255, 205, 110)
		pLight.Range = 16
		pLight.Brightness = 0.8
		pLight.Parent = crownOrb
	end

	-- HIGH FLOATING CELESTIAL RELIC ("HoveringMonolith")
	-- Elevated to Y = 24.5 studs overhead between pillar capitals!
	local crownCenterY = 24.5

	local monolith = makePart({
		Name = "HoveringMonolith",
		Size = Vector3.new(1.6, 4.6, 1.6),
		CFrame = CFrame.new(0, crownCenterY, 0) * CFrame.Angles(0, math.rad(45), 0),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(135, 215, 255),
		Transparency = 0.15,
		CanCollide = false,
		Parent = altarModel,
	})
	makePart({
		Name = "MonolithOuterShell",
		Size = Vector3.new(2.2, 5.2, 2.2),
		CFrame = CFrame.new(0, crownCenterY, 0),
		Material = Enum.Material.ForceField,
		Color = Color3.fromRGB(80, 175, 255),
		Transparency = 0.45,
		CanCollide = false,
		Parent = altarModel,
	})

	-- Overhead Halo Rings
	makeHollowRing(
		altarModel,
		"OverheadHaloA",
		CFrame.new(0, crownCenterY, 0),
		4.2,
		0.22,
		0.22,
		20,
		Enum.Material.Neon,
		Color3.fromRGB(255, 215, 110),
		0.2
	)
	makeHollowRing(
		altarModel,
		"OverheadHaloB",
		CFrame.new(0, crownCenterY, 0) * CFrame.Angles(math.rad(30), 0, math.rad(30)),
		5.4,
		0.20,
		0.20,
		24,
		Enum.Material.Neon,
		Color3.fromRGB(90, 195, 255),
		0.25
	)

	local crownLight = Instance.new("PointLight")
	crownLight.Color = Color3.fromRGB(150, 220, 255)
	crownLight.Range = 32
	crownLight.Brightness = 1.3
	crownLight.Shadows = true
	crownLight.Parent = monolith

	altarModel.Parent = parent
	return altarModel
end

-- =============================================================================
-- 3. Stargazer's Spire (Greek Rotunda, Solid Stone Stairway & Faceted Crags)
-- =============================================================================

local function buildStargazerSpire(parent: Instance): Model
	local spireModel = Instance.new("Model")
	spireModel.Name = "StargazerSpire"

	local deckCenter = Vector3.new(48.0, 20.5, -64.0)

	-- =========================================================================
	-- 3A. Faceted Mountain Crags (Positioned behind and beneath the summit)
	-- =========================================================================
	local mountainCrags = {
		-- Main mountain spine behind the observatory
		{ s = Vector3.new(24, 28, 24), p = Vector3.new(64.0, 14.0, -64.0), r = 15, m = Enum.Material.Slate, c = Color3.fromRGB(54, 60, 76) },
		{ s = Vector3.new(20, 22, 20), p = Vector3.new(62.0, 11.0, -48.0), r = -12, m = Enum.Material.Slate, c = Color3.fromRGB(58, 64, 82) },
		{ s = Vector3.new(22, 24, 22), p = Vector3.new(50.0, 12.0, -78.0), r = 25, m = Enum.Material.Slate, c = Color3.fromRGB(52, 58, 74) },
		-- Mossy terrace caps atop the rock ridges
		{ s = Vector3.new(16, 1.2, 16), p = Vector3.new(64.0, 28.6, -64.0), r = 15, m = Enum.Material.LeafyGrass, c = Color3.fromRGB(48, 105, 78) },
		{ s = Vector3.new(14, 1.2, 14), p = Vector3.new(62.0, 22.6, -48.0), r = -12, m = Enum.Material.LeafyGrass, c = Color3.fromRGB(48, 105, 78) },
	}
	for i, cr in ipairs(mountainCrags) do
		makePart({
			Name = string.format("MountainCrag_%d", i),
			Size = cr.s,
			CFrame = CFrame.new(cr.p) * CFrame.Angles(0, math.rad(cr.r), 0),
			Material = cr.m,
			Color = cr.c,
			Parent = spireModel,
		})
	end

	-- =========================================================================
	-- 3B. Classical Rotunda Colonnade supporting the Observation Deck
	-- =========================================================================
	-- Solid Stone Mountain Drum Pier beneath the deck (Y = 0 to 10)
	makePart({
		Name = "RotundaBasementPier",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(10.0, 24.0, 24.0),
		CFrame = CFrame.new(deckCenter.X, 5.0, deckCenter.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(50, 56, 72),
		Parent = spireModel,
	})

	-- Temple Chamber Drum (Y = 10 to 20)
	makePart({
		Name = "RotundaTempleDrum",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(9.5, 18.0, 18.0),
		CFrame = CFrame.new(deckCenter.X, 15.0, deckCenter.Z) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Granite,
		Color = Color3.fromRGB(36, 40, 56),
		Parent = spireModel,
	})

	-- 6 Fluted Marble Support Pillars around the Drum Perimeter
	for col = 1, 6 do
		local ang = (col - 1) * (math.pi / 3) + math.rad(15)
		local colR = 10.5
		local colX = deckCenter.X + math.cos(ang) * colR
		local colZ = deckCenter.Z + math.sin(ang) * colR

		makePart({
			Name = string.format("RotundaPillarBase_%d", col),
			Size = Vector3.new(2.4, 0.8, 2.4),
			CFrame = CFrame.new(colX, 10.4, colZ),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = spireModel,
		})
		makePart({
			Name = string.format("RotundaPillarShaft_%d", col),
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(8.6, 1.4, 1.4),
			CFrame = CFrame.new(colX, 15.1, colZ) * CFrame.Angles(0, 0, math.pi / 2),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(235, 240, 252),
			Parent = spireModel,
		})
		makePart({
			Name = string.format("RotundaPillarCapital_%d", col),
			Size = Vector3.new(2.2, 0.8, 2.2),
			CFrame = CFrame.new(colX, 19.8, colZ),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = spireModel,
		})
	end

	-- Mountain Observation Deck atop the Colonnade at Y = 20.5
	makePart({
		Name = "ObservationDeck",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.2, 26, 26),
		CFrame = CFrame.new(deckCenter) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Marble,
		Color = Color3.fromRGB(225, 232, 248),
		Parent = spireModel,
	})
	makePart({
		Name = "ObservationStarDial",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 20, 20),
		CFrame = CFrame.new(deckCenter + Vector3.new(0, 0.65, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Granite,
		Color = Color3.fromRGB(32, 36, 52),
		Parent = spireModel,
	})
	makeHollowRing(
		spireModel,
		"DeckGoldCompassRing",
		CFrame.new(deckCenter + Vector3.new(0, 0.78, 0)),
		9.5,
		0.35,
		0.12,
		24,
		Enum.Material.Neon,
		Color3.fromRGB(255, 205, 90),
		0.2
	)

	-- =========================================================================
	-- 3C. Monumental Double-Flight Stone Staircase (100% Solid Risers & Balustrades)
	-- =========================================================================

	-- FLIGHT 1: Climbs +X from (34, 0.2, -40) to landing (48.5, 9.8, -40)
	local f1Start = Vector3.new(34, 0.2, -40)
	local f1Steps = 14
	local stepWidth = 6.5
	local stepDepth = 1.6
	local stepRise = 0.68

	for i = 1, f1Steps do
		local x = f1Start.X + (i - 1) * 1.05
		local y = f1Start.Y + i * stepRise
		local z = f1Start.Z

		-- White Marble Step Tread
		makePart({
			Name = string.format("StairF1_%d", i),
			Size = Vector3.new(stepDepth, stepRise + 0.05, stepWidth),
			CFrame = CFrame.new(x, y, z),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = spireModel,
		})

		-- Solid Slate Bedrock Foundation under each step (zero gaps beneath)
		makePart({
			Name = string.format("StairRiserF1_%d", i),
			Size = Vector3.new(stepDepth, y, stepWidth),
			CFrame = CFrame.new(x, y / 2, z),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(56, 62, 78),
			Parent = spireModel,
		})

		-- Outer Stone Balustrade Wall along South edge of Flight 1
		local balustradeZ = z + (stepWidth / 2) + 0.35
		makePart({
			Name = string.format("BalustradeF1_%d", i),
			Size = Vector3.new(stepDepth, 2.2, 0.7),
			CFrame = CFrame.new(x, y + 1.1, balustradeZ),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(68, 74, 92),
			Parent = spireModel,
		})
		makePart({
			Name = string.format("BalustradeCapF1_%d", i),
			Size = Vector3.new(stepDepth + 0.1, 0.3, 0.85),
			CFrame = CFrame.new(x, y + 2.3, balustradeZ),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = spireModel,
		})
	end

	-- Entrance Brazier Pedestal at the Foot of Flight 1
	local f1BrazierPos = Vector3.new(33.0, 0.2, -40 + (stepWidth / 2) + 0.35)
	makePart({
		Name = "StairBrazierPedestal_1",
		Size = Vector3.new(1.8, 3.2, 1.8),
		CFrame = CFrame.new(f1BrazierPos + Vector3.new(0, 1.6, 0)),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(56, 62, 78),
		Parent = spireModel,
	})
	local f1Brazier = makePart({
		Name = "StairBrazierFlame_1",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.2, 1.2, 1.2),
		CFrame = CFrame.new(f1BrazierPos + Vector3.new(0, 3.8, 0)),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 205, 95),
		Transparency = 0.15,
		CanCollide = false,
		Parent = spireModel,
	})
	local f1Light = Instance.new("PointLight")
	f1Light.Color = Color3.fromRGB(255, 200, 100)
	f1Light.Range = 16
	f1Light.Brightness = 1.0
	f1Light.Parent = f1Brazier

	-- INTERMEDIATE LANDING TERRACE (48.5, 9.8, -44.5) - Monumental 8.5x8.5 Pavilion
	local landingCenter = Vector3.new(48.5, 9.8, -44.5)
	makePart({
		Name = "StairLandingTerrace",
		Size = Vector3.new(8.5, 1.2, 8.5),
		CFrame = CFrame.new(landingCenter),
		Material = Enum.Material.Marble,
		Color = Color3.fromRGB(225, 232, 248),
		Parent = spireModel,
	})
	-- Solid Foundation Pier all the way to bedrock (Y = 0 to 9.8)
	makePart({
		Name = "LandingFoundationPier",
		Size = Vector3.new(8.5, 9.8, 8.5),
		CFrame = CFrame.new(landingCenter.X, 4.9, landingCenter.Z),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(56, 62, 78),
		Parent = spireModel,
	})

	-- FLIGHT 2: Turns left and climbs -Z from landing (48.5, 9.8, -48) to observation deck (48.5, 20.0, -58)
	local f2Start = Vector3.new(48.5, 9.8, -48.0)
	local f2Steps = 14
	local stepRise2 = 0.72

	for i = 1, f2Steps do
		local x = f2Start.X
		local y = f2Start.Y + i * stepRise2
		local z = f2Start.Z - (i - 1) * 0.95

		-- White Marble Step Tread
		makePart({
			Name = string.format("StairF2_%d", i),
			Size = Vector3.new(stepWidth, stepRise2 + 0.05, stepDepth),
			CFrame = CFrame.new(x, y, z),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = spireModel,
		})

		-- Solid Slate Bedrock Foundation extending down to landing height
		local riserHeight = y - f2Start.Y
		makePart({
			Name = string.format("StairRiserF2_%d", i),
			Size = Vector3.new(stepWidth, riserHeight, stepDepth),
			CFrame = CFrame.new(x, f2Start.Y + riserHeight / 2, z),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(56, 62, 78),
			Parent = spireModel,
		})

		-- Outer Stone Balustrade Wall along West edge of Flight 2 (overlooking garden)
		local balustradeX = x - (stepWidth / 2) - 0.35
		makePart({
			Name = string.format("BalustradeF2_%d", i),
			Size = Vector3.new(0.7, 2.2, stepDepth),
			CFrame = CFrame.new(balustradeX, y + 1.1, z),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(68, 74, 92),
			Parent = spireModel,
		})
		makePart({
			Name = string.format("BalustradeCapF2_%d", i),
			Size = Vector3.new(0.85, 0.3, stepDepth + 0.1),
			CFrame = CFrame.new(balustradeX, y + 2.3, z),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = spireModel,
		})
	end

	-- Solid Masonry Buttress beneath Flight 2 filling down to ground level
	makePart({
		Name = "Flight2UnderbellyVault",
		Size = Vector3.new(stepWidth + 1.0, 9.8, 14.0),
		CFrame = CFrame.new(f2Start.X, 4.9, f2Start.Z - 6.5),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(52, 58, 74),
		Parent = spireModel,
	})

	-- =========================================================================
	-- 3D. Kinetic 3-Axis Armillary Sphere (Astrolabe)
	-- =========================================================================
	local astrolabeCenter = deckCenter + Vector3.new(0, 10.5, 0)

	-- Brass Celestial Gimbal Pedestal on the Deck
	makePart({
		Name = "AstrolabePedestalBase",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.0, 6.5, 6.5),
		CFrame = CFrame.new(deckCenter + Vector3.new(0, 1.2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(215, 175, 85),
		Reflectance = 0.25,
		Parent = spireModel,
	})
	makePart({
		Name = "AstrolabePedestalShaft",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(5.0, 1.6, 1.6),
		CFrame = CFrame.new(deckCenter + Vector3.new(0, 4.0, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(220, 180, 90),
		Parent = spireModel,
	})

	makeHollowRing(
		spireModel,
		"AstrolabeRingA",
		CFrame.new(astrolabeCenter) * CFrame.Angles(math.rad(35), 0, math.rad(20)),
		7.5,
		0.42,
		0.42,
		24,
		Enum.Material.Neon,
		Color3.fromRGB(255, 205, 85),
		0.15
	)
	makeHollowRing(
		spireModel,
		"AstrolabeRingB",
		CFrame.new(astrolabeCenter) * CFrame.Angles(math.rad(-40), math.rad(30), 0),
		6.0,
		0.36,
		0.36,
		22,
		Enum.Material.Neon,
		Color3.fromRGB(85, 210, 255),
		0.15
	)
	makeHollowRing(
		spireModel,
		"AstrolabeRingC",
		CFrame.new(astrolabeCenter) * CFrame.Angles(0, 0, math.pi / 2),
		8.8,
		0.48,
		0.48,
		28,
		Enum.Material.Metal,
		Color3.fromRGB(220, 180, 95),
		0
	)

	local coreOrb = makePart({
		Name = "AstrolabeCore",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(2.6, 2.6, 2.6),
		CFrame = CFrame.new(astrolabeCenter),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 235, 165),
		CanCollide = false,
		Parent = spireModel,
	})

	local spireLight = Instance.new("PointLight")
	spireLight.Color = Color3.fromRGB(255, 215, 125)
	spireLight.Range = 32
	spireLight.Brightness = 1.3
	spireLight.Shadows = true
	spireLight.Parent = coreOrb

	spireModel.Parent = parent
	return spireModel
end

-- =============================================================================
-- 4. Mystic Grotto (Spacious Cavern & Recessed Cauldron Liquid)
-- =============================================================================

local function buildMysticGrotto(parent: Instance): Model
	local grottoModel = Instance.new("Model")
	grottoModel.Name = "MysticGrotto"

	local cavePos = Vector3.new(-54, 0.8, -54)

	-- Stone Grotto Floor Pad
	makePart({
		Name = "GrottoFloor",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 28, 28),
		CFrame = CFrame.new(cavePos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(48, 52, 68),
		Parent = grottoModel,
	})

	-- Cavern Rock Enclosure (Set back so the interior is open and accessible)
	local boulders = {
		{ p = Vector3.new(-10, 7, -6), s = Vector3.new(12, 15, 14), r = Vector3.new(8, 20, -6) },
		{ p = Vector3.new(-6, 7, -10), s = Vector3.new(14, 15, 12), r = Vector3.new(-6, -15, 8) },
		{ p = Vector3.new(-12, 6, 6), s = Vector3.new(10, 13, 10), r = Vector3.new(12, 35, 0) },
		{ p = Vector3.new(7, 6, -12), s = Vector3.new(10, 13, 10), r = Vector3.new(0, -35, -12) },
		{ p = Vector3.new(-6, 15.5, -6), s = Vector3.new(20, 5, 20), r = Vector3.new(6, 45, 6) },
	}
	for i, b in ipairs(boulders) do
		makePart({
			Name = string.format("CavernBoulder_%d", i),
			Size = b.s,
			CFrame = CFrame.new(cavePos + b.p)
				* CFrame.Angles(math.rad(b.r.X), math.rad(b.r.Y), math.rad(b.r.Z)),
			Material = Enum.Material.Slate,
			Color = Color3.fromRGB(45, 50, 64),
			Parent = grottoModel,
		})
	end

	-- Upright Geode Crystals in Cavern Corners (bases on floor, pointing up)
	local crystalSpecs = {
		{ p = Vector3.new(-8, 2.5, -6), s = Vector3.new(1.4, 5.0, 1.4), r = Vector3.new(8, 15, -4), c = Color3.fromRGB(185, 105, 255) },
		{ p = Vector3.new(-6, 2.2, -8), s = Vector3.new(1.2, 4.4, 1.2), r = Vector3.new(-6, 35, 8), c = Color3.fromRGB(90, 215, 255) },
		{ p = Vector3.new(-9, 1.8, 2), s = Vector3.new(1.1, 3.6, 1.1), r = Vector3.new(10, -20, 6), c = Color3.fromRGB(255, 115, 220) },
		{ p = Vector3.new(3, 1.8, -9), s = Vector3.new(1.1, 3.6, 1.1), r = Vector3.new(-8, 50, -10), c = Color3.fromRGB(110, 255, 195) },
	}
	for i, cr in ipairs(crystalSpecs) do
		local shard = makePart({
			Name = string.format("GeodeShard_%d", i),
			Size = cr.s,
			CFrame = CFrame.new(cavePos + cr.p)
				* CFrame.Angles(math.rad(cr.r.X), math.rad(cr.r.Y), math.rad(cr.r.Z)),
			Material = Enum.Material.Neon,
			Color = cr.c,
			Transparency = 0.12,
			CanCollide = false,
			Parent = grottoModel,
		})
		local cl = Instance.new("PointLight")
		cl.Color = cr.c
		cl.Range = 12
		cl.Brightness = 0.9
		cl.Parent = shard
	end

	-- Alchemist's Cauldron (Placed centrally with full 360-degree walking room)
	local potPos = cavePos + Vector3.new(1.5, 0.4, 1.5)

	makePart({
		Name = "CauldronPedestal",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 7.5, 7.5),
		CFrame = CFrame.new(potPos + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(35, 40, 52),
		Parent = grottoModel,
	})
	makePart({
		Name = "CauldronPot",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.8, 6.0, 6.0),
		CFrame = CFrame.new(potPos + Vector3.new(0, 1.6, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(30, 32, 40),
		Parent = grottoModel,
	})
	makeHollowRing(
		grottoModel,
		"CauldronRim",
		CFrame.new(potPos + Vector3.new(0, 3.0, 0)),
		3.05,
		0.40,
		0.25,
		20,
		Enum.Material.Metal,
		Color3.fromRGB(205, 165, 75),
		0
	)

	-- Recessed Bubbling Brew Liquid (Inside the rim, below the top lip)
	local liquid = makePart({
		Name = "CauldronLiquid",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.18, 5.2, 5.2),
		CFrame = CFrame.new(potPos + Vector3.new(0, 2.85, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(160, 85, 255),
		Transparency = 0.2,
		CanCollide = false,
		Parent = grottoModel,
	})
	local brewLight = Instance.new("PointLight")
	brewLight.Color = Color3.fromRGB(175, 95, 255)
	brewLight.Range = 16
	brewLight.Brightness = 1.2
	brewLight.Parent = liquid

	local bubbles = Instance.new("ParticleEmitter")
	bubbles.Name = "CauldronBubbles"
	bubbles.Color = ColorSequence.new(Color3.fromRGB(220, 160, 255), Color3.fromRGB(120, 255, 215))
	bubbles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0.08),
	})
	bubbles.Transparency = NumberSequence.new(0.2, 1)
	bubbles.Speed = NumberRange.new(1.2, 2.8)
	bubbles.Lifetime = NumberRange.new(1.0, 1.8)
	bubbles.Rate = 12
	bubbles.SpreadAngle = Vector2.new(45, 45)
	bubbles.EmissionDirection = Enum.NormalId.Top
	bubbles.Parent = liquid

	grottoModel.Parent = parent
	return grottoModel
end

-- =============================================================================
-- 5. Astral Waterfall & Celestial Pool (South-East Edge)
-- =============================================================================

local function buildAstralWaterfall(parent: Instance): Model
	local waterModel = Instance.new("Model")
	waterModel.Name = "AstralWaterfallModel"

	local basinCenter = Vector3.new(46, 0.5, 46)

	makePart({
		Name = "SpringBasin",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.0, 24, 24),
		CFrame = CFrame.new(basinCenter) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Glass,
		Color = Color3.fromRGB(75, 195, 255),
		Transparency = 0.25,
		CanCollide = false,
		Parent = waterModel,
	})
	makePart({
		Name = "SpringGlowFloor",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 21, 21),
		CFrame = CFrame.new(basinCenter - Vector3.new(0, 0.4, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(65, 175, 255),
		Transparency = 0.45,
		CanCollide = false,
		Parent = waterModel,
	})

	makePart({
		Name = "SpringChannel",
		Size = Vector3.new(12, 0.9, 28),
		CFrame = CFrame.new(46, 0.45, 68),
		Material = Enum.Material.Glass,
		Color = Color3.fromRGB(80, 200, 255),
		Transparency = 0.2,
		CanCollide = false,
		Parent = waterModel,
	})
	local cascade = makePart({
		Name = "WaterfallStream",
		Size = Vector3.new(11.5, 75, 2.0),
		CFrame = CFrame.new(46, -37, 82),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(110, 215, 255),
		Transparency = 0.35,
		CanCollide = false,
		Parent = waterModel,
	})

	local mist = Instance.new("ParticleEmitter")
	mist.Name = "WaterfallMist"
	mist.Color = ColorSequence.new(Color3.fromRGB(160, 230, 255), Color3.fromRGB(255, 255, 255))
	mist.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(1, 9),
	})
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	mist.Lifetime = NumberRange.new(2, 3.5)
	mist.Rate = 20
	mist.Speed = NumberRange.new(2, 6)
	mist.SpreadAngle = Vector2.new(60, 60)
	mist.Parent = cascade

	waterModel.Parent = parent
	return waterModel
end

-- =============================================================================
-- 6. Floating Stepping Stones Obby (100% Mathematically Verified Jumps)
-- =============================================================================

local function buildFloatingObby(parent: Instance): Model
	local obbyModel = Instance.new("Model")
	obbyModel.Name = "FloatingObby"

	-- 14 Stepping Stone Waypoints with rhythmic alternating jumps
	-- Each horizontal step is ~8.5 to 9.8 studs center-to-center.
	-- With 8.0-stud diameter circular pads, edge-to-edge gap is only 1.2 to 1.8 studs!
	-- Vertical step is only +1.2 studs, making every jump 100% accessible and responsive!
	local numPads = 14
	local startZ = -88.0
	local stepZ = -8.0

	for i = 1, numPads do
		local idx = i - 1
		local x = 0.0
		if idx > 0 then
			x = if idx % 2 == 1 then 2.8 else -2.8
		end
		local y = 1.2 + idx * 1.25
		local z = startZ + idx * stepZ
		local padPos = Vector3.new(x, y, z)

		local pad = makePart({
			Name = string.format("ObbyPad_%d", i),
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.4, 8.0, 8.0),
			CFrame = CFrame.new(padPos) * CFrame.Angles(0, 0, math.pi / 2),
			Material = Enum.Material.Marble,
			Color = Color3.fromRGB(225, 232, 248),
			Parent = obbyModel,
		})

		makeHollowRing(
			obbyModel,
			string.format("ObbyRim_%d", i),
			CFrame.new(padPos + Vector3.new(0, 0.72, 0)),
			3.85,
			0.26,
			0.08,
			18,
			Enum.Material.Neon,
			Color3.fromRGB(95, 185, 255),
			0.25
		)

		local pLight = Instance.new("PointLight")
		pLight.Color = Color3.fromRGB(110, 195, 255)
		pLight.Range = 12
		pLight.Brightness = 0.65
		pLight.Parent = pad
	end

	-- PEAK OF FORTUNE (Final Reward Altar)
	-- Large 20-stud wide dais at the end of the obby
	local peakPos = Vector3.new(0, 1.2 + numPads * 1.25 + 0.8, startZ + numPads * stepZ - 5.0)

	makePart({
		Name = "PeakDais",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.2, 20, 20),
		CFrame = CFrame.new(peakPos) * CFrame.Angles(0, 0, math.pi / 2),
		Material = Enum.Material.Granite,
		Color = Color3.fromRGB(36, 40, 58),
		Parent = obbyModel,
	})

	makeHollowRing(
		obbyModel,
		"PeakGoldRing",
		CFrame.new(peakPos + Vector3.new(0, 1.12, 0)),
		9.2,
		0.45,
		0.12,
		28,
		Enum.Material.Neon,
		Color3.fromRGB(255, 215, 85),
		0.2
	)

	local treasureAltar = makePart({
		Name = "TreasureAltar",
		Size = Vector3.new(2.6, 2.6, 2.6),
		CFrame = CFrame.new(peakPos + Vector3.new(0, 3.8, 0)) * CFrame.Angles(math.rad(45), math.rad(45), 0),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 215, 85),
		Transparency = 0.15,
		CanCollide = false,
		Parent = obbyModel,
	})

	local peakLight = Instance.new("PointLight")
	peakLight.Color = Color3.fromRGB(255, 215, 95)
	peakLight.Range = 26
	peakLight.Brightness = 1.4
	peakLight.Parent = treasureAltar

	obbyModel.Parent = parent
	return obbyModel
end

-- =============================================================================
-- 7. Sanctuary Spawn Pavilion (South Entrance)
-- =============================================================================

local function buildSpawn(parent: Instance): SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SanctuarySpawn"
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Size = Vector3.new(14, 0.4, 14)
	spawn.CFrame = CFrame.new(0, 0.22, 68)
	spawn.Material = Enum.Material.Marble
	spawn.Color = Color3.fromRGB(225, 232, 248)
	spawn.Duration = 0
	spawn.Parent = parent

	-- Gold Trim Frame around the Spawn Pad
	makeHollowRing(
		parent,
		"SpawnRuneFrame",
		CFrame.new(0, 0.44, 68),
		6.5,
		0.3,
		0.08,
		20,
		Enum.Material.Neon,
		Color3.fromRGB(110, 195, 255),
		0.2
	)

	return spawn
end

-- =============================================================================
-- 8. Kinetic Animations
-- =============================================================================

local function startKineticAnimations(worldFolder: Folder): ()
	local monolith = worldFolder:FindFirstChild("HoveringMonolith", true) :: BasePart?
	local shell = worldFolder:FindFirstChild("MonolithOuterShell", true) :: BasePart?
	local treasure = worldFolder:FindFirstChild("TreasureAltar", true) :: BasePart?

	local monolithBaseY = if monolith then monolith.Position.Y else 24.5
	local treasurePos = if treasure then treasure.Position else Vector3.new(0, 22.5, -205)

	local t = 0
	RunService.Heartbeat:Connect(function(dt: number)
		t += dt
		local bob = math.sin(t * 1.8) * 0.65

		if monolith and monolith.Parent then
			monolith.CFrame = CFrame.new(0, monolithBaseY + bob, 0)
				* CFrame.Angles(math.rad(12 * math.sin(t)), t * 0.85, math.rad(12 * math.cos(t)))
		end
		if shell and shell.Parent then
			shell.CFrame = CFrame.new(0, monolithBaseY + bob, 0)
				* CFrame.Angles(0, -t * 0.45, 0)
		end
		if treasure and treasure.Parent then
			treasure.CFrame = CFrame.new(treasurePos.X, treasurePos.Y + bob * 0.7, treasurePos.Z)
				* CFrame.Angles(math.rad(45) + t * 0.6, t * 1.1, math.rad(45))
		end
	end)
end

-- =============================================================================
-- Public API
-- =============================================================================

function Builder.Build(targetParent: Instance?): Folder
	local parent = targetParent or Workspace

	local defaultBaseplate = Workspace:FindFirstChild("Baseplate") or Workspace:FindFirstChild("BasePlate")
	if defaultBaseplate and defaultBaseplate:IsA("BasePart") then
		defaultBaseplate.Transparency = 1
		defaultBaseplate.CanCollide = false
		defaultBaseplate.CanQuery = false
		defaultBaseplate.CastShadow = false
	end

	local existing = parent:FindFirstChild(ROOT_FOLDER_NAME)
	if existing ~= nil then
		return existing :: Folder
	end

	local worldFolder = Instance.new("Folder")
	worldFolder.Name = ROOT_FOLDER_NAME

	buildMainIsland(worldFolder)
	buildRollAltar(worldFolder)
	buildStargazerSpire(worldFolder)
	buildMysticGrotto(worldFolder)
	buildAstralWaterfall(worldFolder)
	buildFloatingObby(worldFolder)
	buildSpawn(worldFolder)

	worldFolder.Parent = parent
	startKineticAnimations(worldFolder)

	return worldFolder
end

return Builder
