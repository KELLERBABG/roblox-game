--!strict
--[[
	RNGService (server)
	===================
	AUTHORITATIVE side of the aura collector.

	Responsibilities:
	  * Build the Remotes folder (RequestRoll / RollBroadcast / ToggleAutoRoll /
	    EquipAura / StateSync) programmatically in ReplicatedStorage. Nothing is
	    expected to pre-exist in the place file.
	  * Own every piece of game state: total rolls, pity counter, luck, inventory,
	    equipped aura and last roll timestamp.
	  * Enforce the roll cooldown, run the auto-roll clock and resolve every roll
	    through RollMath.
	  * Persist through a DataStore wrapper with an in-memory fallback so local
	    playtests never error and nothing is ever lost during a session.

	HARD RULE: this script never touches visuals. It creates no particles, no
	parts, no highlights and never connects RenderStepped. It publishes intent
	through `Player:SetAttribute("EquippedAura", id)` plus RemoteEvents, and the
	client renders at 60 FPS.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- =============================================================================
-- Shared modules
-- =============================================================================

local sharedInstance = ReplicatedStorage:WaitForChild("Shared", 30)
if sharedInstance == nil then
	error("[RNGService] ReplicatedStorage.Shared is missing. Is `rojo serve` syncing src/shared?")
end
local Shared = sharedInstance :: Folder

local auraRegistryModule = Shared:WaitForChild("AuraRegistry", 30)
local rollMathModule = Shared:WaitForChild("RollMath", 30)
if auraRegistryModule == nil or rollMathModule == nil then
	error("[RNGService] Shared.AuraRegistry / Shared.RollMath are missing.")
end

local AuraRegistry: any = require(auraRegistryModule :: ModuleScript)
local RollMath: any = require(rollMathModule :: ModuleScript)

-- =============================================================================
-- Server modules
-- =============================================================================

-- PerkService is the ONLY source of a luck or cooldown multiplier: this script
-- asks for the resolved number and never learns what produced it, so a client
-- has no way to influence it from here. SaveBackend is the one owner of the
-- DataStore-or-memory policy - the shop's purchase receipts use the very same
-- backend selection, which is what makes a DataStore-less Studio session behave
-- identically on both paths.
local SaveBackend: any = require(script.Parent:WaitForChild("SaveBackend") :: ModuleScript)
local PerkService: any = require(script.Parent:WaitForChild("PerkService") :: ModuleScript)
local StreakMath: any = require(script.Parent:WaitForChild("StreakMath") :: ModuleScript)
local AuraFilter: any = require(script.Parent:WaitForChild("AuraFilter") :: ModuleScript)
local InventoryMath: any = require(script.Parent:WaitForChild("InventoryMath") :: ModuleScript)
local BiomeMath: any = require(script.Parent:WaitForChild("BiomeMath") :: ModuleScript)
local ShrineMath: any = require(script.Parent:WaitForChild("ShrineMath") :: ModuleScript)
local LeaderboardMath: any = require(script.Parent:WaitForChild("LeaderboardMath") :: ModuleScript)
local ServerRemotes: any = require(script.Parent:WaitForChild("ServerRemotes") :: ModuleScript)

-- =============================================================================
-- Balance constants
-- =============================================================================

-- The fast-roll cooldown is deliberately NOT a constant here any more: the Fast
-- Roll pass owns that number (MonetizationConfig), and PerkService is what hands
-- it over. A second copy in this file is a second thing to keep in sync.
local BASE_COOLDOWN: number = 1.2
local BASE_LUCK: number = 1.0
local INVOKE_RATE_LIMIT: number = 0.15
local BROADCAST_RARITY_THRESHOLD: number = 1000
local ROLL_LOG_INTERVAL: number = 25
-- The client summarises auto-roll filtering at this cadence instead of toasting
-- every dropped pull (an auto-rolling player generates one per ~0.6-1.2s).
local FILTERED_SUMMARY_INTERVAL: number = 25
local AUTOSAVE_INTERVAL: number = 90

-- Session streak. The clock is StreakMath's: live = one level per 2 minutes,
-- Studio = the same curve on a 12x faster clock so a playtest can watch it move.
local STREAK_LEVEL_SECONDS: number = StreakMath.ClockSeconds(RunService:IsStudio())
-- How often the streak is re-published. The counter has to visibly grow, and the
-- value must stay the server's, so the server pushes rather than the client
-- counting (see the streak loop near the player lifecycle).
local STREAK_SYNC_INTERVAL: number = 2
-- The Luck Shrine. The REGION is data (ShrineConfig, through ShrineMath) because
-- the Visuals workstream builds the geometry to those numbers; this file only
-- reads it and decides per player whether their own character is inside.
local SHRINE_REGION: any = ShrineMath.Region
local SHRINE_DISPLAY: any = ShrineMath.Display
local SHRINE_BONUS_PERCENT: number = ShrineMath.BonusPercent()
-- How often every character's position is re-read for the HUD readout and the
-- player attributes. A display cadence, not the roll's source of truth - see the
-- sampler below, and `cooldownFor`, for what the roll path does instead.
local SHRINE_SAMPLE_INTERVAL: number = ShrineMath.SampleInterval()
-- The floor under the composed cooldown (and the client's own invoke rate limit).
local MIN_COOLDOWN_SECONDS: number = ShrineMath.MinimumCooldown()

-- The Top Rollers board. One ordered store, whose score carries both numbers a
-- player cares about (see LeaderboardMath): how much they rolled and how rare
-- their best find is. Reads and writes are on a cadence, because an ordered store
-- is write-rate-limited and a per-roll write would be one per second per player.
local LEADERBOARD_STORE_NAME: string = "AuraCollectorLeaderboard_v1"
local LEADERBOARD_MAX_ENTRIES: number = LeaderboardMath.Constants.maxEntries
local LEADERBOARD_WRITE_INTERVAL: number = LeaderboardMath.Constants.writeIntervalSeconds
local LEADERBOARD_REFRESH_INTERVAL: number = LeaderboardMath.Constants.refreshIntervalSeconds
local LADDER_MAX_RARITY: number = AuraRegistry.HighestRarity()
local DATASTORE_NAME: string = "AuraCollectorSave_v1"
local SAVE_VERSION: number = 1
local MAX_INVENTORY_COUNT: number = 1e9
-- A filter change is persisted through the same save path as everything else,
-- but debounced: stepping the threshold fires one request per click, and Roblox
-- refuses writes to the same key inside ~6 seconds. The debounce keeps the LAST
-- value with one write, and PlayerRemoving saves immediately regardless.
local FILTER_SAVE_DEBOUNCE: number = 8

--[[
	THE FILTER'S OPTIONS ARE THE LADDER.

	One rung per aura, straight out of AuraRegistry, ascending rarity - so the
	control can only offer thresholds that exist and a balance change to
	AuraLadder flows into the filter with no second list to edit. Built once and
	shared: the payload references this table rather than rebuilding it on every
	state sync (which happens on every roll).
]]
type FilterRung = {
	rarity: number,
	tier: string,
	auraId: string,
	displayName: string,
}

local FILTER_RUNGS: { FilterRung } = AuraFilter.Rungs(AuraRegistry)
if #FILTER_RUNGS == 0 then
	error("[RNGService] AuraFilter.Rungs found no rungs; the ladder could not be read.")
end

-- Structural mirrors of BiomeMath's exported shapes, local because a module
-- required through `WaitForChild(...) :: ModuleScript` is typed `any` (the same
-- convention the streak and filter mirrors follow).
type BiomeRung = {
	rarity: number,
	tier: string,
	auraId: string,
	displayName: string,
}

type BiomeBoost = {
	id: string,
	multiplier: number,
	auraIds: { [string]: boolean },
	rungs: { BiomeRung },
}

type BiomeState = {
	id: string,
	displayName: string,
	blurb: string,
	accent: { r: number, g: number, b: number },
	index: number,
	cycleSeconds: number,
	multiplier: number,
	elapsedInCycle: number,
	secondsRemaining: number,
	progress: number,
}

--[[
	THE BIOME EVENTS' BOOSTS, resolved once against the real ladder.

	BiomeMath.Boosts raises on any problem with BiomeConfig (an id that is not on
	the ladder, a rung claimed by two events, an event with nothing themed), so a
	bad event config fails at load rather than at 3am in the middle of a roll. The
	rungs it resolves are what the payload lists and the HUD renders, which is why an
event can only ever advertise auras the game actually has.
]]
local BIOME_BOOSTS: { [string]: BiomeBoost } = BiomeMath.Boosts(AuraRegistry)

--[[
	THE CYCLE'S EPOCH, and the reason it is a single number here.

	Every player in this server must see the same event at the same moment, and a
	player joining mid-event must join INTO it rather than restart it - so the
	schedule is derived from the server's own clock since the server started, not
	from anything per-player and not from anything a client sends. os.clock() is
	the same monotonic clock the streak and the cooldowns already use.
]]
local BIOME_EPOCH_CLOCK: number = os.clock()

-- =============================================================================
-- Remotes (created procedurally - the place file starts empty)
-- =============================================================================

-- Creation goes through the shared helper: PerkService and ShopService publish
-- into the same folder, and a second copy of this plumbing is a second chance to
-- spell a remote differently and leave a client waiting forever.

-- Roll request / acknowledgement (client -> server -> client).
local RequestRoll = ServerRemotes.EnsureRemote("RemoteFunction", "RequestRoll") :: RemoteFunction
-- Roll result + global rarity announcement channel (server -> client).
local RollBroadcast = ServerRemotes.EnsureRemote("RemoteEvent", "RollBroadcast") :: RemoteEvent
-- Auto-roll / fast-roll toggles (client -> server).
local ToggleAutoRoll = ServerRemotes.EnsureRemote("RemoteEvent", "ToggleAutoRoll") :: RemoteEvent
-- Equip an owned aura (client -> server).
local EquipAura = ServerRemotes.EnsureRemote("RemoteEvent", "EquipAura") :: RemoteEvent
-- Delete exactly one owned copy of an aura (client -> server).
local DeleteAura = ServerRemotes.EnsureRemote("RemoteEvent", "DeleteAura") :: RemoteEvent
-- Set the auto-filter: (mode, threshold rarity) (client -> server).
local SetFilter = ServerRemotes.EnsureRemote("RemoteEvent", "SetFilter") :: RemoteEvent
-- Full player-state snapshot (server -> client).
local StateSync = ServerRemotes.EnsureRemote("RemoteEvent", "StateSync") :: RemoteEvent

-- =============================================================================
-- Types
-- =============================================================================

type SavedData = {
	version: number,
	totalRolls: number,
	pityCounter: number,
	inventory: { [string]: number },
	equippedAura: string?,
	rarestAura: string?,
	-- The auto-filter, saved with everything else through the same backend. An
	-- older save simply has neither field and loads as "no filter".
	filterMode: string?,
	filterRarity: number?,
}

-- What the filter has thrown away this session, for the panel and telemetry.
type FilteredRecord = {
	auraId: string,
	displayName: string,
	tier: string,
	rarity: number,
	action: string,
	hardPity: boolean,
}

type PlayerState = {
	userId: number,
	username: string,
	loaded: boolean,
	totalRolls: number,
	pityCounter: number,
	luckMultiplier: number,
	inventory: { [string]: number },
	equippedAura: string?,
	rarestAura: string?,
	lastRollClock: number,
	lastInvokeClock: number,

	-- The auto-filter. Server-owned like every other knob: the client asks for a
	-- mode and a threshold, this script validates both against the ladder and is
	-- what the roll path actually consults.
	filterMode: string,
	filterRarity: number,
	filteredPulls: number,
	filteredByRarity: { [number]: number },
	lastFiltered: FilteredRecord?,
	filterSaveToken: number,

	-- The Luck Shrine, per player and server-side only. `shrineInside` is written
	-- by a position read of this player's own character - never by anything a
	-- client sends - and `shrineEnteredClock` is when the current stay began (nil
	-- while outside), which is what the payload reports as `secondsInside`.
	shrineInside: boolean,
	shrineSampleClock: number,
	shrineEnteredClock: number?,

	-- The board. `leaderboardScore` is the encoded score last SUBMITTED for this
	-- player this session (0 before the first submission), so the cadence loop can
	-- skip a write that would not move the board. Not persisted: the board's own
	-- store is, and it is written from the same numbers that are saved here.
	leaderboardScore: number,

	--[[
		WHETHER THIS STATE CAME FROM THE STORE YET.

		A joiner is put into `playerStates` immediately, with a freshly built state,
		because a player exists and has to be rollable before a DataStore read
		returns. That placeholder is empty: `totalRolls = 0`, `rarestAura = nil`. If
		the player LEAVES during that window - which a slow DataStore makes
		minutes-plausible - then saving it writes an empty save over their real one,
		and force-submitting it writes score 0 over their real board row.

		So the leave and shutdown paths act on SETTLED state only. The load task
		already preserves the save itself when it finishes after a leave; the
		placeholder is never treated as a record of what the player has done.
	]]
	loadSettled: boolean,

	-- When this player joined, on the server's clock. The session streak is
	-- derived from it, never from anything the client reports.
	sessionStartClock: number,
	autoEnabled: boolean,
	fastEnabled: boolean,
	autoGeneration: number,

	-- Session telemetry (not persisted): lets us compare the observed rare-or-better
	-- rate against the per-roll analytic expectation while playtesting.
	rarityTally: { [number]: number },
	rarePlusPulls: number,
	hardPityHits: number,
	expectedRarePlus: number,
	-- Rolls per biome id, and how many of them landed ON a themed rung. The point
	-- is being able to see that an event is really doing something in a session.
	biomeRolls: { [string]: number },
	biomeBoostedPulls: number,
}

type RollPayload = {
	sequence: number,
	userId: number,
	username: string,
	auraId: string,
	displayName: string,
	tier: string,
	rarity: number,
	chance: number,
	oneInN: number,
	luckUsed: number,
	softPityStacks: number,
	hardPityTriggered: boolean,
	autoEquipped: boolean,
	ownedCount: number,
	source: string,
	global: boolean,
	-- The biome event this pull was resolved under, and whether the pull itself was
	-- one of its rungs. `biomeBoosted` is the badge-worthy one: an event being on
	-- is not the same as the event having paid out.
	biomeId: string?,
	biomeDisplayName: string?,
	biomeMultiplier: number,
	biomeBoosted: boolean,
	-- The auto-filter's verdict on this pull. `filtered` pulls were NOT stored:
	-- the client is told so it can say what was dropped instead of the result
	-- silently disappearing. `filterAction` is "keep" | "skip" | "delete".
	filtered: boolean,
	filterAction: string,
	filterMode: string,
	filterRarity: number,
	-- How many this session has thrown away INCLUDING this one. An auto-rolling
	-- client uses it to summarise every Nth skip instead of toasting each of them.
	filteredTotal: number,
}

--[[
	THE SHRINE, as the payload carries it.

	`region` is the geometry contract, verbatim from ShrineConfig: whoever owns
	Models builds to those numbers and needs nothing else from this file. `inside`
	and `playersInside` are server-decided - this player's own character was read
	on the server, and no client value contributed.
]]
type ShrinePayload = {
	displayName: string,
	blurb: string,
	bonusPercent: number,
	accent: { r: number, g: number, b: number },
	region: {
		name: string,
		shape: string,
		origin: { x: number, y: number, z: number },
		size: { x: number, y: number, z: number },
		boundaryInclusive: boolean,
	},
	inside: boolean,
	playersInside: number,
	-- How much MORE OFTEN a player in the zone rolls (1.15 = +15%). The roll path
	-- divides the cooldown by this.
	speedMultiplier: number,
	secondsInside: number,
}

type LeaderboardRow = {
	rank: number,
	userId: number,
	name: string,
	rolls: number,
	rarestRarity: number,
	rarestAura: string?,
	rarestDisplayName: string?,
	tier: string?,
}

--[[
	THE BOARD.

	`ready` is the load-bearing field: it is FALSE until a board has actually been
	read, and the panel renders "connecting..." (no numbers at all) until it turns
	true. An unread board and an empty one are otherwise indistinguishable on
	screen, and "0 rolls" about the whole server is a lie - the same class of
	first-frame lie the collection stat and the drawer's grid had.
]]
type LeaderboardPayload = {
	ready: boolean,
	backend: string,
	size: number,
	sessionOnly: boolean,
	entries: { LeaderboardRow },
}

type BiomePayload = {
	id: string,
	displayName: string,
	blurb: string,
	accent: { r: number, g: number, b: number },
	multiplier: number,
	cycleSeconds: number,
	secondsRemaining: number,
	progress: number,
	-- The themed rungs, label and odds included, resolved from the ladder. Shared
	-- table, built once at load - a state sync every 2s must not rebuild it.
	boosted: { BiomeRung },
}

type FilterPayload = {
	mode: string,
	rarity: number,
	-- The selectable rungs, shared and built once at load (see FILTER_RUNGS).
	options: { FilterRung },
	filteredPulls: number,
	lastFiltered: FilteredRecord?,
}

-- Structural mirror of StreakMath's exported snapshot. Local because a module
-- required through `WaitForChild(...) :: ModuleScript` is typed `any` (the same
-- convention PerkService uses for its mirror), and the Lune harness executes
-- StreakMath so this shape cannot drift away from it unnoticed.
type StreakSnapshot = {
	seconds: number,
	level: number,
	maxLevel: number,
	levelSeconds: number,
	levelProgress: number,
	secondsToNextLevel: number,
	luckMultiplier: number,
	capped: boolean,
}

type StatePayload = {
	totalRolls: number,
	pityCounter: number,
	hardPityRolls: number,
	softPityStacks: number,
	softPityActive: boolean,
	rollsUntilGuaranteed: number,
	luckMultiplier: number,
	equippedAura: string?,
	rarestAura: string?,
	inventory: { [string]: number },
	autoEnabled: boolean,
	fastEnabled: boolean,
	cooldown: number,
	saveBackend: string,
	-- Session streak, nested so its shape has exactly one definition (StreakMath's).
	streak: StreakSnapshot,
	-- The auto-filter's current setting plus its options and its session tally.
	filter: FilterPayload,
	-- The biome event running right now, plus its countdown. This is the ONLY
	-- channel the world/atmosphere layer is given: whoever owns Lighting reads it
	-- from here and never learns how the schedule works (see ARCHITECTURE.md).
	biome: BiomePayload,
	-- The Luck Shrine: its region (the geometry contract), whether THIS player is
	-- inside it, and how many players are. The world layer builds to `region`.
	shrine: ShrinePayload,
	-- The Top Rollers board, with `ready` distinguishing "not read yet" from
	-- "read and empty".
	leaderboard: LeaderboardPayload,
}

-- =============================================================================
-- Persistence
-- =============================================================================

-- One backend for this store, resolved through SaveBackend: a DataStore when it
-- works, in-memory when it does not (Studio API access off, offline). Keys are
-- still `player_<userId>`, so progress saved before this change loads as before.
local saveBackend = SaveBackend.Get(DATASTORE_NAME)

-- The board's own backend, selected by the same policy from the same module: an
-- OrderedDataStore when it works, an in-memory one when it does not. Both expose
-- `submit(key, score)` and `top(count)`, so the code below has no branch on which
-- one it got - which is what makes the no-DataStore path worth testing.
local leaderboardBackend = SaveBackend.GetOrdered(LEADERBOARD_STORE_NAME)

-- The last board read back from the store, and whether a read has happened yet.
-- `ready` is what keeps the panel from printing zeros before the first read.
local leaderboardSnapshot: { any } = {}
local leaderboardReady: boolean = false

local function newSaveTable(): SavedData
	return {
		version = SAVE_VERSION,
		totalRolls = 0,
		pityCounter = 0,
		inventory = {},
		equippedAura = nil,
		rarestAura = nil,
		filterMode = AuraFilter.OFF,
		filterRarity = AuraFilter.NO_THRESHOLD,
	}
end

-- =============================================================================
-- In-memory player state
-- =============================================================================

local playerStates: { [Player]: PlayerState } = {}
local sequenceCounter: number = 0

local function sanitizeInventory(raw: any): { [string]: number }
	local clean: { [string]: number } = {}
	if type(raw) ~= "table" then
		return clean
	end
	for key, value in pairs(raw :: { [any]: any }) do
		if type(key) == "string" and type(value) == "number" and value > 0 then
			if AuraRegistry.Get(key) ~= nil then
				local count = math.floor(value)
				if count > MAX_INVENTORY_COUNT then
					count = MAX_INVENTORY_COUNT
				end
				clean[key] = count
			end
		end
	end
	return clean
end

local function sanitizeRarityCount(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.max(0, math.floor(value))
end

local function sanitizeAuraId(value: any): string?
	if type(value) == "string" and AuraRegistry.Get(value) ~= nil then
		return value
	end
	return nil
end

local function buildState(player: Player, saved: SavedData?): PlayerState
	local data = saved or newSaveTable()
	local inventory = sanitizeInventory(data.inventory)

	local equipped = sanitizeAuraId(data.equippedAura)
	if equipped ~= nil and (inventory[equipped] or 0) <= 0 then
		equipped = nil
	end

	-- A saved filter is validated against the LADDER on the way in, exactly like a
	-- request from a client: a save written before the ladder changed cannot
	-- restore a threshold that no longer exists, and a damaged one loads as "off".
	local filterMode = AuraFilter.SanitizeMode(data.filterMode, AuraFilter.OFF)
	local filterRarity = AuraFilter.SanitizeThreshold(data.filterRarity, FILTER_RUNGS)

	return {
		userId = player.UserId,
		username = player.Name,
		loaded = saved ~= nil,
		totalRolls = sanitizeRarityCount(data.totalRolls),
		pityCounter = math.min(sanitizeRarityCount(data.pityCounter), RollMath.HardPityRolls()),
		luckMultiplier = BASE_LUCK,
		inventory = inventory,
		equippedAura = equipped,
		rarestAura = sanitizeAuraId(data.rarestAura),
		lastRollClock = 0,
		lastInvokeClock = 0,
		filterMode = filterMode or AuraFilter.OFF,
		filterRarity = filterRarity,
		filteredPulls = 0,
		filteredByRarity = {},
		lastFiltered = nil,
		filterSaveToken = 0,
		shrineInside = false,
		shrineSampleClock = 0,
		shrineEnteredClock = nil,
		leaderboardScore = 0,
		-- False for the placeholder; the load task marks the state it builds from the
		-- store as settled (see setupPlayer).
		loadSettled = false,
		sessionStartClock = os.clock(),
		autoEnabled = false,
		fastEnabled = false,
		autoGeneration = 0,
		rarityTally = {},
		rarePlusPulls = 0,
		hardPityHits = 0,
		expectedRarePlus = 0,
		biomeRolls = {},
		biomeBoostedPulls = 0,
	}
end

local function toSavedData(state: PlayerState): SavedData
	return {
		version = SAVE_VERSION,
		totalRolls = state.totalRolls,
		pityCounter = state.pityCounter,
		inventory = state.inventory,
		equippedAura = state.equippedAura,
		rarestAura = state.rarestAura,
		-- The filter rides the same save as the inventory, so it survives a rejoin
		-- through the DataStore when one is available and through the in-memory
		-- fallback when it is not - the same backend the rest of the state uses.
		filterMode = state.filterMode,
		filterRarity = state.filterRarity,
	}
end

-- Writes this player's snapshot through the one backend. Declared here, above
-- the remote handlers, because a handler that persists a change (the filter)
-- would otherwise be closing over a local declared further down the file.
local function saveState(state: PlayerState): boolean
	return saveBackend.save(SaveBackend.PlayerKey(state.userId), toSavedData(state))
end

-- =============================================================================
-- Helpers
-- =============================================================================

--[[
	shrineSampleFor(player)

	Reads THIS player's own character, on the server, and tests it against the
	shipped region. That read is the only input path there is: no remote carries a
	position and no client flag is consulted anywhere, so "I am inside the shrine"
	is not a sentence a client can say. A player with no character - not spawned
	yet, mid-respawn, dead - samples as OUTSIDE, because a bonus must fail closed.
]]
local function shrineSampleFor(player: Player): any
	local character = player.Character
	local part: any = nil
	if character ~= nil then
		part = character:FindFirstChild("HumanoidRootPart")
		if part == nil then
			-- A character without a HumanoidRootPart still has a position worth
			-- reading if it has a primary part (a stub or test rig).
			part = character.PrimaryPart
		end
	end

	local position = if part ~= nil then part.Position else nil
	return ShrineMath.SampleHere(position, os.clock())
end

--[[
	refreshShrine(player, state)

	One sample of this player's character, cached on the state: the zone flag, the
	clock it was read at, and - for a player who stays in - when they entered.
	Called from the sampler loop (so the HUD readout and the attributes are live even
	for a player who is not rolling), from the payload build, and again from
	`cooldownFor` (so the number a roll actually uses comes from a read taken at that
	moment).
]]
local function refreshShrine(player: Player, state: PlayerState): ()
	local sample = shrineSampleFor(player)
	local wasInside = state.shrineInside
	local at = if type(sample.at) == "number" then sample.at else os.clock()

	state.shrineInside = sample.inside == true
	state.shrineSampleClock = at
	if state.shrineInside then
		if not wasInside or state.shrineEnteredClock == nil then
			state.shrineEnteredClock = at
		end
	else
		state.shrineEnteredClock = nil
	end
end

-- How many players are standing in the shrine right now. Derived from the same
-- per-player flags the bonus uses, so a crowd cannot be counted from one rule and
-- paid from another.
local function playersInsideShrine(): number
	local total = 0
	for _, state in pairs(playerStates) do
		if state.shrineInside then
			total += 1
		end
	end
	return total
end

--[[
	cooldownInputs(player, state, inside)

	THE list of factors a cooldown is composed from - the base, the pass entitlement
	and the zone - gathered in one place so the roll path and the telemetry readout
	cannot describe different mechanics. `inside` is passed rather than read from the
	state so the telemetry can show both sides of the zone without moving the player.

	`state.fastEnabled` is only a PREFERENCE: the discount itself comes from
	PerkService, which answers 1 for a player who owns neither the Fast Roll pass nor
	Test Mode, so a client that toggles it on cannot shorten its own cooldown - it
	can only ask for an entitlement the server verifies.
]]
local function cooldownInputs(player: Player, state: PlayerState, inside: boolean): any
	return {
		base = BASE_COOLDOWN,
		passMultiplier = if state.fastEnabled then PerkService.GetCooldownMultiplier(player) else 1,
		inShrine = inside,
		minimum = MIN_COOLDOWN_SECONDS,
	}
end

--[[
	cooldownFor(player, state)

	THE single cooldown point. The product itself - including the floor that keeps a
	free roll unreachable - is `ShrineMath.ComposeCooldown`, so the arithmetic is
	pure, executed by the harness and written down in exactly one place.

	The zone factor is re-read HERE, on purpose: this is the reading a ROLL uses, so
	a player who teleports into the zone is paid on the very next roll rather than up
	to one sample later.
]]
local function cooldownFor(player: Player, state: PlayerState): number
	refreshShrine(player, state)
	return ShrineMath.ComposeCooldown(cooldownInputs(player, state, state.shrineInside))
end

-- The session streak, derived from the server's own clock. Nothing here is
-- taken from a client, and the snapshot is total (a NaN or absurd duration
-- degrades to "no streak" or "capped" rather than throwing mid-roll).
local function streakFor(state: PlayerState): StreakSnapshot
	return StreakMath.Snapshot(os.clock() - state.sessionStartClock, STREAK_LEVEL_SECONDS)
end

--[[
	biomeNow()

	Which event this server is in right now, on the server's own schedule. Read
	from BIOME_EPOCH_CLOCK, which is set once at load, so two players asking at the
	same instant get the same answer and a player who joins mid-event joins into it.
	Nothing here reads a client's value, because a client is never sent one to send
	back.
]]
local function biomeNow(): BiomeState
	return BiomeMath.At(os.clock() - BIOME_EPOCH_CLOCK)
end

-- The resolved boost for an event, or nil for an unknown/empty id. The roll path
-- treats nil as "no event", so a config gap degrades to a plain roll.
local function biomeBoostFor(biomeId: string): BiomeBoost?
	return BiomeMath.BoostFor(BIOME_BOOSTS, biomeId)
end

--[[
	getLuckMultiplier(player, state, streak?)

	THE single luck point. Two server-owned sources are folded here and nowhere
	else: owned perks (PerkService) and time in this server (StreakMath). This
	script never learns what else contributed, so it can be read (state syncs,
	telemetry) as often as the UI likes without spending a potion charge:
	spending happens in exactly one place, on a roll that actually happened.

	`streak` is an optional already-read snapshot, passed only by the payload
	builder so the luck it displays and the streak readout beside it cannot be a
	level apart.
]]
local function getLuckMultiplier(player: Player, state: PlayerState, streak: StreakSnapshot?): number
	local activeStreak = streak
	if activeStreak == nil then
		activeStreak = streakFor(state)
	end

	local luck = state.luckMultiplier
		* PerkService.GetLuckMultiplier(player)
		* (activeStreak :: StreakSnapshot).luckMultiplier

	if luck < 0.01 then
		luck = 0.01
	end
	return luck
end

local function rarityOfAuraId(auraId: string?): number
	if auraId == nil then
		return 0
	end
	local config = AuraRegistry.Get(auraId)
	if config == nil then
		return 0
	end
	return config.rarity
end

-- =============================================================================
-- The Top Rollers board
-- =============================================================================

--[[
	The board has two halves and they are merged, never confused:

	  * `leaderboardSnapshot` is what the STORE last gave back - other servers'
	    players, and this one's after a submission has been read back.
	  * the LIVE half is derived from the running states right now, so the numbers
	    move while you play rather than appearing up to a refresh later.

	Both go through LeaderboardMath, so the ordering, the tie-break, the bound and
	the "which of two rows for one player wins" rules are the pure ones the harness
	executes.
]]
local function leaderboardEntryFor(player: Player, state: PlayerState): any
	return LeaderboardMath.Entry(
		state.userId,
		player.Name,
		state.totalRolls,
		rarityOfAuraId(state.rarestAura),
		LADDER_MAX_RARITY
	)
end

local function liveLeaderboardEntries(): { any }
	local entries: { any } = {}
	for player, state in pairs(playerStates) do
		table.insert(entries, leaderboardEntryFor(player, state))
	end
	return entries
end

local function boardEntries(): { any }
	return LeaderboardMath.Merge(leaderboardSnapshot, liveLeaderboardEntries(), LEADERBOARD_MAX_ENTRIES)
end

--[[
	refreshLeaderboard()

	Reads the persisted board back. `leaderboardReady` is set HERE and nowhere
	else, which is what lets the HUD tell "not read yet" from "read and empty":
	one says "connecting" and the other shows the rows it was sent.
]]
local function refreshLeaderboard(): ()
	local rows = leaderboardBackend.top(LEADERBOARD_MAX_ENTRIES)
	if rows == nil then
		--[[
			THE READ FAILED - which is not the same as an empty board. Wiping the
			snapshot here would show every player an empty leaderboard during a store
			outage and call it read; keeping the last good board is both truer and more
			useful. Readiness is deliberately NOT set, so a session whose very first
			read fails keeps saying "connecting..." instead of showing a board that is
			only its own players as though it were the whole one.
		]]
		return
	end

	local entries: { any } = {}
	for _, row in ipairs(rows) do
		local entry = LeaderboardMath.FromRow(row, LADDER_MAX_RARITY)
		if entry ~= nil then
			table.insert(entries, entry)
		end
	end
	leaderboardSnapshot = entries
	leaderboardReady = true
end

--[[
	submitLeaderboard(player, state, force?)

	Writes this player's score when it has MOVED (or when `force` is set, on a
	leave). One write per player per cadence, never per roll: an ordered store is
	write-rate-limited, and a per-second write per player is how a game gets put
	on a cooldown it cannot see.

	A refused write does not update the session's submitted score, so the next
	pass retries it instead of forgetting it - the store's answer is the only thing
	that says a score landed. In-memory boards always accept, which is exactly the
	path the harness executes.
]]
local function submitLeaderboard(player: Player, state: PlayerState, force: boolean?): boolean
	local entry = leaderboardEntryFor(player, state)
	if force ~= true and entry.score <= state.leaderboardScore then
		return false
	end

	local accepted = leaderboardBackend.submit(LeaderboardMath.Key(state.userId, player.Name), entry.score)
	if accepted then
		state.leaderboardScore = entry.score
	end
	return accepted
end

local function buildStatePayload(player: Player, state: PlayerState): StatePayload
	local hardPityRolls = RollMath.HardPityRolls()
	local pity = math.min(state.pityCounter, hardPityRolls)
	-- Read once and reused by the luck line below: the streak travels in the same
	-- payload as the luck it contributes to.
	local streak = streakFor(state)
	-- Same idea for the biome: the countdown and the boosted rungs describe ONE
	-- moment, so they are read together and cannot disagree with each other.
	local biome = biomeNow()
	local biomeBoost = biomeBoostFor(biome.id)

	-- The shrine is sampled HERE, once, so the region, this player's state and the
	-- cooldown line below all describe one reading of one character. `cooldownFor`
	-- re-reads it too - deliberately, because a roll must use a reading taken at
	-- the moment it resolves - and taking two identical readings is harmless.
	refreshShrine(player, state)
	local secondsInside = 0
	if state.shrineInside and state.shrineEnteredClock ~= nil then
		secondsInside = math.max(0, state.shrineSampleClock - (state.shrineEnteredClock :: number))
	end

	local board = boardEntries()

	return {
		totalRolls = state.totalRolls,
		pityCounter = pity,
		hardPityRolls = hardPityRolls,
		softPityStacks = RollMath.SoftPityStacks(pity),
		softPityActive = RollMath.IsSoftPityActive(pity),
		rollsUntilGuaranteed = RollMath.RollsUntilGuaranteed(pity),
		luckMultiplier = getLuckMultiplier(player, state, streak),
		equippedAura = state.equippedAura,
		rarestAura = state.rarestAura,
		inventory = state.inventory,
		autoEnabled = state.autoEnabled,
		fastEnabled = state.fastEnabled,
		cooldown = cooldownFor(player, state),
		saveBackend = saveBackend.kind,
		streak = streak,
		-- The filter travels whole: the setting, the session tally, what was last
		-- dropped, and the rungs themselves. The panel therefore cannot offer a
		-- threshold that is not on the ladder, because it never invents options -
		-- it renders these.
		filter = {
			mode = state.filterMode,
			rarity = state.filterRarity,
			options = FILTER_RUNGS,
			filteredPulls = state.filteredPulls,
			lastFiltered = state.lastFiltered,
		},
		--[[
			THE BIOME, and the whole of what the world layer is given: the event, its
			countdown, its multiplier and the rungs it favours. Nothing here says how
			the schedule works and nothing invites the reader to derive one - an
			atmosphere owner drives Lighting from this table and stops there. If the
			biome has no resolved boost (a config gap), an empty rung list is sent
			rather than nil, so the reader never has to nil-check a nested field.
		]]
		biome = {
			id = biome.id,
			displayName = biome.displayName,
			blurb = biome.blurb,
			accent = biome.accent,
			multiplier = biome.multiplier,
			cycleSeconds = biome.cycleSeconds,
			secondsRemaining = biome.secondsRemaining,
			progress = biome.progress,
			boosted = if biomeBoost ~= nil then biomeBoost.rungs else {},
		},
		--[[
			THE SHRINE, and the whole of the geometry contract: `region` is
			ShrineConfig's own table, sent verbatim, so whoever builds the pedestal
			and the zone reads the numbers from here (and from ShrineConfig) rather
			than measuring anything. `inside` was decided on the server from this
			player's own character; `playersInside` comes from the same per-player
			flags the bonus reads, so a crowd cannot be counted from one rule and paid
			from another.
		]]
		shrine = {
			displayName = SHRINE_DISPLAY.displayName,
			blurb = SHRINE_DISPLAY.blurb,
			bonusPercent = SHRINE_BONUS_PERCENT,
			accent = SHRINE_DISPLAY.accent,
			region = SHRINE_REGION,
			inside = state.shrineInside,
			playersInside = playersInsideShrine(),
			-- The mechanic itself, as a rate: 1.15 inside the zone, 1 outside. A reader
			-- that wants the cooldown form divides by it.
			speedMultiplier = ShrineMath.SpeedMultiplier(),
			secondsInside = secondsInside,
		},
		--[[
			THE BOARD. `ready` is false until a read has actually happened, so the
			panel can say "connecting" instead of printing a server-wide zero: an
			unread board and an empty one are otherwise the same four characters.
		]]
		leaderboard = {
			ready = leaderboardReady,
			backend = leaderboardBackend.kind,
			sessionOnly = leaderboardBackend.kind ~= "OrderedDataStore",
			size = #board,
			entries = LeaderboardMath.Rows(board, AuraRegistry, LEADERBOARD_MAX_ENTRIES),
		},
	}
end

local function publishAttributes(player: Player, state: PlayerState): ()
	local streak = streakFor(state)

	player:SetAttribute("EquippedAura", state.equippedAura)
	player:SetAttribute("AutoRollEnabled", state.autoEnabled)
	player:SetAttribute("FastRollEnabled", state.fastEnabled)
	player:SetAttribute("TotalRolls", state.totalRolls)
	player:SetAttribute("PityCounter", state.pityCounter)
	player:SetAttribute("LuckMultiplier", getLuckMultiplier(player, state, streak))
	player:SetAttribute("RarestAura", state.rarestAura)
	-- Streak mirrors, for anything that reads attributes instead of the payload.
	player:SetAttribute("StreakLevel", streak.level)
	player:SetAttribute("StreakLuckMultiplier", streak.luckMultiplier)
	-- Filter mirrors, for anything that reads attributes instead of the payload.
	player:SetAttribute("FilterMode", state.filterMode)
	player:SetAttribute("FilterRarity", state.filterRarity)
	-- Shrine mirror. Server-decided like every other attribute here, and rewritten
	-- on a zone transition as well as on a roll, so a viewer sees the state change
	-- rather than the last time the player rolled.
	player:SetAttribute("InLuckShrine", state.shrineInside)
	-- The RATE, not a discount: 1.15 inside, 1 outside. A viewer that prefers the
	-- cooldown form can divide by it, the same number the payload carries.
	player:SetAttribute("ShrineRollSpeedMultiplier", if state.shrineInside then ShrineMath.SpeedMultiplier() else 1)
end

local function syncState(player: Player, state: PlayerState): ()
	StateSync:FireClient(player, buildStatePayload(player, state))
end

-- Publishes a roll result to its owner, and to everyone when it is rare enough
-- to be worth a global announcement. Clients de-duplicate on `sequence`.
local function publishRoll(payload: RollPayload): ()
	local roller = Players:GetPlayerByUserId(payload.userId)
	if roller ~= nil then
		RollBroadcast:FireClient(roller, payload)
	end
	if payload.global then
		RollBroadcast:FireAllClients(payload)
	end
end

-- =============================================================================
-- Balance telemetry (Studio only, never persisted)
-- =============================================================================

--[[
	Reports the observed rare-or-better rate against the summed per-roll analytic
	expectation. Over a few hundred rolls these should converge; a persistent gap
	means the pity windows or the luck model are not behaving as designed.
]]
local function logTelemetry(player: Player, state: PlayerState): ()
	if state.totalRolls == 0 then
		return
	end

	local observed = state.rarePlusPulls
	local expected = state.expectedRarePlus
	local deviation = if expected > 0 then (observed - expected) / expected * 100 else 0

	print(
		string.format(
			"[RNGService][telemetry] %s | rolls=%d rare+=%d (expected %.1f, %+.1f%%) hardPity=%d pity=%d/%d luck=%.2fx",
			player.Name,
			state.totalRolls,
			observed,
			expected,
			deviation,
			state.hardPityHits,
			state.pityCounter,
			RollMath.HardPityRolls(),
			getLuckMultiplier(player, state)
		)
	)

	--[[
		The filter's own line. `rare+` above counts what was ROLLED and this counts
		what was thrown away, so if a filter ever suppressed a pull that should have
		reset pity, the two numbers describe the same rolls and the discrepancy shows
		up here rather than as a silent balance change.
	]]
	if state.filterMode ~= AuraFilter.OFF or state.filteredPulls > 0 then
		print(
			string.format(
				"[RNGService][telemetry] %s | filter=%s below 1 in %d | rolled=%d filtered=%d kept=%d",
				player.Name,
				string.upper(state.filterMode),
				state.filterRarity,
				state.totalRolls,
				state.filteredPulls,
				state.totalRolls - state.filteredPulls
			)
		)
	end

	-- Biome coverage: rolls per event and how often the event actually paid out.
	-- A session that never rolls during an event should be visible as such.
	local biomeIds: { string } = {}
	for biomeId in pairs(state.biomeRolls) do
		table.insert(biomeIds, biomeId)
	end
	if #biomeIds > 0 then
		table.sort(biomeIds)
		local parts: { string } = {}
		for _, biomeId in ipairs(biomeIds) do
			table.insert(parts, string.format("%s x%d", biomeId, state.biomeRolls[biomeId]))
		end
		print(
			string.format(
				"[RNGService][telemetry] %s | biome: %s | themed pulls=%d",
				player.Name,
				table.concat(parts, ", "),
				state.biomeBoostedPulls
			)
		)
	end

	local filteredRarities: { number } = {}
	for rarity in pairs(state.filteredByRarity) do
		table.insert(filteredRarities, rarity)
	end
	table.sort(filteredRarities)

	local filteredSpread: { string } = {}
	for _, rarity in ipairs(filteredRarities) do
		table.insert(filteredSpread, string.format("1/%d x%d", rarity, state.filteredByRarity[rarity]))
	end
	if #filteredSpread > 0 then
		print(string.format("[RNGService][telemetry] %s | filtered spread: %s", player.Name, table.concat(filteredSpread, ", ")))
	end

	--[[
		The shrine, reported against the cooldown the server would use RIGHT NOW.
		This is the line a Studio session reads to see the +15% actually applied: the
		composed cooldown out of zone, in zone, and the eta the roll path will use.

		`cooldownFor` is called with the state as it stands - it re-reads the
		character, which is a position read, not a roll, so it cannot spend a potion
		or move pity. Telemetry is Studio-only and never persisted.
	]]
	-- The same inputs the roll path uses, with the zone flag flipped, so this line
	-- can never describe a cooldown the game does not run.
	local outsideCooldown = ShrineMath.ComposeCooldown(cooldownInputs(player, state, false))
	local insideCooldown = ShrineMath.ComposeCooldown(cooldownInputs(player, state, true))
	print(
		string.format(
			"[RNGService][telemetry] %s | shrine: %s | cooldown %.2fs outside, %.2fs inside (x%.3f, +%d%% roll speed = %.1f rolls/s vs %.1f) | %d in zone | board score %d",
			player.Name,
			if state.shrineInside then "INSIDE" else "outside",
			outsideCooldown,
			insideCooldown,
			ShrineMath.SpeedMultiplier(),
			SHRINE_BONUS_PERCENT,
			1 / math.max(insideCooldown, 1e-6),
			1 / math.max(outsideCooldown, 1e-6),
			playersInsideShrine(),
			leaderboardEntryFor(player, state).score
		)
	)

	local tally: { string } = {}
	for _, auraId in ipairs(AuraRegistry.ORDER) do
		local count = state.inventory[auraId] or 0
		if count > 0 then
			table.insert(tally, string.format("%s x%d", auraId, count))
		end
	end
	if #tally > 0 then
		print(string.format("[RNGService][telemetry] %s | owned: %s", player.Name, table.concat(tally, ", ")))
	end

	-- Rarity spread, in nominal odds, so a dry rare tail is visible immediately.
	local rarities: { number } = {}
	for rarity in pairs(state.rarityTally) do
		table.insert(rarities, rarity)
	end
	table.sort(rarities)

	local spread: { string } = {}
	for _, rarity in ipairs(rarities) do
		table.insert(spread, string.format("1/%d x%d", rarity, state.rarityTally[rarity]))
	end
	if #spread > 0 then
		print(string.format("[RNGService][telemetry] %s | rarity spread: %s", player.Name, table.concat(spread, ", ")))
	end
end

-- =============================================================================
-- Roll resolution (the single authoritative path)
-- =============================================================================

local function resolveRoll(player: Player, state: PlayerState, source: string): RollPayload?
	local now = os.clock()
	local cooldown = cooldownFor(player, state)
	local elapsed = now - state.lastRollClock
	if elapsed < cooldown then
		return nil
	end
	state.lastRollClock = now

	local luck = getLuckMultiplier(player, state)
	local rareFloor = RollMath.HardPityMinRarity()

	--[[
		THE BIOME SNAPSHOT, read exactly once per roll.

		A roll that lands on a cycle boundary must be resolved entirely under ONE of
		the two events, so this value is captured here and then used for the expected
		probability, the draw AND the payload - never re-read later in this function.
		The next roll (or the next state sync) reads the clock again and gets whatever
		the schedule says by then.
	]]
	local biome = biomeNow()
	local biomeBoost = biomeBoostFor(biome.id)

	-- Accumulate the analytic probability *before* the draw so the session's
	-- expected rare-or-better count is exact, not approximated after the fact. It
	-- takes the same biome the draw will use: an expectation that ignored a running
	-- event would drift for the whole five minutes of it.
	state.expectedRarePlus += RollMath.ChanceOfAtLeast(rareFloor, luck, state.pityCounter, biomeBoost)

	local outcome = RollMath.SelectAura(luck, state.pityCounter, nil, biomeBoost)

	-- Biome telemetry: which event this roll belonged to, and whether the event
	-- actually paid out on it.
	state.biomeRolls[biome.id] = (state.biomeRolls[biome.id] or 0) + 1
	if outcome.biomeBoosted then
		state.biomeBoostedPulls += 1
	end

	state.totalRolls += 1
	state.rarityTally[outcome.rarity] = (state.rarityTally[outcome.rarity] or 0) + 1
	if outcome.rarity >= rareFloor then
		state.rarePlusPulls += 1
	end
	if outcome.hardPityTriggered then
		state.hardPityHits += 1
	end

	-- Pity bookkeeping: reaching the guaranteed band resets the counter.
	if outcome.rarity >= RollMath.HardPityMinRarity() then
		state.pityCounter = 0
	else
		state.pityCounter = math.min(state.pityCounter + 1, RollMath.HardPityRolls() + 1)
	end

	-- The roll happened, so the armed potion pays for it - here, once, and only
	-- here. Every path that could refuse a roll returned before this point, and
	-- merely reading the multiplier never spends a charge.
	local spentPotion = PerkService.ConsumeRollEffects(player)
	if spentPotion > 1 and RunService:IsStudio() then
		print(string.format(
			"[RNGService] %s: a %.2fx luck charge paid for this roll; the next roll uses owned perks only.",
			player.Name,
			spentPotion
		))
	end

	--[[
		AUTO-FILTER, and where it sits in this function is the whole point.

		It is applied HERE - after the draw, after the rarity tally, after the hard
		and soft pity bookkeeping and after the potion charge is spent, and before
		anything is written to the inventory. Consequences, in order:
		  * a suppressed pull advanced pity exactly as a kept one does, so the filter
		    can never be used to farm the guarantee more cheaply;
		  * it is counted in `rarityTally` / `rarePlusPulls`, so telemetry still
		    describes what was actually rolled, not what was kept;
		  * it never enters the inventory, which is the point of the feature.

		The decision is AuraFilter's, from state the server owns: the client only
		ever asked for a mode and a threshold, and both were validated against the
		ladder before they reached this state.
	]]
	local filterAction = AuraFilter.Decide(state.filterMode, state.filterRarity, outcome.rarity)
	local filtered = AuraFilter.Suppresses(filterAction)

	if filtered then
		state.filteredPulls += 1
		state.filteredByRarity[outcome.rarity] = (state.filteredByRarity[outcome.rarity] or 0) + 1
		-- Kept so the panel and the toast can name what was dropped: an aura that
		-- vanishes with no trace is indistinguishable from a bug to a player.
		state.lastFiltered = {
			auraId = outcome.auraId,
			displayName = outcome.displayName,
			tier = outcome.tier,
			rarity = outcome.rarity,
			action = filterAction,
			hardPity = outcome.hardPityTriggered,
		}
	else
		state.inventory[outcome.auraId] = (state.inventory[outcome.auraId] or 0) + 1
	end

	local ownedCount = state.inventory[outcome.auraId] or 0
	local autoEquipped = false

	-- The rarest-ever record and the auto-equip follow what the player KEEPS: a
	-- pull that was thrown away cannot become their rarest find, and it must not
	-- leave them wearing something they do not own.
	if not filtered then
		if state.rarestAura == nil or outcome.rarity > rarityOfAuraId(state.rarestAura) then
			state.rarestAura = outcome.auraId
		end

		-- Quality-of-life auto equip: only ever upgrades, never downgrades a manual pick.
		if state.equippedAura == nil or outcome.rarity > rarityOfAuraId(state.equippedAura) then
			state.equippedAura = outcome.auraId
			autoEquipped = true
		end
	end

	sequenceCounter += 1

	local payload: RollPayload = {
		sequence = sequenceCounter,
		userId = player.UserId,
		username = player.Name,
		auraId = outcome.auraId,
		displayName = outcome.displayName,
		tier = outcome.tier,
		rarity = outcome.rarity,
		chance = outcome.chance,
		oneInN = outcome.oneInN,
		luckUsed = outcome.luckUsed,
		softPityStacks = outcome.softPityStacks,
		hardPityTriggered = outcome.hardPityTriggered,
		autoEquipped = autoEquipped,
		ownedCount = ownedCount,
		source = source,
		global = outcome.rarity >= BROADCAST_RARITY_THRESHOLD,
		-- The event travels WITH the pull, from the same snapshot the draw used, so
		-- the reveal can badge it without asking the server again (by which time the
		-- event might have switched).
		biomeId = outcome.biomeId,
		biomeDisplayName = if outcome.biomeId ~= nil then biome.displayName else nil,
		biomeMultiplier = outcome.biomeMultiplier,
		biomeBoosted = outcome.biomeBoosted,
		filtered = filtered,
		filterAction = filterAction,
		filterMode = state.filterMode,
		filterRarity = state.filterRarity,
		filteredTotal = state.filteredPulls,
	}

	publishAttributes(player, state)
	syncState(player, state)
	publishRoll(payload)

	if RunService:IsStudio() and state.totalRolls % ROLL_LOG_INTERVAL == 0 then
		logTelemetry(player, state)
	end

	return payload
end

-- =============================================================================
-- Auto-roll clock (server driven, so it stays authoritative and cheat proof)
-- =============================================================================

local function stopAutoRoll(state: PlayerState): ()
	state.autoEnabled = false
	state.autoGeneration += 1
end

local function startAutoRoll(player: Player, state: PlayerState): ()
	state.autoEnabled = true
	state.autoGeneration += 1
	local generation = state.autoGeneration

	task.spawn(function()
		while state.autoEnabled and state.autoGeneration == generation and player.Parent == Players do
			local cooldown = cooldownFor(player, state)
			local elapsed = os.clock() - state.lastRollClock
			if elapsed < cooldown then
				task.wait(cooldown - elapsed)
			end

			if not state.autoEnabled or state.autoGeneration ~= generation or player.Parent ~= Players then
				break
			end

			resolveRoll(player, state, "Auto")
			task.wait(0.05)
		end
	end)
end

-- =============================================================================
-- Remote handlers
-- =============================================================================

RequestRoll.OnServerInvoke = function(player: Player, requestKind: any): any
	local state = playerStates[player]
	if state == nil then
		return { ok = false, reason = "NotReady" }
	end

	if requestKind ~= nil and type(requestKind) ~= "string" then
		return { ok = false, reason = "BadRequest" }
	end

	local now = os.clock()
	if now - state.lastInvokeClock < INVOKE_RATE_LIMIT then
		return { ok = false, reason = "RateLimited" }
	end
	state.lastInvokeClock = now

	local cooldown = cooldownFor(player, state)
	local elapsed = now - state.lastRollClock
	if elapsed < cooldown then
		return {
			ok = false,
			reason = "Cooldown",
			remaining = cooldown - elapsed,
		}
	end

	local payload = resolveRoll(player, state, "Manual")
	if payload == nil then
		return { ok = false, reason = "Cooldown", remaining = cooldownFor(player, state) }
	end

	return { ok = true, sequence = payload.sequence }
end

ToggleAutoRoll.OnServerEvent:Connect(function(player: Player, setting: any, enabled: any)
	local state = playerStates[player]
	if state == nil then
		return
	end

	if type(setting) ~= "string" or type(enabled) ~= "boolean" then
		return
	end

	if setting == "Auto" then
		if enabled then
			-- The Auto-Roll pass (or Test Mode) unlocks the clock. Without it the
			-- request is dropped and the state sync below reports the toggle still
			-- off, so the client's button cannot lie about it.
			if not PerkService.HasAutoRoll(player) then
				if RunService:IsStudio() then
					print(string.format(
						"[RNGService] Refused auto-roll for %s: the Auto-Roll pass (or Test Mode) is required.",
						player.Name
					))
				end
				publishAttributes(player, state)
				syncState(player, state)
				return
			end
			startAutoRoll(player, state)
		else
			stopAutoRoll(state)
		end
	elseif setting == "Fast" then
		if enabled then
			-- Same rule for the cooldown cut: no pass, no discount. The perk owns
			-- the number, this script only honours the preference.
			if not PerkService.HasFastRoll(player) then
				if RunService:IsStudio() then
					print(string.format(
						"[RNGService] Refused fast-roll for %s: the Fast Roll pass (or Test Mode) is required.",
						player.Name
					))
				end
				state.fastEnabled = false
				publishAttributes(player, state)
				syncState(player, state)
				return
			end
		end
		state.fastEnabled = enabled
	else
		return
	end

	publishAttributes(player, state)
	syncState(player, state)
end)

EquipAura.OnServerEvent:Connect(function(player: Player, auraId: any)
	local state = playerStates[player]
	if state == nil then
		return
	end

	if type(auraId) ~= "string" then
		return
	end

	if AuraRegistry.Get(auraId) == nil then
		return
	end

	if (state.inventory[auraId] or 0) <= 0 then
		return
	end

	state.equippedAura = auraId
	publishAttributes(player, state)
	syncState(player, state)
end)

--[[
	DELETE ONE COPY (client -> server)

	The client may ask; this decides. Three refusals, all silent-to-the-caller and
	visible to the player as "nothing changed", because the panel re-renders from
	server truth on the sync that follows:
	  * a non-string id, or one that is not on the ladder;
	  * an id the player owns none of (the stale-grid case);
	  * a player with no state yet.

	Deletion removes EXACTLY ONE copy. Deleting the last copy of the equipped aura
	clears the equip, so nobody ends up wearing something they no longer own.
	`rarestAura` is a record of the rarest thing EVER FOUND, not of what is in the
	inventory, so it is deliberately left alone - the collection stat and the rarest
	record are two different facts.
]]
DeleteAura.OnServerEvent:Connect(function(player: Player, auraId: any)
	local state = playerStates[player]
	if state == nil then
		return
	end

	if type(auraId) ~= "string" or AuraRegistry.Get(auraId) == nil then
		return
	end

	-- The rule itself is InventoryMath's, so its edges are executed by the
	-- harness: a count that is not owned refuses, and an owned count loses
	-- exactly one.
	local removed, remaining = InventoryMath.RemoveOne(state.inventory[auraId] or 0)
	if not removed then
		-- Nothing owned: refuse. Re-syncing anyway is what makes a stale grid
		-- correct itself rather than keep offering a delete that cannot happen.
		publishAttributes(player, state)
		syncState(player, state)
		return
	end

	if InventoryMath.KeySurvives(remaining) then
		state.inventory[auraId] = remaining
	else
		state.inventory[auraId] = nil
		-- The last copy is gone, so an equipped aura must stop being equipped:
		-- nobody should be wearing something they no longer own.
		if state.equippedAura == auraId then
			state.equippedAura = nil
		end
	end

	publishAttributes(player, state)
	syncState(player, state)
end)

--[[
	SET THE AUTO-FILTER (client -> server)

	The mission's control is "Auto-Skip / Auto-Delete below [Rarity]", so this
	takes a mode and a threshold. Both are validated here, against the server's own
	ladder:
	  * the mode must be one of off/skip/delete (junk is ignored, not defaulted);
	  * the threshold must be 0, or a rarity that is a rung of the ladder - a
	    client cannot invent 499 to sit between two rungs, and cannot widen or
	    narrow the filter past what the game actually contains.

	A change is persisted through the same save path as the inventory (debounced,
	see FILTER_SAVE_DEBOUNCE); a repeat of the current setting changes nothing and
	schedules no write.
]]
SetFilter.OnServerEvent:Connect(function(player: Player, mode: any, rarity: any)
	local state = playerStates[player]
	if state == nil then
		return
	end

	if type(mode) ~= "string" or type(rarity) ~= "number" then
		return
	end

	-- nil fallback: an unknown mode is refused outright rather than coerced.
	local cleanMode = AuraFilter.SanitizeMode(mode, nil)
	if cleanMode == nil then
		return
	end

	if rarity ~= 0 and not AuraFilter.IsRung(math.floor(rarity), FILTER_RUNGS) then
		return
	end

	local cleanRarity = AuraFilter.SanitizeThreshold(rarity, FILTER_RUNGS)
	if cleanMode == state.filterMode and cleanRarity == state.filterRarity then
		return
	end

	state.filterMode = cleanMode
	state.filterRarity = cleanRarity

	state.filterSaveToken += 1
	local token = state.filterSaveToken
	task.delay(FILTER_SAVE_DEBOUNCE, function()
		if state.filterSaveToken == token and player.Parent == Players then
			saveState(state)
		end
	end)

	publishAttributes(player, state)
	syncState(player, state)
end)

-- =============================================================================
-- Player lifecycle
-- =============================================================================

local function setupPlayer(player: Player): ()
	local state = buildState(player, nil)
	playerStates[player] = state
	publishAttributes(player, state)

	task.spawn(function()
		local saved = saveBackend.load(SaveBackend.PlayerKey(player.UserId))
		if player.Parent ~= Players then
			-- Player already left: still write the loaded snapshot so nothing is lost.
			if saved ~= nil then
				saveBackend.save(SaveBackend.PlayerKey(player.UserId), saved)
			end
			return
		end

		-- Auto-roll intentionally does NOT survive a rejoin: the client always
		-- starts idle so an AFK player is never surprised by a running clock.
		local loaded = buildState(player, saved)
		-- The SESSION started when they joined, not when the save finished loading
		-- (a DataStore read can take seconds, and the streak is time in the server).
		loaded.sessionStartClock = state.sessionStartClock
		-- Settled: this state came from the store, so it may be saved and submitted
		-- from now on. The placeholder it replaces never was.
		loaded.loadSettled = true
		playerStates[player] = loaded

		publishAttributes(player, loaded)
		syncState(player, loaded)
	end)
end

local function teardownPlayer(player: Player): ()
	local state = playerStates[player]
	if state == nil then
		return
	end
	stopAutoRoll(state)
	--[[
		A LEAVE IS ONE OF THE TWO MOMENTS THE BOARD IS WRITTEN OUT OF BAND (the
		other is shutdown): the player's last session is the one the board should
		remember, and the cadence loop may not run again before they are gone.

		BOTH writes are gated on `loadSettled`, because during the load window this
		state is the empty placeholder and writing it would destroy real progress -
		an empty save, and score 0 over a real board row. The load task preserves the
		save itself if it finishes after the player is gone, so nothing is lost by
		staying quiet here.
	]]
	if state.loadSettled then
		saveState(state)
		submitLeaderboard(player, state, true)
	end
	if RunService:IsStudio() then
		logTelemetry(player, state)
	end
	playerStates[player] = nil
end

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(teardownPlayer)

for _, existingPlayer in ipairs(Players:GetPlayers()) do
	setupPlayer(existingPlayer)
end

--[[
	Session-streak clock.

	The streak is nothing but time in this server, so this loop takes NO client
	input at all: it re-publishes what the server's own clock now says. The server
	pushes rather than the client counting, because a client-side counter would be
	the client asserting its own luck.

	Every two seconds is enough for the HUD counter to visibly step, and it is
	cheap next to what an auto-rolling player already generates (a full state sync
	on every roll, i.e. every 0.6-1.2s). Attributes go out with it so anything
	reading `StreakLevel` sees a live value.
]]
task.spawn(function()
	while true do
		task.wait(STREAK_SYNC_INTERVAL)
		for player, state in pairs(playerStates) do
			if player.Parent == Players then
				publishAttributes(player, state)
				syncState(player, state)
			end
		end
	end
end)

-- Periodic autosave keeps progress safe across crashes; lifecycle saves cover
-- clean leaves.
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for player, state in pairs(playerStates) do
			if player.Parent == Players then
				saveState(state)
			end
		end
	end
end)

--[[
	The Top Rollers board's two clocks, and why they are two.

	READS and WRITES have different budgets: an ordered store is write-rate
	limited, so a score is submitted on a cadence (and never per roll), and the
	persisted board is read back on a slower one. Both call the same pure rules.

	The first read happens immediately rather than after a full interval, so a
	session shows a real board - other servers' players included - instead of
	"connecting..." for the first half-minute. The publish is left to the streak
	loop above (every two seconds), which already carries a full payload to every
	player: a second publisher here would double the traffic for nothing.
]]
task.spawn(function()
	refreshLeaderboard()
	while true do
		task.wait(LEADERBOARD_REFRESH_INTERVAL)
		refreshLeaderboard()
	end
end)

task.spawn(function()
	while true do
		task.wait(LEADERBOARD_WRITE_INTERVAL)
		for player, state in pairs(playerStates) do
			if player.Parent == Players then
				submitLeaderboard(player, state)
			end
		end
	end
end)

--[[
	The shrine sampler.

	One reading of every player's OWN character at the shrine's cadence, so the HUD
	readout and the attributes stay live even for a player who is not rolling. A
	TRANSITION is published immediately - stepping into the zone should show up at
	once, not on the next roll - and otherwise the reading rides the two-second
	streak sync that already goes out. Sampling a boolean ten times as often as a
	full payload (which carries the inventory) is the whole point of the split.

	The roll path does not depend on this loop: `cooldownFor` re-reads the
	character when a roll resolves, so a player who teleports in is paid on the very
	next roll rather than up to one sample later.
]]
task.spawn(function()
	while true do
		task.wait(SHRINE_SAMPLE_INTERVAL)
		for player, state in pairs(playerStates) do
			if player.Parent == Players then
				local wasInside = state.shrineInside
				refreshShrine(player, state)
				if state.shrineInside ~= wasInside then
					publishAttributes(player, state)
					syncState(player, state)
				end
			end
		end
	end
end)

game:BindToClose(function()
	for player, state in pairs(playerStates) do
		-- Same rule as a leave: a player still inside their load window has a
		-- placeholder in `playerStates`, and shutdown must not write it.
		if player.Parent == Players and state.loadSettled then
			saveState(state)
			submitLeaderboard(player, state, true)
		end
	end
	-- A DataStore write can still be in flight when the server closes; the wait
	-- is for the last ordered write, which is the one most likely to be dropped.
	if saveBackend.kind ~= "DataStore" or leaderboardBackend.kind ~= "OrderedDataStore" then
		task.wait(0.2)
	end
end)

if RunService:IsStudio() then
	print(
		string.format(
			"[RNGService] Ready in Studio. Aura pool: %d (rarest 1 in %d). Persistence: %s. "
				.. "Cooldown: %.2fs base, scaled by owned perks (PerkService).",
			AuraRegistry.Count,
			AuraRegistry.HighestRarity(),
			saveBackend.kind,
			BASE_COOLDOWN
		)
	)
	local biomeIds: { string } = {}
	for _, biome in ipairs(BiomeMath.Biomes) do
		table.insert(biomeIds, biome.displayName)
	end
	print(
		string.format(
			"[RNGService] Biome events: %ds per event, x%d on the themed rungs, cycling %s. "
				.. "Boosted rungs are resolved from the ladder; the cycle runs off this server's clock.",
			BiomeMath.CycleSeconds(),
			BiomeMath.Multiplier(),
			table.concat(biomeIds, " -> ")
		)
	)
	for _, biomeId in ipairs(BiomeMath.Ids()) do
		local boost = BIOME_BOOSTS[biomeId]
		if boost ~= nil then
			local names: { string } = {}
			for _, rung in ipairs(boost.rungs) do
				table.insert(names, string.format("%s (1 in %d)", rung.displayName, rung.rarity))
			end
			print(string.format("[RNGService]   %s: %s", biomeId, table.concat(names, ", ")))
		end
	end

	print(
		string.format(
			"[RNGService] Luck Shrine: %s at (%.0f, %.0f, %.0f), %s, r=%.0f, h=%.0f -> +%d%% roll speed (cooldown x%.4f), floor %.2fs. "
				.. "No geometry is created here; the Visuals layer builds to these numbers.",
			SHRINE_REGION.name,
			SHRINE_REGION.origin.x,
			SHRINE_REGION.origin.y,
			SHRINE_REGION.origin.z,
			SHRINE_REGION.shape,
			math.max(SHRINE_REGION.size.x, SHRINE_REGION.size.z) / 2,
			SHRINE_REGION.size.y,
			SHRINE_BONUS_PERCENT,
			ShrineMath.CooldownMultiplier(),
			MIN_COOLDOWN_SECONDS
		)
	)
	print(
		string.format(
			"[RNGService] Top Rollers: %d entries max, position = rolls then rarest find, writes every %ds, reload every %ds. Backend: %s.",
			LEADERBOARD_MAX_ENTRIES,
			LEADERBOARD_WRITE_INTERVAL,
			LEADERBOARD_REFRESH_INTERVAL,
			leaderboardBackend.kind
		)
	)

	print(
		string.format(
			"[RNGService] Session streak: %d level(s) max, %ds per level, +%d%% luck each -> up to %.2fx. %s",
			StreakMath.Constants.maxLevel,
			STREAK_LEVEL_SECONDS,
			math.floor(StreakMath.Constants.luckPerLevel * 100 + 0.5),
			1 + StreakMath.Constants.luckPerLevel * StreakMath.Constants.maxLevel,
			if STREAK_LEVEL_SECONDS == StreakMath.Constants.studioLevelSeconds
				then "STUDIO-ACCELERATED clock (live is 120s per level) - the same curve, deliberately faster to watch."
				else "Live curve."
		)
	)
end
