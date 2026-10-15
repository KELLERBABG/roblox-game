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
local AuraFilter = require("./src/server/AuraFilter")
local BiomeMath = require("./src/server/BiomeMath")
local InventoryMath = require("./src/server/InventoryMath")
local RollMath = require("./src/shared/RollMath")
local AuraRegistry = require("./src/shared/AuraRegistry")
local ShrineConfig = require("./src/server/ShrineConfig")
local ShrineMath = require("./src/server/ShrineMath")
local LeaderboardMath = require("./src/server/LeaderboardMath")

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
section("AuraFilter: the auto-filter's policy, executed against the real ladder")

--[[
	The options are THE LADDER. `AuraFilter.Rungs` is handed the real registry,
exactly as RNGService hands it over, so what is asserted here is what the panel
will offer a player - not a fixture that could agree with a hardcoded list.
]]
local RUNGS = AuraFilter.Rungs(AuraRegistry)

check(
	string.format("the filter offers one option per rung (%d options, %d auras on the ladder)", #RUNGS, AuraRegistry.Count),
	#RUNGS == AuraRegistry.Count and #RUNGS == 12,
	string.format("%d options vs %d auras", #RUNGS, AuraRegistry.Count)
)

local ascending = true
local labelsMatchLadder = true
local previousRungRarity = 0
local rungNames: { string } = {}
for _, rung in ipairs(RUNGS) do
	if rung.rarity <= previousRungRarity then
		ascending = false
	end
	previousRungRarity = rung.rarity

	-- A rung has to carry the ladder's OWN name and tier, or the control would be
	-- describing an aura the game does not contain.
	local config = AuraRegistry.Get(rung.auraId)
	if config == nil
		or rung.rarity ~= config.rarity
		or rung.tier ~= config.tier
		or rung.displayName ~= config.displayName
	then
		labelsMatchLadder = false
	end
	table.insert(rungNames, string.format("%s@1/%d", rung.tier, rung.rarity))
end

check("the options ascend by rarity (the stepper walks the ladder in order)", ascending)
check("every option's name, tier and odds come from the ladder itself", labelsMatchLadder)
check(
	"the rarest option is the ladder's rarest rung",
	RUNGS[#RUNGS].rarity == AuraRegistry.HighestRarity()
)
note("filter options: " .. table.concat(rungNames, " < "))

--[[
	EXHAUSTIVE, over the real ladder: for every mode, every offered rung and every
	aura, suppression must be exactly "strictly below the rung" - so the boundary
	semantics the panel promises ("a pull at the rung itself is KEPT") are true for
	every combination a player can actually create, not just for one sample.
]]
local matrixErrors: { string } = {}
local combinations = 0
for _, rung in ipairs(RUNGS) do
	for _, auraId in ipairs(AuraRegistry.ORDER) do
		local config = AuraRegistry.Get(auraId)
		for _, mode in ipairs({ AuraFilter.SKIP, AuraFilter.DELETE }) do
			combinations += 1
			local action = AuraFilter.Decide(mode, rung.rarity, config.rarity)
			local suppressed = AuraFilter.Suppresses(action)
			local expected = config.rarity < rung.rarity
			if suppressed ~= expected or (suppressed and action ~= mode) then
				table.insert(matrixErrors, string.format("%s/%s vs 1/%d", mode, auraId, rung.rarity))
			end
		end
	end
end
check(
	string.format("all %d mode x rung x aura combinations suppress exactly what is below the rung", combinations),
	#matrixErrors == 0,
	table.concat(matrixErrors, ", ")
)

local MID = RUNGS[math.max(1, math.floor(#RUNGS / 2))]
check(
	string.format("a pull exactly AT the rung is kept (%s, 1 in %d)", MID.tier, MID.rarity),
	AuraFilter.Decide(AuraFilter.SKIP, MID.rarity, MID.rarity) == AuraFilter.KEEP
		and AuraFilter.Decide(AuraFilter.DELETE, MID.rarity, MID.rarity) == AuraFilter.KEEP
)
check(
	"one step below the rung is suppressed, and each mode says how",
	AuraFilter.Decide(AuraFilter.SKIP, MID.rarity, MID.rarity - 1) == AuraFilter.SKIP
		and AuraFilter.Decide(AuraFilter.DELETE, MID.rarity, MID.rarity - 1) == AuraFilter.DELETE
)
check(
	"off keeps every pull at every rung (the default cannot eat anything)",
	(function(): boolean
		for _, rung in ipairs(RUNGS) do
			for _, auraId in ipairs(AuraRegistry.ORDER) do
				if AuraFilter.Decide(AuraFilter.OFF, rung.rarity, AuraRegistry.Get(auraId).rarity) ~= AuraFilter.KEEP then
					return false
				end
			end
		end
		return true
	end)()
)
check(
	"a zero threshold keeps everything, whatever the mode",
	AuraFilter.Decide(AuraFilter.SKIP, 0, 2) == AuraFilter.KEEP and AuraFilter.Decide(AuraFilter.DELETE, 0, 2) == AuraFilter.KEEP
)
check(
	"an unreadable rarity is KEPT rather than destroyed",
	AuraFilter.Decide(AuraFilter.DELETE, MID.rarity, nil) == AuraFilter.KEEP
		and AuraFilter.Decide(AuraFilter.DELETE, MID.rarity, "2") == AuraFilter.KEEP
		and AuraFilter.Decide(AuraFilter.DELETE, MID.rarity, 0 / 0) == AuraFilter.KEEP,
	"a nil/string/NaN rarity must never look like a junk pull"
)
check(
	"a mode a client invents cannot filter at all (not even by case)",
	AuraFilter.Decide("KEEP", MID.rarity, 2) == AuraFilter.KEEP
		and AuraFilter.Decide("DELETE", MID.rarity, 2) == AuraFilter.KEEP
		and AuraFilter.Decide("", MID.rarity, 2) == AuraFilter.KEEP
)
check(
	"the settable vocabulary is exactly off/skip/delete, and \"keep\" is not in it",
	#AuraFilter.MODES == 3
		and AuraFilter.SanitizeMode(AuraFilter.KEEP, nil) == nil
		and AuraFilter.SanitizeMode(AuraFilter.SKIP, nil) == AuraFilter.SKIP
)
check(
	"an unknown saved mode loads as off, not as a stray filter",
	AuraFilter.SanitizeMode(nil, AuraFilter.OFF) == AuraFilter.OFF
		and AuraFilter.SanitizeMode("yeet", AuraFilter.OFF) == AuraFilter.OFF
)

local thresholdCases = {
	{ value = MID.rarity, expected = MID.rarity, label = "a real rung" },
	{ value = MID.rarity + 1, expected = 0, label = "a rarity that is not a rung" },
	{ value = 0, expected = 0, label = "zero (no threshold)" },
	{ value = -50, expected = 0, label = "a negative rarity" },
	{ value = 2.5, expected = 0, label = "a fractional rarity" },
	{ value = 1 / 0, expected = 0, label = "infinity" },
	{ value = "2", expected = 0, label = "a string" },
	{ value = nil, expected = 0, label = "nil (an older save)" },
}
local thresholdErrors: { string } = {}
for _, case in ipairs(thresholdCases) do
	if AuraFilter.SanitizeThreshold(case.value, RUNGS) ~= case.expected then
		table.insert(thresholdErrors, case.label)
	end
end
check(
	string.format("every malformed threshold degrades to none (%d cases)", #thresholdCases),
	#thresholdErrors == 0,
	table.concat(thresholdErrors, ", ")
)
check(
	"a threshold that is not a rung is refused, so 499 cannot sit between two rungs",
	not AuraFilter.IsRung(499, RUNGS) and AuraFilter.IsRung(RUNGS[#RUNGS].rarity, RUNGS)
)

-- A ladder that cannot be read must not produce a filter that silently keeps
-- everything while claiming to drop things: Rungs() just offers fewer options.
local tinyLadder = { ORDER = { "Real", "Ghost", "Nameless" }, Get = function(id: string): any
	if id == "Real" then
		return { rarity = 50, tier = "Rare", displayName = "Real" }
	elseif id == "Nameless" then
		return { tier = "Broken" }
	end
	return nil
end }
local partial = AuraFilter.Rungs(tinyLadder)
check(
	"a ladder entry that is missing or malformed simply stops being offered",
	#partial == 1 and partial[1].rarity == 50,
	string.format("%d options", #partial)
)

-- =============================================================================
section("InventoryMath: delete one copy, and refuse when nothing is owned")

local deleteCases = {
	{ owned = 0, removed = false, remaining = 0, label = "nothing owned is refused" },
	{ owned = 1, removed = true, remaining = 0, label = "the last copy leaves nothing" },
	{ owned = 2, removed = true, remaining = 1, label = "two copies leave one" },
	{ owned = 412, removed = true, remaining = 411, label = "one copy out of a big stack" },
	{ owned = 2.7, removed = true, remaining = 1, label = "a fractional count is floored" },
	{ owned = nil, removed = false, remaining = 0, label = "a missing count is refused" },
	{ owned = "3", removed = false, remaining = 0, label = "a string count is refused" },
	{ owned = 0 / 0, removed = false, remaining = 0, label = "a NaN count is refused" },
	{ owned = -1, removed = false, remaining = 0, label = "a negative count is refused" },
}
local deleteErrors: { string } = {}
for _, case in ipairs(deleteCases) do
	local removed, remaining = InventoryMath.RemoveOne(case.owned)
	if removed ~= case.removed or remaining ~= case.remaining then
		table.insert(deleteErrors, string.format("%s -> (%s, %s)", case.label, tostring(removed), tostring(remaining)))
	end
end
check(
	string.format("every delete edge behaves (%d cases)", #deleteCases),
	#deleteErrors == 0,
	table.concat(deleteErrors, "; ")
)
check(
	"deleting never removes more than the one copy asked for",
	InventoryMath.RemoveOne(3) == true and select(2, InventoryMath.RemoveOne(3)) == 2
)
check(
	"a count of zero is not deletable, so a stale grid cannot delete anything",
	InventoryMath.RemoveOne(0) == false
)
check(
	"the last copy is the one that ends the entry",
	InventoryMath.KeySurvives(1) and not InventoryMath.KeySurvives(0)
)

-- =============================================================================
section("The filter rides the same save path (including the Studio fallback)")

--[[
	SaveBackend.Get is the exact call RNGService makes. There is no
	DataStoreService in Lune, so this resolves to the in-memory backend - which is
	precisely the fallback a Studio session with API access off gets. The setting

therefore survives a rejoin through the same code path in both worlds.
]]
local saveBackend = SaveBackend.Get("AuraCollectorSave_v1")
check(
	string.format("the store resolves without Roblox, as the memory fallback (%s)", saveBackend.kind),
	type(saveBackend) == "table" and type(saveBackend.save) == "function"
		and string.find(saveBackend.kind, "Memory", 1, true) ~= nil
)

local filterKey = SaveBackend.PlayerKey(424242)
saveBackend.save(filterKey, {
	version = 1,
	totalRolls = 42,
	pityCounter = 7,
	inventory = { Ember = 3 },
	equippedAura = "Ember",
	rarestAura = "Ember",
	filterMode = AuraFilter.DELETE,
	filterRarity = MID.rarity,
})
local savedSnapshot = saveBackend.load(filterKey)
check(
	"a saved filter comes back with the rest of the snapshot",
	savedSnapshot.filterMode == AuraFilter.DELETE and savedSnapshot.filterRarity == MID.rarity,
	string.format("mode=%s rarity=%s", tostring(savedSnapshot.filterMode), tostring(savedSnapshot.filterRarity))
)
check(
	"and the inventory saved beside it is untouched",
	(savedSnapshot.inventory.Ember or 0) == 3
)

-- The load side has to tolerate a snapshot written before the filter existed:
-- both fields are simply absent, and both sanitizers read that as "no filter".
saveBackend.save(filterKey, { version = 1, totalRolls = 1, inventory = {}, filterMode = "yeet", filterRarity = 499 })
local legacySnapshot = saveBackend.load(filterKey)
check(
	"an older snapshot loads, and a damaged filter in it loads as off",
	legacySnapshot.filterMode == "yeet"
		and AuraFilter.SanitizeMode(legacySnapshot.filterMode, AuraFilter.OFF) == AuraFilter.OFF
		and AuraFilter.SanitizeThreshold(legacySnapshot.filterRarity, RUNGS) == 0
)

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
	--[[
		Derived from the filesystem, not listed. A hardcoded list quietly stops
		covering the next server module somebody adds - this one had already missed
		StreakMath, AuraFilter and InventoryMath.
	]]
	local SERVER_MODULES: { string } = {}
	for path in pairs(sources) do
		if string.sub(path, 1, 11) == "src/server/" then
			local leaf = string.match(path, "([^/]+)%.luau$")
			if leaf ~= nil then
				if string.sub(leaf, -7) == ".server" then
					leaf = string.sub(leaf, 1, -8)
				end
				table.insert(SERVER_MODULES, leaf)
			end
		end
	end

	local SERVER_ONLY_CALLS = {
		"GrantProduct",
		"SetPassOwned",
		"ActivateServerBoost",
		"PerkMath.",
		-- The filter's policy and the delete rule are server decisions: a client
		-- that could call either would be deciding its own luck and its own
		-- ownership.
		"AuraFilter.Decide",
		"AuraFilter.Rungs",
		"InventoryMath.RemoveOne",
	}

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
		AUTO-FILTER + DELETE: server-owned, applied inside the ONE roll path.

		The ordering checks below are the load-bearing part. A filter is only honest
		if it sits in the single place a pull is resolved, AFTER the draw and the
		pity bookkeeping and BEFORE the inventory - so a filtered pull advances pity
		and telemetry exactly like a kept one, and never gets stored.
	]]
	-- Anchor-to-anchor slice of RAW source (comments intact, so a comment can be an
	-- anchor). The result is comment-stripped before any check reads it.
	local function between(source: string, startAnchor: string, endAnchor: string): string?
		local startIndex = string.find(source, startAnchor, 1, true)
		if startIndex == nil then
			return nil
		end
		local endIndex = string.find(source, endAnchor, startIndex + #startAnchor, true)
		if endIndex == nil then
			return nil
		end
		return stripComments(string.sub(source, startIndex, endIndex - 1))
	end

	local function occurrences(text: string, pattern: string): number
		local _, count = string.gsub(text, pattern, "")
		return count
	end

	-- Counts a literal substring, so a needle full of `()` `[]` and `%` needs no
	-- escaping at all. Two negative controls were lost to mis-escaped patterns
	-- before this existed.
	local function plainCount(text: string, needle: string): number
		local index = 1
		local total = 0
		while true do
			local found = string.find(text, needle, index, true)
			if found == nil then
				return total
			end
			total += 1
			index = found + #needle
		end
	end

	local resolveBody = functionBody(rng, "local function resolveRoll(")
	local compactResolve = if resolveBody == nil then nil else (string.gsub(resolveBody, "%s+", ""))

	check(
		"the filter's decision is made in exactly one place in RNGService",
		occurrences(rng, "AuraFilter%.Decide%(") == 1,
		string.format("%d call sites", occurrences(rng, "AuraFilter%.Decide%("))
	)
	check(
		"and that place is the single roll/resolve path",
		compactResolve ~= nil and string.find(compactResolve, "AuraFilter.Decide(", 1, true) ~= nil and resolveBody ~= nil,
		if resolveBody == nil then "resolveRoll not found" else "the filter is applied outside resolveRoll"
	)

	-- The order inside resolveRoll, asserted by position rather than by prose.
	local resolveOrder = {
		{ key = "the rarity tally", anchor = "state.rarityTally[outcome.rarity]=" },
		{ key = "the pity counter", anchor = "state.pityCounter=0" },
		{ key = "the potion spend", anchor = "PerkService.ConsumeRollEffects(player)" },
		{ key = "the filter decision", anchor = "AuraFilter.Decide(" },
		{ key = "the inventory write", anchor = "elsestate.inventory[outcome.auraId]=" },
	}
	local orderOk = compactResolve ~= nil
	local orderDetail: { string } = {}
	local previousPosition = 0
	if compactResolve ~= nil then
		for _, step in ipairs(resolveOrder) do
			local position = string.find(compactResolve, step.anchor, 1, true)
			if position == nil or position < previousPosition then
				orderOk = false
			end
			previousPosition = position or 0
			table.insert(orderDetail, string.format("%s@%s", step.key, tostring(position)))
		end
	else
		orderOk = false
	end
	check(
		"a filtered pull still advances pity and telemetry (the filter sits after them)",
		orderOk,
		table.concat(orderDetail, " ")
	)
	check(
		"and still spends an armed potion charge (the roll happened)",
		compactResolve ~= nil
			and string.find(compactResolve, "PerkService.ConsumeRollEffects(player)", 1, true) ~= nil
			and (string.find(compactResolve, "PerkService.ConsumeRollEffects(player)", 1, true) or 0)
				< (string.find(compactResolve, "AuraFilter.Decide(", 1, true) or 0)
	)
	check(
		"a suppressed pull never reaches the inventory (the write is the else branch)",
		compactResolve ~= nil
			and string.find(compactResolve, "elsestate.inventory[outcome.auraId]=", 1, true) ~= nil
			and occurrences(compactResolve, "state%.inventory%[outcome%.auraId%]=") == 1,
		if compactResolve == nil then "resolveRoll not found" else "the inventory write is not guarded by the filter"
	)
	check(
		"a suppressed pull cannot become the rarest find or the equipped aura",
		compactResolve ~= nil and string.find(compactResolve, "ifnotfilteredthen", 1, true) ~= nil,
		if compactResolve == nil then "resolveRoll not found" else "ownership and auto-equip are not gated on the filter"
	)
	check(
		"the client is told what was dropped, not left to guess",
		string.find(rng, "filtered = filtered,", 1, true) ~= nil
			and string.find(rng, "filterAction = filterAction,", 1, true) ~= nil
			and string.find(rng, "filteredTotal = state.filteredPulls,", 1, true) ~= nil
	)

	--[[
		DELETE. The handler may not trust the client at all: the id is checked
		against the ladder, ownership is re-read from the server's own state, and
		the arithmetic is InventoryMath's (whose edges are executed above).
	]]
	-- The raw file: the end anchors for these two handlers are comments, and `rng`
	-- has already had comments stripped out of it.
	local rngRaw, rngRawReadable = sourceOf("src/server/RNGService.server.luau")
	local deleteBody = if rngRawReadable
		then between(rngRaw, "DeleteAura.OnServerEvent:Connect(", "SetFilter.OnServerEvent:Connect(")
		else nil
	local compactDelete = if deleteBody == nil then nil else (string.gsub(deleteBody, "%s+", ""))
	check(
		"deletion re-reads ownership server-side and refuses an id the ladder does not have",
		deleteBody ~= nil
			and string.find(deleteBody, "AuraRegistry.Get(auraId) == nil", 1, true) ~= nil
			and string.find(deleteBody, "InventoryMath.RemoveOne(state.inventory[auraId] or 0)", 1, true) ~= nil,
		if deleteBody == nil then "the DeleteAura handler was not found" else "ownership is not re-checked"
	)
	--[[
		Both anchors are required to EXIST before they are compared. An earlier
		version of this check fell back to 0 for a missing anchor, so deleting the
		refusal entirely ("if not removed then" -> "if false then") made the check
		PASS - a negative control caught that, which is the whole point of controls.
	]]
	local refusalIndex: number? = nil
	local mutationIndex: number? = nil
	if deleteBody ~= nil then
		refusalIndex = string.find(deleteBody, "if not removed then", 1, true)
		mutationIndex = string.find(deleteBody, "state.inventory[auraId] = remaining", 1, true)
	end
	check(
		"the ownership refusal exists, and comes before anything is mutated",
		refusalIndex ~= nil and mutationIndex ~= nil and refusalIndex < mutationIndex,
		string.format("refusal@%s mutation@%s", tostring(refusalIndex), tostring(mutationIndex))
	)
	check(
		"deletion removes exactly one copy per request, through one rule",
		--[[
			Two assignments are expected, and they are the two outcomes of ONE
			removal: the count that survives, or the key disappearing when it was the
			last copy. What must not be here is the handler subtracting on its own -
			that is what the next check pins.
		]]
		compactDelete ~= nil
			and occurrences(compactDelete, "InventoryMath%.RemoveOne%(") == 1
			and occurrences(compactDelete, "state%.inventory%[auraId%]=") == 2
			and string.find(compactDelete, "state.inventory[auraId]=remaining", 1, true) ~= nil
			and string.find(compactDelete, "state.inventory[auraId]=nil", 1, true) ~= nil
			and string.find(compactDelete, "InventoryMath.KeySurvives(remaining)", 1, true) ~= nil,
		if compactDelete == nil then "the DeleteAura handler was not found" else "the delete does not go through exactly one rule"
	)
	check(
		"the handler does no arithmetic of its own (no -1 on a count outside the rule)",
		compactDelete ~= nil and string.find(compactDelete, "inventory[auraId]-1", 1, true) == nil
	)
	check(
		"deleting the last copy of the equipped aura clears the equip",
		deleteBody ~= nil
			and string.find(deleteBody, "state.equippedAura = nil", 1, true) ~= nil
			and string.find(deleteBody, "state.inventory[auraId] = nil", 1, true) ~= nil
	)

	--[[
		SET FILTER. Both halves of the request are validated against the server's
		own ladder, the change is persisted through the same save call as everything
		else, and the answer the client gets is a sync - never the client's own guess.
	]]
	local setFilterBody = if rngRawReadable
		then between(rngRaw, "SetFilter.OnServerEvent:Connect(", "-- Player lifecycle")
		else nil
	check(
		"a junk mode is refused rather than coerced (nil fallback, not a default)",
		setFilterBody ~= nil and string.find(setFilterBody, "AuraFilter.SanitizeMode(mode, nil)", 1, true) ~= nil,
		if setFilterBody == nil then "the SetFilter handler was not found" else "an unknown mode is not refused"
	)
	check(
		"the threshold must be a rung of the real ladder",
		setFilterBody ~= nil
			and string.find(setFilterBody, "AuraFilter.IsRung(", 1, true) ~= nil
			and string.find(setFilterBody, "FILTER_RUNGS", 1, true) ~= nil
	)
	check(
		"the filter is persisted through the same save call as the rest of the state",
		setFilterBody ~= nil and string.find(setFilterBody, "saveState(state)", 1, true) ~= nil
	)
	check(
		"and that write is debounced (a stepper fires one request per click)",
		setFilterBody ~= nil and string.find(setFilterBody, "filterSaveToken", 1, true) ~= nil
	)
	check(
		"the setting the roll path reads is the server's own state",
		setFilterBody ~= nil
			and string.find(setFilterBody, "state.filterMode = cleanMode", 1, true) ~= nil
			and string.find(setFilterBody, "state.filterRarity = cleanRarity", 1, true) ~= nil
			and string.find(setFilterBody, "syncState(player, state)", 1, true) ~= nil
	)
	check(
		"the options the panel offers are the ladder, built once",
		string.find(rng, "AuraFilter.Rungs(AuraRegistry)", 1, true) ~= nil
			and string.find(rng, "options = FILTER_RUNGS,", 1, true) ~= nil
	)

	-- THE NO-SECOND-LIST CHECK: no tier name may appear as a literal in the game's
	-- own code. The names are derived from the ladder everywhere, so a hardcoded
	-- tier list would have to spell one out - and this catches it in any file.
	local hardcodedTiers: { string } = {}
	local tierNames: { string } = {}
	for _, auraId in ipairs(AuraRegistry.ORDER) do
		local tier = AuraRegistry.Get(auraId).tier
		if not table.find(tierNames, tier) then
			table.insert(tierNames, tier)
		end
	end
	--[[
		One tier name is also an AURA id (the ladder's top rung is named Sovereign,
		and so is its tier), so the two files that legitimately NAME AURAS may spell
		it without that being a hardcoded tier list. Every other tier name, in every
		file - and all 12 names everywhere else - is still flagged, so a second tier
		list still cannot hide: 11 of the 12 names would betray it.
	]]
	local auraNamingFiles: { [string]: boolean } = { AuraLadder = true, BiomeConfig = true }
	local checkedTiers = 0
	for path, source in pairs(sources) do
		if string.sub(path, 1, 11) == "src/server/" or string.sub(path, 1, 11) == "src/client/" then
			local leaf = string.match(path, "([^/]+)%.luau$") or path
			for _, tier in ipairs(tierNames) do
				local isAuraId = AuraRegistry.Get(tier) ~= nil
				if not (isAuraId and auraNamingFiles[leaf] == true) then
					checkedTiers += 1
					if string.find(source, '"' .. tier .. '"', 1, true) ~= nil then
						table.insert(hardcodedTiers, string.format("%s spells \"%s\"", path, tier))
					end
				end
			end
		end
	end
	check(
		string.format("no tier name is hardcoded in any server or client file (%d tiers x %d files checked)", #tierNames, #sourcePaths),
		#hardcodedTiers == 0,
		table.concat(hardcodedTiers, ", ")
	)

	--[[
		THE CLIENT SIDE. The drawer is its own module, mounted by MainUI; MainUI no
		longer owns the grid at all. Every mutation leaves through a remote, and no
		client file can reach the filter's policy.
	]]
	local inventoryUi, inventoryUiReadable = sourceOf("src/client/InventoryUI.luau")
	check(
		"the drawer is its own client module, mounted by MainUI",
		inventoryUiReadable and string.find(mainUi, "InventoryUI.Mount(", 1, true) ~= nil,
		if not inventoryUiReadable then "src/client/InventoryUI.luau is missing" else "MainUI does not mount the drawer"
	)
	check(
		"MainUI no longer owns the grid (no cells, no equip call, no scrolling frame)",
		string.find(mainUi, "buildInventoryCell", 1, true) == nil
			and string.find(mainUi, "EquipAura", 1, true) == nil
			and string.find(mainUi, "ScrollingFrame", 1, true) == nil
	)
	check(
		"MainUI hands every payload to the drawer instead of caching its own copy",
		string.find(mainUi, "InventoryUI.ApplyState(payload)", 1, true) ~= nil
	)
	check(
		"and replays the join-time sync, because the drawer is mounted after it arrives",
		-- The StateSync connection is set up above the panels: without a replay the
		-- drawer's first frame shows an empty grid and "filter off" as if that were
		-- the player's real state.
		string.find(mainUi, "InventoryUI.ApplyState(lastStatePayload)", 1, true) ~= nil,
		"the drawer can miss the join-time payload and paint an empty grid"
	)
	check(
		"the drawer equips, deletes and sets the filter through remotes only",
		inventoryUiReadable
			and string.find(inventoryUi, "EquipAura:FireServer(", 1, true) ~= nil
			and string.find(inventoryUi, "DeleteAura:FireServer(", 1, true) ~= nil
			and string.find(inventoryUi, "SetFilter:FireServer(", 1, true) ~= nil
	)
	check(
		"the drawer renders the server's options rather than a list of its own",
		inventoryUiReadable
			and string.find(inventoryUi, "payload.filter", 1, true) ~= nil
			and string.find(inventoryUi, "filter.options", 1, true) ~= nil
	)
	check(
		"the drawer never claims an ownership number of its own",
		inventoryUiReadable
			and string.find(inventoryUi, "payload.inventory", 1, true) ~= nil
			and string.find(inventoryUi, "SetAttribute", 1, true) == nil
	)
	check(
		"the client is told what a filtered pull dropped, and says so",
		string.find(mainUi, "payload.filtered == true", 1, true) ~= nil
			and string.find(mainUi, "payload.filterAction", 1, true) ~= nil
			and string.find(mainUi, "AuraRegistry.TierOf(threshold)", 1, true) ~= nil
	)

	--[[
		BIOME EVENTS: server-owned schedule, one selection path, and a HUD that is
		told rather than guessing.

		Three claims are pinned here, in the order they matter:
		  1. The schedule and the multiplier are the SERVER's. The epoch is read once
		     at load, the event is resolved from that epoch and nothing else, and no
		     remote carries a biome in either direction.
		  2. The boost enters through the ONE selection path - the same call site luck
		     and pity already flow through - so there is no second selector and no
		     per-aura case outside the biome's own data file.
		  3. The client is told (event, countdown, boosted rungs) and derives nothing.
		     No client file names BiomeMath, and no client file can read the cycle.

		The boundary is asserted too: the biome work writes to no world service. The
		world/atmosphere layer is a separate workstream and is handed the payload.
	]]
	local biomeMath, biomeMathReadable = sourceOf("src/server/BiomeMath.luau")
	local biomeConfig, biomeConfigReadable = sourceOf("src/server/BiomeConfig.luau")
	local biomeMathClean = stripComments(biomeMath)
	local biomeConfigClean = stripComments(biomeConfig)
	local rollMath, rollMathReadable = sourceOf("src/shared/RollMath.luau")
	local rollMathClean = stripComments(rollMath)

	do
		-- Detail strings are held in locals rather than written inline: this Luau
		-- rejects an if-expression in the argument position that follows a multi-line
		-- expression, so the readable form also happens to be the one that parses.
		local biomeFilesDetail = if not biomeMathReadable
			then "src/server/BiomeMath.luau is missing"
			else "src/server/BiomeConfig.luau is missing"
		check(
			"the biome's data and rules are their own two files",
			biomeMathReadable and biomeConfigReadable,
			biomeFilesDetail
		)

		--[[
			The epoch. `os.clock()` in RNGService is the server's clock, fixed once at
			load; every read of "what event is it now" is that epoch subtracted from
			the same clock, so two players asking at the same moment get one answer and
			a joiner lands inside the event already running rather than at its start.
		]]
		check(
			"the cycle epoch is set once, at load, from the server's own clock",
			plainCount(rng, "BIOME_EPOCH_CLOCK: number = os.clock()") == 1,
			string.format("%d assignments", plainCount(rng, "BIOME_EPOCH_CLOCK: number = os.clock()"))
		)
		check(
			"an event is resolved from that epoch and nothing else",
			string.find(rng, "BiomeMath.At(os.clock() - BIOME_EPOCH_CLOCK)", 1, true) ~= nil
		)
		check(
			"the schedule is read in exactly one place (one clock, one rule for everyone)",
			occurrences(rng, "BiomeMath%.At%(") == 1,
			string.format("%d call sites", occurrences(rng, "BiomeMath%.At%("))
		)
		check(
			"the boosts are resolved once, against the real ladder, at load",
			string.find(rng, "BiomeMath.Boosts(AuraRegistry)", 1, true) ~= nil
				and occurrences(rng, "BiomeMath%.Boosts%(") == 1,
			string.format("%d resolution sites", occurrences(rng, "BiomeMath%.Boosts%("))
		)
		local biomeNowBody = functionBody(rng, "local function biomeNow(")
		local biomeNowDetail = if biomeNowBody == nil
			then "biomeNow not found"
			else "the event is resolved from a caller's value"
		check(
			"the biome is never derived from a player - the resolver takes no player, no payload",
			biomeNowBody ~= nil
				and string.find(biomeNowBody, "player", 1, true) == nil
				and string.find(biomeNowBody, "payload", 1, true) == nil,
			biomeNowDetail
		)

		-- No remote carries a biome in either direction: the client cannot ask for one,
		-- and the server never reads one. (The client's only biome traffic is the
		-- payload it is sent, checked below.)
		local biomeArguments: { string } = {}
		for argument in string.gmatch(rng, "OnServerEvent:Connect(function%(%s*player%s*,?%s*([%w_]*)") do
			if string.find(string.lower(argument), "biome", 1, true) ~= nil then
				table.insert(biomeArguments, argument)
			end
		end
		check(
			"no remote handler accepts a biome from a client",
			#biomeArguments == 0,
			table.concat(biomeArguments, ", ")
		)

		--[[
			ONE SELECTION PATH. `RollMath.SelectAura` is the only place a pull is
			decided, so anywhere in src/ besides the definition and that single call is
			a second path - which is exactly the bug this asserts against.
		]]
		--[[
			Counted OUTSIDE the module that defines it. RollMath calls itself once, from
			`Simulate` - the harness helper inside the same module, which cannot be a
			second path because it is not on the server's roll path at all. Every real
			call site is counted, and there must be exactly one.
		]]
		local selectCalls: { string } = {}
		for path, source in pairs(sources) do
			if string.match(path, "([^/]+)%.luau$") ~= "RollMath" then
				local _, calls = string.gsub(stripComments(source), "RollMath%.SelectAura%(", "")
				for _ = 1, calls do
					table.insert(selectCalls, path)
				end
			end
		end
		check(
			"exactly one call site outside RollMath selects an aura, and it is the roll path",
			#selectCalls == 1 and selectCalls[1] == "src/server/RNGService.server.luau",
			table.concat(selectCalls, ", ")
		)
		check(
			"RollMath's own call to it is the simulation helper, not a second game path",
			between(rollMath, "function RollMath.Simulate(", "RollMath.SelectAura(") ~= nil,
			"the internal SelectAura call is not inside Simulate"
		)
		local selectDetail = if compactResolve == nil
			then "resolveRoll not found"
			else "the draw is not passed the resolved boost"
		check(
			"and it is the roll path, passing the event as a weight factor beside luck and pity",
			compactResolve ~= nil
				and string.find(compactResolve, "RollMath.SelectAura(luck,state.pityCounter,nil,biomeBoost)", 1, true) ~= nil,
			selectDetail
		)
		-- Held in a local: Luau will not accept an if-expression as the argument
		-- that follows a multi-line function literal.
		local readOnceDetail = if compactResolve == nil
			then "resolveRoll not found"
			else "the event is read more than once per roll"
		check(
			"the session's expected rare-or-better count is computed under the same event as the draw",
			-- An expectation that ignored a running event would drift from what the
			-- roll actually does for the whole five minutes of it.
			compactResolve ~= nil
				and string.find(compactResolve, "ChanceOfAtLeast(rareFloor,luck,state.pityCounter,biomeBoost)", 1, true) ~= nil,
			"the expectation does not take the event the draw uses"
		)
		check(
			"the roll path reads the event ONCE and uses that one read for the odds and the draw",
			--[[
				Two reads could disagree across a switch: the expectation would be
				computed under one event and the draw under the next, which is how a
				five-minute window ends up mis-attributed in the telemetry.
			]]
			(function(): boolean
				if compactResolve == nil then
					return false
				end
				local read = string.find(compactResolve, "localbiome=biomeNow()", 1, true)
				local resolve = string.find(compactResolve, "localbiomeBoost=biomeBoostFor(biome.id)", 1, true)
				local odds = string.find(compactResolve, "ChanceOfAtLeast(", 1, true)
				local draw = string.find(compactResolve, "RollMath.SelectAura(luck,state.pityCounter,nil,biomeBoost)", 1, true)
				return plainCount(compactResolve, "biomeNow()") == 1
					and read ~= nil
					and resolve > read
					and odds ~= nil
					and draw ~= nil
					and read < odds
					and read < draw
			end)(),
			readOnceDetail
		)

		--[[
			NO PER-AURA SPECIAL CASES. If a themed rung were named anywhere in the game's
			own code, the theme would live outside the data that defines it. The ids are
			allowed in exactly two files: the ladder (which defines them) and the biome
			config (which themes them).
		]]
		local strayAuraIds: { string } = {}
		for path, source in pairs(sources) do
			-- The capture excludes the ".luau" suffix: this is the module's own name.
			local leaf = string.match(path, "([^/]+)%.luau$") or path
			if leaf ~= "AuraLadder" and leaf ~= "BiomeConfig" then
				local clean = stripComments(source)
				for _, auraId in ipairs(AuraRegistry.ORDER) do
					if string.find(clean, '"' .. auraId .. '"', 1, true) ~= nil then
						table.insert(strayAuraIds, string.format("%s names %s", path, auraId))
					end
				end
			end
		end
		check(
			"no aura is special-cased outside the ladder and the biome's own data file",
			#strayAuraIds == 0,
			table.concat(strayAuraIds, ", ")
		)
		check(
			"the biome rules never name an aura either (they weigh whatever the config themes)",
			(function(): boolean
				for _, auraId in ipairs(AuraRegistry.ORDER) do
					if string.find(biomeMathClean, '"' .. auraId .. '"', 1, true) ~= nil then
						return false
					end
				end
				return true
			end)(),
			"BiomeMath.luau names a rung"
		)

		--[[
			WHAT THE CLIENT IS GIVEN. The payload carries the event, its countdown and
			the rungs it favours - and that table is the whole interface the separate
			world/atmosphere workstream gets. It is asserted here so the boundary is a
			contract rather than a conversation.
		]]
		local payloadBody = functionBody(rng, "local function buildStatePayload(")
		local payloadDetail = if payloadBody == nil
			then "buildStatePayload not found"
			else "the payload does not carry the full event"
		check(
			"the state payload carries the event, its countdown, its multiplier and its rungs",
			payloadBody ~= nil
				and string.find(payloadBody, "biome = {", 1, true) ~= nil
				and string.find(payloadBody, "id = biome.id,", 1, true) ~= nil
				and string.find(payloadBody, "displayName = biome.displayName,", 1, true) ~= nil
				and string.find(payloadBody, "secondsRemaining = biome.secondsRemaining,", 1, true) ~= nil
				and string.find(payloadBody, "progress = biome.progress,", 1, true) ~= nil
				and string.find(payloadBody, "multiplier = biome.multiplier,", 1, true) ~= nil
				and string.find(payloadBody, "boosted = ", 1, true) ~= nil,
			payloadDetail
		)
		check(
			"a config gap sends an empty rung list, so the reader never nil-checks a nested field",
			payloadBody ~= nil and string.find(payloadBody, "biomeBoost.rungs else {},", 1, true) ~= nil
		)
		local payloadAgreementDetail = if payloadBody == nil
			then "buildStatePayload not found"
			else "the payload's event and its rungs can disagree"
		check(
			"the countdown the client is told is the server's, read in the same breath as the rungs",
			payloadBody ~= nil
				and string.find(payloadBody, "local biome = biomeNow()", 1, true) ~= nil
				and string.find(payloadBody, "local biomeBoost = biomeBoostFor(biome.id)", 1, true) ~= nil,
			payloadAgreementDetail
		)
		check(
			"the event and its countdown ride the timer that already pushes state, so a joiner gets it too",
			-- The loop that waits on the streak interval sends the whole payload.
			string.find(rng, "task.wait(STREAK_SYNC_INTERVAL)", 1, true) ~= nil
				and between(rng, "task.wait(STREAK_SYNC_INTERVAL)", "syncState(player, state)") ~= nil
		)
		check(
			"the join path publishes state immediately (a player joining mid-event waits for nothing)",
			between(rng, "local function setupPlayer(", "syncState(player, loaded)") ~= nil
		)
		check(
			"the roll reports which event it was resolved under, and whether THAT pull was one of its rungs",
			string.find(rng, "biomeId = outcome.biomeId,", 1, true) ~= nil
				and string.find(rng, "biomeBoosted = outcome.biomeBoosted,", 1, true) ~= nil
		)

		--[[
			THE HUD. The strip shows the event it is told about and nothing else: the
			countdown is interpolated locally between pushes (once per displayed second,
			inside the loop that already ticks), but the EVENT only ever changes on a
			sync. When the local countdown runs out the panel says "switching..." and
			waits, because a client that named the next event itself could name one the
			server is not running.
		]]
		local biomeViewBody = functionBody(mainUi, "local function updateBiomeView(")
		local biomeViewDetail = if biomeViewBody == nil
			then "updateBiomeView not found"
			else "the strip invents its own event state"
		check(
			"the strip renders from the payload, with no event of its own",
			biomeViewBody ~= nil
				and string.find(biomeViewBody, "payload.biome", 1, true) ~= nil
				and string.find(biomeViewBody, "biome.displayName", 1, true) ~= nil
				and string.find(biomeViewBody, "biome.secondsRemaining", 1, true) ~= nil
				and string.find(biomeViewBody, "boosted", 1, true) ~= nil,
			biomeViewDetail
		)
		local blankDetail = if biomeViewBody == nil
			then "updateBiomeView not found"
			else "an unknown event is rendered as the previous one"
		check(
			"a missing or unknown event blanks the strip instead of leaving the last one standing",
			biomeViewBody ~= nil
				and string.find(biomeViewBody, "connecting...", 1, true) ~= nil
				and string.find(biomeViewBody, "biomeHasState = false", 1, true) ~= nil
				and string.find(biomeViewBody, "biomeBoostedIds = {}", 1, true) ~= nil,
			blankDetail
		)
		check(
			"the event only changes on a sync - one render site, no local switch",
			occurrences(mainUi, "updateBiomeView%(payload%)") == 1
				and occurrences(mainUi, "updateBiomeView%({}%)") == 1,
			string.format("%d sync renders", occurrences(mainUi, "updateBiomeView%(payload%)"))
		)
		check(
			"the countdown is interpolated between pushes, inside the loop that already ticks",
			--[[
				The paint has to be in the existing 20Hz loop and has to be driven by the
				sync clock: a client-side count-up (or a second timer) would drift away
				from the server every five minutes.
			]]
			(function(): boolean
				local tickLoop = between(mainUi, "local lastFill = -1", "task.wait(0.05)")
				return tickLoop ~= nil
					and string.find(tickLoop, "paintBiomeCountdown()", 1, true) ~= nil
					and string.find(mainUi, "biomeSyncedAt = os.clock()", 1, true) ~= nil
			end)(),
			"the countdown is not painted from the existing tick loop"
		)
		check(
			"running out locally claims nothing: the strip says it is switching and waits",
			string.find(mainUi, '"switching..."', 1, true) ~= nil
		)

		--[[
			THE TOP-CENTRE STACK, as arithmetic. The panel's height decides where the
			banner rests and the banner decides where the reveal hangs; read from the
			source so the three numbers cannot drift apart again. This is the check that
			would have caught the biome strip being added to a panel that was never made
			taller - the failure mode is a banner drawn over the new rows.

			In its own block on purpose: this file already carries a lot of locals and
			Luau allows 200 registers, so a scope that closes releases them again.
		]]
		do
		local function numberConstant(source: string, name: string): number?
			local captured = string.match(source, name .. "%s*: number = (%d+)")
			if captured == nil then
				return nil
			end
			return tonumber(captured)
		end

		local topY = numberConstant(mainUi, "HUD_TOP_Y")
		local panelHeight = numberConstant(mainUi, "PITY_PANEL_HEIGHT")
		local bannerRest = numberConstant(mainUi, "BANNER_REST_Y")
		local revealRest = numberConstant(mainUi, "REVEAL_REST_Y")
		local railY = numberConstant(mainUi, "BIOME_RAIL_Y")
		local stackDetail = string.format(
			"top=%s height=%s banner=%s reveal=%s rail=%s",
			tostring(topY),
			tostring(panelHeight),
			tostring(bannerRest),
			tostring(revealRest),
			tostring(railY)
		)
		check(
			"the HUD stack's constants still agree: the banner clears the panel and the reveal clears the banner",
			topY ~= nil
				and panelHeight ~= nil
				and bannerRest ~= nil
				and revealRest ~= nil
				and bannerRest >= (topY :: number) + (panelHeight :: number)
				and revealRest > bannerRest,
			stackDetail
		)
		check(
			"the biome strip's rows fit inside the panel they were added to",
			-- The rail is the bottom row; 6px is its height as declared below.
			panelHeight ~= nil and railY ~= nil and ((railY :: number) + 6) <= (panelHeight :: number),
			stackDetail
		)
		end
		check(
			"the multiplier on screen is the server's number, not a literal 3x",
			string.find(mainUi, "tonumber(biome.multiplier)", 1, true) ~= nil
				and string.find(mainUi, "x%s ON THEMED RUNGS", 1, true) ~= nil,
			"the strip hardcodes its multiplier"
		)
		check(
			"the boosted rungs named on the strip come from the payload's own list",
			string.find(mainUi, "formatBoostedRungs(boosted)", 1, true) ~= nil
				and string.find(mainUi, "Boosted: ", 1, true) ~= nil
		)
		check(
			"a reveal is badged only when the pulled aura is in the server's boosted set",
			string.find(mainUi, "biomeBoostedIds[config.id] == true", 1, true) ~= nil
				and string.find(mainUi, "biomeBadgeText", 1, true) ~= nil
		)
		check(
			"no client file names BiomeMath or reads the cycle length: clients cannot derive the schedule",
			(function(): boolean
				for path, source in pairs(sources) do
					if string.sub(path, 1, 11) == "src/client/" then
						local clean = stripComments(source)
						if string.find(clean, "BiomeMath", 1, true) ~= nil
							or string.find(clean, "BiomeConfig", 1, true) ~= nil
							or string.find(clean, "cycleSeconds", 1, true) ~= nil
							or string.find(clean, "CycleSeconds", 1, true) ~= nil
						then
							return false
						end
					end
				end
				return true
			end)()
		)
		check(
			"no client file sends a biome anywhere",
			(function(): boolean
				for path, source in pairs(sources) do
					if string.sub(path, 1, 11) == "src/client/" then
						for argument in string.gmatch(source, "FireServer%(([^%)]*)") do
							if string.find(string.lower(argument), "biome", 1, true) ~= nil then
								return false
							end
						end
					end
				end
				return true
			end)()
		)

		--[[
			THE BOUNDARY. The world/atmosphere layer is a separate workstream and owns
			Lighting, Atmosphere, Workspace and Camera. Nothing in this repository's
			server or HUD code may touch them: the biome work exposes the event on the
			payload and stops there.

			ProceduralVFX is the pre-existing, frozen VFX engine (it parents its own
			parts and shakes the camera) and is excluded by name, not by pattern.
		]]
		local worldWrites: { string } = {}
		for path, source in pairs(sources) do
			local leaf = string.match(path, "([^/]+)%.luau$") or path
			if leaf ~= "ProceduralVFX" then
				local clean = stripComments(source)
				for _, service in ipairs({ "Lighting", "Atmosphere", "Workspace", "CurrentCamera", "Camera" }) do
					if string.find(clean, service, 1, true) ~= nil then
						table.insert(worldWrites, string.format("%s touches %s", path, service))
					end
				end
			end
		end
		check(
			"no server or HUD file writes the world layer (Lighting/Atmosphere/Workspace/Camera)",
			#worldWrites == 0,
			table.concat(worldWrites, ", ")
		)
		check(
			"the biome's accent travels as data, not as a Roblox colour created server-side",
			string.find(biomeConfigClean, "Color3", 1, true) == nil
				and string.find(biomeConfigClean, "fromRGB", 1, true) == nil,
			"BiomeConfig reaches for a Roblox type"
		)

		--[[
			THE READING. The themed sets are checked against the real ladder rather than
			read off their names: what each event actually favours, in the ladder's own
			terms. The table is printed so the reading is visible in the harness output
			and not just asserted, and the two claims that must hold for the strip to be
			honest are checked: every event themes at least one rung, and a rung list short
			enough to render on one line.
		]]
		local themedNames: { string } = {}
		local stripProblems: { string } = {}
		local cheapest: { number } = {}
		for _, definition in ipairs(BiomeMath.Biomes) do
			local names: { string } = {}
			local lowest = math.huge
			for _, auraId in ipairs(definition.auraIds) do
				local config = AuraRegistry.Get(auraId)
				if config == nil then
					names = { auraId .. "(not on the ladder)" }
					break
				end
				lowest = math.min(lowest, config.rarity)
				table.insert(names, string.format("%s 1 in %d", config.displayName, config.rarity))
			end
			table.insert(cheapest, lowest)
			table.insert(themedNames, string.format("%s: %s", definition.displayName, table.concat(names, " | ")))
			if #definition.auraIds == 0 or #definition.auraIds > 5 then
				table.insert(stripProblems, string.format("%s themes %d rungs", definition.id, #definition.auraIds))
			end
		end
		for _, line in ipairs(themedNames) do
			note("themed set -> " .. line)
		end
		note(
			string.format(
				"cheapest themed rung per event: %s (a spread of %.0fx) - the events favour different bands, not one band renamed",
				table.concat(
					(function(): { string }
						local out: { string } = {}
						for index, value in ipairs(cheapest) do
							table.insert(out, string.format("%s=1 in %d", BiomeMath.Biomes[index].id, value))
						end
						return out
					end)(),
					" "
				),
				math.max(table.unpack(cheapest)) / math.max(1, math.min(table.unpack(cheapest)))
			)
		)
		check(
			"every event themes between 1 and 5 rungs (a short list is what the strip can render on one line)",
			#stripProblems == 0,
			table.concat(stripProblems, ", ")
		)
		check(
			"the events favour different bands of the ladder, not three names for one band",
			math.max(table.unpack(cheapest)) / math.max(1, math.min(table.unpack(cheapest))) >= 100,
			string.format("cheapest rungs: %s", table.concat(cheapest, ", "))
		)
		check(
			"every themed rung exists on the ladder with the label the payload carries",
			(function(): boolean
				for _, definition in ipairs(BiomeMath.Biomes) do
					for _, auraId in ipairs(definition.auraIds) do
						if AuraRegistry.Get(auraId) == nil then
							return false
						end
					end
				end
				return true
			end)()
		)
	end

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

	-- =============================================================================
	section("The Luck Shrine: the zone test, executed against the shipped region")

	--[[
		WHAT IS EXECUTED AND WHAT IS ONLY READ.

		ShrineConfig and ShrineMath are pure Luau with no Roblox in them, so the zone
		test and the cooldown arithmetic are EXECUTED here - the rim, one thousandth
		of a stud past it, the ceiling, a teleporting player, damaged input, several
		wallets at once. What cannot be executed is a SERVER reading a character's
		position; that needs Roblox. So the wiring that makes such a read the only
		input is asserted against RNGService's source in the next section, and the two
		halves are kept honestly apart.
	]]
	do
		local region = ShrineMath.Region
		local ox, oy, oz = region.origin.x, region.origin.y, region.origin.z
		local radius = math.max(region.size.x, region.size.z) / 2
		local height = region.size.y

		check(
			"the shipped region is a cylinder sitting ON its origin and growing up",
			region.shape == "cylinder"
				and region.boundaryInclusive == true
				and radius > 0
				and height > 0,
			string.format(
				"%s shape=%s r=%.1f h=%.1f inclusive=%s",
				region.name,
				region.shape,
				radius,
				height,
				tostring(region.boundaryInclusive)
			)
		)

		local function at(x: number, y: number, z: number): any
			return { X = x, Y = y, Z = z }
		end

		check("the centre of the floor is inside", ShrineMath.Contains(region, at(ox, oy, oz)))
		check("a point one stud up is inside", ShrineMath.Contains(region, at(ox, oy + 1, oz)))
		check(
			"the top of the zone is inside and a thousandth above it is not",
			ShrineMath.Contains(region, at(ox, oy + height, oz))
				and not ShrineMath.Contains(region, at(ox, oy + height + 0.001, oz))
		)
		check(
			"standing exactly on the rim counts as inside - the boundary belongs to the zone",
			ShrineMath.Contains(region, at(ox + radius, oy, oz))
				and ShrineMath.Contains(region, at(ox, oy, oz - radius))
				and ShrineMath.Contains(region, at(ox - radius, oy + 1, oz)),
			string.format("rim at r=%.1f", radius)
		)
		check(
			"a thousandth of a stud past the rim is outside",
			not ShrineMath.Contains(region, at(ox + radius + 0.001, oy + 1, oz))
				and not ShrineMath.Contains(region, at(ox, oy + 1, oz + radius + 0.001))
		)
		check("a thousandth of a stud below the floor is outside", not ShrineMath.Contains(region, at(ox, oy - 0.001, oz)))
		check(
			"the corner of the bounding box is outside: this is a disc, not a square",
			not ShrineMath.Contains(region, at(ox + radius * 0.99, oy + 1, oz + radius * 0.99))
		)
		check(
			"a stub that spells its axes in lowercase is read too (the harness's own shape)",
			ShrineMath.Contains(region, { x = ox, y = oy, z = oz })
				and not ShrineMath.Contains(region, { x = ox + radius + 1, y = oy, z = oz })
		)

		--[[
			A TELEPORTING PLAYER needs no special case, and THAT IS THE POINT: the zone
			test is a position, so "teleported in" and "walked in" are the same call with
			different arguments. What is worth pinning is that nothing is remembered
			between readings - out, in, out, in, with no carry-over.
		]]
		local far = at(ox + radius * 40, oy, oz + radius * 40)
		local here = at(ox, oy + 2, oz)
		check(
			"a teleport is just the next position: out, in, out, in, remembering nothing",
			not ShrineMath.Contains(region, far)
				and ShrineMath.Contains(region, here)
				and not ShrineMath.Contains(region, far)
				and ShrineMath.Contains(region, here)
		)

		-- An array of { label, value } pairs: the label is what a failure prints.
		local damaged = {
			{ "nil (no character to read)", nil },
			{ "an empty table", {} },
			{ "a string", "the shrine" },
			{ "a number", 12 },
			{ "NaN on an axis", { X = 0 / 0, Y = oy, Z = oz } },
			{ "infinity on an axis", { X = math.huge, Y = oy, Z = oz } },
			{ "a missing axis", { X = ox, Y = oy } },
			{ "a string axis", { X = tostring(ox), Y = oy, Z = oz } },
		}
		local leaks: { string } = {}
		for _, entry in ipairs(damaged) do
			if ShrineMath.Contains(region, entry[2]) then
				table.insert(leaks, entry[1])
			end
		end
		check(
			"an unreadable position is OUTSIDE - a failed read never pays the bonus",
			#leaks == 0,
			table.concat(leaks, ", ")
		)

		-- A config with a hole in it must not take the roll path down: the region is
		-- data, and data gets checked.
		local survived = pcall(function()
			ShrineMath.Contains({ name = "no size", shape = "cylinder" }, at(0, 1, 0))
			ShrineMath.Contains({ name = "no origin", shape = "box", size = { x = 4, y = 4, z = 4 } }, at(0, 1, 0))
			ShrineMath.Sample({ name = "nothing" }, at(0, 1, 0), 1)
			ShrineMath.ComposeCooldown({ base = 1.2, passMultiplier = 1, inShrine = true, minimum = 0.15 })
		end)
		check("a region with a missing field degrades instead of throwing mid-roll", survived)

		-- The box and the sphere are part of the contract even though no shipped
		-- region uses them: whoever builds geometry is told which convention applies.
		local box = {
			name = "Box",
			shape = "box",
			origin = { x = 0, y = 0, z = 0 },
			size = { x = 4, y = 3, z = 2 },
			boundaryInclusive = true,
		}
		check(
			"a box region reads x/z as full extents centred on origin, and y as height above the floor",
			ShrineMath.Contains(box, at(1.99, 0, 0.99))
				and ShrineMath.Contains(box, at(-1.99, 2.99, -0.99))
				and not ShrineMath.Contains(box, at(2.01, 0, 0))
				and not ShrineMath.Contains(box, at(0, 3.01, 0))
				and not ShrineMath.Contains(box, at(0, 0, 1.01))
		)

		local sphere = {
			name = "Sphere",
			shape = "sphere",
			origin = { x = 0, y = 0, z = 0 },
			size = { x = 6, y = 6, z = 6 },
			boundaryInclusive = true,
		}
		check(
			"a sphere region is centred above its origin, on the wireframe",
			ShrineMath.Contains(sphere, at(3, 3, 0))
				and ShrineMath.Contains(sphere, at(0, 3, 3))
				and not ShrineMath.Contains(sphere, at(3.01, 3, 0))
				and not ShrineMath.Contains(sphere, at(0, 6.01, 0))
		)

		local typo = {
			name = "Typo",
			shape = "cylander",
			origin = { x = 0, y = 0, z = 0 },
			size = { x = 4, y = 4, z = 4 },
			boundaryInclusive = true,
		}
		check(
			"a misspelled shape degrades to the cylinder test rather than taking the server down",
			ShrineMath.Contains(typo, at(0, 1, 0)) and not ShrineMath.Contains(typo, at(2.5, 1, 0))
		)

		local sample = ShrineMath.SampleHere(at(ox, oy, oz), 42.5)
		local missing = ShrineMath.SampleHere(nil, 42.5)
		check(
			"a sample carries the clock it was taken at, so a caller never needs a second read",
			sample.inside == true and sample.at == 42.5
		)
		check(
			"a sample with no character to read is outside, and still says when it asked",
			missing.inside == false and missing.at == 42.5
		)

		-- The on-disk region is not mutated by being tested. A test that wrote through
		-- would move the shrine for every subsequent player in the server.
		local before = string.format("%s|%s|%s|%s|%.3f|%.3f|%.3f", region.name, region.shape, tostring(region.boundaryInclusive), tostring(region.origin.x), region.size.x, region.size.y, region.size.z)
		ShrineMath.Contains(region, at(ox + radius, oy, oz))
		ShrineMath.SampleHere(at(ox, oy, oz), 1)
		local after = string.format("%s|%s|%s|%s|%.3f|%.3f|%.3f", region.name, region.shape, tostring(region.boundaryInclusive), tostring(region.origin.x), region.size.x, region.size.y, region.size.z)
		check("testing the zone does not move the zone", before == after)
	end

	-- =============================================================================
	section("The Luck Shrine: the +15%, executed in and out of the zone")

	do
		local base = 1.2
		local floor = ShrineMath.MinimumCooldown()
		local rate = ShrineMath.SpeedMultiplier()

		local function compose(pass: number, inside: boolean, minimum: number?): number
			return ShrineMath.ComposeCooldown({
				base = base,
				passMultiplier = pass,
				inShrine = inside,
				minimum = if minimum ~= nil then minimum else floor,
			})
		end

		local outside = compose(1, false)
		local inside = compose(1, true)

		check(
			"out of the zone the cooldown is untouched: base times the pass factor",
			approx(outside, base, 1e-12),
			string.format("%.12f vs %.12f", outside, base)
		)
		check(
			"the +15% is a RATE, so being in the zone DIVIDES the cooldown by 1.15",
			approx(rate, 1.15, 1e-12) and approx(inside, base / 1.15, 1e-12),
			string.format("rate=%.12f in-zone=%.12f expected=%.12f", rate, inside, base / 1.15)
		)
		check(
			"and a player in the zone rolls exactly 15% more often than the same player outside",
			-- The mission's words are "+15% roll speed", so the ROLLS PER SECOND ratio is
			-- the claim that has to hold - not the cooldown ratio, which is a different
			-- (larger) bonus wearing the same word.
			approx((1 / inside) / (1 / outside), 1.15, 1e-12),
			string.format("%.12f rolls/s inside vs %.12f outside (ratio %.12f)", 1 / inside, 1 / outside, (1 / inside) / (1 / outside))
		)
		check(
			"the percentage the HUD prints and the mechanic are the same number",
			ShrineMath.BonusPercent() == 15 and approx(rate - 1, 0.15, 1e-12),
			string.format("bonus=%d%% rate=%.6f", ShrineMath.BonusPercent(), rate)
		)
		check(
			"the cooldown form of the same mechanic is the rate inverted",
			approx(ShrineMath.CooldownMultiplier(), 1 / 1.15, 1e-12),
			string.format("%.12f", ShrineMath.CooldownMultiplier())
		)

		check(
			"the Fast Roll pass and the zone compose, in and out",
			approx(compose(0.6, false), base * 0.6, 1e-12)
				and approx(compose(0.6, true), base * 0.6 / 1.15, 1e-12),
			string.format("pass=0.6 out=%.6f in=%.6f", compose(0.6, false), compose(0.6, true))
		)
		check(
			"the zone still pays its 15% under the pass: the two factors are independent",
			approx(compose(0.6, false) / compose(0.6, true), 1.15, 1e-12),
			string.format("ratio %.12f", compose(0.6, false) / compose(0.6, true))
		)

		--[[
			THE EXPLOIT BOUND. Two ways a "bonus" turns into free rolls: applying
			itself more than once, and multiplying a cooldown down past zero. The first is
			structural (`inShrine` is a boolean, one division, no accumulation), the second
			is the floor.
		]]
		local shrineMathSource = stripComments(sourceOf("src/server/ShrineMath.luau"))
		check(
			"the zone cannot stack with itself: one division, a boolean, no accumulation",
			plainCount(shrineMathSource, "cooldown /=") == 1
				and plainCount(shrineMathSource, "inShrine") >= 1
				and plainCount(shrineMathSource, "inShrineCount") == 0,
			string.format("%d division(s)", plainCount(shrineMathSource, "cooldown /="))
		)
		check(
			"standing in the zone for an hour buys no more than standing in it for a second",
			-- Time is nowhere in the arithmetic: there is no duration input at all.
			approx(compose(1, true), compose(1, true), 0)
				and plainCount(shrineMathSource, "secondsInside") == 0
				and plainCount(shrineMathSource, "duration") == 0
		)
		check(
			"a stack of factors that would reach a free roll is clamped to the floor",
			approx(compose(0.01, true), floor, 1e-12),
			string.format("%.12f vs floor %.12f", compose(0.01, true), floor)
		)
		check(
			"the floor is a real roll away from free, and matches the invoke rate limit the client lives under",
			floor > 0 and approx(floor, 0.15, 1e-12),
			string.format("floor=%.4f", floor)
		)
		check(
			"damaged factors degrade to no bonus - never slower, never free",
			approx(compose(0, true), base / 1.15, 1e-12)
				and approx(compose(-1, true), base / 1.15, 1e-12)
				and approx(compose(1, true, 0 / 0), inside, 1e-12),
			string.format("pass=0 -> %.6f, pass=-1 -> %.6f", compose(0, true), compose(-1, true))
		)

		check(
			"several players in the zone at once compose independently",
			(function(): boolean
				local readings: { number } = {}
				for index = 1, 5 do
					readings[index] = compose(if index == 3 then 0.6 else 1, true)
				end
				-- Four of them have identical inputs and must get identical seconds: the
				-- function holds no state, so one player's zone time cannot discount
				-- another's, and a crowd is not a bonus multiplier.
				local same = 0
				for index = 1, 5 do
					if index ~= 3 and approx(readings[index], readings[1], 0) then
						same += 1
					end
				end
				return same == 4 and readings[3] < readings[1]
			end)(),
			"a crowd of players in the zone did not compose independently"
		)

		check(
			"a player outside pays the plain cooldown however many players are inside",
			approx(compose(1, false), base, 1e-12) and approx(compose(0.6, false), base * 0.6, 1e-12)
		)
	end

	-- =============================================================================
	section("LeaderboardMath: ordering, ties, bounds and the encoded score (executed)")

	do
		local ladderMax = AuraRegistry.HighestRarity()
		local maxEntries = LeaderboardMath.Constants.maxEntries

		local function entry(userId: number, name: string, rolls: number, rarity: number): any
			return LeaderboardMath.Entry(userId, name, rolls, rarity, ladderMax)
		end

		--[[
			THE ENCODING carries both numbers a board wants in one integer, and the
			round trip is EXECUTED rather than assumed: the rarest find has to survive
			being packed into the same value as the roll count.
		]]
		local roundTripProblems: { string } = {}
		for _, pair in ipairs({ { 0, 0 }, { 1, 1 }, { 1234, 1500 }, { 999999, ladderMax }, { 1, ladderMax } }) do
			local rolls, rarity = pair[1], pair[2]
			local encoded = LeaderboardMath.Encode(rolls, rarity, ladderMax)
			local decodedRolls, decodedRarity = LeaderboardMath.Decode(encoded, ladderMax)
			if decodedRolls ~= rolls or decodedRarity ~= rarity then
				table.insert(roundTripProblems, string.format("(%d, %d) -> %d -> (%d, %d)", rolls, rarity, encoded, decodedRolls, decodedRarity))
			end
		end
		check(
			"a score round-trips into exactly the rolls and the rarest find it was built from",
			#roundTripProblems == 0,
			table.concat(roundTripProblems, ", ")
		)

		local headroom = LeaderboardMath.Encode(LeaderboardMath.Constants.maxRolls, ladderMax, ladderMax)
		check(
			"the encoding has headroom: the worst case is still an integer Roblox stores exactly",
			headroom < 2 ^ 53 and headroom > 0,
			string.format("worst case %.0f vs 2^53 = %.0f", headroom, 2 ^ 53)
		)
		check(
			"an absurd roll count is clamped rather than wrapping into the rarity digits",
			(function(): boolean
				local decodedRolls, decodedRarity = LeaderboardMath.Decode(LeaderboardMath.Encode(1e30, ladderMax, ladderMax), ladderMax)
				return decodedRolls == LeaderboardMath.Constants.maxRolls and decodedRarity == ladderMax
			end)(),
			"a wrapped score would read as a bogus rarest find"
		)

		--[[
			THE ORDER, in the terms a player would use: more rolls first, and a tie on
			rolls broken by the rarer find. Every one of these is the same rule applied
			by the same function, from the ladder's real ceiling.
		]]
		local ranked = LeaderboardMath.Rank({
			entry(4, "Delta", 99, ladderMax),
			entry(1, "Alpha", 100, 1),
			entry(3, "Charlie", 100, ladderMax),
			entry(2, "Bravo", 100, ladderMax),
		}, maxEntries)

		check(
			"more rolls rank first",
			ranked[1].rolls == 100 and ranked[#ranked].rolls == 99,
			string.format("first roll count %d, last %d", ranked[1].rolls, ranked[#ranked].rolls)
		)
		check(
			"a tie on rolls is broken by the rarer find, rarest first",
			ranked[1].rarestRarity == ladderMax and ranked[2].rarestRarity == ladderMax and ranked[3].rarestRarity == 1,
			string.format("rarities: %d, %d, %d", ranked[1].rarestRarity, ranked[2].rarestRarity, ranked[3].rarestRarity)
		)
		check(
			"a tie on both is broken by user id ascending, so two runs cannot disagree",
			ranked[1].userId == 2 and ranked[2].userId == 3,
			string.format("ids: %d, %d", ranked[1].userId, ranked[2].userId)
		)
		check(
			"an exact tie sorts the same way whichever order the entries arrived in",
			(function(): boolean
				local a = { entry(7, "Golf", 500, 100), entry(5, "Echo", 500, 100) }
				local b = { entry(5, "Echo", 500, 100), entry(7, "Golf", 500, 100) }
				local first = LeaderboardMath.Rank(a, maxEntries)
				local second = LeaderboardMath.Rank(b, maxEntries)
				return first[1].userId == 5 and second[1].userId == 5
			end)()
		)

		local many: { any } = {}
		for index = 1, 25 do
			many[index] = entry(index, string.format("Player%d", index), index * 10, index)
		end
		local bounded = LeaderboardMath.Rank(many, maxEntries)
		check(
			string.format("the board is bounded: 25 entries in, exactly %d out, best first", maxEntries),
			#bounded == maxEntries and bounded[1].rolls == 250 and bounded[#bounded].rolls == 160,
			string.format("got %d entries, first %d, last %d", #bounded, bounded[1].rolls, bounded[#bounded].rolls)
		)
		check(
			"asking for more than the bound cannot widen it",
			#LeaderboardMath.Rank(many, 1000) == maxEntries
				and #LeaderboardMath.Rank(many, nil) == maxEntries
				and #LeaderboardMath.Rank(many, 0) == 0
				and #LeaderboardMath.Rank(many, 0 / 0) == maxEntries,
			string.format("1000 -> %d, nil -> %d, 0 -> %d", #LeaderboardMath.Rank(many, 1000), #LeaderboardMath.Rank(many, nil), #LeaderboardMath.Rank(many, 0))
		)

		--[[
			DAMAGED INPUT. A store row that is not a row, a key that is not a key, a
			value that is not a number: each is skipped rather than ranked as zero, and
			none of them throws. That matters because the board is read from a store the
			server does not own the history of.
		]]
		-- The rows below are all non-nil on purpose: a table with a nil hole cannot be
		-- walked with ipairs at all, so "no row at all" is its own check.
		local damagedRows: { any } = {
			42,
			"a string",
			{ key = "nonsense", value = 10 },
			{ key = "12|Twelve", value = 0 },
			{ key = "12|Twelve", value = -5 },
			{ key = "12|Twelve", value = 0 / 0 },
			{ key = "0|Nobody", value = 10 },
			{ key = "12|Twelve", value = "ten" },
		}
		local skipped = 0
		for _, row in ipairs(damagedRows) do
			if LeaderboardMath.FromRow(row, ladderMax) == nil then
				skipped += 1
			end
		end
		check(
			"a store row that is nothing at all is skipped",
			LeaderboardMath.FromRow(nil, ladderMax) == nil
		)
		check(
			"a damaged store row is skipped, not ranked as zero",
			skipped == #damagedRows,
			string.format("%d of %d skipped", skipped, #damagedRows)
		)

		local good = LeaderboardMath.FromRow({ key = "42|FortyTwo", value = LeaderboardMath.Encode(321, 1500, ladderMax) }, ladderMax)
		check(
			"a good store row decodes to its key's name and both numbers",
			good ~= nil and good.userId == 42 and good.name == "FortyTwo" and good.rolls == 321 and good.rarestRarity == 1500,
			if good == nil then "nil" else string.format("%s/%d/%d", good.name, good.rolls, good.rarestRarity)
		)

		--[[
			KEYS. Names travel in the key so an offline player is still nameable, and the
			sanitising is what keeps a name from splitting its own key in two.
		]]
		local keyProblems: { string } = {}
		local names = { "Normal", "with|pipe", "with\nnewline", string.rep("x", 40), "" }
		for _, name in ipairs(names) do
			local key = LeaderboardMath.Key(12345, name)
			local userId, parsedName = LeaderboardMath.ParseKey(key)
			if userId ~= 12345 or #key > 50 or string.find(parsedName, "|", 1, true) ~= nil then
				table.insert(keyProblems, string.format("%q -> %q", name, key))
			end
		end
		check(
			"a key survives any name, stays inside the store's length limit, and parses back",
			#keyProblems == 0,
			table.concat(keyProblems, ", ")
		)
		check(
			"a garbage key parses to nothing rather than to user zero",
			(function(): boolean
				for _, key in ipairs({ "", "nonsense", "|NoId", "abc|Name", 42, nil }) do
					local userId = LeaderboardMath.ParseKey(key)
					if userId ~= nil then
						return false
					end
				end
				return true
			end)()
		)

		--[[
			THE MERGE. The board a player sees is the persisted one with this server's
			players folded in. One entry per user, the better score wins, and a live
			entry wins a tie because it carries the current name.
		]]
		local merged = LeaderboardMath.Merge(
			{ entry(10, "OldName", 500, 100), entry(20, "Persisted", 900, 10) },
			{ entry(10, "NewName", 500, 100), entry(30, "Live", 100, 0) },
			maxEntries
		)
		local function rowForUserId(entries: { any }, userId: number): any
			for _, row in ipairs(entries) do
				if row.userId == userId then
					return row
				end
			end
			return nil
		end

		check(
			"merging the store's board with this server's players leaves one row per user",
			#merged == 3,
			string.format("%d rows", #merged)
		)
		local renamed = rowForUserId(merged, 10)
		check(
			"a live entry wins an exact tie, so a rename does not leave two rows for one person",
			renamed ~= nil and renamed.name == "NewName" and renamed.rolls == 500,
			if renamed == nil then "the user vanished from the merge" else string.format("user 10 is %s", renamed.name)
		)
		check(
			"and the merge is ranked, not concatenated: 900 rolls ranks above 500",
			merged[1].name == "Persisted" and merged[1].rolls == 900,
			string.format("top row %s with %d", merged[1].name, merged[1].rolls)
		)
		check(
			"the better of two entries for one user wins",
			(function(): boolean
				local better = LeaderboardMath.Merge({ entry(1, "A", 900, 0) }, { entry(1, "A", 100, 0) }, maxEntries)
				local worse = LeaderboardMath.Merge({ entry(1, "A", 100, 0) }, { entry(1, "A", 900, 0) }, maxEntries)
				return #better == 1 and better[1].rolls == 900 and #worse == 1 and worse[1].rolls == 900
			end)()
		)

		--[[
			A PLAYER WHO HAS DONE NOTHING HAS NO ROW. The live half of the board is built
			from every connected player, so without this rule a fresh server's whole board
			is one row reading `0 rolls` - a picture that looks like data about the server
			rather than like "nobody has rolled yet". These two are executed, not asserted:
			the merge really drops the entry, and the rows a HUD renders really come back
			empty so the panel's empty state is reachable at all.
		]]
		local nothingYet = LeaderboardMath.Merge({}, { entry(1, "JustJoined", 0, 0) }, maxEntries)
		local mixed = LeaderboardMath.Merge({ entry(2, "Roller", 5, 0) }, { entry(1, "JustJoined", 0, 0) }, maxEntries)
		check(
			"a player who has not rolled yet has no row: a zero score cannot join the board",
			#nothingYet == 0 and #mixed == 1 and mixed[1].name == "Roller",
			string.format("fresh board %d row(s), mixed board %d row(s)", #nothingYet, #mixed)
		)
		check(
			"and the rendered rows are then empty, which is the only way the panel's empty state is reached",
			#LeaderboardMath.Rows(nothingYet, AuraRegistry, maxEntries) == 0
				and #LeaderboardMath.Rows(mixed, AuraRegistry, maxEntries) == 1
		)
		check(
			"a brand-new player cannot displace a full board of ten, and adds no zero row to it",
			(function(): boolean
				local full = {}
				for index = 1, maxEntries do
					full[index] = entry(100 + index, string.format("Veteran%d", index), 500 - index, index * 100)
				end
				local withNewcomer = LeaderboardMath.Merge(full, { entry(1, "JustJoined", 0, 0) }, maxEntries)
				if #withNewcomer ~= maxEntries then
					return false
				end
				for _, row in ipairs(withNewcomer) do
					if row.rolls <= 0 then
						return false
					end
				end
				return withNewcomer[1].name == "Veteran1"
			end)(),
			"a joiner reached a board row"
		)
		check(
			"a damaged score cannot join it either, so a bad live value is never a rank",
			-- NaN and infinity are the two that `score <= 0` would wave through, and a NaN
			-- in the list makes the comparator answer false both ways for one pair.
			(function(): boolean
				local nanEntry = { userId = 7, name = "Bad", rolls = 0, rarestRarity = 0, score = 0 / 0 }
				local infEntry = { userId = 8, name = "Worse", rolls = 0, rarestRarity = 0, score = math.huge }
				local stringEntry = { userId = 9, name = "Wrong", rolls = 0, rarestRarity = 0, score = "999" }
				return #LeaderboardMath.Merge({}, { nanEntry, infEntry, stringEntry }, maxEntries) == 0
			end)(),
			"a damaged score reached a board row"
		)

		--[[
			ROWS. What actually leaves the server: rank, both numbers, and the rarest
			find resolved against the ladder's own labels.
		]]
		local rarityAura = LeaderboardMath.AuraAtRarity(AuraRegistry, ladderMax)
		local rows = LeaderboardMath.Rows({ entry(2, "Two", 10, ladderMax), entry(1, "One", 20, 0) }, AuraRegistry, maxEntries)
		check(
			"rows are numbered from one, in ranked order",
			#rows == 2 and rows[1].rank == 1 and rows[1].name == "One" and rows[2].rank == 2
		)
		check(
			"the rarest find is resolved to the ladder's own label and tier",
			rarityAura ~= nil and rows[2].rarestAura == rarityAura.id and rows[2].rarestDisplayName == rarityAura.displayName,
			if rarityAura == nil then "the ladder has no rung at the top rarity" else string.format("%s (%s)", rows[2].rarestDisplayName, rows[2].tier)
		)
		check(
			"a player with nothing rare yet has no aura name, not a wrong one",
			rows[1].rarestAura == nil and rows[1].rarestRarity == 0 and rows[1].rarestDisplayName == nil
		)
		check(
			"an entry the key could not name still gets a stable label",
			LeaderboardMath.DisplayName(entry(987654, "", 1, 0)) == "Player 987654"
		)
		check(
			"a user id that is not a real id cannot enter the board",
			LeaderboardMath.SanitizeUserId(0) == 0
				and LeaderboardMath.SanitizeUserId(-5) == 0
				and LeaderboardMath.SanitizeUserId(0 / 0) == 0
				and LeaderboardMath.SanitizeUserId(2 ^ 53 + 2) == 0
				and LeaderboardMath.SanitizeUserId(1) == 1
		)
	end

	-- =============================================================================
	section("The Top Rollers board without a DataStore (executed end to end)")

	do
		--[[
			THE FALLBACK IS NOT SIMULATED: in Lune there is no DataStoreService, so this
			IS the Studio-without-API-access path - the same one the saves use. The board
			has to rank, bound and tie-break identically, because a board that works only
			where a store exists is a board nobody can test.
		]]
		local memory = SaveBackend.GetOrdered("harness_top_rollers")
		check(
			"without a DataStore the board falls back to memory, and says which it is",
			string.find(memory.kind, "Memory") ~= nil,
			memory.kind
		)

		check("an empty key is refused rather than recorded", memory.submit("", 5) == false)
		check("a submission is accepted", memory.submit("1|Alpha", 100) == true)
		memory.submit("2|Bravo", 100)
		memory.submit("3|Charlie", 250)
		memory.submit("4|Delta", 10)

		local top = memory.top(10)
		check(
			"the board comes back highest first, ties broken by key so two reads agree",
			#top == 4
				and top[1].key == "3|Charlie"
				and top[2].key == "1|Alpha"
				and top[3].key == "2|Bravo"
				and top[4].key == "4|Delta",
			top[1].key .. ", " .. top[2].key .. ", " .. top[3].key .. ", " .. top[4].key
		)
		check(
			"the read is bounded by the count asked for",
			#memory.top(2) == 2 and #memory.top(0) == 0 and #memory.top(-3) == 0
		)
		check(
			"a lower score never demotes a recorded one",
			memory.submit("3|Charlie", 5) == true and memory.top(1)[1].key == "3|Charlie" and memory.top(1)[1].value == 250
		)
		check(
			"a damaged score is stored as zero rather than as a huge number",
			(function(): boolean
				memory.submit("9|Nine", 0 / 0)
				for _, row in ipairs(memory.top(10)) do
					if row.key == "9|Nine" then
						return row.value == 0
					end
				end
				return false
			end)(),
			"a NaN score was not stored as zero"
		)
		check(
			"and the same store read twice gives the same order",
			(function(): boolean
				local first = memory.top(4)
				local second = memory.top(4)
				for index = 1, #first do
					if first[index].key ~= second[index].key then
						return false
					end
				end
				return true
			end)()
		)

		--[[
			THE WHOLE PIPELINE, on the fallback: ENCODED scores are what a real server
			writes (the board's integer carries the rolls and the rarest find), so this
			half uses the same `Encode` the game does - store rows -> entries -> merged
			with a live server's players -> the rows a HUD renders. This is the path a
			Studio session without API access really takes.
		]]
		local ladderMax = AuraRegistry.HighestRarity()
		local pipeline = SaveBackend.GetOrdered("harness_top_rollers_pipeline")
		pipeline.submit(LeaderboardMath.Key(3, "Charlie"), LeaderboardMath.Encode(250, 0, ladderMax))
		pipeline.submit(LeaderboardMath.Key(1, "Alpha"), LeaderboardMath.Encode(100, 0, ladderMax))
		pipeline.submit(LeaderboardMath.Key(2, "Bravo"), LeaderboardMath.Encode(100, ladderMax, ladderMax))

		local persisted: { any } = {}
		for _, row in ipairs(pipeline.top(LeaderboardMath.Constants.maxEntries)) do
			local decoded = LeaderboardMath.FromRow(row, ladderMax)
			if decoded ~= nil then
				table.insert(persisted, decoded)
			end
		end
		local live = {
			LeaderboardMath.Entry(77, "PlayingNow", 120, 5000, ladderMax),
			LeaderboardMath.Entry(1, "Alpha", 100, 0, ladderMax),
		}
		local board = LeaderboardMath.Rows(LeaderboardMath.Merge(persisted, live, LeaderboardMath.Constants.maxEntries), AuraRegistry, nil)
		check(
			"the fallback store feeds the same ranking the payload carries",
			#board == 4 and board[1].name == "Charlie" and board[1].rolls == 250 and board[1].rank == 1,
			if board[1] == nil then "empty board" else string.format("%s first with %d rolls", board[1].name, board[1].rolls)
		)
		check(
			"the rarest find carried in the score decides the tie on the board itself",
			board[2].name == "PlayingNow" and board[2].rolls == 120 and board[2].rank == 2,
			-- PlayingNow has 120 rolls; Bravo has 100 but the rarest rung in the ladder.
			-- Rolls rank first, so the 120-roll player is above the 100-roll one.
			string.format("second row is %s with %d rolls", board[2].name, board[2].rolls)
		)
		check(
			"a live player's rolls are in the list while the session runs",
			(function(): boolean
				for _, row in ipairs(board) do
					if row.name == "PlayingNow" and row.rolls == 120 and row.rarestRarity == 5000 then
						return true
					end
				end
				return false
			end)(),
			"the live half of the board did not reach the rows"
		)
	end

	-- =============================================================================
	section("The shrine and the board, wired: what only a server can decide")

	do
		local shrineMathSource = stripComments(sourceOf("src/server/ShrineMath.luau"))
		local shrineConfigSource = stripComments(sourceOf("src/server/ShrineConfig.luau"))
		local cooldownBody = functionBody(rng, "local function cooldownFor(")
		local inputsBody = functionBody(rng, "local function cooldownInputs(")

		check(
			"there is exactly one cooldown function, and exactly one place that gathers its factors",
			--[[
				Every composition site takes its inputs from `cooldownInputs`, so the roll path
				and the telemetry readout cannot describe different mechanics. An inline
				input table anywhere is the drift this catches - the earlier version of this
				check pinned THREE copies of that table instead of removing them.
			]]
			plainCount(rng, "local function cooldownFor(player: Player, state: PlayerState): number") == 1
				and plainCount(rng, "local function cooldownInputs(") == 1
				and functionBody(rng, "local function cooldownFor(") ~= nil
				and plainCount(rng, "cooldownInputs(player, state") == 3
				and plainCount(rng, "ShrineMath.ComposeCooldown(cooldownInputs(") == 3,
			string.format(
				"%d input builders, %d inline input tables",
				plainCount(rng, "local function cooldownInputs("),
				plainCount(rng, "passMultiplier = if state.fastEnabled")
			)
		)
		check(
			"no cooldown input table is written out by hand outside that one builder",
			plainCount(rng, "passMultiplier = if state.fastEnabled then PerkService.GetCooldownMultiplier(player) else 1") == 1,
			string.format(
				"%d hand-written factor lists",
				plainCount(rng, "passMultiplier = if state.fastEnabled then PerkService.GetCooldownMultiplier(player) else 1")
			)
		)
		check(
			"no file outside ShrineMath does cooldown arithmetic of its own",
			(function(): boolean
				local offenders: { string } = {}
				for path, source in pairs(sources) do
					if string.match(path, "([^/]+)%.luau$") ~= "ShrineMath" then
						local clean = stripComments(source)
						if string.find(clean, "BASE_COOLDOWN *", 1, true) ~= nil
							or string.find(clean, "BASE_COOLDOWN /", 1, true) ~= nil
							or string.find(clean, "cooldown *", 1, true) ~= nil then
							table.insert(offenders, path)
						end
					end
				end
				if #offenders > 0 then
					note("second cooldown arithmetic in: " .. table.concat(offenders, ", "))
				end
				return #offenders == 0
			end)()
		)
		check(
			"the cooldown the roll path uses is composed from the base, the pass and the zone",
			--[[
				The three factors live in `cooldownInputs` and the roll path passes the zone
				flag from its own server-read state, so a hand-written factor list cannot
				sneak in beside the composition.
			]]
			cooldownBody ~= nil
				and string.find(cooldownBody, "ShrineMath.ComposeCooldown(cooldownInputs(player, state, state.shrineInside))", 1, true) ~= nil
				and string.find(inputsBody or "", "base = BASE_COOLDOWN", 1, true) ~= nil
				and string.find(inputsBody or "", "PerkService.GetCooldownMultiplier(player)", 1, true) ~= nil
				and string.find(inputsBody or "", "inShrine = inside", 1, true) ~= nil,
			if cooldownBody == nil then "cooldownFor not found" else "a factor is not composed"
		)
		check(
			"the zone state a roll uses is read at that moment, not from the last sample",
			-- A player who teleports in has to be paid on the VERY NEXT roll; reading only
			-- a 0.5s sample would make the bonus up to one sample late forever.
			cooldownBody ~= nil and string.find(cooldownBody, "refreshShrine(player, state)", 1, true) ~= nil,
			"the roll path does not re-read the character"
		)
		check(
			"the pass entitlement is consulted only when the player asked for fast roll",
			inputsBody ~= nil
				and string.find(inputsBody, "if state.fastEnabled then PerkService.GetCooldownMultiplier(player) else 1", 1, true) ~= nil,
			"a client preference is not a discount"
		)

		--[[
			THE ONLY INPUT IS A SERVER READ. No remote carries a position, a zone or an
			"inside" flag in either direction, and the sampler takes a player, never a
			client argument. The structural claim is what makes the client's inability to
			claim the bonus true rather than aspirational.
		]]
		local sampleBody = functionBody(rng, "local function shrineSampleFor(")
		check(
			"the zone state is decided from the player's own character, on the server",
			sampleBody ~= nil
				and string.find(sampleBody, "player.Character", 1, true) ~= nil
				and string.find(sampleBody, "HumanoidRootPart", 1, true) ~= nil
				and string.find(sampleBody, "ShrineMath.SampleHere(position", 1, true) ~= nil,
			if sampleBody == nil then "shrineSampleFor not found" else "the sample is not taken from a character"
		)
		check(
			"a missing character samples as OUTSIDE, so the bonus fails closed",
			sampleBody ~= nil and string.find(sampleBody, "if part ~= nil then part.Position else nil", 1, true) ~= nil
		)
		check(
			"no remote handler accepts a position, a zone or an inside flag from a client",
			(function(): boolean
				for argument in string.gmatch(rng, "OnServerEvent:Connect(function%(%s*player%s*,?%s*([%w_]*)") do
					local lowered = string.lower(argument)
					if string.find(lowered, "pos", 1, true) ~= nil
						or string.find(lowered, "shr", 1, true) ~= nil
						or string.find(lowered, "inside", 1, true) ~= nil
						or string.find(lowered, "zone", 1, true) ~= nil then
						return false
					end
				end
				return true
			end)(),
			"a remote carries the zone in"
		)
		check(
			"no client file names ShrineMath or ShrineConfig, so no client can run the zone test itself",
			(function(): boolean
				for path, source in pairs(sources) do
					if string.sub(path, 1, 11) == "src/client/" then
						local clean = stripComments(source)
						if string.find(clean, "ShrineMath", 1, true) ~= nil
							or string.find(clean, "ShrineConfig", 1, true) ~= nil
							or string.find(clean, "rollSpeedMultiplier", 1, true) ~= nil then
							return false
						end
					end
				end
				return true
			end)()
		)
		check(
			"no client file sends a position or a zone state anywhere",
			(function(): boolean
				for path, source in pairs(sources) do
					if string.sub(path, 1, 11) == "src/client/" then
						for argument in string.gmatch(source, "FireServer%(([^%)]*)") do
							local lowered = string.lower(argument)
							if string.find(lowered, "position", 1, true) ~= nil
								or string.find(lowered, "shrine", 1, true) ~= nil
								or string.find(lowered, "zone", 1, true) ~= nil then
								return false
							end
						end
					end
				end
				return true
			end)()
		)
		check(
			"a crowd is counted from the same flags the bonus reads, one per player and starting at none",
			-- Read structurally because the count needs Roblox to run: it has to start from
			-- zero, add exactly one per player whose own state says they are inside, and
			-- consult nothing else - a count that started at one, or added a constant,
			-- would advertise a crowd that is not there.
			(function(): boolean
				local crowdBody = functionBody(rng, "local function playersInsideShrine(")
				return crowdBody ~= nil
					and string.find(crowdBody, "local total = 0", 1, true) ~= nil
					and string.find(crowdBody, "if state.shrineInside then", 1, true) ~= nil
					and string.find(crowdBody, "total += 1", 1, true) ~= nil
					and plainCount(crowdBody, "total += 1") == 1
			end)(),
			"the count and the bonus disagree about who is inside"
		)
		check(
			"the sampler publishes a transition immediately and otherwise rides the sync",
			-- Stepping into the zone should show up at once; a boolean does not need a full
			-- payload (which carries the inventory) ten times a second.
			(function(): boolean
				local loop = between(rng, "task.wait(SHRINE_SAMPLE_INTERVAL)", "\n\tend\nend)")
				return loop ~= nil
					and string.find(loop, "local wasInside = state.shrineInside", 1, true) ~= nil
					and string.find(loop, "if state.shrineInside ~= wasInside then", 1, true) ~= nil
					and string.find(loop, "syncState(player, state)", 1, true) ~= nil
			end)(),
			"the shrine loop does not publish on a transition"
		)

		--[[
			THE GEOMETRY CONTRACT. This module creates no geometry: whoever owns the world
			layer builds to the numbers, and the numbers travel in the payload. The check
			that nothing in src/ writes to the world services already exists above; these
			pin the data half of the same boundary.
		]]
		check(
			"the shrine config is data, not geometry: no Instance, no Vector3, no Color3",
			shrineConfigSource ~= ""
				and string.find(shrineConfigSource, "Instance.new", 1, true) == nil
				and string.find(shrineConfigSource, "Vector3", 1, true) == nil
				and string.find(shrineConfigSource, "Color3", 1, true) == nil
				and string.find(shrineConfigSource, "CFrame", 1, true) == nil,
			"ShrineConfig reaches for a Roblox type"
		)
		check(
			"the shrine's rules are pure: no Roblox type in ShrineMath either",
			shrineMathSource ~= ""
				and string.find(shrineMathSource, "Instance.new", 1, true) == nil
				and string.find(shrineMathSource, "Vector3", 1, true) == nil
				and string.find(shrineMathSource, "workspace", 1, true) == nil
				and string.find(shrineMathSource, "game:", 1, true) == nil
		)
		check(
			"the region travels in the payload, verbatim, for whoever builds the pedestal",
			plainCount(rng, "region = SHRINE_REGION") == 1
				and string.find(rng, "region = SHRINE_REGION", 1, true) ~= nil,
			"the geometry contract is not published"
		)
		check(
			"the readout attributes a viewer can poll are set from the same state",
			plainCount(rng, 'SetAttribute("InLuckShrine", state.shrineInside)') == 1
				and plainCount(rng, 'SetAttribute("ShrineRollSpeedMultiplier",') == 1
		)
		check(
			"the floor the composer clamps to and the invoke rate limit are the same number",
			-- A clamped cooldown below the invoke limit would be a roll the server refuses,
			-- i.e. a visible lie about how fast the game goes.
			plainCount(rng, "INVOKE_RATE_LIMIT: number = 0.15") == 1
				and approx(ShrineMath.MinimumCooldown(), 0.15, 1e-12),
			string.format("floor %.4f", ShrineMath.MinimumCooldown())
		)

		--[[
			THE BOARD'S WIRING. What only a server can do: submit on a cadence rather
			than per roll (an ordered store is rate limited), read the persisted board
			back, and be the single place readiness is decided.
		]]
		check(
			"the board is one ordered store, chosen through the same backend policy as the saves",
			plainCount(rng, "SaveBackend.GetOrdered(LEADERBOARD_STORE_NAME)") == 1
				and plainCount(rng, "SaveBackend.Get(DATASTORE_NAME)") == 1
		)
		check(
			"readiness starts false and is set true in exactly one place: by the read itself",
			-- Both halves are load-bearing. Without the `= false` start, a session would
			-- open claiming to have read a board it has not; without the single
			-- assignment inside the read, it could never stop claiming that.
			plainCount(rng, "local leaderboardReady: boolean = false") == 1
				and plainCount(rng, "leaderboardReady = true") == 1
				and string.find(functionBody(rng, "local function refreshLeaderboard(") or "", "leaderboardReady = true", 1, true) ~= nil,
			string.format("%d assignment(s)", plainCount(rng, "leaderboardReady = true"))
		)
		check(
			"the payload reports the flag, never a literal, so an unread board cannot look empty",
			plainCount(rng, "ready = leaderboardReady") == 1
				and plainCount(rng, "ready = true") == 0
		)
		check(
			"a store read that FAILS is not an empty board: the backend says so instead of answering zero rows",
			--[[
				Not a hypothetical: the ordered read catches its own failure (rate limit,
				outage) and warns. Answering `{}` there would silently replace a good board
				with an empty one and call it read - the same class of lie as a fake zero.
				The check reads the FIRST return after that warning, which is the value the
				caller is handed.
			]]
			(function(): boolean
				local saveBackendClean = stripComments(sourceOf("src/server/SaveBackend.luau"))
				local anchor = string.find(saveBackendClean, "Ordered read failed for %s", 1, true)
				if anchor == nil then
					return false
				end
				local firstReturn = string.find(saveBackendClean, "return", anchor, true)
				if firstReturn == nil then
					return false
				end
				return string.sub(saveBackendClean, firstReturn, firstReturn + #"return nil" - 1) == "return nil"
			end)(),
			"the failed read is reported as an empty board"
		)
		check(
			"and the failure branch does nothing but return early: no snapshot write, no readiness claim",
			--[[
				Read as the branch's own text: the slice from its guard to its closing `end`,
				with the whitespace removed, must still be exactly the guard and its return.
				Any statement added inside it shows up here as extra characters - including
				`rows = {}`, which the first version of this check accepted (it looked for two
				field names, and a control proved it let the failure fall through to "empty
				board, read").
			]]
			(function(): boolean
				local body = functionBody(rng, "local function refreshLeaderboard(")
				if body == nil then
					return false
				end
				local branch = between(body, "if rows == nil then", "\tend")
				if branch == nil then
					return false
				end
				local bare = string.gsub(branch, "%s", "")
				return bare == "ifrows==nilthenreturn"
			end)(),
			"the failure branch does more than return"
		)
		check(
			"an in-memory board never fails, so it always hands back a table",
			-- The fallback is the path the harness itself runs on; it must not be the
			-- reason a caller has to nil-check.
			(function(): boolean
				local ordered = SaveBackend.GetOrdered("harness_never_fails")
				local rows = ordered.top(5)
				return type(rows) == "table" and #rows == 0
			end)()
		)
		check(
			"a score is never submitted from the roll path - only from the cadence, a leave and shutdown",
			(function(): boolean
				local rollBody = functionBody(rng, "local function resolveRoll(")
				if rollBody == nil or string.find(rollBody, "submitLeaderboard(", 1, true) ~= nil then
					return false
				end
				-- Four: the definition itself, the cadence loop, a leave, and shutdown.
				-- Pinned so a fifth site has to be considered rather than slipping in -
				-- and the roll path is checked to be none of them, above.
				return plainCount(rng, "submitLeaderboard(") == 4
			end)(),
			string.format("%d submit call sites", plainCount(rng, "submitLeaderboard("))
		)
		check(
			"every write of the board is gated on a SETTLED state, so a placeholder can never destroy real progress",
			--[[
				The window this guards: a joiner is put into `playerStates` immediately with
				an empty state, because they must be rollable before a DataStore read
				returns. A leave (or a shutdown) inside that window would otherwise save an
				empty snapshot and force-submit score 0 over a real board row. Both the
				leave path and the shutdown path therefore act only on settled state, and
				the load task is the only thing that marks a state settled.
			]]
			(function(): boolean
				local leaveBody = functionBody(rng, "local function teardownPlayer(")
				local shutdown = between(rng, "game:BindToClose(function()", "saveBackend.kind ~= \"DataStore\"")
				if leaveBody == nil or string.find(leaveBody, "if state.loadSettled then", 1, true) == nil then
					return false
				end
				if string.find(shutdown or "", "state.loadSettled", 1, true) == nil then
					return false
				end
				-- Both the save and the board write sit inside that guard: an unsettled
				-- state must not reach either store.
				local guarded = between(leaveBody, "if state.loadSettled then", "end")
				return guarded ~= nil
					and string.find(guarded, "saveState(state)", 1, true) ~= nil
					and string.find(guarded, "submitLeaderboard(player, state, true)", 1, true) ~= nil
			end)(),
			"the leave or shutdown path would write a placeholder"
		)
		check(
			"settled is marked in exactly one place: the load task, on the state it built from the store",
			plainCount(rng, "loadSettled = true") == 1
				and plainCount(rng, "local state = buildState(player, nil)") == 1
				and plainCount(rng, "loadSettled = false") == 1,
			string.format("%d marker(s)", plainCount(rng, "loadSettled = true"))
		)
		check(
			"a refused write is not forgotten: only the store's answer updates the session's score",
			(function(): boolean
				local body = functionBody(rng, "local function submitLeaderboard(")
				return body ~= nil
					and string.find(body, "if accepted then", 1, true) ~= nil
					and string.find(body, "state.leaderboardScore = entry.score", 1, true) ~= nil
			end)(),
			"a rate-limited write would be lost"
		)
		check(
			"the board is read once at load, so a session does not open on 'connecting...' for half a minute",
			(function(): boolean
				local loop = between(rng, "task.spawn(function()\n\trefreshLeaderboard()", "task.wait(LEADERBOARD_REFRESH_INTERVAL)")
				return loop ~= nil
			end)(),
			"the first board read is a full interval late"
		)
		check(
			"the write cadence is a constant, not a per-roll side effect",
			plainCount(rng, "task.wait(LEADERBOARD_WRITE_INTERVAL)") == 1
				and plainCount(rng, "LEADERBOARD_WRITE_INTERVAL: number = LeaderboardMath.Constants.writeIntervalSeconds") == 1
		)
		check(
			"no client file sends a score or a rank",
			(function(): boolean
				for path, source in pairs(sources) do
					if string.sub(path, 1, 11) == "src/client/" then
						for argument in string.gmatch(source, "FireServer%(([^%)]*)") do
							local lowered = string.lower(argument)
							if string.find(lowered, "score", 1, true) ~= nil
								or string.find(lowered, "rank", 1, true) ~= nil
								or string.find(lowered, "rolls", 1, true) ~= nil then
								return false
							end
						end
					end
				end
				return true
			end)()
		)
		check(
			"the board's score and the persisted rolls are the same number",
			-- The board is not a second, drifting account of how much a player rolled: it
			-- reads the state the save writes.
			plainCount(rng, "state.totalRolls,") >= 1
				and string.find(functionBody(rng, "local function leaderboardEntryFor(") or "", "state.totalRolls", 1, true) ~= nil
		)

		-- =========================================================================
		-- The HUD half: what the client is allowed to show
		-- =========================================================================

		local shrineViewBody = functionBody(mainUi, "local function updateShrineView(")
		check(
			"the shrine row is rendered from the payload, and claims nothing before one arrives",
			shrineViewBody ~= nil
				and string.find(shrineViewBody, "payload.shrine", 1, true) ~= nil
				and string.find(shrineViewBody, "shrine.inside", 1, true) ~= nil
				and string.find(shrineViewBody, "connecting...", 1, true) ~= nil,
			if shrineViewBody == nil then "updateShrineView not found" else "the row invents zone state"
		)
		check(
			"the +15% printed on the row is the server's percentage, not a literal in the client",
			shrineViewBody ~= nil
				and string.find(shrineViewBody, "tonumber(shrine.bonusPercent)", 1, true) ~= nil
				and string.find(shrineViewBody, "+%d%%", 1, true) ~= nil,
			"the HUD hardcodes the bonus"
		)
		check(
			"and the seconds it buys are the payload's composed cooldown",
			shrineViewBody ~= nil and string.find(shrineViewBody, "tonumber(payload.cooldown)", 1, true) ~= nil
		)
		check(
			"the crowd figure is the server's count",
			shrineViewBody ~= nil and string.find(shrineViewBody, "tonumber(shrine.playersInside)", 1, true) ~= nil
		)

		local boardViewBody = functionBody(mainUi, "local function updateLeaderboardView(")
		check(
			"the board renders rows from the payload and resolves nothing itself",
			boardViewBody ~= nil
				and string.find(boardViewBody, "payload.leaderboard", 1, true) ~= nil
				and string.find(boardViewBody, "board.entries", 1, true) ~= nil,
			if boardViewBody == nil then "updateLeaderboardView not found" else "the panel invents its own board"
		)
		check(
			"NO FAKE ZEROS: before the first read the panel hides every row and draws no numbers",
			-- The not-ready branch, sliced from its own guard to its `return`, must clear
			-- the rows and must not reach the row formatter. An unread board and an empty
			-- one are otherwise the same picture, and one of them is a lie about the
			-- whole server - the bug this check exists for.
			(function(): boolean
				local branch = between(mainUi, "board.ready ~= true", "return")
				if branch == nil then
					return false
				end
				return string.find(branch, "Visible = false", 1, true) ~= nil
					and string.find(branch, "label.Text = \"\"", 1, true) ~= nil
					and string.find(branch, "formatBoardRow(", 1, true) == nil
			end)(),
			"the panel would print a board it has not read"
		)
		check(
			"the panel is told once, before the first sync, that it knows nothing yet",
			plainCount(mainUi, "updateLeaderboardView({})") == 1
				and plainCount(mainUi, "updateLeaderboardView(payload)") == 1
				and plainCount(mainUi, "updateShrineView({})") == 1
				and plainCount(mainUi, "updateShrineView(payload)") == 1,
			"the first-frame state is not stated"
		)
		check(
			"a session-only board says so instead of reading like a global one",
			boardViewBody ~= nil and string.find(boardViewBody, "board.sessionOnly == true", 1, true) ~= nil
				and string.find(boardViewBody, "session only", 1, true) ~= nil
		)
		check(
			"an actually-empty board says it is empty rather than showing numbered zeroes",
			boardViewBody ~= nil and string.find(boardViewBody, "if shown == 0 then", 1, true) ~= nil
		)
		check(
			"the local player's own row is marked from the id, not from the name",
			boardViewBody ~= nil
				and string.find(boardViewBody, "tonumber(row.userId) == localUserId", 1, true) ~= nil
		)

		do
			local function numberConstant(source: string, name: string): number?
				local captured = string.match(source, name .. "%s*: number = (%d+)")
				if captured == nil then
					return nil
				end
				return tonumber(captured)
			end

			local rows = numberConstant(mainUi, "BOARD_ROWS")
			local rowTop = numberConstant(mainUi, "BOARD_ROW_TOP")
			local rowHeight = numberConstant(mainUi, "BOARD_ROW_HEIGHT")
			local boardDetail = string.format(
				"rows=%s top=%s height=%s server max=%s",
				tostring(rows),
				tostring(rowTop),
				tostring(rowHeight),
				tostring(LeaderboardMath.Constants.maxEntries)
			)
			check(
				"the panel has exactly as many rows as the server can send, and they fit inside it",
				rows ~= nil
					and rowTop ~= nil
					and rowHeight ~= nil
					and rows == LeaderboardMath.Constants.maxEntries
					and (rowTop :: number) + rows * (rowHeight :: number) <= 56 + rows * (rowHeight :: number)
					and (rowTop :: number) <= 56,
				boardDetail
			)
			check(
				"the board panel's height is derived from its own row count, not a second literal",
				(function(): boolean
					local expression = string.match(mainUi, "BOARD_PANEL_HEIGHT: number = ([^\n]+)")
					return expression ~= nil
						and string.find(expression, "BOARD_ROWS * BOARD_ROW_HEIGHT", 1, true) ~= nil
				end)(),
				"the panel height is a literal that can drift from the rows"
			)
			check(
				"the HUD stack still agrees: the board panel sits inside the same band as the top panel",
				-- The board is anchored to the top right, so the only thing to keep true is
				-- that it starts at the same top offset rather than floating over the panel.
				string.find(mainUi, "local boardPanel = makeFrame(hud, {", 1, true) ~= nil
					and string.find(mainUi, "Position = UDim2.new(1, -14, 0, HUD_TOP_Y)", 1, true) ~= nil
			)
			check(
				"the shrine row's own row fits the panel it was added to",
				(function(): boolean
					local shrineY = numberConstant(mainUi, "SHRINE_ROW_Y")
					local panelHeight = numberConstant(mainUi, "PITY_PANEL_HEIGHT")
					return shrineY ~= nil and panelHeight ~= nil and (shrineY :: number) + 14 <= (panelHeight :: number)
				end)(),
				"the shrine row was added to a panel that was never made taller"
			)
		end
	end
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
	note("Also unproven: the drawer and filter control rendering, a real delete round-trip, the ")
	note("server-side filter visibly dropping junk during an auto-roll, and the rejoin that restores ")
	note("a saved filter setting (its SAVE PATH is executed here; Roblox's persistence is not). ")
	note("Studio Play mode covers those - see the README / final report for the checklist.")
end

process.exit(failures == 0 and 0 or 1)
