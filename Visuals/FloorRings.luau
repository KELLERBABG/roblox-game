--!strict
--[[
	Visuals.FloorRings
	==================
	Procedural summoning seals, magic floor circles, and runic ground projections
	inspired by Sol's RNG. Features multiple distinct architectural styles:
	FlameSeal, FrostGlyph, ChronosGear, CelestialStar, DigitalMatrix, HolySigil,
	VoidRift, and AbyssalWhirlpool.
]]

local Workspace = game:GetService("Workspace")

export type FloorRuneStyle =
	| "None"
	| "FlameSeal"
	| "FrostGlyph"
	| "VoidRift"
	| "ChronosGear"
	| "CelestialStar"
	| "HolySigil"
	| "DigitalMatrix"
	| "CosmicNebula"
	| "LightningPentagram"
	| "AbyssalWhirlpool"

export type FloorRing = {
	container: Folder,
	innerRing: Part,
	outerRing: Part,
	styleParts: { Part },
	light: PointLight,
	radius: number,
	style: FloorRuneStyle,
	innerSpeed: number,
	outerSpeed: number,
	color: Color3,
}

local FloorRings = {}

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

local function makeDisc(name: string, size: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Size = size -- Size.X = thickness, Y & Z = diameter
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.5
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Builds specialized procedural geometry on the floor according to the style
local function buildStyleGeometry(
	container: Folder,
	style: FloorRuneStyle,
	radius: number,
	colorA: Color3,
	colorB: Color3
): { Part }
	local parts: { Part } = {}

	if style == "ChronosGear" then
		-- 8 perimeter gear teeth
		local teethCount = 8
		local toothAngle = (math.pi * 2) / teethCount
		for i = 1, teethCount do
			local tooth = Instance.new("Part")
			tooth.Name = string.format("GearTooth_%d", i)
			tooth.Size = Vector3.new(0.12, 0.4, 0.7)
			tooth.Material = Enum.Material.Neon
			tooth.Color = colorA
			tooth.Transparency = 0.35
			tooth.Anchored = true
			tooth.CanCollide = false
			tooth.CanTouch = false
			tooth.CanQuery = false
			tooth.CastShadow = false
			tooth.Parent = container
			table.insert(parts, tooth)
		end
	elseif style == "CelestialStar" or style == "HolySigil" then
		-- 4 intersecting crossbars / star beams forming an octagram
		for i = 1, 4 do
			local bar = Instance.new("Part")
			bar.Name = string.format("StarBar_%d", i)
			bar.Size = Vector3.new(0.08, 0.15, radius * 1.8)
			bar.Material = Enum.Material.Neon
			bar.Color = colorA
			bar.Transparency = 0.4
			bar.Anchored = true
			bar.CanCollide = false
			bar.CanTouch = false
			bar.CanQuery = false
			bar.CastShadow = false
			bar.Parent = container
			table.insert(parts, bar)
		end
	elseif style == "LightningPentagram" then
		-- 5-point star nodes
		for i = 1, 5 do
			local node = Instance.new("Part")
			node.Name = string.format("LightningNode_%d", i)
			node.Shape = Enum.PartType.Ball
			node.Size = Vector3.new(0.4, 0.4, 0.4)
			node.Material = Enum.Material.Neon
			node.Color = colorB
			node.Anchored = true
			node.CanCollide = false
			node.CanTouch = false
			node.CanQuery = false
			node.CastShadow = false
			node.Parent = container
			table.insert(parts, node)
		end
	elseif style == "DigitalMatrix" then
		-- 4 corner circuit anchors
		for i = 1, 4 do
			local corner = Instance.new("Part")
			corner.Name = string.format("MatrixNode_%d", i)
			corner.Size = Vector3.new(0.15, 0.5, 0.5)
			corner.Material = Enum.Material.Neon
			corner.Color = colorA
			corner.Anchored = true
			corner.CanCollide = false
			corner.CanTouch = false
			corner.CanQuery = false
			corner.CastShadow = false
			corner.Parent = container
			table.insert(parts, corner)
		end
	end

	return parts
end

-- Builds a multi-layered floor aura rune with style-specific details
function FloorRings.Create(
	parent: Instance,
	radius: number,
	primaryColor: Color3,
	secondaryColor: Color3,
	style: FloorRuneStyle?
): FloorRing
	local runeStyle = style or "FlameSeal"
	local container = Instance.new("Folder")
	container.Name = "FloorRune"

	-- Outer glowing perimeter disc
	local outer = makeDisc("OuterRing", Vector3.new(0.08, radius * 2, radius * 2), secondaryColor, container)
	outer.Transparency = 0.65

	-- Inner concentrated core disc
	local inner = makeDisc("InnerRing", Vector3.new(0.1, radius * 1.3, radius * 1.3), primaryColor, container)
	inner.Transparency = 0.45

	-- Style-specific geometric parts
	local styleParts = buildStyleGeometry(container, runeStyle, radius, primaryColor, secondaryColor)

	-- Ground PointLight for cast reflection
	local light = Instance.new("PointLight")
	light.Name = "GroundLight"
	light.Color = primaryColor
	light.Range = radius * 3.5
	light.Brightness = 2.0
	light.Shadows = false
	light.Parent = inner

	container.Parent = parent

	return {
		container = container,
		innerRing = inner,
		outerRing = outer,
		styleParts = styleParts,
		light = light,
		radius = radius,
		style = runeStyle,
		innerSpeed = 0.8,
		outerSpeed = -0.45,
		color = primaryColor,
	}
end

-- Updates the floor ring's position and rotates style components
function FloorRings.Update(
	ring: FloorRing,
	rootCFrame: CFrame,
	characterModel: Model,
	now: number
): ()
	-- Raycast down to find ground plane
	raycastParams.FilterDescendantsInstances = { characterModel, ring.container }
	local rayOrigin = rootCFrame.Position
	local rayDirection = Vector3.new(0, -10, 0)
	local rayResult = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)

	local groundPos: Vector3
	local groundNormal: Vector3

	if rayResult ~= nil then
		groundPos = rayResult.Position + Vector3.new(0, 0.05, 0)
		groundNormal = rayResult.Normal
	else
		groundPos = rayOrigin - Vector3.new(0, 2.8, 0)
		groundNormal = Vector3.new(0, 1, 0)
	end

	local alignCF = CFrame.lookAlong(groundPos, groundNormal) * CFrame.Angles(0, 0, math.pi / 2)

	local innerRot = CFrame.Angles(now * ring.innerSpeed, 0, 0)
	local outerRot = CFrame.Angles(now * ring.outerSpeed, 0, 0)

	local pulse = 1 + 0.06 * math.sin(now * 3.5)
	local baseSize = ring.radius * 2 * pulse

	ring.outerRing.CFrame = alignCF * outerRot
	ring.outerRing.Size = Vector3.new(0.08, baseSize, baseSize)

	local innerSize = ring.radius * 1.3 * (1 + 0.08 * math.sin(now * 4 + 1))
	ring.innerRing.CFrame = alignCF * innerRot
	ring.innerRing.Size = Vector3.new(0.1, innerSize, innerSize)

	ring.light.Brightness = 2.0 + 0.4 * math.sin(now * 4)

	-- Update style specific geometry
	local styleCount = #ring.styleParts
	if ring.style == "ChronosGear" and styleCount > 0 then
		local step = (math.pi * 2) / styleCount
		for i, tooth in ipairs(ring.styleParts) do
			local angle = now * ring.outerSpeed + (i - 1) * step
			local toothCF = alignCF * CFrame.Angles(angle, 0, 0) * CFrame.new(0, ring.radius * 0.98, 0)
			tooth.CFrame = toothCF
		end
	elseif (ring.style == "CelestialStar" or ring.style == "HolySigil") and styleCount > 0 then
		local step = math.pi / styleCount
		for i, bar in ipairs(ring.styleParts) do
			local barRot = alignCF * CFrame.Angles(now * ring.innerSpeed + (i - 1) * step, 0, 0)
			bar.CFrame = barRot
		end
	elseif ring.style == "LightningPentagram" and styleCount > 0 then
		local step = (math.pi * 2) / styleCount
		for i, node in ipairs(ring.styleParts) do
			local angle = now * ring.innerSpeed + (i - 1) * step
			local nodeCF = alignCF * CFrame.Angles(angle, 0, 0) * CFrame.new(0, ring.radius * 0.85, 0)
			node.CFrame = nodeCF
		end
	elseif ring.style == "DigitalMatrix" and styleCount > 0 then
		local step = (math.pi * 2) / styleCount
		for i, node in ipairs(ring.styleParts) do
			local angle = now * ring.outerSpeed + (i - 1) * step
			local nodeCF = alignCF * CFrame.Angles(angle, 0, 0) * CFrame.new(0, ring.radius * 0.9, 0)
			node.CFrame = nodeCF
		end
	end
end

function FloorRings.Destroy(ring: FloorRing): ()
	ring.container:Destroy()
end

return FloorRings
