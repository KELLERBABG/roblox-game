--!nocheck
--[[
	Terminal test harness for the monetization layer: MonetizationConfig,
	PerkMath, SaveBackend's receipt guard, and the WIRING between them.

	    lune run test_perks

	What this file can and cannot prove
	-----------------------------------
	PerkMath, MonetizationConfig and the receipt-claim guard are pure Luau, so they
	are EXECUTED here rather than inspected: the potion really is spent once per
	roll, the multipliers really do stack to 30x, an unset id really does refuse to
	resolve to placeholder 0.

	PerkService, ShopService and RNGService need a Roblox runtime, so their
	server-authority is asserted two ways instead: behaviourally at the seam the
	harness can reach (the pure numbers they consume), and structurally against
	their source (RNGService asks PerkService for every multiplier and spends a
	potion through it; no MarketplaceService call exists outside ShopService).
	Studio Play mode is still required to prove the engine-side half - see the
	NOTEs printed at the end.

	The source scan needs the harness to run from the project root; if the files
	cannot be read it prints a NOTE instead of pretending to pass.
]]

local process = require("@lune/process")
local fs = require("@lune/fs")

local MonetizationConfig = require("./src/server/MonetizationConfig")
local PerkMath = require("./src/server/PerkMath")
local SaveBackend = require("./src/server/SaveBackend")
local StreakMath = require("./src/server/StreakMath")
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

-- =============================================================================
section("MonetizationConfig: the four passes the mission specifies")

check("four passes are declared", #MonetizationConfig.passes == 4, tostring(#MonetizationConfig.passes))

local doubleLuck = MonetizationConfig.FindPass("DoubleLuck")
local fastRoll = MonetizationConfig.FindPass("FastRoll")
local autoRoll = MonetizationConfig.FindPass("AutoRoll")
local vip = MonetizationConfig.FindPass("VIP")
check("every specified pass key resolves", doubleLuck ~= nil and fastRoll ~= nil and autoRoll ~= nil and vip ~= nil)

check("2x Luck grants exactly 2x luck", doubleLuck ~= nil and doubleLuck.luckMultiplier == 2)
check(
	"Fast Roll cuts the cooldown to 0.6x (-40%)",
	fastRoll ~= nil and fastRoll.cooldownMultiplier == 0.6,
	if fastRoll ~= nil then tostring(fastRoll.cooldownMultiplier) else "missing"
)
check(
	"Fast Roll grants no luck of its own",
	fastRoll ~= nil and fastRoll.luckMultiplier == nil
)
check("Auto-Roll unlocks the auto-roll clock", autoRoll ~= nil and autoRoll.unlocksAutoRoll == true)
check(
	"Auto-Roll grants neither luck nor a cooldown cut",
	autoRoll ~= nil and autoRoll.luckMultiplier == nil and autoRoll.cooldownMultiplier == nil
)
check(
	"VIP grants +25% luck and the gold nametag",
	vip ~= nil and vip.luckMultiplier == 1.25 and vip.givesNametag == true,
	if vip ~= nil then tostring(vip.luckMultiplier) else "missing"
)

local duplicateKeys: { string } = {}
local seenPassKey: { [string]: boolean } = {}
for _, entry in ipairs(MonetizationConfig.passes) do
	if seenPassKey[entry.key] then
		table.insert(duplicateKeys, entry.key)
	end
	seenPassKey[entry.key] = true
end
check("pass keys are unique", #duplicateKeys == 0, table.concat(duplicateKeys, ", "))

local orderedPasses = 0
local passOrderOk = #MonetizationConfig.passOrder == #MonetizationConfig.passes
for _, key in ipairs(MonetizationConfig.passOrder) do
	if MonetizationConfig.FindPass(key) == nil then
		passOrderOk = false
	else
		orderedPasses += 1
	end
end
check("passOrder names every pass and nothing else", passOrderOk and orderedPasses == #MonetizationConfig.passes)

local effectlessPasses: { string } = {}
for _, entry in ipairs(MonetizationConfig.passes) do
	local hasEffect = entry.luckMultiplier ~= nil
		or entry.cooldownMultiplier ~= nil
		or entry.unlocksAutoRoll == true
		or entry.givesNametag == true
	if not hasEffect then
		table.insert(effectlessPasses, entry.key)
	end
end
check("no pass is a no-op (each grants at least one effect)", #effectlessPasses == 0, table.concat(effectlessPasses, ", "))

-- =============================================================================
section("MonetizationConfig: the two developer products")

check("two products are declared", #MonetizationConfig.products == 2, tostring(#MonetizationConfig.products))

local potion = MonetizationConfig.FindProduct("LuckPotion")
local boost = MonetizationConfig.FindProduct("ServerBoost")
check("the potion is +500% luck (6x) for one roll", potion ~= nil and potion.luckMultiplier == 6 and potion.charges == 1)
check("the potion is not a timed boost", potion ~= nil and potion.durationSeconds == nil)
check(
	"the server boost is 2x for 10 minutes, server-wide",
	boost ~= nil and boost.luckMultiplier == 2 and boost.durationSeconds == 600
)
check("the server boost is not a per-player charge", boost ~= nil and boost.charges == nil)

local productOrderOk = #MonetizationConfig.productOrder == #MonetizationConfig.products
for _, key in ipairs(MonetizationConfig.productOrder) do
	if MonetizationConfig.FindProduct(key) == nil then
		productOrderOk = false
	end
end
check("productOrder names every product", productOrderOk)

-- =============================================================================
section("Unset ids degrade instead of resolving to placeholder 0")

local configuredIds = 0
for _, entry in ipairs(MonetizationConfig.passes) do
	if MonetizationConfig.IsConfigured(entry) then
		configuredIds += 1
	end
end
for _, entry in ipairs(MonetizationConfig.products) do
	if MonetizationConfig.IsConfigured(entry) then
		configuredIds += 1
	end
end
check("no real id is set yet, so every entry reports unconfigured", configuredIds == 0, tostring(configuredIds))

-- The trap this guards: placeholder ids are 0, so a naive lookup would match one
-- and a stray receipt or query for id 0 would land on a real perk.
check("product id 0 does NOT resolve to a product", MonetizationConfig.FindProductById(0) == nil)
check("pass id 0 does NOT resolve to a pass", MonetizationConfig.FindPassById(0) == nil)
check("an unpublished id (1) resolves to nothing", MonetizationConfig.FindProductById(1) == nil)

local summary = MonetizationConfig.Describe()
check(
	"Describe() reports 4 passes / 2 products / 0 configured",
	summary.passCount == 4 and summary.productCount == 2
		and summary.configuredPasses == 0 and summary.configuredProducts == 0,
	string.format("%d/%d/%d/%d", summary.passCount, summary.productCount, summary.configuredPasses, summary.configuredProducts)
)

-- =============================================================================
section("PerkMath: owning nothing is exactly neutral")

local neutral = PerkMath.NoContributions()
check(
	"no contributions is 1x luck, 1x cooldown, no unlocks",
	neutral.luckMultiplier == 1 and neutral.cooldownMultiplier == 1
		and neutral.unlocksAutoRoll == false and neutral.givesNametag == false
)

local bare = PerkMath.Combine(neutral, nil, 1)
check("a player with no perks rolls at exactly 1x luck", bare.luckMultiplier == 1, tostring(bare.luckMultiplier))
check("a player with no perks has no auto-roll and no nametag", bare.autoRollUnlocked == false and bare.vipNametag == false)
check("an expired/absent boost multiplies by nothing", PerkMath.Combine(neutral, nil, 0).luckMultiplier == 1)
check("an empty potion is not armed", not PerkMath.IsArmed(PerkMath.EmptyPotion()))

-- =============================================================================
section("PerkMath: owned passes fold, and multiply rather than add")

local allOwned: { [string]: boolean } = {}
for _, entry in ipairs(MonetizationConfig.passes) do
	allOwned[entry.key] = true
end

local allPassEffects = PerkMath.Combine(PerkMath.Contributions(MonetizationConfig.passes, allOwned), nil, 1)
check(
	"all four passes: 2x Luck * VIP 1.25 = 2.5x luck",
	approx(allPassEffects.luckMultiplier, 2.5, 1e-9),
	tostring(allPassEffects.luckMultiplier)
)
check("all four passes: cooldown is 0.6x", approx(allPassEffects.cooldownMultiplier, 0.6, 1e-9))
check("all four passes: auto-roll unlocked and nametag on", allPassEffects.autoRollUnlocked and allPassEffects.vipNametag)

local function effectsFor(keys: { string }): any
	local owned: { [string]: boolean } = {}
	for _, key in ipairs(keys) do
		owned[key] = true
	end
	return PerkMath.Combine(PerkMath.Contributions(MonetizationConfig.passes, owned), nil, 1)
end

local fastOnly = effectsFor({ "FastRoll" })
check("Fast Roll alone leaves luck at 1x", fastOnly.luckMultiplier == 1, tostring(fastOnly.luckMultiplier))
check("Fast Roll alone gives the 0.6x cooldown", approx(fastOnly.cooldownMultiplier, 0.6, 1e-9))
check("Fast Roll does not unlock auto-roll", not fastOnly.autoRollUnlocked)

local autoOnly = effectsFor({ "AutoRoll" })
check("Auto-Roll alone unlocks the clock at 1x luck", autoOnly.autoRollUnlocked and autoOnly.luckMultiplier == 1)
check("Auto-Roll alone does not change the cooldown", autoOnly.cooldownMultiplier == 1)

local vipOnly = effectsFor({ "VIP" })
check("VIP alone is 1.25x luck + nametag", approx(vipOnly.luckMultiplier, 1.25, 1e-9) and vipOnly.vipNametag)
check("VIP alone leaves the cooldown alone", vipOnly.cooldownMultiplier == 1)

-- =============================================================================
section("PerkMath: potion and server boost stack with the passes")

local withPotion = PerkMath.Combine(PerkMath.Contributions(MonetizationConfig.passes, allOwned), PerkMath.ArmPotion(6, 1), 1)
check("all passes + 6x potion = 15x", approx(withPotion.luckMultiplier, 15, 1e-9), tostring(withPotion.luckMultiplier))

local withEverything = PerkMath.Combine(
	PerkMath.Contributions(MonetizationConfig.passes, allOwned),
	PerkMath.ArmPotion(6, 1),
	2
)
check("all passes + potion + 2x server boost = 30x", approx(withEverything.luckMultiplier, 30, 1e-9), tostring(withEverything.luckMultiplier))
check("the potion and boost do not touch the cooldown", approx(withEverything.cooldownMultiplier, 0.6, 1e-9))

local potionOnly = PerkMath.Combine(neutral, PerkMath.ArmPotion(6, 1), 1)
check("a potion on a fresh account is 6x", approx(potionOnly.luckMultiplier, 6, 1e-9))
check("a server boost alone is 2x for everyone", approx(PerkMath.Combine(neutral, nil, 2).luckMultiplier, 2, 1e-9))

check("an active boost counts while its clock runs", PerkMath.BoostMultiplier(2, 1000, 999.9) == 2)
check("a boost stops counting the moment it expires", PerkMath.BoostMultiplier(2, 1000, 1000) == 1)
check("a boost stops counting after it expires", PerkMath.BoostMultiplier(2, 1000, 1001) == 1)
check("remaining boost time clamps at zero", PerkMath.BoostSecondsRemaining(1000, 1500) == 0)
check("remaining boost time counts down", approx(PerkMath.BoostSecondsRemaining(1000, 400), 600, 1e-9))

-- =============================================================================
section("PerkMath: the potion is consumed by exactly one roll")

local armed = PerkMath.ArmPotion(6, 1)
check("an armed potion reports as armed", PerkMath.IsArmed(armed))

local spentMultiplier, afterFirst = PerkMath.RollPotion(armed)
check("the first roll uses the potion multiplier (6x)", spentMultiplier == 6, tostring(spentMultiplier))
check("the potion has no charges left after that roll", afterFirst.charges == 0)
check("and is no longer armed", not PerkMath.IsArmed(afterFirst))

local secondMultiplier, afterSecond = PerkMath.RollPotion(afterFirst)
check("the second roll is back to 1x", secondMultiplier == 1, tostring(secondMultiplier))
check("rolling again never refills the potion", afterSecond.charges == 0)

local thirdMultiplier = PerkMath.RollPotion(afterSecond)
check("and the tenth roll is still 1x", thirdMultiplier == 1)

-- The same rule across a full roll sequence, which is the claim in the mission.
local sequenceMultipliers: { number } = {}
local runningState = PerkMath.ArmPotion(6, 1)
for _ = 1, 5 do
	local used: number
	used, runningState = PerkMath.RollPotion(runningState)
	table.insert(sequenceMultipliers, used)
end
check(
	"five rolls with one potion: 6,1,1,1,1",
	table.concat(sequenceMultipliers, ",") == "6,1,1,1,1",
	table.concat(sequenceMultipliers, ",")
)

local twoCharges = PerkMath.ArmPotion(6, 2)
local firstOfTwo, twoState = PerkMath.RollPotion(twoCharges)
local secondOfTwo, twoStateAfter = PerkMath.RollPotion(twoState)
local thirdOfTwo = PerkMath.RollPotion(twoStateAfter)
check("two stacked purchases pay for two rolls, then stop", firstOfTwo == 6 and secondOfTwo == 6 and thirdOfTwo == 1)

check("a potion armed with no charges is not armed", not PerkMath.IsArmed(PerkMath.ArmPotion(6, 0)))
check("a potion cannot be armed with a multiplier of 1", not PerkMath.IsArmed(PerkMath.ArmPotion(1, 3)))
check("negative charges are clamped to zero", PerkMath.ArmPotion(6, -4).charges == 0)
check(
	"a spent potion contributes no luck to the next roll",
	PerkMath.Combine(neutral, afterFirst, 1).luckMultiplier == 1
)

-- =============================================================================
section("PerkMath: a malformed config entry cannot break the roll path")

local function contributionOf(entry: any): any
	return PerkMath.Contributions({ entry }, { [entry.key] = true })
end

check("luckMultiplier 0 contributes nothing (never a zero-luck roll)", contributionOf({ key = "x", luckMultiplier = 0 }).luckMultiplier == 1)
check("luckMultiplier -5 contributes nothing", contributionOf({ key = "x", luckMultiplier = -5 }).luckMultiplier == 1)
check("luckMultiplier nil contributes nothing", contributionOf({ key = "x" }).luckMultiplier == 1)
check("cooldownMultiplier 0 contributes nothing", contributionOf({ key = "x", cooldownMultiplier = 0 }).cooldownMultiplier == 1)
check("an entry for a pass the player does not own contributes nothing", (function(): boolean
	local owned: { [string]: boolean } = {}
	local result = PerkMath.Contributions(MonetizationConfig.passes, owned)
	return result.luckMultiplier == 1 and result.cooldownMultiplier == 1
end)())
check("two entries of the same perk multiply (documented stacking)", (function(): boolean
	local result = PerkMath.Contributions(
		{ { key = "dup", luckMultiplier = 2 }, { key = "dup", luckMultiplier = 2 } },
		{ dup = true }
	)
	return approx(result.luckMultiplier, 4, 1e-9)
end)())

-- =============================================================================
section("SaveBackend: the save path's fallback, now shared with receipts")

check("player keys are unchanged (player_<userId>)", SaveBackend.PlayerKey(12345) == "player_12345", SaveBackend.PlayerKey(12345))
check("receipt keys are namespaced", SaveBackend.ReceiptKey("abc") == "receipt_abc", SaveBackend.ReceiptKey("abc"))

local backend = SaveBackend.Get("TestStore_v1")
check(
	"with no engine, the backend degrades to memory instead of erroring",
	backend.kind ~= "DataStore",
	backend.kind
)
check("an unknown key loads as nil", backend.load("player_999") == nil)

backend.save("player_999", { totalRolls = 7 })
local roundTrip = backend.load("player_999")
check("a saved value loads back", roundTrip ~= nil and roundTrip.totalRolls == 7)
check("Get returns the same backend for the same store", SaveBackend.Get("TestStore_v1") == backend)
check("a different store name gets its own backend", SaveBackend.Get("OtherStore_v1") ~= backend)

-- =============================================================================
section("SaveBackend: receipt claims are idempotent (one grant per purchase)")

local firstClaim = SaveBackend.ClaimReceipt(backend, SaveBackend.ReceiptKey("PurchaseA"))
check("the first claim of a purchase wins", firstClaim == true)
check("the same claim is refused", SaveBackend.ClaimReceipt(backend, SaveBackend.ReceiptKey("PurchaseA")) == false)
check("the claim is remembered in this session", SaveBackend.IsReceiptClaimed(SaveBackend.ReceiptKey("PurchaseA")))
check("a different purchase still grants", SaveBackend.ClaimReceipt(backend, SaveBackend.ReceiptKey("PurchaseB")) == true)
check(
	"the winning claim wrote a durable record",
	backend.load(SaveBackend.ReceiptKey("PurchaseA")) ~= nil
)

-- A claim already recorded by a previous session (durable store, cold session).
local freshSession = SaveBackend.Get("ReceiptsFromYesterday_v1")
freshSession.save(SaveBackend.ReceiptKey("PurchaseC"), { receipt = "PurchaseC" })
check(
	"a receipt granted by an earlier session is refused, not granted twice",
	SaveBackend.ClaimReceipt(freshSession, SaveBackend.ReceiptKey("PurchaseC")) == false
)

-- =============================================================================
section("Session streak curve: passive luck that grows with time served")

--[[
	Executed, not inspected: StreakMath is pure Luau, so the curve the HUD shows
	is the curve asserted here. Two clocks are in play - the live one and the
	Studio-accelerated one - and every check that matters runs against both.
]]
local LIVE_CLOCK = StreakMath.ClockSeconds(false)
local STUDIO_CLOCK = StreakMath.ClockSeconds(true)
local MAX_LEVEL = StreakMath.Constants.maxLevel
local PER_LEVEL = StreakMath.Constants.luckPerLevel

check("a live clock and an accelerated Studio clock exist", LIVE_CLOCK > 0 and STUDIO_CLOCK > 0)
check("the Studio clock is faster than the live one", STUDIO_CLOCK < LIVE_CLOCK, string.format("%ds vs %ds", STUDIO_CLOCK, LIVE_CLOCK))

check("joining the server grants no luck yet (level 0 is exactly 1.00x)", StreakMath.LuckMultiplier(0, LIVE_CLOCK) == 1)
check("one second in is still level 0", StreakMath.Level(1, LIVE_CLOCK) == 0)
check(
	"the level steps exactly on the clock boundary, not before it",
	StreakMath.Level(LIVE_CLOCK - 1, LIVE_CLOCK) == 0 and StreakMath.Level(LIVE_CLOCK, LIVE_CLOCK) == 1,
	string.format("%d then %d", StreakMath.Level(LIVE_CLOCK - 1, LIVE_CLOCK), StreakMath.Level(LIVE_CLOCK, LIVE_CLOCK))
)
check(
	"level 1 is worth exactly one slice of luck",
	approx(StreakMath.LuckMultiplier(LIVE_CLOCK, LIVE_CLOCK), 1 + PER_LEVEL, 1e-9),
	tostring(StreakMath.LuckMultiplier(LIVE_CLOCK, LIVE_CLOCK))
)

-- Strictly rising across every boundary, and never falling in between: this is
-- the "luck provably rises with session time" claim.
local boundaryMultipliers: { number } = {}
local strictlyRising = true
local previousMultiplier = StreakMath.LuckMultiplier(0, LIVE_CLOCK)
for level = 1, MAX_LEVEL do
	local multiplier = StreakMath.LuckMultiplier(level * LIVE_CLOCK, LIVE_CLOCK)
	table.insert(boundaryMultipliers, multiplier)
	if multiplier <= previousMultiplier then
		strictlyRising = false
	end
	previousMultiplier = multiplier
end
check(
	string.format("luck rises strictly across all %d level boundaries", MAX_LEVEL),
	strictlyRising,
	table.concat(boundaryMultipliers, ", ")
)

local samples: { number } = {}
local neverFalls = true
local previousSample = StreakMath.LuckMultiplier(0, LIVE_CLOCK)
for second = 0, MAX_LEVEL * LIVE_CLOCK do
	local multiplier = StreakMath.LuckMultiplier(second, LIVE_CLOCK)
	if multiplier < previousSample then
		neverFalls = false
	end
	previousSample = multiplier
	table.insert(samples, multiplier)
end
check("luck never falls as session time grows", neverFalls)

local distinct: { [number]: boolean } = {}
for _, multiplier in ipairs(samples) do
	distinct[multiplier] = true
end
local distinctCount = 0
for _ in pairs(distinct) do
	distinctCount += 1
end
check(
	string.format("the sweep produced exactly %d distinct luck values (one per level + 1)", MAX_LEVEL + 1),
	distinctCount == MAX_LEVEL + 1,
	tostring(distinctCount)
)

--[[
	END TO END, EXECUTED: the number a roll would actually use. The harness holds
the perk bundle, the potion and the server boost still and lets only SESSION
TIME move, then runs the same pure functions the roll path runs - own the perks
once, combine the consumables, multiply the streak in. The mirrored product is
not taken on trust: the check further down pins the roll path itself to exactly
`base * perks * streak`.
]]
local perkBundleLuck = PerkMath.Combine(
	PerkMath.Contributions(MonetizationConfig.passes, { DoubleLuck = true, VIP = true }),
	nil,
	nil
).luckMultiplier
local function rollLuckAt(seconds: number, perkLuck: number): number
	return perkLuck * StreakMath.Snapshot(seconds, LIVE_CLOCK).luckMultiplier
end

local sessionOnlyAtJoin = rollLuckAt(0, 1)
local sessionOnlyAtCap = rollLuckAt(MAX_LEVEL * LIVE_CLOCK, 1)
check("a fresh joiner's luck is exactly 1.00x (no streak yet)", sessionOnlyAtJoin == 1)
check(
	string.format("session time alone carries the roll from 1.00x to %.2fx", sessionOnlyAtCap),
	approx(sessionOnlyAtCap, 1 + PER_LEVEL * MAX_LEVEL, 1e-9),
	tostring(sessionOnlyAtCap)
)

local perksAtJoin = rollLuckAt(0, perkBundleLuck)
local perksAtCap = rollLuckAt(MAX_LEVEL * LIVE_CLOCK, perkBundleLuck)
check(
	string.format(
		"with a held %.2fx perk bundle the same roll reads %.2fx at join and %.2fx at the cap",
		perkBundleLuck,
		perksAtJoin,
		perksAtCap
	),
	approx(perksAtJoin, perkBundleLuck, 1e-9)
		and approx(perksAtCap, perkBundleLuck * (1 + PER_LEVEL * MAX_LEVEL), 1e-9),
	string.format("%.2fx -> %.2fx", perksAtJoin, perksAtCap)
)

-- The growth must survive the stacking: the streak multiplies in, it does not
-- replace or cancel the perks it is folded into.
-- The growth the streak contributes must be the SAME factor whether or not
-- perks are stacked, and it must exceed 1: this holds whatever the per-level
-- reward is, so it cannot be satisfied by a curve that was flattened to zero.
local sessionGrowth = sessionOnlyAtCap / sessionOnlyAtJoin
local stackedGrowth = perksAtCap / perksAtJoin
check(
	string.format("the streak contributes the same growth factor with and without perks (%.3fx)", sessionGrowth),
	approx(sessionGrowth, stackedGrowth, 1e-9),
	string.format("%.4f vs %.4f", sessionGrowth, stackedGrowth)
)
check(
	string.format("that shared factor really is growth (%.3fx by the cap)", sessionGrowth),
	sessionGrowth > 1.001,
	tostring(sessionGrowth)
)

-- DELIBERATE BALANCE PINS. Written as literals, unlike the shape checks above,
-- because those compare against numbers read back out of StreakMath - a control
-- that set luckPerLevel to 0 moved both sides of the comparison at once. These
-- pin the documented curve, so retuning it fails loudly here as well.
check(
	"the cap is exactly +75% luck (120s x 15 levels x +5%, pinned)",
	approx(sessionOnlyAtCap, 1.75, 1e-9),
	tostring(sessionOnlyAtCap)
)
check(
	"the live clock is 120s per level, capped at 15 levels (pinned)",
	LIVE_CLOCK == 120 and MAX_LEVEL == 15,
	string.format("%ds x %d levels", LIVE_CLOCK, MAX_LEVEL)
)
check(
	"the Studio clock is 10s per level (12x faster, so a playtest can watch it)",
	STUDIO_CLOCK == 10,
	tostring(STUDIO_CLOCK)
)

local risesWithPerksStacked = true
for level = 1, MAX_LEVEL do
	if rollLuckAt(level * LIVE_CLOCK, perkBundleLuck) <= rollLuckAt((level - 1) * LIVE_CLOCK, perkBundleLuck) then
		risesWithPerksStacked = false
	end
end
check("the roll's luck rises at every streak boundary even with perks stacked on", risesWithPerksStacked)

local capSeconds = MAX_LEVEL * LIVE_CLOCK
local capped = StreakMath.Snapshot(capSeconds, LIVE_CLOCK)
local beyondCap = StreakMath.Snapshot(capSeconds * 10, LIVE_CLOCK)
check(
	"the streak caps instead of growing forever",
	capped.level == MAX_LEVEL and capped.capped == true
		and beyondCap.level == MAX_LEVEL and beyondCap.capped == true
)
check(
	string.format("the cap is worth %.2fx luck", 1 + PER_LEVEL * MAX_LEVEL),
	approx(capped.luckMultiplier, 1 + PER_LEVEL * MAX_LEVEL, 1e-9),
	tostring(capped.luckMultiplier)
)
check(
	"a capped streak reports full progress and no countdown",
	capped.levelProgress == 1 and capped.secondsToNextLevel == 0
)
check(
	"the reported seconds are clamped at the cap (no absurd value reaches a remote)",
	beyondCap.seconds == capSeconds,
	tostring(beyondCap.seconds)
)

local justAfterBoundary = StreakMath.Snapshot(2 * LIVE_CLOCK + 5, LIVE_CLOCK)
local justBeforeBoundary = StreakMath.Snapshot(3 * LIVE_CLOCK - 5, LIVE_CLOCK)
check("progress restarts small after a level up", justAfterBoundary.levelProgress < 0.2)
check("progress fills up before the next level", justBeforeBoundary.levelProgress > 0.8)
check(
	"the countdown to the next level matches the clock",
	StreakMath.Snapshot(2 * LIVE_CLOCK, LIVE_CLOCK).secondsToNextLevel == LIVE_CLOCK
)

-- Defensive totality: this is fed by an engine clock inside a hot path.
check("a negative duration is treated as no time served", StreakMath.Level(-500, LIVE_CLOCK) == 0)
check("a NaN duration cannot produce a NaN level", StreakMath.Level(0 / 0, LIVE_CLOCK) == 0)
local nanSnapshot = StreakMath.Snapshot(0 / 0, LIVE_CLOCK)
check(
	"a NaN duration produces a usable snapshot",
	nanSnapshot.seconds == nanSnapshot.seconds and nanSnapshot.level == 0 and nanSnapshot.luckMultiplier == 1
)
check("an infinite duration is capped, not propagated", StreakMath.Snapshot(math.huge, LIVE_CLOCK).capped == true)
check(
	"a malformed clock interval falls back to the live one",
	StreakMath.Level(2 * LIVE_CLOCK, -1) == 2 and StreakMath.Level(2 * LIVE_CLOCK, 0 / 0) == 2
)

-- Same curve, different clock: the Studio acceleration must not change the shape
-- or the reward per level, only how long a level takes.
local shapesAgree = true
for level = 0, MAX_LEVEL + 3 do
	if StreakMath.Level(level * STUDIO_CLOCK, STUDIO_CLOCK) ~= StreakMath.Level(level * LIVE_CLOCK, LIVE_CLOCK) then
		shapesAgree = false
	end
end
check("the Studio-accelerated clock runs the identical curve", shapesAgree)
check(
	"both clocks pay the same luck at the same level",
	approx(StreakMath.LuckMultiplier(4 * STUDIO_CLOCK, STUDIO_CLOCK), StreakMath.LuckMultiplier(4 * LIVE_CLOCK, LIVE_CLOCK), 1e-9)
)

local SNAPSHOT_FIELDS = {
	"seconds", "level", "maxLevel", "levelSeconds", "levelProgress",
	"secondsToNextLevel", "luckMultiplier", "capped",
}
local declaredSnapshotFields: { [string]: boolean } = {}
for _, field in ipairs(SNAPSHOT_FIELDS) do
	declaredSnapshotFields[field] = true
end
local snapshotShapeOk = true
local extraFields: { string } = {}
local fieldCount = 0
for field in pairs(StreakMath.Snapshot(LIVE_CLOCK, LIVE_CLOCK)) do
	fieldCount += 1
	if declaredSnapshotFields[field] == nil then
		table.insert(extraFields, field)
	end
end
snapshotShapeOk = fieldCount == #SNAPSHOT_FIELDS and #extraFields == 0
check(
	"the snapshot carries exactly the documented fields (the shape RNGService mirrors)",
	snapshotShapeOk,
	table.concat(extraFields, ", ")
)
-- The published snapshot and the standalone accessor must agree at every level:
-- they are the same number read by two callers (the payload and the luck point),
-- so a second copy of the formula would show up here.
local snapshotMatchesAccessor = true
for level = 0, MAX_LEVEL + 2 do
	local seconds = level * LIVE_CLOCK
	if StreakMath.Snapshot(seconds, LIVE_CLOCK).luckMultiplier ~= StreakMath.LuckMultiplier(seconds, LIVE_CLOCK) then
		snapshotMatchesAccessor = false
	end
end
check(
	"the snapshot's luck and the accessor's luck agree at every level (one formula)",
	snapshotMatchesAccessor
)

check("the streak grants luck and nothing else" , (function(): boolean
	local snapshot = StreakMath.Snapshot(LIVE_CLOCK, LIVE_CLOCK)
	return snapshot.luckMultiplier > 1
		and (snapshot :: any).cooldownMultiplier == nil
		and (snapshot :: any).pityOffset == nil
end)())

-- =============================================================================
section("The pity copy is true of the mechanic, not relabelled")

-- These two run against the real RollMath, so a window move in that module fails
-- the copy checks rather than leaving a lie on screen.
local SOFT_INTERVAL = RollMath.SoftPityInterval()
local HARD_ROLLS = RollMath.HardPityRolls()
local RARE_TIER = AuraRegistry.TierOf(RollMath.HardPityMinRarity())

check(
	string.format("the primary line's milestone really is 2x luck (x%.2f at %d rolls)", RollMath.SoftPityMultiplier(SOFT_INTERVAL), SOFT_INTERVAL),
	RollMath.SoftPityMultiplier(SOFT_INTERVAL) == 2
)
check(
	"the countdown lands exactly on the first 2x point (no soft pity the roll before)",
	RollMath.SoftPityStacks(SOFT_INTERVAL - 1) == 0 and not RollMath.IsSoftPityActive(SOFT_INTERVAL - 1)
)
check(
	"soft pity keeps ramping past the first step (the 'stack n/n' part of the copy)",
	RollMath.SoftPityMultiplier(2 * SOFT_INTERVAL) > RollMath.SoftPityMultiplier(SOFT_INTERVAL)
)
check(
	string.format("the guarantee line's tier really is the pity floor's tier (%s)", RARE_TIER),
	RARE_TIER == "Rare" and HARD_ROLLS == 100
)

-- The vision's "50 / Rare+" is one line describing two mechanics. The 50 is the
-- soft-pity 2x point; the guarantee is the 100-roll window, which is NOT 50. If a
-- later pass decides the vision meant the guarantee at 50, that is a balance
-- change to RollMath - not a relabel of this panel - and this check is the tripwire.
check(
	"the 2x point and the hard guarantee are different rolls (nothing here halves the window)",
	SOFT_INTERVAL ~= HARD_ROLLS,
	string.format("interval=%d hard=%d", SOFT_INTERVAL, HARD_ROLLS)
)
check(
	"the guarantee is real at 100 and not at 50",
	RollMath.IsHardPityNext(HARD_ROLLS - 1) and not RollMath.IsHardPityNext(SOFT_INTERVAL - 1)
)
note(string.format(
	"Deliberate reading: the vision's 50 is the SOFT-PITY 2x point (%d rolls -> x%.0f luck); the Rare+ guarantee is %d rolls. Odds and thresholds are untouched.",
	SOFT_INTERVAL, RollMath.SoftPityMultiplier(SOFT_INTERVAL), HARD_ROLLS
))

-- =============================================================================
section("Wiring contract: which module owns which decision")

local function collectLuau(root: string, into: { string }): ()
	for _, entry in ipairs(fs.readDir(root)) do
		local path = root .. "/" .. entry
		if fs.isDir(path) then
			collectLuau(path, into)
		elseif string.sub(entry, -5) == ".luau" then
			table.insert(into, path)
		end
	end
end

local sources: { [string]: string } = {}
local sourcePaths: { string } = {}
collectLuau("src", sourcePaths)

for _, path in ipairs(sourcePaths) do
	local ok, contents = pcall(fs.readFile, path)
	if ok and type(contents) == "string" then
		sources[path] = contents
	end
end

local sourcesReadable = sources["src/server/RNGService.server.luau"] ~= nil
if not sourcesReadable then
	note("could not read the shipped sources - run the harness from the project root")
else
	-- Read through this helper so a renamed or missing file produces FAILed
	-- checks (with the name it looked for) instead of a crashed harness.
	local function sourceOf(path: string): (string, boolean)
		local source = sources[path]
		if source == nil then
			return "" , false
		end
		return source, true
	end

	local EXPECTED_FILES = {
		"src/server/RNGService.server.luau",
		"src/server/ShopService.server.luau",
		"src/server/PerkService.luau",
		"src/client/ShopUI.luau",
		"src/client/MainUI.client.luau",
	}
	local missingFiles: { string } = {}
	for _, expected in ipairs(EXPECTED_FILES) do
		if sources[expected] == nil then
			table.insert(missingFiles, expected)
		end
	end
	check("every file these checks name still exists", #missingFiles == 0, table.concat(missingFiles, ", "))

	-- Body of a top-level function, for checks that care what a function DOES
	-- (a plain name match elsewhere in the file cannot tell). The closing `end` of
	-- such a function starts at column zero, so this skips the indented `end`s of
	-- the blocks inside it.
	-- Comments are stripped before any source check reads them: a negative control
	-- showed that a comment mentioning the thing being checked ("-- streak dropped")
	-- satisfied a search for it, which would have let a real removal pass.
	local function stripComments(source: string): string
		local withoutBlocks = string.gsub(source, "%-%-%[%[.-%]%]", "")
		local withoutLines = string.gsub(withoutBlocks, "%-%-[^\n]*", "")
		return withoutLines
	end

	local function functionBody(source: string, header: string): string?
		local headerStart = string.find(source, header, 1, true)
		if headerStart == nil then
			return nil
		end
		local bodyEnd = string.find(source, "\nend", headerStart, true)
		if bodyEnd == nil then
			return nil
		end
		return stripComments(string.sub(source, headerStart, bodyEnd))
	end

	-- Every semantic check below reads comment-stripped source, so no check can be
	-- satisfied by prose about the code it is meant to verify. (String literals -
	-- the UI copy checks - survive stripping untouched.)
	local rng = stripComments(sourceOf("src/server/RNGService.server.luau"))
	local shop = stripComments(sourceOf("src/server/ShopService.server.luau"))
	local perks = stripComments(sourceOf("src/server/PerkService.luau"))
	local shopUi = stripComments(sourceOf("src/client/ShopUI.luau"))
	local mainUi = stripComments(sourceOf("src/client/MainUI.client.luau"))

	-- RNGService consults PerkService for every perk decision. Matched WITH their
	-- argument list: a plain name match would accept `PerkService.HasFastRollDisabled`,
	-- which a negative control proved by sneaking past the weaker form of this check.
	local requiredCalls = {
		"PerkService.GetLuckMultiplier(player)",
		"PerkService.GetCooldownMultiplier(player)",
		"PerkService.HasAutoRoll(player)",
		"PerkService.HasFastRoll(player)",
		"PerkService.ConsumeRollEffects(player)",
	}
	local missingCalls: { string } = {}
	for _, call in ipairs(requiredCalls) do
		if string.find(rng, call, 1, true) == nil then
			table.insert(missingCalls, call)
		end
	end
	check(
		"RNGService consults PerkService for luck, cooldown, auto-roll, fast-roll and potion spend",
		#missingCalls == 0,
		table.concat(missingCalls, ", ")
	)

	check(
		"RNGService no longer carries a fast-roll cooldown constant (the pass owns it)",
		string.find(rng, "FAST_ROLL_COOLDOWN", 1, true) == nil
	)
	check(
		"the roll path multiplies base luck by the perk multiplier before the roll",
		(function(): boolean
			local body = functionBody(rng, "local function getLuckMultiplier(")
			return body ~= nil
				and string.find(body, "state.luckMultiplier", 1, true) ~= nil
				and string.find(body, "* PerkService.GetLuckMultiplier(player)", 1, true) ~= nil
		end)()
	)
	check(
		"the potion is spent once, in the single roll resolution path",
		(function(): boolean
			local first = string.find(rng, "PerkService.ConsumeRollEffects(player)", 1, true)
			return first ~= nil and string.find(rng, "PerkService.ConsumeRollEffects(player)", first + 1, true) == nil
		end)()
	)
	check(
		"a roll that is refused on cooldown cannot spend a potion charge",
		(function(): boolean
			local cooldownGate = string.find(rng, "if elapsed < cooldown then", 1, true)
			local spend = string.find(rng, "PerkService.ConsumeRollEffects(player)", 1, true)
			return cooldownGate ~= nil and spend ~= nil and cooldownGate < spend
		end)()
	)

	-- No marketplace logic embedded in the roll service.
	check(
		"no MarketplaceService call exists outside ShopService",
		(function(): boolean
			-- Matched on the name, not one exact filename: a rename must not be able to
			-- turn this check green by accident (it did, before this was written).
			for path, source in pairs(sources) do
				if string.find(path, "ShopService", 1, true) == nil and string.find(source, "MarketplaceService", 1, true) ~= nil then
					return false
				end
			end
			return true
		end)()
	)

	check(
		"ShopService owns receipts: ProcessReceipt, the claim guard and the single grant call",
		string.find(shop, "MarketplaceService.ProcessReceipt = function", 1, true) ~= nil
			and string.find(shop, "SaveBackend.ClaimReceipt(receiptBackend", 1, true) ~= nil
			and string.find(shop, "PerkService.GrantProduct(player", 1, true) ~= nil
	)
	check(
		"ShopService defers (never grants) an unknown product id",
		string.find(shop, "NotProcessedYet", 1, true) ~= nil
	)

	-- One owner for each policy.
	check(
		"the save path and the receipt path use the same backend policy",
		string.find(rng, "SaveBackend.Get(DATASTORE_NAME)", 1, true) ~= nil
			and string.find(shop, "SaveBackend.Get(RECEIPT_STORE)", 1, true) ~= nil
	)
	check(
		"only PerkService resolves a luck multiplier",
		string.find(perks, "function PerkService.GetLuckMultiplier", 1, true) ~= nil
	)

	-- The client renders and asks; it must not be able to reach a perk number, a
	-- server config or a grant function. Checked precisely - what matters is that
	-- no client file REQUIRES a server module (a shop hint may name one in prose)
	-- and that no client calls a server-only mutator.
	local SERVER_MODULES = { "MonetizationConfig", "PerkMath", "PerkService", "SaveBackend", "ShopService" }
	local SERVER_ONLY_CALLS = { "GrantProduct", "SetPassOwned", "ActivateServerBoost", "PerkMath." }

	local clientLeaks: { string } = {}
	for path, source in pairs(sources) do
		if string.sub(path, 1, 11) == "src/client/" then
			for required in string.gmatch(source, "require%(([^%)]*)") do
				for _, moduleName in ipairs(SERVER_MODULES) do
					if string.find(required, moduleName, 1, true) ~= nil then
						table.insert(clientLeaks, string.format("%s requires %s", path, moduleName))
					end
				end
			end
			for _, forbidden in ipairs(SERVER_ONLY_CALLS) do
				if string.find(source, forbidden, 1, true) ~= nil then
					table.insert(clientLeaks, string.format("%s calls %s", path, forbidden))
				end
			end
		end
	end
	check(
		"no client file requires a server module or calls a server-only grant",
		#clientLeaks == 0,
		table.concat(clientLeaks, ", ")
	)

	local clientRequiresShop = string.find(sources["src/client/MainUI.client.luau"], "require(script.Parent:WaitForChild(\"ShopUI\")", 1, true) ~= nil
	check("MainUI reaches the shop module (and only that module)", clientRequiresShop)

	check("MainUI only mounts the shop", string.find(mainUi, "ShopUI.Mount(", 1, true) ~= nil)
	check(
		"the shop panel and its remotes live in ShopUI, not MainUI",
		string.find(mainUi, "ProcessReceipt", 1, true) == nil and string.find(shopUi, "ShopCatalog", 1, true) ~= nil
	)
	check(
		"the client asks the server for Test Mode instead of assuming it",
		string.find(shopUi, 'FireServer("SetTestMode"', 1, true) ~= nil
			and string.find(shopUi, "testModeAllowed", 1, true) ~= nil
	)
	check(
		"Test Mode is refused unless the server's policy allows it",
		string.find(perks, "canUseTestMode", 1, true) ~= nil
			and string.find(perks, "MonetizationConfig.testMode.enabledInStudio", 1, true) ~= nil
	)

	-- SESSION STREAK: server-derived (never a client claim) and folded into the
	-- single luck point.
	local luckBody = functionBody(rng, "local function getLuckMultiplier(")
	-- Whitespace-free copy, so the product can be matched as the ordered sequence
	-- of factors it is rather than as substrings that merely appear somewhere in
	-- the function.
	local luckProduct = if luckBody == nil then nil else (string.gsub(luckBody, "%s+", ""))
	check(
		"RNGService's single luck point folds in the session streak",
		--[[
			The streak has to be MULTIPLIED IN, as the LAST factor of the product. The
			looser version of this check ("luckMultiplier appears twice, and the body
			mentions activeStreak") was defeated by a negative control that deleted the
			term and left the name behind in a comment; `state.luckMultiplier` alone
			also satisfied a naive search for `.luckMultiplier`. This asserts the
			streak's own field is a factor of the product, not a name nearby.
		]]
		(function(): boolean
			if luckProduct == nil then
				return false
			end
			local base = "state.luckMultiplier*PerkService.GetLuckMultiplier(player)*"
			local start = string.find(luckProduct, base, 1, true)
			if start == nil then
				return false
			end
			-- Everything from the streak factor up to the next multiply (the product
			-- ends there, so usually that is the rest of the expression).
			local after = string.sub(luckProduct, start + #base)
			local nextStar = string.find(after, "*", 2, true)
			local factor = if nextStar == nil then after else string.sub(after, 1, nextStar - 1)
			return string.find(factor, "activeStreak", 1, true) ~= nil
				and string.find(factor, ".luckMultiplier", 1, true) ~= nil
		end)(),
		if luckProduct == nil
			then "getLuckMultiplier not found"
			else "the streak is not the last factor of the luck product"
	)
	check(
		"the same luck point still folds in the perks (one place, two sources)",
		luckBody ~= nil and string.find(luckBody, "PerkService.GetLuckMultiplier", 1, true) ~= nil
	)
	check(
		"perk luck is applied exactly once in the whole file (no second luck path)",
		(function(): boolean
			local _, count = string.gsub(rng, "PerkService%.GetLuckMultiplier%(player", "")
			return count == 1
		end)()
	)
	check(
		"the streak is derived from the server's own session clock",
		string.find(rng, "os.clock() - state.sessionStartClock", 1, true) ~= nil
	)
	check(
		"the session clock starts at join and survives the save load",
		string.find(rng, "sessionStartClock = os.clock()", 1, true) ~= nil
			and string.find(rng, "loaded.sessionStartClock = state.sessionStartClock", 1, true) ~= nil
	)
	check(
		"the streak curve lives in StreakMath, not inline in RNGService",
		-- The curve's numbers are READ from StreakMath (Constants is exposed for
		-- exactly that), never DEFINED here: that is what stops a second copy of
		-- "+5% per level" appearing in the roll path.
		string.find(rng, "StreakMath.Snapshot(", 1, true) ~= nil
			and string.find(rng, "StreakMath.ClockSeconds(", 1, true) ~= nil
			and string.find(rng, "luckPerLevel =", 1, true) == nil
			and string.find(rng, "maxLevel =", 1, true) == nil
	)
	check(
		"the server pushes the streak on its own timer (the client never counts it)",
		-- The constant existing is not the point: the loop has to wait on it.
		string.find(rng, "task.wait(STREAK_SYNC_INTERVAL)", 1, true) ~= nil
	)
	check(
		"the streak ships in the state payload and as player attributes",
		string.find(rng, "streak = streak,", 1, true) ~= nil
			and string.find(rng, 'SetAttribute("StreakLevel"', 1, true) ~= nil
	)
	check(
		"no client file ever SENDS a streak value (it may only read payload.streak)",
		(function(): boolean
			for path, source in pairs(sources) do
				if string.sub(path, 1, 11) == "src/client/" then
					for argument in string.gmatch(source, "FireServer%(([^%)]*)") do
						if string.find(string.lower(argument), "streak", 1, true) ~= nil then
							return false
						end
					end
				end
			end
			return true
		end)()
	)

	-- PITY COPY: two lines, two mechanics, both numbers read from RollMath.
	check(
		"the primary pity line is the 2x-luck countdown, worded as specified",
		string.find(mainUi, "Rolls until Guaranteed 2x Luck: %d/%d", 1, true) ~= nil
	)
	check(
		"the 100-roll guarantee keeps a line of its own",
		string.find(mainUi, "Rolls until Guaranteed %s: %d/%d", 1, true) ~= nil
			and string.find(mainUi, 'Name = "GuaranteeCountdown"', 1, true) ~= nil
	)
	-- Checked per site rather than by counting occurrences: a count lets one
	-- hardcoded copy hide behind the others, which is exactly the failure this is
	-- meant to catch (a HUD that says 50 after the window moved).
	local progressionBody = functionBody(mainUi, "local function updateProgressionView(")
	check(
		"the primary countdown's interval comes from RollMath, not a literal",
		string.find(
			mainUi,
			'string.format("Rolls until Guaranteed 2x Luck: 0/%d", RollMath.SoftPityInterval())',
			1,
			true
		) ~= nil,
		"the initial label text does not read the interval"
	)
	check(
		"the live countdown re-reads the interval from RollMath on every render",
		progressionBody ~= nil and string.find(progressionBody, "RollMath.SoftPityInterval()", 1, true) ~= nil,
		if progressionBody == nil then "updateProgressionView not found" else "interval hardcoded in the render"
	)
	check(
		"the guarantee line reads its window from RollMath",
		progressionBody ~= nil
			and string.find(progressionBody, "payload.hardPityRolls", 1, true) ~= nil
			and string.find(mainUi, "RollMath.HardPityRolls()", 1, true) ~= nil
	)
	check(
		"the pity rail notch is placed from both RollMath numbers",
		string.find(mainUi, "RollMath.SoftPityInterval() / RollMath.HardPityRolls()", 1, true) ~= nil
	)
	--[[
		ACROSS A ROLL. The panel has two forms and which one is right depends on the
		counter, so the countdown text alone is not enough: after a Rare+ pull resets
		the counter the panel has to go back to counting. The executable half uses
		RollMath, which is the same function the render calls.
	]]
	local softInterval = RollMath.SoftPityInterval()
	check(
		"below the 2x point the panel is counting, not claiming a bonus",
		RollMath.SoftPityStacks(0) == 0
			and RollMath.SoftPityStacks(softInterval - 1) == 0
			and RollMath.SoftPityMultiplier(softInterval - 1) == 1,
		string.format("stacks at %d = %d", softInterval - 1, RollMath.SoftPityStacks(softInterval - 1))
	)
	check(
		"reaching the interval flips the panel to its active form (stacks > 0, x2)",
		RollMath.SoftPityStacks(softInterval) > 0 and RollMath.SoftPityMultiplier(softInterval) == 2,
		string.format("stacks at %d = %d, x%.2f", softInterval, RollMath.SoftPityStacks(softInterval), RollMath.SoftPityMultiplier(softInterval))
	)
	check(
		"a Rare+ pull resetting the counter returns the panel to the countdown form",
		RollMath.SoftPityStacks(0) == 0 and RollMath.SoftPityMultiplier(0) == 1
	)
	check(
		"the active form exists at all (a panel that only counts would hide the bonus)",
		progressionBody ~= nil and string.find(progressionBody, "2x Luck ACTIVE", 1, true) ~= nil,
		if progressionBody == nil then "updateProgressionView not found" else "no active-pity form in the render"
	)
	check(
		"the active form reports the multiplier RollMath really applies, not a literal 2",
		progressionBody ~= nil
			and string.find(progressionBody, "RollMath.SoftPityMultiplier(pity)", 1, true) ~= nil,
		if progressionBody == nil then "updateProgressionView not found" else "the active form hardcodes its multiplier"
	)
	check(
		"the two forms are chosen by the pity counter, not both shown",
		progressionBody ~= nil
			and string.find(progressionBody, "if softPityStacks <= 0 then", 1, true) ~= nil,
		if progressionBody == nil then "updateProgressionView not found" else "the forms are not gated on the counter"
	)
	check(
		"the HUD renders the session streak from the server payload",
		string.find(mainUi, "payload.streak", 1, true) ~= nil
			and string.find(mainUi, 'Name = "Streak"', 1, true) ~= nil
	)

	--[[
		REACHABILITY. In Roblox a ModuleScript only runs when something requires
		it, so a module nothing requires is dormant: no error, no warning, no trace
		in the compiler, in rojo, or anywhere else. That is how a shop with no
		ProcessReceipt, no remotes and no catalog would have shipped - it did, until
		this check existed. `.server.luau` and `.client.luau` files are run by Roblox
		on their own, so only plain modules are examined.

		Names are collected from the places a file is actually REFERENCED (a
		require argument, WaitForChild, or the ladder stack's loadSibling), not from
		the whole text: matching raw text meant a module mentioned only in a comment
		counted as reached, which a negative control proved by renaming the shop
		back to a dormant ModuleScript and watching this check stay green.
	]]
	local function referencedNames(source: string): { [string]: boolean }
		local names: { [string]: boolean } = {}

		-- require("...") / require(script.Parent:WaitForChild("X")) and friends.
		for argument in string.gmatch(source, "require%(([^%)]*)") do
			for quoted in string.gmatch(argument, '\"([^\"]+)\"') do
				names[quoted] = true
			end
		end
		-- WaitForChild("X") - how Roblox-side requires name their module.
		for quoted in string.gmatch(source, 'WaitForChild%((\"[^\"]+\")') do
			names[string.sub(quoted, 2, -2)] = true
		end
		-- loadSibling("X") - the ladder stack's dual-runtime loader.
		for quoted in string.gmatch(source, 'loadSibling%((\"[^\"]+\")') do
			names[string.sub(quoted, 2, -2)] = true
		end
		return names
	end

	local modulePaths: { string } = {}
	for path in pairs(sources) do
		if string.find(path, "%.server%.luau$") == nil and string.find(path, "%.client%.luau$") == nil then
			table.insert(modulePaths, path)
		end
	end
	table.sort(modulePaths)

	-- Every file is a legitimate requirer; a module's own file is not (a self
	-- reference would otherwise make every module look reached).
	local referenced: { [string]: boolean } = {}
	for requirerPath, requirerSource in pairs(sources) do
		local requirerLeaf = string.match(requirerPath, "([^/]+)%.luau$")
		for name in pairs(referencedNames(requirerSource)) do
			local leaf = string.match(name, "([^/\"]+)$") or name
			if leaf ~= requirerLeaf then
				referenced[leaf] = true
			end
		end
	end

	local dormant: { string } = {}
	for _, path in ipairs(modulePaths) do
		local leaf = string.match(path, "([^/]+)%.luau$")
		if referenced[leaf] ~= true then
			table.insert(dormant, path)
		end
	end
	check(
		string.format("every one of the %d modules in src/ is reached by another file (no dormant module)", #modulePaths),
		#dormant == 0,
		table.concat(dormant, ", ")
	)
end

-- =============================================================================
print("")
if failures == 0 then
	print(string.format("ALL %d CHECKS PASSED", checks))
else
	print(string.format("%d of %d CHECKS FAILED", failures, checks))
end

if sourcesReadable then
	print("")
	note("Cannot be proven here (no Roblox runtime): the shop panel rendering, the purchase prompt, ")
	note("a real ProcessReceipt delivery, UserOwnsGamePassAsync, and the replicating VIP nametag. ")
	note("Studio Play mode covers those - see the README / final report for the checklist.")
end

process.exit(failures == 0 and 0 or 1)
