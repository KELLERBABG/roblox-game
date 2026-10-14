--!strict
--[[
	AuraMaterializer
	================
	The only module in the aura stack that touches Roblox datatypes. It converts
	one ladder entry's declarative numbers into the concrete Color3 /
	ColorSequence / NumberSequence / NumberRange / Vector3 / Enum values a
	renderer needs, and caches exactly one result per aura id.

	This is the seam between the ladder and any renderer, so it stays dumb: it is
	a pure function of the config it is handed. It reads no registry state and
	depends only on AuraLadder's types, so a renderer can target this contract
	without knowing how the registry is indexed or classified.

	Every datatype is constructed when a caller asks for it, never at module
	scope, so AuraRegistry - and therefore the Lune test harness - can load this
	file with no Roblox engine present.
]]

local function loadSibling(name: string): any
	-- Roblox resolves siblings as instances; Lune resolves the relative path.
	local scriptGlobal: any = script
	if scriptGlobal ~= nil then
		local parent: any = scriptGlobal.Parent
		if parent ~= nil then
			local module: any = parent:FindFirstChild(name)
			if module ~= nil then
				return require(module)
			end
		end
	end

	local ok, module = pcall(require, "./" .. name)
	if ok and module ~= nil then
		return module
	end

	error(string.format("[AuraMaterializer] could not load sibling module %q", name), 2)
end

--[[
	The annotation is a TYPE-ONLY reference to the real module, so the aura shape
	keeps exactly one definition. The runtime value always comes from the dual
	loader above: a `typeof(...)` in type position is erased before execution, so
	it never runs the require (verified: the call count stays 0).
]]
local AuraLadder: typeof(require("./AuraLadder")) = loadSibling("AuraLadder")

type RGB = AuraLadder.RGB
type AuraConfig = AuraLadder.AuraConfig

export type MaterializedAura = {
	config: AuraConfig,
	primary: Color3,
	secondary: Color3,
	rim: Color3,

	shardSize: Vector3,
	shardPartType: Enum.PartType,
	shardColorA: Color3,
	shardColorB: Color3,

	trailColor: ColorSequence,
	trailWidth: NumberSequence,
	trailTransparency: NumberSequence,

	particleColor: ColorSequence,
	particleSize: NumberSequence,
	particleTransparency: NumberSequence,
	particleSpeed: NumberRange,
	particleLifetime: NumberRange,

	lightColor: Color3,
	highlightDepthMode: Enum.HighlightDepthMode,
	cutsceneFovDelta: number,
}

local materializedCache: { [string]: MaterializedAura } = {}
local shardShapeCache: { [string]: Enum.PartType }? = nil

-- Built lazily: `Enum` does not exist outside Roblox, and this module has to
-- stay loadable from Lune / the Luau CLI for terminal testing.
local function resolveShardShapes(): { [string]: Enum.PartType }
	local cached = shardShapeCache
	if cached ~= nil then
		return cached
	end

	local resolved: { [string]: Enum.PartType } = {
		Ball = Enum.PartType.Ball,
		Block = Enum.PartType.Block,
		Cylinder = Enum.PartType.Cylinder,
		Wedge = Enum.PartType.Wedge,
		CornerWedge = Enum.PartType.CornerWedge,
	}
	shardShapeCache = resolved
	return resolved
end

local AuraMaterializer = {}

function AuraMaterializer.ToColor3(rgb: RGB): Color3
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

-- One materialized table per aura id, shared by every caller so repeated reads
-- return the same instance.
function AuraMaterializer.Materialize(config: AuraConfig): MaterializedAura
	local cached = materializedCache[config.id]
	if cached ~= nil then
		return cached
	end

	local primary = Color3.fromRGB(config.primary.r, config.primary.g, config.primary.b)
	local secondary = Color3.fromRGB(config.secondary.r, config.secondary.g, config.secondary.b)
	local rim = Color3.fromRGB(config.rim.r, config.rim.g, config.rim.b)

	local materialized: MaterializedAura = {
		config = config,
		primary = primary,
		secondary = secondary,
		rim = rim,

		shardSize = Vector3.new(config.shardSize.x, config.shardSize.y, config.shardSize.z),
		shardPartType = resolveShardShapes()[config.shardShape],
		shardColorA = primary,
		shardColorB = secondary,

		trailColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, primary),
			ColorSequenceKeypoint.new(1, secondary),
		}),
		trailWidth = NumberSequence.new({
			NumberSequenceKeypoint.new(0, config.trailWidthStart),
			NumberSequenceKeypoint.new(1, config.trailWidthEnd),
		}),
		trailTransparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, config.trailTransparencyStart),
			NumberSequenceKeypoint.new(1, 1),
		}),

		particleColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, primary),
			ColorSequenceKeypoint.new(0.55, secondary),
			ColorSequenceKeypoint.new(1, rim),
		}),
		particleSize = NumberSequence.new({
			NumberSequenceKeypoint.new(0, config.particleSizeStart),
			NumberSequenceKeypoint.new(1, config.particleSizeEnd),
		}),
		particleTransparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, config.particleTransparencyStart),
			NumberSequenceKeypoint.new(0.7, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		}),
		particleSpeed = NumberRange.new(config.particleSpeedMin, config.particleSpeedMax),
		particleLifetime = NumberRange.new(config.particleLifetimeMin, config.particleLifetimeMax),

		-- Every aura declares an authored light tint; blend a little rim in so the
		-- emitter still reads as "hot core, cool edge" like the derived version did.
		lightColor = AuraMaterializer.ToColor3(config.lightColor):Lerp(rim, 0.15),
		highlightDepthMode = if config.alwaysOnTop
			then Enum.HighlightDepthMode.AlwaysOnTop
			else Enum.HighlightDepthMode.Occluded,
		cutsceneFovDelta = 8 + 16 * config.cutsceneIntensity,
	}

	materializedCache[config.id] = materialized
	return materialized
end

return AuraMaterializer
