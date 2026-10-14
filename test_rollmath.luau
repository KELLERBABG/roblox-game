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
print("")
if failures == 0 then
	print(string.format("ALL %d CHECKS PASSED", checks))
else
	print(string.format("%d of %d CHECKS FAILED", failures, checks))
end

process.exit(failures == 0 and 0 or 1)
