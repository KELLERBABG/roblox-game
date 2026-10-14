--!strict
--[[
	PerkService (server)
	====================
	Owner of every earned perk and of the numbers the roll path consults. Nothing
	else in the game decides how much luck a player has.

	WHO OWNS WHAT
	  * This module owns: which passes a player has, whether Test Mode is on for
	    them, their armed potion charges, the server-wide boost, and the VIP tag.
	  * ShopService owns the Marketplace boundary (catalog, receipts, ownership
	    queries) and calls SetPassOwned / GrantProduct in here.
	  * RNGService owns the roll and asks this module for a luck multiplier, a
	    cooldown multiplier and an auto-roll unlock - all read-only, no yields.

	SERVER AUTHORITY
	  The client never sends a multiplier, a cooldown, an amount, or the word
	  "owned". It can ask exactly three things over one remote: toggle Test Mode
	  (refused unless policy allows it), simulate a product (refused unless Test
	  Mode is already on), or re-request its own state. Every number below is
	  computed here from MonetizationConfig and this module's own state.

	TEST MODE is a server-side flag, and it is offered only where
	MonetizationConfig.testMode allows - Studio, or an explicit user allowlist -
	so a published server cannot be talked into handing out free perks.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig") :: ModuleScript)
local PerkMath = require(script.Parent:WaitForChild("PerkMath") :: ModuleScript)
local ServerRemotes = require(script.Parent:WaitForChild("ServerRemotes") :: ModuleScript)

-- Structural mirrors of PerkMath's exported types. Local because a module
-- required through `WaitForChild(...) :: ModuleScript` is typed `any` (the same
-- convention RNGService uses), so an exported type name is not addressable in a
-- type position. The Lune harness executes PerkMath and pins these shapes, so
-- drift is caught rather than assumed.
type PotionState = { charges: number, multiplier: number }
type PerkEffects = {
	luckMultiplier: number,
	cooldownMultiplier: number,
	autoRollUnlocked: boolean,
	vipNametag: boolean,
}

local VIP_TAG_NAME: string = "VipNametag"
local GOLD = Color3.fromRGB(255, 214, 110)
local ACTION_RATE_LIMIT: number = 0.2
local BOOST_TICK_SECONDS: number = 1

-- =============================================================================
-- Remotes (ReplicatedStorage.Remotes, created through the shared helper)
-- =============================================================================

-- Server -> client: owned perks (and the effective set under Test Mode), potion
-- charges, the server boost and its remaining time.
local PerkState = ServerRemotes.EnsureRemote("RemoteEvent", "PerkState") :: RemoteEvent
-- Client -> server: "SetTestMode" | "SimulateProduct" | "RequestState" and one
-- argument. Nothing here can name a value the server trusts.
local PerkAction = ServerRemotes.EnsureRemote("RemoteEvent", "PerkAction") :: RemoteEvent

-- =============================================================================
-- State
-- =============================================================================

type PerkRecord = {
	userId: number,
	ownedKeys: { [string]: boolean },
	testMode: boolean,
	potion: PotionState,
	vipTag: Instance?,
	lastActionClock: number,
}

type PerkPayload = {
	testMode: boolean,
	-- Whether THIS server would accept a Test Mode toggle at all (Studio, or the
	-- config's allowlist). The shop hides the toggle when it is false.
	testModeAllowed: boolean,
	ownedPassKeys: { [string]: boolean },
	potionCharges: number,
	potionMultiplier: number,
	boostMultiplier: number,
	boostSecondsRemaining: number,
	cooldownMultiplier: number,
	luckMultiplier: number,
}

local records: { [Player]: PerkRecord } = {}

-- The server-wide boost. One at a time: applying another extends it and keeps
-- the stronger multiplier, so two players buying at once cannot shorten it.
local serverBoost: { multiplier: number, endsAtClock: number } = { multiplier = 1, endsAtClock = 0 }

-- Every pass key, resolved once, for Test Mode.
local allPassKeys: { [string]: boolean } = {}
for _, entry in ipairs(MonetizationConfig.passes) do
	allPassKeys[entry.key] = true
end

local PerkService = {}

-- =============================================================================
-- Internal helpers
-- =============================================================================

local function activeBoostMultiplier(): number
	return PerkMath.BoostMultiplier(serverBoost.multiplier, serverBoost.endsAtClock, os.clock())
end

-- Forward declaration: the Test Mode policy lives with the rest of the Test
-- Mode section further down, but the payload builder has to report whether this
-- server would allow it. Declaring the local here keeps it scoped to this chunk
-- (no global) while still being defined in the section that owns the policy.
local canUseTestMode: (Player) -> boolean

local function effectiveOwnedKeys(record: PerkRecord): { [string]: boolean }
	-- Test Mode stands in for ownership rather than granting items, so turning
	-- it off restores exactly what the player really owns.
	if record.testMode then
		return allPassKeys
	end
	return record.ownedKeys
end

local function resolveEffects(record: PerkRecord): PerkEffects
	local contributions = PerkMath.Contributions(MonetizationConfig.passes, effectiveOwnedKeys(record))
	return PerkMath.Combine(contributions, record.potion, activeBoostMultiplier())
end

local function buildPayload(player: Player, record: PerkRecord): PerkPayload
	local effects = resolveEffects(record)
	return {
		testMode = record.testMode,
		testModeAllowed = canUseTestMode(player),
		ownedPassKeys = effectiveOwnedKeys(record),
		potionCharges = record.potion.charges,
		potionMultiplier = record.potion.multiplier,
		boostMultiplier = activeBoostMultiplier(),
		boostSecondsRemaining = PerkMath.BoostSecondsRemaining(serverBoost.endsAtClock, os.clock()),
		cooldownMultiplier = effects.cooldownMultiplier,
		luckMultiplier = effects.luckMultiplier,
	}
end

local function publishAttributes(player: Player, record: PerkRecord): ()
	local effects = resolveEffects(record)
	player:SetAttribute("TestMode", record.testMode)
	player:SetAttribute("VipNametag", effects.vipNametag)
	player:SetAttribute("AutoRollUnlocked", effects.autoRollUnlocked)
	player:SetAttribute("PotionCharges", record.potion.charges)
	player:SetAttribute("PerkLuckMultiplier", effects.luckMultiplier)
	player:SetAttribute("ServerBoostMultiplier", activeBoostMultiplier())
end

-- =============================================================================
-- VIP nametag (server-created, so it replicates to every other player)
-- =============================================================================

local function removeNametag(record: PerkRecord): ()
	local tag = record.vipTag
	if tag ~= nil then
		if tag.Parent ~= nil then
			tag:Destroy()
		end
		record.vipTag = nil
	end
end

local function applyNametag(player: Player, record: PerkRecord): ()
	local character = player.Character
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	if head == nil then
		-- No character yet (first spawn still resolving); CharacterAdded re-runs.
		return
	end

	local existing = head:FindFirstChild(VIP_TAG_NAME)
	local tag = if existing ~= nil then existing else Instance.new("BillboardGui")

	local billboard = tag :: BillboardGui

	if existing == nil then
		billboard.Name = VIP_TAG_NAME
		billboard.Size = UDim2.fromOffset(180, 54)
		-- Above Roblox's own name tag, so it reads as a badge rather than a clash.
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.9, 0)
		billboard.AlwaysOnTop = false
		billboard.LightInfluence = 0
		billboard.MaxDistance = 120

		local badge = Instance.new("TextLabel") :: TextLabel
		badge.Name = "Badge"
		badge.BackgroundTransparency = 1
		badge.Size = UDim2.fromScale(1, 0.5)
		badge.Font = Enum.Font.GothamBlack
		badge.TextScaled = true
		badge.TextColor3 = GOLD
		badge.TextStrokeTransparency = 0.35
		badge.Text = "VIP"
		badge.Parent = billboard

		local title = Instance.new("TextLabel") :: TextLabel
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromScale(0, 0.52)
		title.Size = UDim2.fromScale(1, 0.42)
		title.Font = Enum.Font.GothamBold
		title.TextScaled = true
		title.TextColor3 = Color3.fromRGB(255, 240, 208) -- warm white, gold-adjacent
		title.TextStrokeTransparency = 0.45
		title.Text = player.Name
		title.Parent = billboard
	end

	billboard.Adornee = head
	billboard.Parent = head

	-- The name is re-applied on reuse: a player can be renamed between sessions.
	local title = billboard:FindFirstChild("Title")
	if title ~= nil then
		(title :: TextLabel).Text = player.Name
	end

	record.vipTag = billboard
end

local function refreshNametag(player: Player, record: PerkRecord): ()
	if resolveEffects(record).vipNametag then
		applyNametag(player, record)
	else
		removeNametag(record)
	end
end

-- =============================================================================
-- Sync
-- =============================================================================

local function syncPerkState(player: Player, record: PerkRecord): ()
	PerkState:FireClient(player, buildPayload(player, record))
end

-- Boosts are server-wide, so their changes go to everyone.
local function broadcastPerkState(): ()
	for player, record in pairs(records) do
		if player.Parent == Players then
			publishAttributes(player, record)
			PerkState:FireClient(player, buildPayload(player, record))
		end
	end
end

local function refresh(player: Player, record: PerkRecord): ()
	publishAttributes(player, record)
	refreshNametag(player, record)
	syncPerkState(player, record)
end

-- =============================================================================
-- Public API: read-only, called by RNGService on the authoritative roll path
--
-- All three are pure lookups: no yields, no Marketplace calls, cheap enough to
-- sit inside a roll, and none of them can be reached by a client directly.
-- =============================================================================

function PerkService.GetLuckMultiplier(player: Player): number
	local record = records[player]
	if record == nil then
		return 1
	end
	return resolveEffects(record).luckMultiplier
end

function PerkService.GetCooldownMultiplier(player: Player): number
	local record = records[player]
	if record == nil then
		return 1
	end
	return resolveEffects(record).cooldownMultiplier
end

function PerkService.HasAutoRoll(player: Player): boolean
	local record = records[player]
	if record == nil then
		return false
	end
	return resolveEffects(record).autoRollUnlocked
end

-- True when the player owns (or is testing) the cooldown pass. RNGService asks
-- before it honours a fast-roll toggle, which is what stops a client from
-- cutting its own cooldown by pressing a button.
function PerkService.HasFastRoll(player: Player): boolean
	local record = records[player]
	if record == nil then
		return false
	end
	return resolveEffects(record).cooldownMultiplier < 1
end

--[[
	ConsumeRollEffects(player)

	Called by RNGService exactly once per roll that actually happened, and by
	nothing else. This is the only place a potion charge is spent, which is what
	makes "consumed by exactly one roll" true: reading the multiplier never
	spends it.

	Returns the multiplier that roll just used (for logging/telemetry).
]]
function PerkService.ConsumeRollEffects(player: Player): number
	local record = records[player]
	if record == nil then
		return 1
	end

	local spent, nextPotion = PerkMath.RollPotion(record.potion)
	if spent > 1 then
		record.potion = nextPotion
		publishAttributes(player, record)
		syncPerkState(player, record)
	end
	return spent
end

-- =============================================================================
-- Public API: writes, called by ShopService (and by Test Mode simulation)
-- =============================================================================

function PerkService.SetPassOwned(player: Player, passKey: string, owned: boolean): ()
	local record = records[player]
	if record == nil then
		return
	end

	if owned then
		record.ownedKeys[passKey] = true
	else
		record.ownedKeys[passKey] = nil
	end

	refresh(player, record)
end

function PerkService.ActivateServerBoost(multiplier: number, durationSeconds: number): ()
	if multiplier <= 1 or durationSeconds <= 0 then
		return
	end

	local now = os.clock()
	local base = math.max(now, serverBoost.endsAtClock)
	serverBoost = {
		multiplier = math.max(serverBoost.multiplier, multiplier),
		endsAtClock = base + durationSeconds,
	}

	broadcastPerkState()
end

--[[
	GrantProduct(player, productKey)

	The single place a product's effect is applied, used by both the real
	ProcessReceipt path and Test Mode simulation, so what you try in Studio is
	the same code a purchase runs.

	Returns false when the key is unknown, so ProcessReceipt can defer instead of
	reporting a grant it did not make.
]]
function PerkService.GrantProduct(player: Player, productKey: string): boolean
	local record = records[player]
	local entry = MonetizationConfig.FindProduct(productKey)
	if record == nil or entry == nil then
		return false
	end

	if entry.durationSeconds ~= nil and entry.durationSeconds > 0 then
		PerkService.ActivateServerBoost(entry.luckMultiplier, entry.durationSeconds)
		return true
	end

	-- Consumable luck charge. Buying more stacks charges; the strongest
	-- multiplier wins so a cheaper potion can never weaken an armed one.
	local charges = entry.charges or 1
	local existing = record.potion
	local multiplier = math.max(
		if PerkMath.IsArmed(existing) then existing.multiplier else 1,
		entry.luckMultiplier
	)
	record.potion = PerkMath.ArmPotion(multiplier, existing.charges + charges)

	refresh(player, record)
	return true
end

-- =============================================================================
-- Test Mode (server-side flag, policy gated)
-- =============================================================================

-- Defined here, in the section that owns the policy; declared as a forward
-- local above so the payload builder can report it without a global.
function canUseTestMode(player: Player): boolean
	if MonetizationConfig.testMode.enabledInStudio and RunService:IsStudio() then
		return true
	end
	return table.find(MonetizationConfig.testMode.enabledUserIds, player.UserId) ~= nil
end

function PerkService.SetTestMode(player: Player, enabled: boolean): boolean
	local record = records[player]
	if record == nil then
		return false
	end

	if enabled and not canUseTestMode(player) then
		warn(string.format(
			"[PerkService] %s asked for Test Mode on a server where it is not allowed; refused.",
			player.Name
		))
		return false
	end

	record.testMode = enabled
	refresh(player, record)
	return true
end

-- =============================================================================
-- Client actions (intent only - no values are accepted)
-- =============================================================================

PerkAction.OnServerEvent:Connect(function(player: Player, action: any, argument: any)
	local record = records[player]
	if record == nil or type(action) ~= "string" then
		return
	end

	local now = os.clock()
	if now - record.lastActionClock < ACTION_RATE_LIMIT then
		return
	end
	record.lastActionClock = now

	if action == "SetTestMode" then
		if type(argument) ~= "boolean" then
			return
		end
		PerkService.SetTestMode(player, argument)
	elseif action == "SimulateProduct" then
		if type(argument) ~= "string" then
			return
		end
		-- Only ever a simulation, and only while Test Mode is already on.
		if not record.testMode then
			return
		end
		if MonetizationConfig.FindProduct(argument) == nil then
			return
		end
		PerkService.GrantProduct(player, argument)
	elseif action == "RequestState" then
		syncPerkState(player, record)
	end
end)

-- =============================================================================
-- Boost clock (server driven)
-- =============================================================================

task.spawn(function()
	while true do
		task.wait(BOOST_TICK_SECONDS)
		if serverBoost.multiplier > 1 then
			if os.clock() >= serverBoost.endsAtClock then
				serverBoost = { multiplier = 1, endsAtClock = 0 }
				print("[PerkService] Server luck boost expired.")
			end
			-- Still ticking or just expired: everyone's countdown needs the update.
			broadcastPerkState()
		end
	end
end)

-- =============================================================================
-- Player lifecycle
-- =============================================================================

local function setupPlayer(player: Player): ()
	local record: PerkRecord = {
		userId = player.UserId,
		ownedKeys = {},
		testMode = false,
		potion = PerkMath.EmptyPotion(),
		vipTag = nil,
		lastActionClock = 0,
	}
	records[player] = record

	-- Test Mode may start on by policy so a fresh Studio session can try every
	-- perk with no published assets. It is still a server-side decision.
	if MonetizationConfig.testMode.enabledInStudio and RunService:IsStudio() then
		record.testMode = true
		print("[PerkService] Test Mode ON for this Studio session (server-side flag).")
	end

	publishAttributes(player, record)
	syncPerkState(player, record)

	player.CharacterAdded:Connect(function()
		-- Re-apply the tag on every respawn; nothing else touches it.
		local current = records[player]
		if current ~= nil then
			refreshNametag(player, current)
		end
	end)
end

local function teardownPlayer(player: Player): ()
	local record = records[player]
	if record == nil then
		return
	end
	removeNametag(record)
	records[player] = nil
end

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(teardownPlayer)

for _, existingPlayer in ipairs(Players:GetPlayers()) do
	setupPlayer(existingPlayer)
end

if RunService:IsStudio() then
	local summary = MonetizationConfig.Describe()
	print(string.format(
		"[PerkService] Ready. Passes: %d (%d configured). Products: %d (%d configured).",
		summary.passCount,
		summary.configuredPasses,
		summary.productCount,
		summary.configuredProducts
	))
	if summary.configuredPasses == 0 and summary.configuredProducts == 0 then
		print("[PerkService] No real ids pasted into MonetizationConfig yet - use Test Mode in the shop to try every perk.")
	end
end

return PerkService
