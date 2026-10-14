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
local AUTOSAVE_INTERVAL: number = 90

-- Session streak. The clock is StreakMath's: live = one level per 2 minutes,
-- Studio = the same curve on a 12x faster clock so a playtest can watch it move.
local STREAK_LEVEL_SECONDS: number = StreakMath.ClockSeconds(RunService:IsStudio())
-- How often the streak is re-published. The counter has to visibly grow, and the
-- value must stay the server's, so the server pushes rather than the client
-- counting (see the streak loop near the player lifecycle).
local STREAK_SYNC_INTERVAL: number = 2
local DATASTORE_NAME: string = "AuraCollectorSave_v1"
local SAVE_VERSION: number = 1
local MAX_INVENTORY_COUNT: number = 1e9

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
}

-- =============================================================================
-- Persistence
-- =============================================================================

-- One backend for this store, resolved through SaveBackend: a DataStore when it
-- works, in-memory when it does not (Studio API access off, offline). Keys are
-- still `player_<userId>`, so progress saved before this change loads as before.
local saveBackend = SaveBackend.Get(DATASTORE_NAME)

local function newSaveTable(): SavedData
	return {
		version = SAVE_VERSION,
		totalRolls = 0,
		pityCounter = 0,
		inventory = {},
		equippedAura = nil,
		rarestAura = nil,
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
		sessionStartClock = os.clock(),
		autoEnabled = false,
		fastEnabled = false,
		autoGeneration = 0,
		rarityTally = {},
		rarePlusPulls = 0,
		hardPityHits = 0,
		expectedRarePlus = 0,
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
	}
end

-- =============================================================================
-- Helpers
-- =============================================================================

--[[
	cooldownFor(player, state)

	`state.fastEnabled` is only a PREFERENCE. The discount itself comes from
	PerkService, which reports 1 for a player who owns neither the Fast Roll pass
	nor Test Mode - so a client toggling this on cannot shorten its own cooldown,
	it can only ask for an entitlement the server verifies.
]]
local function cooldownFor(player: Player, state: PlayerState): number
	if state.fastEnabled then
		return BASE_COOLDOWN * PerkService.GetCooldownMultiplier(player)
	end
	return BASE_COOLDOWN
end

-- The session streak, derived from the server's own clock. Nothing here is
-- taken from a client, and the snapshot is total (a NaN or absurd duration
-- degrades to "no streak" or "capped" rather than throwing mid-roll).
local function streakFor(state: PlayerState): StreakSnapshot
	return StreakMath.Snapshot(os.clock() - state.sessionStartClock, STREAK_LEVEL_SECONDS)
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

local function buildStatePayload(player: Player, state: PlayerState): StatePayload
	local hardPityRolls = RollMath.HardPityRolls()
	local pity = math.min(state.pityCounter, hardPityRolls)
	-- Read once and reused by the luck line below: the streak travels in the same
	-- payload as the luck it contributes to.
	local streak = streakFor(state)

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

	-- Accumulate the analytic probability *before* the draw so the session's
	-- expected rare-or-better count is exact, not approximated after the fact.
	state.expectedRarePlus += RollMath.ChanceOfAtLeast(rareFloor, luck, state.pityCounter)

	local outcome = RollMath.SelectAura(luck, state.pityCounter)

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

	state.inventory[outcome.auraId] = (state.inventory[outcome.auraId] or 0) + 1
	local ownedCount = state.inventory[outcome.auraId]

	if state.rarestAura == nil or outcome.rarity > rarityOfAuraId(state.rarestAura) then
		state.rarestAura = outcome.auraId
	end

	-- Quality-of-life auto equip: only ever upgrades, never downgrades a manual pick.
	local autoEquipped = false
	if state.equippedAura == nil or outcome.rarity > rarityOfAuraId(state.equippedAura) then
		state.equippedAura = outcome.auraId
		autoEquipped = true
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

-- =============================================================================
-- Player lifecycle
-- =============================================================================

local function saveState(state: PlayerState): boolean
	return saveBackend.save(SaveBackend.PlayerKey(state.userId), toSavedData(state))
end

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
	saveState(state)
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

game:BindToClose(function()
	for player, state in pairs(playerStates) do
		if player.Parent == Players then
			saveState(state)
		end
	end
	if saveBackend.kind ~= "DataStore" then
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
