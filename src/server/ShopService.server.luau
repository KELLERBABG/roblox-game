--!strict
--[[
	ShopService (server)
	====================
	A server SCRIPT, not a module: it sets MarketplaceService.ProcessReceipt at
	load, publishes the shop remotes and starts the ownership poll, none of which
	happen unless something actually runs it. (As a ModuleScript it would have been
	dormant until required - and nothing requires the shop. `test_perks.luau` now
	asserts that every server module has a requirer, which is the check that would
	have caught that.)

	The ONLY file that talks to MarketplaceService. Three jobs, nothing else:

	  1. Push a display catalog to each client, so the shop UI never has to know
	     what a perk is worth - it renders what it is given and nothing more.
	  2. Own the ownership question for passes: ask Roblox, tell PerkService.
	  3. Own ProcessReceipt for products: claim the receipt exactly once, then
	     grant through PerkService.GrantProduct.

	WHAT IT DOES NOT OWN: how a perk feels. This module never adds luck, never
	touches a cooldown and never invents an effect. It resolves an id, asks
	PerkService to apply the entry, and reports what happened. That is why the
	Test Mode simulation in PerkService and a real purchase run the same code.

	UNCONFIGURED IDS ARE THE NORMAL CASE TODAY
	------------------------------------------
	Every id in MonetizationConfig is 0 (placeholder) until the real passes and
	products are published. So:
	  * a prompt for an unconfigured entry is refused with a notice to the player
	    instead of calling Roblox with id 0;
	  * ownership polling skips unconfigured passes entirely (no error, no query);
	  * ProcessReceipt warns and DEFERS for an unknown product id rather than
	    reporting a grant it did not make.

	Everything therefore works in Studio today through Test Mode, and pasting
	real ids into MonetizationConfig is the only step to go live.

	DATALESS STUDIO SESSIONS
	------------------------
	Receipts are claimed through SaveBackend, the same backend policy the save
	path uses: one DataStore when it works, an in-memory store when it does not,
	with the claim recorded in BOTH. A Studio session with API access off is
	therefore still idempotent for its whole lifetime, and a DataStore-backed
	session is idempotent across servers.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig") :: ModuleScript)
local PerkService = require(script.Parent:WaitForChild("PerkService") :: ModuleScript)
local SaveBackend = require(script.Parent:WaitForChild("SaveBackend") :: ModuleScript)
local ServerRemotes = require(script.Parent:WaitForChild("ServerRemotes") :: ModuleScript)

local RECEIPT_STORE: string = "AuraCollectorReceipts_v1"
local OWNERSHIP_POLL_SECONDS: number = 15
local PROMPT_RATE_LIMIT: number = 1
local CATALOG_RATE_LIMIT: number = 0.5

-- =============================================================================
-- Remotes
-- =============================================================================

-- Server -> client: the display catalog. Deliberately no per-player ownership in
-- here - PerkService already publishes that on PerkState, and one datum wants one
-- owner.
local ShopCatalog = ServerRemotes.EnsureRemote("RemoteEvent", "ShopCatalog") :: RemoteEvent
-- Client -> server: "PromptPass" | "PromptProduct" | "RequestCatalog" plus a key.
local ShopAction = ServerRemotes.EnsureRemote("RemoteEvent", "ShopAction") :: RemoteEvent
-- Server -> client: a human-readable line for the shop's status readout.
local ShopNotice = ServerRemotes.EnsureRemote("RemoteEvent", "ShopNotice") :: RemoteEvent

-- =============================================================================
-- State
-- =============================================================================

local receiptBackend = SaveBackend.Get(RECEIPT_STORE)

local promptClock: { [Player]: number } = {}
local catalogClock: { [Player]: number } = {}

-- Last answer Roblox gave us per player per pass id, so we only push changes.
local ownershipCache: { [Player]: { [number]: boolean } } = {}

local warnedUnconfigured: { [string]: boolean } = {}
local warnedOwnershipQuery = false

-- =============================================================================
-- Notices
-- =============================================================================

local function notify(player: Player, text: string, kind: string?): ()
	ShopNotice:FireClient(player, { text = text, kind = kind or "info", at = os.clock() })
end

local function warnUnconfigured(entryKey: string, displayName: string): ()
	if warnedUnconfigured[entryKey] then
		return
	end
	warnedUnconfigured[entryKey] = true
	warn(string.format(
		"[ShopService] %s has no real id yet (MonetizationConfig placeholder 0); prompts for it are refused. "
			.. "Test Mode in the shop exercises the same perk without a purchase.",
		displayName
	))
end

-- =============================================================================
-- Catalog
-- =============================================================================

--[[
	The catalog carries the numbers, not a sentence about them: the client renders
	"+500% luck" from `luckMultiplier = 6`, so a balance edit in MonetizationConfig
	can never leave stale marketing copy behind in the UI.

	Prices are deliberately absent. Roblox's own purchase prompt shows the real
	price from the live asset, so fetching product info here would add a yielding
	network call to the shop path to display a number the player is about to see
	anyway.
]]
local function buildCatalog(): { [string]: any }
	local passes: { { [string]: any } } = {}
	for _, key in ipairs(MonetizationConfig.passOrder) do
		local entry = MonetizationConfig.FindPass(key)
		if entry ~= nil then
			table.insert(passes, {
				key = entry.key,
				displayName = entry.displayName,
				description = entry.description,
				accent = entry.accent,
				configured = MonetizationConfig.IsConfigured(entry),
				luckMultiplier = entry.luckMultiplier,
				cooldownMultiplier = entry.cooldownMultiplier,
				unlocksAutoRoll = entry.unlocksAutoRoll == true,
				givesNametag = entry.givesNametag == true,
			})
		end
	end

	local products: { { [string]: any } } = {}
	for _, key in ipairs(MonetizationConfig.productOrder) do
		local entry = MonetizationConfig.FindProduct(key)
		if entry ~= nil then
			table.insert(products, {
				key = entry.key,
				displayName = entry.displayName,
				description = entry.description,
				accent = entry.accent,
				configured = MonetizationConfig.IsConfigured(entry),
				luckMultiplier = entry.luckMultiplier,
				charges = entry.charges,
				durationSeconds = entry.durationSeconds,
			})
		end
	end

	return { passes = passes, products = products, at = os.clock() }
end

local function sendCatalog(player: Player): ()
	local catalog = buildCatalog()
	player:SetAttribute("ShopPassCount", #catalog.passes)
	player:SetAttribute("ShopProductCount", #catalog.products)
	ShopCatalog:FireClient(player, catalog)
end

-- =============================================================================
-- Pass ownership
-- =============================================================================

--[[
	Asks Roblox whether this player owns each configured pass and reports only
	what changed. Two rules keep this safe:

	  * a failed query changes nothing - an offline or API-disabled session must
	    not be read as "you own nothing";
	  * ownership is only ever pushed for a pass we are told is owned, or for one
	    we previously reported as owned and now are not.
]]
local function refreshOwnership(player: Player): ()
	local cache = ownershipCache[player]
	if cache == nil then
		cache = {}
		ownershipCache[player] = cache
	end

	for _, entry in ipairs(MonetizationConfig.passes) do
		if MonetizationConfig.IsConfigured(entry) then
			local ok, result = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, entry.id)
			end)

			if not ok then
				if not warnedOwnershipQuery then
					warnedOwnershipQuery = true
					warn(
						"[ShopService] Game pass ownership query failed (Studio API access off, or offline): "
							.. tostring(result)
							.. ". Perks stay as they are; Test Mode covers local testing."
					)
				end
				continue
			end

			local owned = result == true
			if owned or cache[entry.id] == true then
				if cache[entry.id] ~= owned then
					cache[entry.id] = owned
					PerkService.SetPassOwned(player, entry.key, owned)
					if owned then
						notify(player, string.format("%s is active on your account.", entry.displayName), "grant")
					end
				end
			end
		end
	end
end

-- =============================================================================
-- Prompts
-- =============================================================================

local function promptPass(player: Player, passKey: any): ()
	if type(passKey) ~= "string" then
		return
	end

	local entry = MonetizationConfig.FindPass(passKey)
	if entry == nil then
		return
	end

	if not MonetizationConfig.IsConfigured(entry) then
		warnUnconfigured(entry.key, entry.displayName)
		notify(player, string.format(
			"%s is not on sale yet. (Server: set its id in MonetizationConfig to sell it, or use Test Mode to try it.)",
			entry.displayName
		), "warn")
		return
	end

	MarketplaceService:PromptGamePassPurchase(player, entry.id)
end

local function promptProduct(player: Player, productKey: any): ()
	if type(productKey) ~= "string" then
		return
	end

	local entry = MonetizationConfig.FindProduct(productKey)
	if entry == nil then
		return
	end

	if not MonetizationConfig.IsConfigured(entry) then
		warnUnconfigured(entry.key, entry.displayName)
		notify(player, string.format(
			"%s is not on sale yet. (Server: set its id in MonetizationConfig to sell it, or use Test Mode to try it.)",
			entry.displayName
		), "warn")
		return
	end

	MarketplaceService:PromptProductPurchase(player, entry.id)
end

-- =============================================================================
-- Receipts
-- =============================================================================

--[[
	ProcessReceipt must be idempotent: Roblox re-delivers a receipt until it is
	granted, and it can arrive twice if a server dies mid-grant. The claim is
	taken through SaveBackend (session table + durable store), BEFORE anything is
	granted, and the loser of the claim returns PurchaseGranted without granting
	again.
]]
MarketplaceService.ProcessReceipt = function(receiptInfo: { [string]: any }): Enum.ProductPurchaseDecision
	local productId = tonumber(receiptInfo.ProductId) or 0
	local entry = MonetizationConfig.FindProductById(productId)

	if entry == nil then
		-- Either an id that is not in the config yet, or a product from another
		-- game. Defer rather than consume: once the id is pasted in, Roblox's
		-- next delivery will grant it.
		warn(string.format(
			"[ShopService] Receipt for unknown product id %d (not in MonetizationConfig); deferring, not consuming.",
			productId
		))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(tonumber(receiptInfo.PlayerId) or 0)
	if player == nil then
		-- They left before we could grant. Ask for another delivery instead of
		-- dropping a purchase we were paid for.
		warn(string.format("[ShopService] Receipt for %s arrived after the player left; deferring.", entry.displayName))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local receiptKey = SaveBackend.ReceiptKey(tostring(receiptInfo.PurchaseId))
	if not SaveBackend.ClaimReceipt(receiptBackend, receiptKey) then
		-- Already granted, in this session or a previous one.
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if not PerkService.GrantProduct(player, entry.key) then
		warn(string.format("[ShopService] %s could not be granted; leaving the receipt for redelivery.", entry.displayName))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	notify(player, string.format("%s activated.", entry.displayName), "grant")
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- =============================================================================
-- Client actions (keys only - never an amount, a multiplier or an effect)
-- =============================================================================

ShopAction.OnServerEvent:Connect(function(player: Player, action: any, key: any)
	if type(action) ~= "string" then
		return
	end

	local now = os.clock()

	if action == "RequestCatalog" then
		if now - (catalogClock[player] or 0) < CATALOG_RATE_LIMIT then
			return
		end
		catalogClock[player] = now
		sendCatalog(player)
	elseif action == "PromptPass" then
		if now - (promptClock[player] or 0) < PROMPT_RATE_LIMIT then
			return
		end
		promptClock[player] = now
		promptPass(player, key)
	elseif action == "PromptProduct" then
		if now - (promptClock[player] or 0) < PROMPT_RATE_LIMIT then
			return
		end
		promptClock[player] = now
		promptProduct(player, key)
	end
end)

-- =============================================================================
-- Immediate grant after a pass purchase (the poll would catch it, this is
-- instant) and lifecycle
-- =============================================================================

MarketplaceService.PromptGamePassPurchaseFinished:Connect(
	function(player: Player, passId: number, wasPurchased: boolean)
		if not wasPurchased then
			return
		end

		local entry = MonetizationConfig.FindPassById(passId)
		if entry == nil then
			return
		end

		local cache = ownershipCache[player]
		if cache == nil then
			cache = {}
			ownershipCache[player] = cache
		end
		cache[passId] = true

		PerkService.SetPassOwned(player, entry.key, true)
		notify(player, string.format("%s activated. Thank you!", entry.displayName), "grant")
	end
)

local function setupPlayer(player: Player): ()
	sendCatalog(player)

	-- Ownership first, then the poll takes over. Both are yields; neither blocks
	-- the roll path.
	task.spawn(function()
		refreshOwnership(player)
	end)
end

local function teardownPlayer(player: Player): ()
	ownershipCache[player] = nil
	promptClock[player] = nil
	catalogClock[player] = nil
end

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(teardownPlayer)

for _, existingPlayer in ipairs(Players:GetPlayers()) do
	setupPlayer(existingPlayer)
end

task.spawn(function()
	while true do
		task.wait(OWNERSHIP_POLL_SECONDS)
		for player in pairs(ownershipCache) do
			if player.Parent == Players then
				refreshOwnership(player)
			end
		end
	end
end)

-- =============================================================================
-- Startup readout
-- =============================================================================

if RunService:IsStudio() then
	local summary = MonetizationConfig.Describe()
	print(string.format(
		"[ShopService] Ready. Receipts: %s. Pass ids configured: %d/%d, product ids configured: %d/%d.",
		receiptBackend.kind,
		summary.configuredPasses,
		summary.passCount,
		summary.configuredProducts,
		summary.productCount
	))
	if summary.configuredPasses == 0 and summary.configuredProducts == 0 then
		print("[ShopService] All ids are placeholders - the shop will refuse prompts and offer Test Mode instead.")
	end
end
