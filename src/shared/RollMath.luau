--!strict
--[[
	RollMath
	========
	A PURE, deterministic-testable weighted RNG selector with soft/hard pity.

	ZERO Roblox dependencies:
	  * No `game`, no `Instance`, no `typeof`, no `task`, no workspace access.
	  * The only globals used are the plain Luau standard library
	    (`math`, `table`, `string`, `pcall`, `error`, `type`, `require`).
	  * Because of that you can execute and test this file straight from a
	    terminal with Lune or the Luau CLI. `require("./AuraRegistry")` is used as
	    a fallback loader when the Roblox `script` global does not exist.

	  lune run ./test_rollmath        (or)
	  luau --interactive --path .

	RNG MODEL
	---------
	The pool is sampled with a single uniform draw against cumulative weights.

	Luck must change the *shape* of the distribution, not merely its scale. A
	weight of `luck / rarity` applied to every entry scales the whole weight
	vector by a constant, which cancels out during normalisation and would make
	luck do literally nothing. So the pool's most common aura (its "floor")
	keeps its base weight while everything rarer gets `rarity / luck`. The floor
	absorbs the difference and luck genuinely shifts odds toward the rare end.

	PITY MODEL
	----------
	  * Soft pity  : every SOFT_PITY_INTERVAL rolls without a rarity >= 50 pull,
	                 luck gains a stacking bonus of SOFT_PITY_STEP.
	  * Hard pity  : on the HARD_PITY_ROLLS-th consecutive roll the pool is
	                 restricted to auras with rarity >= HARD_PITY_MIN_RARITY,
	                 which guarantees the pull.
]]

export type RegistryEntry = {
	id: string,
	displayName: string,
	tier: string,
	rarity: number,
}

export type RegistryLike = {
	ORDER: { string },
	Get: (id: string) -> RegistryEntry?,
}

export type RandomSource = () -> number

export type Constants = {
	softPityInterval: number,
	softPityStep: number,
	maxSoftPityStacks: number,
	hardPityRolls: number,
	hardPityMinRarity: number,
	minLuck: number,
	maxLuck: number,
}

export type RollOutcome = {
	auraId: string,
	displayName: string,
	tier: string,
	rarity: number,
	chance: number, -- true probability of this aura on this roll
	oneInN: number, -- 1 / chance, after luck + pity
	luckUsed: number, -- effective luck applied to the weights
	softPityStacks: number,
	hardPityTriggered: boolean,
	rollsSinceRare: number,
	poolSize: number,
}

export type OddsEntry = {
	auraId: string,
	displayName: string,
	tier: string,
	rarity: number,
	chance: number,
	oneInN: number,
}

export type SimulationReport = {
	rolls: number,
	counts: { [string]: number },
	rarityCounts: { [number]: number },
	bestAuraId: string?,
	bestRarity: number,
	hardPityHits: number,
	longestDrought: number,
	rarePlusCount: number,
}

local CONSTANTS: Constants = {
	-- Soft pity: +100% luck for every 50 consecutive rolls without a rare.
	softPityInterval = 50,
	softPityStep = 1.0,
	maxSoftPityStacks = 5,

	-- Hard pity: the 100th consecutive roll is guaranteed rarity >= 50.
	hardPityRolls = 100,
	hardPityMinRarity = 50,

	minLuck = 0.01,
	maxLuck = 1e6,
}

-- =============================================================================
-- Registry loading (Roblox first, then Lune/Luau CLI relative require).
-- =============================================================================

local registryOverride: RegistryLike? = nil
local cachedRegistry: RegistryLike? = nil

local function loadRegistry(): RegistryLike
	local override = registryOverride
	if override ~= nil then
		return override
	end

	local cached = cachedRegistry
	if cached ~= nil then
		return cached
	end

	-- 1) Roblox: this module lives next to AuraRegistry inside ReplicatedStorage.Shared.
	local scriptGlobal: any = script
	if scriptGlobal ~= nil then
		local parent: any = scriptGlobal.Parent
		if parent ~= nil then
			local module: any = parent:FindFirstChild("AuraRegistry")
			if module ~= nil then
				local loaded: RegistryLike = require(module)
				cachedRegistry = loaded
				return loaded
			end
		end
	end

	-- 2) Lune / Luau CLI: require the sibling file by relative path.
	local dynRequire: any = require
	local ok: boolean, module: any = pcall(dynRequire, "./AuraRegistry")
	if ok and module ~= nil then
		local loaded: RegistryLike = module
		cachedRegistry = loaded
		return loaded
	end

	error(
		"RollMath: could not locate AuraRegistry. When running outside Roblox, "
			.. "call RollMath.SetRegistry(AuraRegistry) before rolling.",
		2
	)
end

-- =============================================================================
-- Internal helpers
-- =============================================================================

local function defaultRandom(): number
	return math.random()
end

local function sanitizeNumber(value: number, fallback: number, minimum: number, maximum: number): number
	if type(value) ~= "number" then
		return fallback
	end
	if value ~= value then -- NaN
		return fallback
	end
	if value < minimum then
		return minimum
	end
	if value > maximum then
		return maximum
	end
	return value
end

local function sanitizeRandom(source: RandomSource?): RandomSource
	if type(source) ~= "function" then
		return defaultRandom
	end
	return source
end

type Pool = {
	entries: { RegistryEntry },
	weights: { number },
	total: number,
	luckUsed: number,
	softPityStacks: number,
	hardPityTriggered: boolean,
}

local function buildPool(luckMultiplier: number, pityCount: number): Pool
	local registry = loadRegistry()

	local safeLuck = sanitizeNumber(luckMultiplier, 1, CONSTANTS.minLuck, CONSTANTS.maxLuck)
	local safePity = sanitizeNumber(pityCount, 0, 0, CONSTANTS.hardPityRolls * 1000)
	safePity = math.floor(safePity)

	local hardPityTriggered = (safePity + 1) >= CONSTANTS.hardPityRolls and safePity > 0
	local stacks = math.floor(safePity / CONSTANTS.softPityInterval)
	if stacks > CONSTANTS.maxSoftPityStacks then
		stacks = CONSTANTS.maxSoftPityStacks
	end
	if stacks < 0 then
		stacks = 0
	end

	-- Hard pity ignores the soft pity ramp: the pool is already restricted.
	local luckUsed = safeLuck
	if not hardPityTriggered then
		luckUsed = safeLuck * (1 + CONSTANTS.softPityStep * stacks)
	end

	local entries: { RegistryEntry } = {}
	for _, id in ipairs(registry.ORDER) do
		local entry = registry.Get(id)
		if entry ~= nil then
			if not hardPityTriggered or entry.rarity >= CONSTANTS.hardPityMinRarity then
				table.insert(entries, entry)
			end
		end
	end

	-- Degenerate registry guard: never return an empty pool.
	if #entries == 0 then
		for _, id in ipairs(registry.ORDER) do
			local entry = registry.Get(id)
			if entry ~= nil then
				table.insert(entries, entry)
			end
		end
	end

	-- Floor rarity == the most common aura in this pool. It is exempt from the
	-- luck boost so the remaining weights can actually re-normalise.
	local floorRarity = math.huge
	for _, entry in ipairs(entries) do
		if entry.rarity < floorRarity then
			floorRarity = entry.rarity
		end
	end

	local weights: { number } = table.create(#entries)
	local total = 0
	for index, entry in ipairs(entries) do
		local effectiveRarity = entry.rarity
		if entry.rarity > floorRarity then
			effectiveRarity = entry.rarity / luckUsed
		end
		if effectiveRarity < 1 then
			effectiveRarity = 1
		end

		local weight = 1 / effectiveRarity
		weights[index] = weight
		total += weight
	end

	return {
		entries = entries,
		weights = weights,
		total = total,
		luckUsed = luckUsed,
		softPityStacks = stacks,
		hardPityTriggered = hardPityTriggered,
	}
end

-- Converts a [0, 1) draw into an index. Clamps defensive values so a broken
-- RNG can never index outside the pool.
local function pickIndex(pool: Pool, roll: number): number
	local count = #pool.weights
	local draw = sanitizeNumber(roll, 0, 0, 0.9999999999)
	local target = draw * pool.total
	local cumulative = 0
	for index = 1, count do
		cumulative += pool.weights[index]
		if target < cumulative then
			return index
		end
	end
	return count
end

-- =============================================================================
-- Public API
-- =============================================================================

local RollMath = {}

RollMath.Constants = CONSTANTS

-- Test / non-Roblox seam: inject the registry that supplies ids and rarities.
function RollMath.SetRegistry(registry: RegistryLike): ()
	registryOverride = registry
	cachedRegistry = nil
end

-- Drops the cached registry so the next roll re-resolves it.
function RollMath.ResetRegistryCache(): ()
	cachedRegistry = nil
end

function RollMath.SoftPityInterval(): number
	return CONSTANTS.softPityInterval
end

function RollMath.HardPityRolls(): number
	return CONSTANTS.hardPityRolls
end

function RollMath.HardPityMinRarity(): number
	return CONSTANTS.hardPityMinRarity
end

-- Number of soft-pity stacks accumulated at the given pity count.
function RollMath.SoftPityStacks(pityCount: number): number
	local safePity = math.max(0, math.floor(sanitizeNumber(pityCount, 0, 0, 1e9)))
	local stacks = math.floor(safePity / CONSTANTS.softPityInterval)
	if stacks > CONSTANTS.maxSoftPityStacks then
		return CONSTANTS.maxSoftPityStacks
	end
	return stacks
end

-- Luck multiplier contributed by soft pity alone (1.0 when inactive).
function RollMath.SoftPityMultiplier(pityCount: number): number
	return 1 + CONSTANTS.softPityStep * RollMath.SoftPityStacks(pityCount)
end

function RollMath.IsSoftPityActive(pityCount: number): boolean
	return RollMath.SoftPityStacks(pityCount) > 0
end

-- How many more rolls until the guaranteed rarity >= 50 pull. 0 == this roll.
function RollMath.RollsUntilGuaranteed(pityCount: number): number
	local safePity = math.max(0, math.floor(sanitizeNumber(pityCount, 0, 0, 1e9)))
	return math.max(0, CONSTANTS.hardPityRolls - (safePity + 1))
end

-- True when the *next* roll will be a guaranteed rarity >= 50 pull.
function RollMath.IsHardPityNext(pityCount: number): boolean
	return RollMath.RollsUntilGuaranteed(pityCount) == 0
end

--[[
	SelectAura(luckMultiplier, pityCount [, random])

	Pure weighted selection. `pityCount` is the number of consecutive rolls since
	the last aura with rarity >= HARD_PITY_MIN_RARITY.

	`random` is an injected 0..1 source; pass a deterministic generator for
	reproducible tests (see `RollMath.SequenceRandom`).

	Returns the full `RollOutcome` plus the raw registry entry that was drawn.
]]
function RollMath.SelectAura(
	luckMultiplier: number,
	pityCount: number,
	random: RandomSource?
): (RollOutcome, RegistryEntry)
	local pool = buildPool(luckMultiplier, pityCount)
	local source = sanitizeRandom(random)
	local index = pickIndex(pool, source())

	local chosen = pool.entries[index]
	local chance = pool.weights[index] / pool.total
	if chance <= 0 then
		chance = 1 / #pool.entries
	end

	local outcome: RollOutcome = {
		auraId = chosen.id,
		displayName = chosen.displayName,
		tier = chosen.tier,
		rarity = chosen.rarity,
		chance = chance,
		oneInN = 1 / chance,
		luckUsed = pool.luckUsed,
		softPityStacks = pool.softPityStacks,
		hardPityTriggered = pool.hardPityTriggered,
		rollsSinceRare = math.max(0, math.floor(sanitizeNumber(pityCount, 0, 0, 1e9))),
		poolSize = #pool.entries,
	}

	return outcome, chosen
end

--[[
	ChanceTable(luckMultiplier, pityCount)

	Every aura's real probability for the *next* roll, rarest first. Purely
	informational - useful for odds panels and for asserting pity behaviour.
]]
function RollMath.ChanceTable(luckMultiplier: number, pityCount: number): { OddsEntry }
	local pool = buildPool(luckMultiplier, pityCount)
	local table_: { OddsEntry } = table.create(#pool.entries)

	for index, entry in ipairs(pool.entries) do
		local chance = pool.weights[index] / pool.total
		table.insert(table_, {
			auraId = entry.id,
			displayName = entry.displayName,
			tier = entry.tier,
			rarity = entry.rarity,
			chance = chance,
			oneInN = if chance > 0 then 1 / chance else math.huge,
		})
	end

	table.sort(table_, function(left: OddsEntry, right: OddsEntry): boolean
		return left.chance > right.chance
	end)

	return table_
end

-- Probability of pulling anything at rarity >= minRarity on the next roll.
function RollMath.ChanceOfAtLeast(minRarity: number, luckMultiplier: number, pityCount: number): number
	local odds = RollMath.ChanceTable(luckMultiplier, pityCount)
	local total = 0
	for _, entry in ipairs(odds) do
		if entry.rarity >= minRarity then
			total += entry.chance
		end
	end
	return total
end

--[[
	Deterministic 0..1 generator for tests: a plain LCG so the same seed always
	produces the same sequence of rolls on every machine.
]]
function RollMath.SequenceRandom(seed: number?): RandomSource
	local state = math.floor(sanitizeNumber(seed, 0, 0, 2 ^ 31 - 1))
	if state <= 0 then
		state = 20260114
	end

	return function(): number
		-- Numerical Recipes LCG: state = 1664525*state + 1013904223 (mod 2^32)
		state = (1664525 * state + 1013904223) % 4294967296
		return state / 4294967296
	end
end

--[[
	Simulate(rollCount, luckMultiplier?, random?)

	Runs the real pity state machine for `rollCount` rolls and reports the
	distribution. This is the function the terminal test harness exercises, and
	it is also handy for balancing tiers without launching Roblox.
]]
function RollMath.Simulate(rollCount: number, luckMultiplier: number?, random: RandomSource?): SimulationReport
	local total = math.max(0, math.floor(sanitizeNumber(rollCount, 0, 0, 1e9)))
	local luck = sanitizeNumber(luckMultiplier, 1, CONSTANTS.minLuck, CONSTANTS.maxLuck)
	local source = sanitizeRandom(random)

	local counts: { [string]: number } = {}
	local rarityCounts: { [number]: number } = {}
	local pity = 0
	local drought = 0
	local longestDrought = 0
	local hardPityHits = 0
	local rarePlusCount = 0
	local bestRarity = 0
	local bestAuraId: string? = nil

	for _ = 1, total do
		local outcome = RollMath.SelectAura(luck, pity, source)

		counts[outcome.auraId] = (counts[outcome.auraId] or 0) + 1
		rarityCounts[outcome.rarity] = (rarityCounts[outcome.rarity] or 0) + 1

		if outcome.hardPityTriggered then
			hardPityHits += 1
		end

		if outcome.rarity > bestRarity then
			bestRarity = outcome.rarity
			bestAuraId = outcome.auraId
		end

		if outcome.rarity >= CONSTANTS.hardPityMinRarity then
			rarePlusCount += 1
			pity = 0
			if drought > longestDrought then
				longestDrought = drought
			end
			drought = 0
		else
			pity += 1
			drought += 1
		end
	end

	if drought > longestDrought then
		longestDrought = drought
	end

	return {
		rolls = total,
		counts = counts,
		rarityCounts = rarityCounts,
		bestAuraId = bestAuraId,
		bestRarity = bestRarity,
		hardPityHits = hardPityHits,
		longestDrought = longestDrought,
		rarePlusCount = rarePlusCount,
	}
end

return RollMath
