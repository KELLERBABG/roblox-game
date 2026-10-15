--!nocheck
--[[
	Terminal test harness for RollMath + AuraRegistry.

	Runs outside Roblox, so you can validate balance and pity behaviour without
	launching Studio:

	    lune run test_rollmath
	    lune run test_rollmath -- --rolls 500000

	This file lives outside `src/`, so Rojo never syncs it into the place.

	Two sections reach outside the modules to prove a contract rather than an
	implementation detail:

	  * "Config contract" reads the real consumer sources (`ProceduralVFX`,
	    `MainUI`, `RNGService`) and asserts every `config.<field>` they touch
	    exists on all 12 auras. That is the machine check behind "the frozen VFX
	    engine renders the new tiers with no edits to that file". It needs the
	    harness to run from the project root; if the files cannot be read it
	    prints a NOTE instead of pretending to pass.
      * "Weight exactness" re-derives each aura's luck-1 probability from its
	    declared odds and compares against RollMath's own table, so a rung whose
	    stated odds and actual weight disagree cannot pass.
]]

local process = require("@lune/process")
local fs = require("@lune/fs")

local RollMath = require("./src/shared/RollMath")
local AuraRegistry = require("./src/shared/AuraRegistry")
local BiomeMath = require("./src/server/BiomeMath")

local failures = 0
local checks = 0

local function check(name: string, condition: boolean, detail: string?): ()
	checks += 1
	if condition then
		print(string.format("  PASS  %s", name))
	else
		failures += 1
		print(string.format("  FAIL  %s%s", name, if detail ~= nil then "  -> " .. detail else ""))
	end
end

local function note(message: string): ()
	print(string.format("  NOTE  %s", message))
end

local function section(title: string): ()
	print("")
	print("== " .. title .. " ==")
end

local function approx(a: number, b: number, tolerance: number): boolean
	return math.abs(a - b) <= tolerance
end

-- The declared ladder, ascending. This is the mission's 12-rung spec, written
-- out independently of the registry so a rung edited in the source fails here.
local LADDER = {
	{ "Ember", 2 },
	{ "Frostbite", 8 },
	{ "Static", 15 },
	{ "Voidwalker", 50 },
	{ "Bloom", 150 },
	{ "Chronos", 500 },
	{ "Sunflare", 1500 },
	{ "AstralTempest", 5000 },
	{ "Nebula", 25000 },
	{ "CelestialSingularity", 100000 },
	{ "Transcendence", 400000 },
	{ "Sovereign", 1000000 },
}

-- Every field any consumer reads off an aura. Proven below to be the exact set
-- the shipped sources reference.
local CONTRACT_FIELDS = {
	-- identity & derived tier
	"id", "displayName", "rarity", "tier", "tierColor",
	-- palette
	"primary", "secondary", "rim",
	-- shard cluster
	"shardCount", "shardShape", "shardSize", "shardSpin",
	-- orbit geometry
	"orbitRadius", "orbitHeight", "orbitSpeed", "tiltDegrees", "precessionSpeed",
	"harmonicFrequency", "harmonicRatioA", "lissajousAmplitude",
	-- trail
	"trailEnabled", "trailLifetime", "trailWidthStart", "trailWidthEnd",
	"trailTransparencyStart", "trailLightEmission",
	-- particle layers
	"particleLayers", "particleRate", "particleSpeedMin", "particleSpeedMax",
	"particleLifetimeMin", "particleLifetimeMax", "particleSizeStart", "particleSizeEnd",
	"particleTransparencyStart", "particleSpread", "particleLightEmission",
	"particleTexture", "smokeTexture",
	-- light
	"lightColor", "lightRange", "lightBrightness",
	-- highlight
	"highlightFillTransparency", "highlightOutlineTransparency", "alwaysOnTop",
	-- cutscene
	"cutsceneIntensity", "cutsceneShakeMagnitude",
}

-- =============================================================================
section("AuraRegistry wiring")

local order = AuraRegistry.ORDER
check("registry exposes 12 auras", #order == 12, tostring(#order))
check("AuraRegistry.Count agrees with ORDER", AuraRegistry.Count == #order, tostring(AuraRegistry.Count))
check("ladder tops out at 1 in 1,000,000", AuraRegistry.HighestRarity() == 1000000, tostring(AuraRegistry.HighestRarity()))

for index, pair in ipairs(LADDER) do
	local id = pair[1]
	local config = AuraRegistry.Get(id)
	check(
		string.format("aura %2d is %s at 1 in %d", index, id, pair[2]),
		config ~= nil and config.rarity == pair[2],
		if config == nil then "missing" else string.format("rarity=%d", config.rarity)
	)
end

check("ORDER is sorted by ascending rarity", (function(): boolean
	for index = 2, #order do
		if AuraRegistry.Get(order[index - 1]).rarity > AuraRegistry.Get(order[index]).rarity then
			return false
		end
	end
	return true
end)())

-- =============================================================================
section("Tier metadata is derived, not authored")

local tierSet: { [string]: string } = {}
local derivationsOk = true
local colorsOk = true
local derivationDetail = ""
for _, id in ipairs(order) do
	local config = AuraRegistry.Get(id)
	local derivedTier = AuraRegistry.TierOf(config.rarity)
	local derivedColor = AuraRegistry.TierColorOf(config.rarity)

	if config.tier ~= derivedTier then
		derivationsOk = false
		derivationDetail = string.format("%s says %q but rarity %d derives %q", id, config.tier, config.rarity, derivedTier)
	end
	if config.tierColor.r ~= derivedColor.r or config.tierColor.g ~= derivedColor.g or config.tierColor.b ~= derivedColor.b then
		colorsOk = false
		derivationDetail = string.format("%s colour (%d,%d,%d) != derived (%d,%d,%d)", id, config.tierColor.r, config.tierColor.g, config.tierColor.b, derivedColor.r, derivedColor.g, derivedColor.b)
	end

	local clash = tierSet[derivedTier]
	if clash ~= nil then
		derivationDetail = string.format("%s and %s share tier %q", clash, id, derivedTier)
		derivationsOk = false
	end
	tierSet[derivedTier] = id
end

check("every aura's tier equals TierOf(rarity)", derivationsOk, derivationDetail)
check("every aura's tierColor equals TierColorOf(rarity)", colorsOk, derivationDetail)
check("all 12 rungs carry a distinct tier", (function(): boolean
	local count = 0
	for _ in pairs(tierSet) do
		count += 1
	end
	return count == 12
end)(), tostring(#order))

check("TierOf clamps below the ladder floor to Common", AuraRegistry.TierOf(0) == "Common", AuraRegistry.TierOf(0))
check("TierOf clamps above the ladder ceiling to Sovereign", AuraRegistry.TierOf(1e9) == "Sovereign", AuraRegistry.TierOf(1e9))
check("the God tier is named Sovereign", AuraRegistry.Get("Sovereign").tier == "Sovereign")
check("tier names escalate with rarity", (function(): boolean
	for index = 2, #order do
		local previous = AuraRegistry.TierOf(AuraRegistry.Get(order[index - 1]).rarity)
		local current = AuraRegistry.TierOf(AuraRegistry.Get(order[index]).rarity)
		if previous == current then
			return false
		end
	end
	return true
end)())

-- =============================================================================
section("Config contract (the frozen VFX engine can render every new tier)")

local declaredFields: { [string]: boolean } = {}
for _, field in ipairs(CONTRACT_FIELDS) do
	declaredFields[field] = true
end

local missingFields: { string } = {}
for _, id in ipairs(order) do
	local config = AuraRegistry.Get(id)
	for _, field in ipairs(CONTRACT_FIELDS) do
		if config[field] == nil then
			table.insert(missingFields, string.format("%s.%s", id, field))
		end
	end
end
check(
	string.format("all %d auras carry all %d declared fields", #order, #CONTRACT_FIELDS),
	#missingFields == 0,
	table.concat(missingFields, ", ")
)

check("every aura declares the identical field set (no hand-transcription gaps)", (function(): boolean
	local reference = AuraRegistry.Get(order[1])
	local referenceCount = 0
	for _ in pairs(reference) do
		referenceCount += 1
	end

	for _, id in ipairs(order) do
		local config = AuraRegistry.Get(id)
		local count = 0
		for field in pairs(config) do
			count += 1
			if reference[field] == nil then
				return false
			end
		end
		if count ~= referenceCount then
			return false
		end
	end
	return true
end)())

-- Live extraction from the shipped sources, so the list above cannot silently
-- drift away from what the game actually reads.
-- Every module that reads a field off an aura config. Split across the ladder
-- stack on purpose: the registry reads the derived tier fields, the materializer
-- reads the renderer's inputs, the consumers read the rest.
local CONSUMER_SOURCES = {
	"src/client/ProceduralVFX.luau",
	"src/client/MainUI.client.luau",
	"src/server/RNGService.server.luau",
	"src/shared/AuraRegistry.luau",
	"src/shared/AuraMaterializer.luau",
}

local function readSource(path: string): string?
	local ok, contents = pcall(fs.readFile, path)
	if ok and type(contents) == "string" then
		return contents
	end
	return nil
end

local function extractReads(source: string, root: string): { [string]: boolean }
	local found: { [string]: boolean } = {}
	for field in string.gmatch(source, root .. "%.([%a_][%w_]*)") do
		found[field] = true
	end
	return found
end

local sourcesReadable = true
local liveFields: { [string]: boolean } = {}
local materializedReads: { [string]: boolean } = {}

for _, path in ipairs(CONSUMER_SOURCES) do
	local source = readSource(path)
	if source == nil then
		sourcesReadable = false
		note(string.format("could not read %s - run the harness from the project root", path))
	else
		for field in pairs(extractReads(source, "config")) do
			liveFields[field] = true
		end
	end
end

local vfxSource = readSource(CONSUMER_SOURCES[1])
if vfxSource ~= nil then
	materializedReads = extractReads(vfxSource, "materialized")
end

if sourcesReadable then
	local unreferenced: { string } = {}
	for field in pairs(liveFields) do
		if declaredFields[field] == nil then
			table.insert(unreferenced, field)
		end
	end
	check(
		"the hardcoded contract list covers every field consumers read",
		#unreferenced == 0,
		table.concat(unreferenced, ", ")
	)

	local structural: { string } = {}
	for _, field in ipairs(CONTRACT_FIELDS) do
		if liveFields[field] == nil then
			table.insert(structural, field)
		end
	end
	check(
		"no listed field is unreferenced by any consumer (no dead per-aura data)",
		#structural == 0,
		table.concat(structural, ", ")
	)

	-- The VFX engine reads its aggregate values off `materialized`. The
	-- materializer never reads `materialized.foo` itself - it *produces* the
	-- table - so verify production two ways: the declared output type must cover
	-- every field the VFX reads, and every declared field must actually be
	-- assigned in the module that owns that type.
	local materializerSource = readSource("src/shared/AuraMaterializer.luau") or ""
	local typeBlock = string.match(materializerSource, "export type MaterializedAura = {(.-)\n}")

	if typeBlock == nil then
		note("could not locate the MaterializedAura type block")
	else
		local declaredMaterialized: { [string]: boolean } = {}
		for field in string.gmatch(typeBlock, "(%a[%w_]*):") do
			declaredMaterialized[field] = true
		end

		local undeclared: { string } = {}
		local readCount = 0
		for field in pairs(materializedReads) do
			readCount += 1
			if declaredMaterialized[field] == nil then
				table.insert(undeclared, field)
			end
		end
		check(
			string.format("AuraMaterializer's MaterializedAura type covers all %d fields the VFX reads", readCount),
			#undeclared == 0,
			table.concat(undeclared, ", ")
		)

		local unassigned: { string } = {}
		for field in pairs(declaredMaterialized) do
			if string.find(materializerSource, field .. "%s*=") == nil then
				table.insert(unassigned, field)
			end
		end
		check(
			"AuraMaterializer assigns every field its output type promises (no nil handoff to the renderer)",
			#unassigned == 0,
			table.concat(unassigned, ", ")
		)
	end
else
	note("source-level contract extraction skipped (relative paths unresolved)")
end

-- =============================================================================
section("Renderer limits (values a clamp or an engine cap would silently eat)")

local limitViolations: { string } = {}
local function within(value: number, minimum: number, maximum: number, id: string, field: string): ()
	if type(value) ~= "number" or value < minimum or value > maximum then
		table.insert(limitViolations, string.format(
			"%s.%s=%s (want %s..%s)", id, field, tostring(value), tostring(minimum), tostring(maximum)
		))
	end
end

for _, id in ipairs(order) do
	local config = AuraRegistry.Get(id)
	within(config.particleLayers, 1, 3, id, "particleLayers")       -- the VFX layer clamps this to 1..3
	within(config.cutsceneIntensity, 0, 1, id, "cutsceneIntensity") -- ...and this to 0..1
	within(config.particleRate, 1, 100, id, "particleRate")         -- engine cap is 400/s; keep headroom
	within(config.lightRange, 1, 60, id, "lightRange")              -- PointLight.Range cap
	within(config.particleLifetimeMax, 0.01, 20, id, "particleLifetimeMax")
	within(config.particleSpread, 1, 90, id, "particleSpread")
	within(config.shardCount, 1, 40, id, "shardCount")
	within(config.orbitRadius, 0.5, 12, id, "orbitRadius")
end

check(
	"no rung relies on being clipped by a clamp or an engine cap",
	#limitViolations == 0,
	table.concat(limitViolations, ", ")
)

-- =============================================================================
section("Rarity escalation (a rarer rung never looks or sounds weaker)")

-- Ascending metrics: each rung must be at least its cheaper neighbour.
local ASCENDING = {
	"shardCount", "particleLayers", "particleRate", "particleSpeedMin", "particleSpeedMax",
	"particleLifetimeMin", "particleLifetimeMax", "particleSizeStart", "particleSpread",
	"particleLightEmission", "trailLightEmission", "lightRange", "lightBrightness",
	"orbitRadius", "orbitSpeed", "cutsceneIntensity", "cutsceneShakeMagnitude",
}

-- Descending metrics: more transparency means a thinner-looking effect, so these
-- must never rise with rarity.
local DESCENDING = {
	"highlightFillTransparency", "highlightOutlineTransparency",
	"particleTransparencyStart", "trailTransparencyStart",
}

local escalationProblems: { string } = {}
local function compareMetric(field: string, ascending: boolean): ()
	for index = 2, #order do
		local previous = AuraRegistry.Get(order[index - 1])
		local current = AuraRegistry.Get(order[index])
		local ok = if ascending then current[field] >= previous[field] else current[field] <= previous[field]
		if not ok then
			table.insert(escalationProblems, string.format(
				"%s.%s=%s vs %s.%s=%s",
				current.id, field, tostring(current[field]), previous.id, field, tostring(previous[field])
			))
		end
	end
end

for _, field in ipairs(ASCENDING) do
	compareMetric(field, true)
end
for _, field in ipairs(DESCENDING) do
	compareMetric(field, false)
end

check(
	string.format("all %d power metrics escalate monotonically across the 12 rungs", #ASCENDING + #DESCENDING),
	#escalationProblems == 0,
	table.concat(escalationProblems, ", ")
)

-- =============================================================================
section("Weight exactness at luck 1")

local inverseSum = 0
for _, id in ipairs(order) do
	inverseSum += 1 / AuraRegistry.Get(id).rarity
end

local analytic = RollMath.ChanceTable(1, 0)
local totalChance = 0
for _, entry in ipairs(analytic) do
	totalChance += entry.chance
end

local weightMismatches: { string } = {}
for _, entry in ipairs(analytic) do
	local expected = (1 / entry.rarity) / inverseSum
	if not approx(entry.chance, expected, 1e-9) then
		table.insert(weightMismatches, string.format("%s %.10f vs expected %.10f", entry.auraId, entry.chance, expected))
	end
end

check(
	string.format("every rung's actual weight equals its declared 1-in-N odds (of %d)", #analytic),
	#weightMismatches == 0,
	table.concat(weightMismatches, ", ")
)
check("the odds table sums to exactly 1", approx(totalChance, 1, 1e-9), string.format("%.12f", totalChance))
local expectedCommonShare = 0.5 / inverseSum
check(
	string.format("Ember holds the 1-in-2 share the 12-rung ladder implies (%.4f%%)", expectedCommonShare * 100),
	approx(analytic[1].chance, expectedCommonShare, 1e-9),
	tostring(analytic[1].chance)
)

-- =============================================================================
section("Determinism (injected RNG)")

local function sequence(seed: number, count: number): { string }
	local rng = RollMath.SequenceRandom(seed)
	local ids: { string } = {}
	for _ = 1, count do
		local outcome = RollMath.SelectAura(1, 0, rng)
		table.insert(ids, outcome.auraId)
	end
	return ids
end

local first = sequence(1337, 60)
local second = sequence(1337, 60)
local third = sequence(9001, 60)

local identical = true
for index = 1, #first do
	if first[index] ~= second[index] then
		identical = false
		break
	end
end
check("same seed produces the identical roll sequence", identical)

local differs = false
for index = 1, #first do
	if first[index] ~= third[index] then
		differs = true
		break
	end
end
check("different seed produces a different sequence", differs)

local zeroRoll = RollMath.SelectAura(1, 0, function(): number
	return 0
end)
check("roll=0 hits the first (most common) entry", zeroRoll.auraId == "Ember", zeroRoll.auraId)

local maxRoll = RollMath.SelectAura(1, 0, function(): number
	return 0.9999999
end)
check("roll~=1 hits the last (rarest) entry - the 1-in-1,000,000 God tier", maxRoll.auraId == "Sovereign", maxRoll.auraId)

-- =============================================================================
section("Instantaneous distribution at luck 1 (analytic vs sampled)")

local rollsPerTest = 300000
local counts: { [string]: number } = {}
for _ = 1, rollsPerTest do
	local outcome = RollMath.SelectAura(1, 0)
	counts[outcome.auraId] = (counts[outcome.auraId] or 0) + 1
end

for _, entry in ipairs(analytic) do
	local sampled = (counts[entry.auraId] or 0) / rollsPerTest
	check(
		string.format("%-22s sampled %.4f%% vs analytic %.4f%%", entry.auraId, sampled * 100, entry.chance * 100),
		approx(sampled, entry.chance, math.max(0.004, entry.chance * 0.35)),
		string.format("delta=%.5f", math.abs(sampled - entry.chance))
	)
end

-- =============================================================================
section("Luck actually shifts the odds (regression guard)")

local rareAtOne = RollMath.ChanceOfAtLeast(50, 1, 0)
local rareAtFifty = RollMath.ChanceOfAtLeast(50, 50, 0)
local rareAtFiveThousand = RollMath.ChanceOfAtLeast(50, 5000, 0)
local rareAtMax = RollMath.ChanceOfAtLeast(50, 1e6, 0)

check(
	string.format("rarity>=50 odds grow with luck: %.4f%% -> %.4f%% -> %.3f%%", rareAtOne * 100, rareAtFifty * 100, rareAtFiveThousand * 100),
	-- Luck is not linear: RollMath clamps effectiveRarity at 1, so each rung
	-- collapses to weight 1 once luck exceeds its rarity. Assert real gains and
	-- strict monotonicity rather than an impossible 10x at 5000x.
	rareAtFifty > rareAtOne * 2
		and rareAtFifty > 0.30
		and rareAtFiveThousand > rareAtFifty
		and rareAtFiveThousand > 0.60
		and rareAtFiveThousand < 1
)

check(
	string.format("luck saturates below certainty: %.4f%% -> %.4f%%", rareAtFiveThousand * 100, rareAtMax * 100),
	rareAtMax > rareAtFiveThousand and rareAtMax < 1,
	tostring(rareAtMax)
)

local topTierAtOne = RollMath.ChanceOfAtLeast(100000, 1, 0)
local topTierAtThousand = RollMath.ChanceOfAtLeast(100000, 1000, 0)
check(
	string.format("top-tier odds scale with luck: 1 in %.0f -> 1 in %.0f", 1 / topTierAtOne, 1 / topTierAtThousand),
	topTierAtThousand > topTierAtOne * 20
)

check("every rung is reachable (no zero-probability aura)", (function(): boolean
	for _, entry in ipairs(analytic) do
		if entry.chance <= 0 then
			return false
		end
	end
	return true
end)())

check("luck=0 is clamped, never crashes", RollMath.ChanceOfAtLeast(50, 0, 0) >= 0)
check("NaN luck falls back to 1x", approx(RollMath.ChanceOfAtLeast(50, 0 / 0, 0), rareAtOne, 1e-9))

-- =============================================================================
section("Soft pity")

check("no soft pity at 0 rolls", RollMath.SoftPityStacks(0) == 0)
check("no soft pity at 49 rolls", RollMath.SoftPityStacks(49) == 0)
check("1 stack at 50 rolls", RollMath.SoftPityStacks(50) == 1, tostring(RollMath.SoftPityStacks(50)))
check("soft pity multiplier is x2 at 50 rolls", approx(RollMath.SoftPityMultiplier(50), 2, 1e-9))

local softOff = RollMath.ChanceOfAtLeast(50, 1, 49)
local softOn = RollMath.ChanceOfAtLeast(50, 1, 50)
check(
	string.format("soft pity raises rare odds: %.5f%% -> %.5f%%", softOff * 100, softOn * 100),
	softOn > softOff
)

-- =============================================================================
section("Hard pity")

-- pity 0 means the guarantee lands on roll 100, i.e. 99 further rolls from here.
check("0 rolls -> 99 more to guarantee", RollMath.RollsUntilGuaranteed(0) == 99, tostring(RollMath.RollsUntilGuaranteed(0)))
check("50 rolls -> 49 more to guarantee", RollMath.RollsUntilGuaranteed(50) == 49)
check("99 rolls -> 0 to guarantee", RollMath.RollsUntilGuaranteed(99) == 0)
check("99 rolls is flagged as hard pity next", RollMath.IsHardPityNext(99))
check("98 rolls is not hard pity", not RollMath.IsHardPityNext(98))

local expectedPityPool = 0
for _, id in ipairs(order) do
	if AuraRegistry.Get(id).rarity >= RollMath.HardPityMinRarity() then
		expectedPityPool += 1
	end
end

local hardOdds = RollMath.ChanceTable(1, 99)
local allRare = true
local oddsSum = 0
for _, entry in ipairs(hardOdds) do
	oddsSum += entry.chance
	if entry.rarity < 50 then
		allRare = false
	end
end
check("hard pity pool excludes everything below 1 in 50", allRare, string.format("pool=%d", #hardOdds))
check(
	string.format("hard pity pool covers every rung at 1 in 50 or rarer (%d of %d)", #hardOdds, #order),
	#hardOdds == expectedPityPool,
	string.format("expected %d", expectedPityPool)
)
check("hard pity odds sum to 1", approx(oddsSum, 1, 1e-6), tostring(oddsSum))

local guaranteedOk = true
for _ = 1, 5000 do
	local outcome = RollMath.SelectAura(1, 99)
	if outcome.rarity < 50 or not outcome.hardPityTriggered then
		guaranteedOk = false
		break
	end
end
check("5000 pity rolls all produced rarity >= 50", guaranteedOk)

-- =============================================================================
section("Full pity state machine simulation")

-- Fixed seed so the balance report below is reproducible run to run.
local report = RollMath.Simulate(200000, 1, RollMath.SequenceRandom(20260114))
print(
	string.format(
		"  rolls=%d  rare+ pulls=%d  hard-pity hits=%d  longest drought=%d  best=%s (1 in %d)",
		report.rolls,
		report.rarePlusCount,
		report.hardPityHits,
		report.longestDrought,
		tostring(report.bestAuraId),
		report.bestRarity
	)
)
for _, id in ipairs(order) do
	local count = report.counts[id] or 0
	print(string.format("    %-22s %7d  (%.4f%%)", id, count, (count / report.rolls) * 100))
end

check("simulation produced hard-pity hits", report.hardPityHits > 0, tostring(report.hardPityHits))
check("drought never exceeds the 99-roll hard pity window", report.longestDrought <= 99, tostring(report.longestDrought))
check("every rung at 1 in 25,000 or better was pulled", (function(): boolean
	for _, id in ipairs(order) do
		local config = AuraRegistry.Get(id)
		if config.rarity <= 25000 and (report.counts[id] or 0) == 0 then
			return false
		end
	end
	return true
end)())
check("the rarest pull in 200,000 rolls is reported correctly", (function(): boolean
	if report.bestAuraId == nil then
		return false
	end
	local best = AuraRegistry.Get(report.bestAuraId)
	return best ~= nil and best.rarity == report.bestRarity
end)(), tostring(report.bestAuraId))

-- =============================================================================
section("Materialized contract (adapter executed against stubbed datatypes)")

-- Lune has no Roblox engine, so stand up the smallest faithful stand-ins for the
-- datatypes the adapter touches and then RUN the adapter. This closes the one
-- gap the source scan cannot: a field that is declared and assigned but still
-- reaches a renderer as nil (a bad shardShape key, say) is invisible to a static
-- check and obvious the moment the call is made.
local function makeColor3(r: number, g: number, b: number): any
	return {
		r = r,
		g = g,
		b = b,
		Lerp = function(self: any, other: any, alpha: number): any
			return makeColor3(
				self.r + (other.r - self.r) * alpha,
				self.g + (other.g - self.g) * alpha,
				self.b + (other.b - self.b) * alpha
			)
		end,
	}
end

local function makeKeypoint(time: number, value: any): any
	return { time = time, value = value }
end

-- Assigned as PLAIN globals, not via `_G`: an `_G.x` write is only visible
-- through `_G`, while a plain assignment lands in the global namespace the
-- required module actually reads. (Both forms probed before relying on it.)
Color3 = { fromRGB = makeColor3 }
Vector3 = { new = function(x: number, y: number, z: number): any
	return { x = x, y = y, z = z }
end }
ColorSequence = { new = function(keypoints: any): any
	return { keypoints = keypoints }
end }
ColorSequenceKeypoint = { new = makeKeypoint }
NumberSequence = { new = function(keypoints: any): any
	return { keypoints = keypoints }
end }
NumberSequenceKeypoint = { new = makeKeypoint }
NumberRange = { new = function(min: number, max: number): any
	return { min = min, max = max }
end }
Enum = {
	PartType = {
		Ball = "PartType.Ball",
		Block = "PartType.Block",
		Cylinder = "PartType.Cylinder",
		Wedge = "PartType.Wedge",
		CornerWedge = "PartType.CornerWedge",
	},
	HighlightDepthMode = {
		AlwaysOnTop = "HighlightDepthMode.AlwaysOnTop",
		Occluded = "HighlightDepthMode.Occluded",
	},
}

local MATERIALIZED_FIELDS = {
	"config", "primary", "secondary", "rim",
	"shardSize", "shardPartType", "shardColorA", "shardColorB",
	"trailColor", "trailWidth", "trailTransparency",
	"particleColor", "particleSize", "particleTransparency", "particleSpeed", "particleLifetime",
	"lightColor", "highlightDepthMode", "cutsceneFovDelta",
}

local nilFields: { string } = {}
local mappingProblems: { string } = {}
local cacheMismatches: { string } = {}

for _, id in ipairs(order) do
	local config = AuraRegistry.Get(id)

	-- Exercise the public facade, not the adapter directly. That covers the
	-- delegation and the config lookup in one go.
	local materialized = AuraRegistry.Materialize(id)
	if materialized == nil then
		table.insert(nilFields, id .. " (nil)")
		continue
	end

	for _, field in ipairs(MATERIALIZED_FIELDS) do
		if materialized[field] == nil then
			table.insert(nilFields, string.format("%s.%s", id, field))
		end
	end

	-- A shardShape with no engine equivalent would come back nil here. Compare
	-- against a NON-nil expectation, otherwise a bad shape passes as nil == nil.
	local expectedPartType = Enum.PartType[config.shardShape]
	if expectedPartType == nil or materialized.shardPartType ~= expectedPartType then
		table.insert(mappingProblems, string.format("%s.shardShape=%s", id, tostring(config.shardShape)))
	end

	if not approx(materialized.cutsceneFovDelta, 8 + 16 * config.cutsceneIntensity, 1e-9) then
		table.insert(mappingProblems, string.format("%s.cutsceneFovDelta=%s", id, tostring(materialized.cutsceneFovDelta)))
	end

	if materialized.trailWidth.keypoints[1].value ~= config.trailWidthStart
		or materialized.trailWidth.keypoints[2].value ~= config.trailWidthEnd
		then
		table.insert(mappingProblems, id .. ".trailWidth")
	end

	-- The authored lightColor must be the one that reaches the emitter (15% rim mixed in).
	local expectedLightR = config.lightColor.r + (config.rim.r - config.lightColor.r) * 0.15
	if not approx(materialized.lightColor.r, expectedLightR, 1e-9) then
		table.insert(mappingProblems, string.format("%s.lightColor tint not applied", id))
	end

	if AuraRegistry.Materialize(id) ~= materialized then
		table.insert(cacheMismatches, id)
	end
end

check(
	string.format("all 12 auras materialize all %d contract fields (nothing nil reaches a renderer)", #MATERIALIZED_FIELDS),
	#nilFields == 0,
	table.concat(nilFields, ", ")
)
check("shardShape, trailWidth and cutscene values map exactly as declared", #mappingProblems == 0, table.concat(mappingProblems, ", "))
check("materializing twice returns the same cached instance", #cacheMismatches == 0, table.concat(cacheMismatches, ", "))
check("materializing an unknown id returns nil", AuraRegistry.Materialize("NotAnAura") == nil)

-- =============================================================================
section("Biome events: the schedule runs off an injected clock")

local BIOME_IDS = BiomeMath.Ids()
local CYCLE = BiomeMath.CycleSeconds()
local BIOME_BOOSTS = BiomeMath.Boosts(AuraRegistry)

check(
	"three events, one duration, no fourth state",
	BiomeMath.Count() == 3 and CYCLE == 300 and #BIOME_IDS == 3,
	string.format("count=%d cycle=%s", BiomeMath.Count(), tostring(CYCLE))
)
check("one multiplier for the whole system (x3), not one per event", BiomeMath.Multiplier() == 3, tostring(BiomeMath.Multiplier()))

local opening = BiomeMath.At(0)
check(
	"the cycle opens on the first event, at full time and at zero progress",
	opening.id == BIOME_IDS[1] and opening.secondsRemaining == CYCLE and opening.progress == 0,
	string.format("%s rem=%s progress=%s", opening.id, tostring(opening.secondsRemaining), tostring(opening.progress))
)

--[[
	The boundary itself, from both sides. "Advances on schedule" has to mean
	exactly: at 299.999s the previous event is still running with 0.001s left, at
	300.000s the next one has started at full time. An off-by-one (>= instead of >)
	or a ceil where a floor belongs shows up here and nowhere else.
]]
local boundaryProblems: { string } = {}
for step = 1, 6 do
	local start = step * CYCLE
	local expected = BIOME_IDS[(step % #BIOME_IDS) + 1]
	local before = BiomeMath.At(start - 0.001)
	local at = BiomeMath.At(start)
	local after = BiomeMath.At(start + 0.001)

	if at.id ~= expected or at.secondsRemaining ~= CYCLE or at.progress ~= 0 then
		table.insert(boundaryProblems, string.format("at %ds expected %s, got %s", start, expected, at.id))
	end
	if before.id == expected or before.secondsRemaining <= 0 or before.secondsRemaining > 0.002 then
		table.insert(
			boundaryProblems,
			string.format("just before %ds: %s with %s left", start, before.id, tostring(before.secondsRemaining))
		)
	end
	if after.id ~= expected or after.secondsRemaining >= CYCLE then
		table.insert(boundaryProblems, string.format("just after %ds: %s", start, after.id))
	end
end
check("an event changes exactly on its boundary and nowhere else", #boundaryProblems == 0, table.concat(boundaryProblems, "; "))

--[[
	A second-by-second walk over three full cycles. Checking only the boundaries
	would pass an implementation that is right at multiples of the cycle and wrong
	in between, so every second of three cycles is compared against the schedule
	written out here independently.
]]
local walkProblems: { string } = {}
for elapsed = 0, CYCLE * 3 - 1 do
	local state = BiomeMath.At(elapsed)
	local expectedId = BIOME_IDS[math.floor(elapsed / CYCLE) % #BIOME_IDS + 1]
	local expectedRemaining = CYCLE - (elapsed % CYCLE)

	if state.id ~= expectedId then
		table.insert(walkProblems, string.format("t=%ds: %s not %s", elapsed, state.id, expectedId))
	elseif math.abs(state.secondsRemaining - expectedRemaining) > 1e-9 then
		table.insert(walkProblems, string.format("t=%ds: %s left, not %d", elapsed, tostring(state.secondsRemaining), expectedRemaining))
	elseif math.abs(state.progress - (elapsed % CYCLE) / CYCLE) > 1e-9 then
		table.insert(walkProblems, string.format("t=%ds: progress %s", elapsed, tostring(state.progress)))
	end
end
check(
	string.format("every second of three full cycles (%d samples) lands on schedule", CYCLE * 3),
	#walkProblems == 0,
	table.concat(walkProblems, "; ") .. (if #walkProblems > 2 then " ..." else "")
)

--[[
	A player who joins mid-event. Nothing in BiomeMath reads a clock of its own or
	remembers a player, so the same elapsed time must produce the same event for
	two callers - the joiner and the player who has been there since the start.
]]
local joinProblems: { string } = {}
for _, elapsed in ipairs({ 7, 149, 299, 301, 425, 899 }) do
	local first = BiomeMath.At(elapsed)
	local second = BiomeMath.At(elapsed)
	if
		first.id ~= second.id
		or first.secondsRemaining ~= second.secondsRemaining
		or first.progress ~= second.progress
		or first.index ~= second.index
		or first.multiplier ~= second.multiplier
	then
		table.insert(joinProblems, string.format("t=%ds disagrees between callers", elapsed))
	end
end
check("two callers asking about the same instant are told the same event", #joinProblems == 0, table.concat(joinProblems, "; "))

local midEvent = BiomeMath.At(425)
check(
	"a player joining mid-event joins the event already running (t=425s is 125s into Blood Moon)",
	midEvent.id == "BloodMoon" and midEvent.secondsRemaining == 175 and math.abs(midEvent.progress - 125 / CYCLE) < 1e-9,
	string.format("%s rem=%s", midEvent.id, tostring(midEvent.secondsRemaining))
)

--[[
	A damaged clock must not put a NaN countdown on screen. Two outcomes are
	admissible and this pins both: a real event state with the real multiplier, or
	the "no event" shape (empty id, 1x) for a time that is not a number at all. What
	is NOT admissible is a NaN or out-of-range countdown, or a state that claims an
	event while carrying no multiplier.
]]
local clockProblems: { string } = {}
for _, elapsed in ipairs({ -1, -1e9, 0 / 0, math.huge, -math.huge, 1e15, 2 ^ 53 }) do
	local state = BiomeMath.At(elapsed)
	local finite = state.secondsRemaining == state.secondsRemaining
		and state.secondsRemaining >= 0
		and state.secondsRemaining <= CYCLE
		and state.progress == state.progress
		and state.progress >= 0
		and state.progress < 1
	local named = state.id ~= ""
		and state.multiplier == BiomeMath.Multiplier()
		and state.secondsRemaining > 0
	local anonymous = state.id == ""
		and state.multiplier == 1
		and state.displayName == ""
		and state.secondsRemaining == CYCLE
	if not (finite and (named or anonymous)) then
		table.insert(
			clockProblems,
			string.format("%s -> id=%q rem=%s progress=%s x%s", tostring(elapsed), state.id, tostring(state.secondsRemaining), tostring(state.progress), tostring(state.multiplier))
		)
	end
end
check("a broken or extreme clock yields either a real event or an honest no-event, never a NaN countdown", #clockProblems == 0, table.concat(clockProblems, "; "))

--[[
	The data, read against the real ladder. `Boosts` resolves BiomeConfig's ids
	through AuraRegistry and raises on any problem, so this running at all proves
the shipped config names only real auras. What is asserted here is the shape the
	roll path and the payload depend on.
]]
local rungProblems: { string } = {}
local themedTotal: { [string]: number } = {}
for _, biomeId in ipairs(BIOME_IDS) do
	local boost = BIOME_BOOSTS[biomeId]
	if boost == nil then
		table.insert(rungProblems, biomeId .. " has no resolved boost")
		continue
	end
	if boost.id ~= biomeId or boost.multiplier ~= 3 then
		table.insert(rungProblems, string.format("%s: id=%s multiplier=%s", biomeId, boost.id, tostring(boost.multiplier)))
	end
	-- The resolved rungs must be the config's own list, not a subset or a superset:
	-- a rung dropped in resolution would silently stop being boosted.
	local declared: number? = nil
	for _, definition in ipairs(BiomeMath.Biomes) do
		if definition.id == biomeId then
			declared = #definition.auraIds
		end
	end
	if declared == nil or declared ~= #boost.rungs then
		table.insert(
			rungProblems,
			string.format("%s declares %s rungs but resolved %d", biomeId, tostring(declared), #boost.rungs)
		)
	end

	for _, rung in ipairs(boost.rungs) do
		local config = AuraRegistry.Get(rung.auraId)
		if config == nil then
			table.insert(rungProblems, string.format("%s rung %s is not on the ladder", biomeId, rung.auraId))
		elseif config.rarity ~= rung.rarity or config.displayName ~= rung.displayName or config.tier ~= rung.tier then
			table.insert(rungProblems, string.format("%s rung %s disagrees with the ladder", biomeId, rung.auraId))
		end
		themedTotal[rung.auraId] = (themedTotal[rung.auraId] or 0) + 1
	end
	for index = 2, #boost.rungs do
		if boost.rungs[index - 1].rarity >= boost.rungs[index].rarity then
			table.insert(rungProblems, string.format("%s rungs are not ascending by rarity", biomeId))
		end
	end
end
check("every event's rungs resolve to real ladder entries, ascending, with the ladder's own labels", #rungProblems == 0, table.concat(rungProblems, "; "))

--[[
	Coverage, which is a design statement rather than a bug: the three themes
	partition the ladder. It is asserted so that a later retune has to remove a rung
	from one event before adding it to another, instead of quietly leaving a rung
	that no event can ever favour.
]]
local uncovered: { string } = {}
local duplicated: { string } = {}
for _, auraId in ipairs(AuraRegistry.ORDER) do
	local count = themedTotal[auraId] or 0
	if count == 0 then
		table.insert(uncovered, auraId)
	elseif count > 1 then
		table.insert(duplicated, auraId)
	end
end
check(
	"every rung on the ladder belongs to exactly one event (12 of 12 themed, none twice)",
	#uncovered == 0 and #duplicated == 0,
	string.format("unthemed: [%s]  themed twice: [%s]", table.concat(uncovered, ", "), table.concat(duplicated, ", "))
)

check("the shipped biome config audits clean", #BiomeMath.Audit(AuraRegistry) == 0, table.concat(BiomeMath.Audit(AuraRegistry), "; "))

-- Negative control for the audit: a ladder missing a themed aura must be caught.
local crippledLadder = {
	ORDER = AuraRegistry.ORDER,
	Get = function(id: string): any?
		if id == "Ember" then
			return nil
		end
		return AuraRegistry.Get(id)
	end,
}
local crippledProblems = BiomeMath.Audit(crippledLadder :: any)
local mentionsEmber = false
for _, problem in ipairs(crippledProblems) do
	if string.find(problem, "Ember", 1, true) ~= nil then
		mentionsEmber = true
	end
end
check(
	"the audit catches a themed aura the ladder does not have (control)",
	#crippledProblems > 0 and mentionsEmber,
	table.concat(crippledProblems, "; ")
)

-- =============================================================================
section("Biome events: the boost is one more weight factor in the one selection path")

local function chanceById(odds: { any }, auraId: string): number?
	for _, entry in ipairs(odds) do
		if entry.auraId == auraId then
			return entry.chance
		end
	end
	return nil
end

local function shareOf(odds: { any }, ids: { [string]: boolean }): number
	local total = 0
	for _, entry in ipairs(odds) do
		if ids[entry.auraId] == true then
			total += entry.chance
		end
	end
	return total
end

--[[
	THE claim, exactly: under an event, a themed rung's probability relative to an
	unthemed rung's is 3x what it is without the event. Both sides are measured from
	RollMath's own table, so this fails if the multiply is dropped, applied to the
	whole pool, or applied to a rung the event does not theme.

	Run at several luck/pity points, because the factor has to COMPOSE with the
	two factors already in the weight vector rather than replace them.
]]
local ratioProblems: { string } = {}
local untouchedProblems: { string } = {}
local sumProblems: { string } = {}
for _, scenario in ipairs({
	{ label = "luck 1", luck = 1, pity = 0 },
	{ label = "luck 25", luck = 25, pity = 0 },
	{ label = "soft pity (1 stack)", luck = 1, pity = 60 },
	{ label = "soft pity cap", luck = 1, pity = 300 },
}) do
	local without = RollMath.ChanceTable(scenario.luck, scenario.pity, nil)
	for _, biomeId in ipairs(BIOME_IDS) do
		local boost = BIOME_BOOSTS[biomeId]
		local with = RollMath.ChanceTable(scenario.luck, scenario.pity, boost)

		local total = 0
		for _, entry in ipairs(with) do
			total += entry.chance
		end
		if math.abs(total - 1) > 1e-9 then
			table.insert(sumProblems, string.format("%s / %s: total=%s", biomeId, scenario.label, tostring(total)))
		end

		-- Unthemed rungs: every one of them must have moved by the SAME factor,
		-- which is exactly what "only the themed weights changed" means numerically.
		local unthemedFactor: number? = nil
		local themed: { string } = {}
		local unthemed: { string } = {}
		for _, entry in ipairs(with) do
			local base = chanceById(without, entry.auraId)
			if base == nil or base <= 0 then
				table.insert(ratioProblems, string.format("%s / %s: %s missing without the event", biomeId, scenario.label, entry.auraId))
			elseif boost.auraIds[entry.auraId] == true then
				table.insert(themed, entry.auraId)
			else
				table.insert(unthemed, entry.auraId)
				local factor = entry.chance / base
				if unthemedFactor == nil then
					unthemedFactor = factor
				elseif not approx(factor, unthemedFactor, 1e-12) then
					table.insert(untouchedProblems, string.format("%s / %s: %s moved by %s, the rest by %s", biomeId, scenario.label, entry.auraId, tostring(factor), tostring(unthemedFactor)))
				end
			end
		end

		for _, auraId in ipairs(themed) do
			local base = chanceById(without, auraId) :: number
			local withChance = chanceById(with, auraId) :: number
			local relative = (withChance / base) / (unthemedFactor :: number)
			if not approx(relative, 3, 1e-9) then
				table.insert(ratioProblems, string.format("%s / %s: %s is %sx, not 3x", biomeId, scenario.label, auraId, string.format("%.6f", relative)))
			end
		end
	end
end
check("every themed rung is exactly 3x its unthemed neighbours, under luck and soft pity", #ratioProblems == 0, table.concat(ratioProblems, "; "))
check("no unthemed rung is individually affected - they all share one re-normalisation factor", #untouchedProblems == 0, table.concat(untouchedProblems, "; "))
check("the distribution sums to exactly 1 with an event running (the weights still normalise)", #sumProblems == 0, table.concat(sumProblems, "; "))

-- The luck still works while an event runs: composing must not mean replacing.
-- At luck 50 the rarest themed rung is about 8.9x more likely than at luck 1 (the
-- floor rung drains the pool as luck rises); the bound is deliberately loose so a
-- balance change is not a test failure, while "luck did nothing" still is.
local luckGap = chanceById(RollMath.ChanceTable(50, 0, BIOME_BOOSTS.Starfall), "Sovereign")
	/ (chanceById(RollMath.ChanceTable(1, 0, BIOME_BOOSTS.Starfall), "Sovereign") :: number)
check("luck still moves the odds while an event runs (it composes, it does not replace)", luckGap > 3, string.format("luck 50 vs luck 1: %.2fx", luckGap))

--[[
	Hard pity restricts the pool. An event does not un-restrict it, and a themed
	rung below the pity floor simply is not in that pool - the boost is not a way
	around the floor.
]]
local pityOdds = RollMath.ChanceTable(1, 99, BIOME_BOOSTS.BloodMoon)
local pityWithout = RollMath.ChanceTable(1, 99, nil)
local pityTotal = 0
for _, entry in ipairs(pityOdds) do
	pityTotal += entry.chance
end
-- Sunflare is the unthemed reference: it is in the hard-pity pool (1 in 1,500),
-- which Frostbite and Static are not.
local pityRelative = (chanceById(pityOdds, "Voidwalker") :: number / (chanceById(pityWithout, "Voidwalker") :: number))
	/ (chanceById(pityOdds, "Sunflare") :: number / (chanceById(pityWithout, "Sunflare") :: number))
check(
	"under hard pity the themed rungs still in the pool are 3x, the rest of the pool is not",
	math.abs(pityTotal - 1) < 1e-9 and approx(pityRelative, 3, 1e-9),
	string.format("total=%s relative=%s", tostring(pityTotal), string.format("%.6f", pityRelative))
)
check(
	"the hard-pity pool is exactly the rungs at or above the pity floor - an event does not widen it",
	chanceById(pityOdds, "Frostbite") == nil
		and chanceById(pityOdds, "Static") == nil
		and chanceById(pityOdds, "Bloom") ~= nil
		and chanceById(pityOdds, "Voidwalker") ~= nil,
	string.format("pool size %d", #pityOdds)
)
check(
	"a themed rung below the hard-pity floor is not in that pool at all (the event is not a way around pity)",
	chanceById(pityOdds, "Ember") == nil and chanceById(pityOdds, "Ember") == nil,
	if chanceById(pityOdds, "Ember") ~= nil then "Ember appeared in a hard-pity pool" else ""
)

--[[
	The pool's FLOOR is the rung that the luck boost is deliberately exempt from, so
	it is the one rung where the two factors interact. Ember (1 in 2) is Blood Moon's
	floor, and "floor" must mean "exempt from luck", not "exempt from the event".
]]
local floorProblems: { string } = {}
for _, luck in ipairs({ 1, 25, 500, 1e6 }) do
	local without = RollMath.ChanceTable(luck, 0, nil)
	local with = RollMath.ChanceTable(luck, 0, BIOME_BOOSTS.BloodMoon)
	local emberBase = chanceById(without, "Ember") :: number
	local emberWith = chanceById(with, "Ember") :: number
	local otherBase = chanceById(without, "Frostbite") :: number
	local otherWith = chanceById(with, "Frostbite") :: number
	local relative = (emberWith / emberBase) / (otherWith / otherBase)
	if not approx(relative, 3, 1e-9) then
		table.insert(floorProblems, string.format("luck %s: floor rung is %sx", tostring(luck), string.format("%.6f", relative)))
	end
end
check("the pool's floor rung is boosted exactly like any other themed rung (floor exempts luck, not events)", #floorProblems == 0, table.concat(floorProblems, "; "))

--[[
	What the DRAWN roll reports, and whether the draw really walked the boosted
	weights. 40,000 rolls under Blood Moon, whose floor rung is themed: if the
	multiply is dropped the themed share falls by ~1.6 points, which is ~7 standard
	errors at this sample size, so the per-rung bound below is a real test of the
draw and not just of the table it was built from.
]]
local SAMPLE_ROLLS = 40000
local sampleBoost = BIOME_BOOSTS.BloodMoon
local sampleOdds = RollMath.ChanceTable(1, 0, sampleBoost)
local predicted: { [string]: number } = {}
for _, entry in ipairs(sampleOdds) do
	predicted[entry.auraId] = entry.chance
end
local counts: { [string]: number } = {}
local source = RollMath.SequenceRandom(20261015)
local idMismatches = 0
local flagMismatches = 0
local chanceMismatches = 0
for _ = 1, SAMPLE_ROLLS do
	local outcome = RollMath.SelectAura(1, 0, source, sampleBoost)
	counts[outcome.auraId] = (counts[outcome.auraId] or 0) + 1

	if outcome.biomeId ~= sampleBoost.id then
		idMismatches += 1
	end
	if outcome.biomeBoosted ~= (sampleBoost.auraIds[outcome.auraId] == true) then
		flagMismatches += 1
	end
	if not approx(outcome.chance, predicted[outcome.auraId] :: number, 1e-12) then
		chanceMismatches += 1
	end
end
check("every draw under an event reports that event as its own", idMismatches == 0, string.format("%d draws", idMismatches))
check("biomeBoosted is true for exactly the themed rungs and no others", flagMismatches == 0, string.format("%d draws", flagMismatches))
check("the drawn rung's reported chance is the event's own probability", chanceMismatches == 0, string.format("%d draws", chanceMismatches))

local sampleProblems: { string } = {}
for _, entry in ipairs(sampleOdds) do
	local observed = counts[entry.auraId] or 0
	local expected = entry.chance * SAMPLE_ROLLS
	local deviation = math.sqrt(SAMPLE_ROLLS * entry.chance * (1 - entry.chance))
	-- 4 sigma, plus a floor so a rung expected once is not held to a fractional count.
	local allowed = 4 * deviation + 2
	if math.abs(observed - expected) > allowed then
		table.insert(sampleProblems, string.format("%s: drew %d, expected %.1f (+-%.1f)", entry.auraId, observed, expected, allowed))
	end
end
check(
	string.format("%d draws match the boosted table rung by rung (the draw walks the boosted weights)", SAMPLE_ROLLS),
	#sampleProblems == 0,
	table.concat(sampleProblems, "; ")
)

local observedThemed = 0
for auraId, count in pairs(counts) do
	if sampleBoost.auraIds[auraId] == true then
		observedThemed += count
	end
end
local unboostedThemed = shareOf(RollMath.ChanceTable(1, 0, nil), sampleBoost.auraIds)
local observedShare = observedThemed / SAMPLE_ROLLS
check(
	"the event visibly lifts its themed share of pulls (x3 is not a rounding error)",
	observedShare > unboostedThemed + 0.005,
	string.format("observed %.4f vs unboosted %.4f", observedShare, unboostedThemed)
)

--[[
	A roll that lands exactly on a switch. RollMath has no clock and no ambient
	event: the boost is an argument, resolved for the whole pool before the first
	weight is written, so a roll cannot be half one event and half the next. What
	this asserts is that the outcome can only ever describe the event it was given.
]]
local crossProblems: { string } = {}
for _, biomeId in ipairs(BIOME_IDS) do
	local boost = BIOME_BOOSTS[biomeId]
	local draws = RollMath.SequenceRandom(11)
	for _ = 1, 2000 do
		local outcome = RollMath.SelectAura(1, 0, draws, boost)
		local themedBy = 0
		for _, otherId in ipairs(BIOME_IDS) do
			if BIOME_BOOSTS[otherId].auraIds[outcome.auraId] == true then
				themedBy += 1
			end
		end
		if outcome.biomeId ~= biomeId or themedBy > 1 then
			table.insert(crossProblems, string.format("%s draw reported %s", biomeId, tostring(outcome.biomeId)))
		elseif outcome.biomeBoosted and boost.auraIds[outcome.auraId] ~= true then
			table.insert(crossProblems, string.format("%s draw boosted a rung it does not theme", biomeId))
		end
	end
end
check(
	"a roll is resolved entirely under the event it was given - never half of each (2000 draws x 3 events)",
	#crossProblems == 0,
	table.concat(crossProblems, "; ")
)

--[[
	Hostile and malformed boosts. The roll path has to stay total: every one of
	these must behave as a plain roll, and - specifically - a boost must never be a
	NERF, because a damaged config turning the game harder for five minutes is worse
	than no event at all.
]]
local function matchesTable(boost: any, reference: { any }): boolean
	local odds = RollMath.ChanceTable(1, 0, boost)
	if #odds ~= #reference then
		return false
	end
	for index, entry in ipairs(odds) do
		if entry.auraId ~= reference[index].auraId or not approx(entry.chance, reference[index].chance, 1e-12) then
			return false
		end
	end
	return true
end

local plain = RollMath.ChanceTable(1, 0, nil)
local starfallSansId = { multiplier = 3, auraIds = BIOME_BOOSTS.Starfall.auraIds }
local capped = RollMath.ChanceTable(1, 0, { id = "X", multiplier = 100, auraIds = BIOME_BOOSTS.Starfall.auraIds })

check("no event at all leaves the table untouched", matchesTable(nil, plain))
check("a multiplier below 1 degrades to no event rather than becoming a nerf", matchesTable({ id = "Starfall", multiplier = 0.5, auraIds = BIOME_BOOSTS.Starfall.auraIds }, plain))
check("a multiplier that is not a number degrades to no event", matchesTable({ id = "Starfall", multiplier = "3", auraIds = BIOME_BOOSTS.Starfall.auraIds }, plain))
check("a NaN multiplier degrades to no event", matchesTable({ id = "Starfall", multiplier = 0 / 0, auraIds = BIOME_BOOSTS.Starfall.auraIds }, plain))
check("an absent multiplier degrades to no event", matchesTable({ id = "Starfall", auraIds = BIOME_BOOSTS.Starfall.auraIds }, plain))
check(
	"an absurd multiplier is clamped to the constant instead of swallowing the pool",
	matchesTable({ id = "X", multiplier = 1e9, auraIds = BIOME_BOOSTS.Starfall.auraIds }, capped)
		and not matchesTable({ id = "X", multiplier = 1e9, auraIds = BIOME_BOOSTS.Starfall.auraIds }, plain),
	"a 1e9 multiplier is not equal to the clamped table"
)
check(
	"an event with no rungs weighs nothing (but still names itself)",
	matchesTable({ id = "X", multiplier = 3, auraIds = {} }, plain)
		and RollMath.SelectAura(1, 0, nil, { id = "X", multiplier = 3, auraIds = {} }).biomeId == "X",
	"an empty themed set changed a weight"
)
check(
	"a thematic rung id that is not on the ladder matches no entry",
	matchesTable({ id = "X", multiplier = 3, auraIds = { NotAnAura = true } }, plain)
)
check(
	"an aura list passed where a membership set belongs degrades to no event (not to a mis-weighing)",
	matchesTable({ id = "X", multiplier = 3, auraIds = { "Ember" } }, plain)
)
check(
	"an event with no id still weighs - the id is a label, the weights are the effect",
	matchesTable(starfallSansId, RollMath.ChanceTable(1, 0, BIOME_BOOSTS.Starfall)),
	"an anonymous event did not weigh like the named one"
)
check(
	"an anonymous event reports no id, so a client can never badge a pull with it",
	RollMath.SelectAura(1, 0, nil, starfallSansId).biomeId == nil
)
check("a plain roll reports no event", RollMath.SelectAura(1, 0, nil, nil).biomeId == nil and RollMath.SelectAura(1, 0, nil).biomeMultiplier == 1)

-- Determinism under an event: the same seed and the same event give the same run.
local function runIds(seed: number, boost: any, rolls: number): { string }
	local draws = RollMath.SequenceRandom(seed)
	local seen: { string } = {}
	for _ = 1, rolls do
		table.insert(seen, RollMath.SelectAura(1, 0, draws, boost).auraId)
	end
	return seen
end

local runA = runIds(4242, BIOME_BOOSTS.VoidEclipse, 500)
local runB = runIds(4242, BIOME_BOOSTS.VoidEclipse, 500)
local identical = #runA == #runB
if identical then
	for index, auraId in ipairs(runA) do
		if auraId ~= runB[index] then
			identical = false
			break
		end
	end
end
check("the same seed under the same event reproduces the same 500 pulls", identical)

local runC = runIds(4242, BIOME_BOOSTS.Starfall, 500)
local differs = false
for index, auraId in ipairs(runA) do
	if auraId ~= runC[index] then
		differs = true
		break
	end
end
check("a different event on the same seed draws a different run (the weights really differ)", differs)

-- =============================================================================
print("")
if failures == 0 then
	print(string.format("ALL %d CHECKS PASSED", checks))
else
	print(string.format("%d of %d CHECKS FAILED", failures, checks))
end

process.exit(failures == 0 and 0 or 1)
