--!strict
--[[
	MonetizationConfig
	==================
	THE one place pass and product identifiers live, plus every perk number.
	Nothing else in the project hardcodes an id, and no client is ever told a
	perk number it could act on: the server resolves perks from these values and
	ships the client only a display catalog.

	PLACEHOLDER IDS
	---------------
	Every `id` below is 0, which means "not published yet". Create the real
	passes/products on the Roblox site, paste the ids in here, then republish -
	no other file needs to change.

	`IsConfigured(entry)` is the single question every code path asks before
	touching the Marketplace, so an unset id degrades instead of erroring:

	  * the client shows "NOT CONFIGURED" and offers the Test Mode shortcut
	    instead of calling a prompt that would fail;
	  * the server skips the ownership query and treats the perk as unowned;
	  * ProcessReceipt warns and defers rather than granting an unknown product.

	TEST MODE
	---------
	A server-side flag per player (never a client claim - see PerkService). It is
	offered only where this policy allows it, which is Studio and an explicit
	allowlist, so a published server cannot be talked into free perks.

	STACKING
	--------
	Multipliers multiply rather than add, e.g. 2x Luck * VIP 1.25 * potion 6 *
	server boost 2 = 30x. `PerkMath` owns that arithmetic and the Lune harness
	pins it, so a balance change here is a deliberate, tested edit.
]]

export type PassEntry = {
	key: string,
	id: number,
	displayName: string,
	description: string,
	accent: { r: number, g: number, b: number },

	-- Perk effects, all optional: a pass may grant luck, a cooldown cut, an
	-- unlock, a nametag, or several of those.
	luckMultiplier: number?,
	cooldownMultiplier: number?,
	unlocksAutoRoll: boolean?,
	givesNametag: boolean?,
}

export type ProductEntry = {
	key: string,
	id: number,
	displayName: string,
	description: string,
	accent: { r: number, g: number, b: number },

	-- Either a charge of luck for the next roll, or a timed server-wide boost.
	luckMultiplier: number,
	charges: number?,
	durationSeconds: number?,
}

local MonetizationConfig = {}

-- =============================================================================
-- Game passes (per-player, permanent while owned)
-- =============================================================================

MonetizationConfig.passes = {
	{
		key = "DoubleLuck",
		id = 0, -- PLACEHOLDER
		displayName = "2x Luck",
		description = "Doubles every roll's luck, permanently.",
		accent = { r = 122, g = 232, b = 160 },
		luckMultiplier = 2,
	},
	{
		key = "FastRoll",
		id = 0, -- PLACEHOLDER
		displayName = "Fast Roll",
		description = "Roll cooldown cut by 40%.",
		accent = { r = 255, g = 176, b = 92 },
		cooldownMultiplier = 0.6, -- -40%
	},
	{
		key = "AutoRoll",
		id = 0, -- PLACEHOLDER
		displayName = "Auto-Roll",
		description = "Unlocks the auto-roll clock.",
		accent = { r = 96, g = 168, b = 255 },
		unlocksAutoRoll = true,
	},
	{
		key = "VIP",
		id = 0, -- PLACEHOLDER
		displayName = "VIP",
		description = "+25% luck and a gold nametag everyone can see.",
		accent = { r = 255, g = 214, b = 110 },
		luckMultiplier = 1.25, -- +25%
		givesNametag = true,
	},
} :: { PassEntry }

-- =============================================================================
-- Developer products (consumable)
-- =============================================================================

MonetizationConfig.products = {
	{
		key = "LuckPotion",
		id = 0, -- PLACEHOLDER
		displayName = "Heavenly Luck Potion",
		description = "+500% luck for your next roll only.",
		accent = { r = 214, g = 148, b = 255 },
		luckMultiplier = 6, -- +500%
		charges = 1,
	},
	{
		key = "ServerBoost",
		id = 0, -- PLACEHOLDER
		displayName = "Server Luck Boost",
		description = "2x luck for every player here, for 10 minutes.",
		accent = { r = 255, g = 232, b = 150 },
		luckMultiplier = 2,
		durationSeconds = 600,
	},
} :: { ProductEntry }

-- Display order for the shop, so the UI never re-sorts the catalog itself.
MonetizationConfig.passOrder = { "DoubleLuck", "FastRoll", "AutoRoll", "VIP" }
MonetizationConfig.productOrder = { "LuckPotion", "ServerBoost" }

-- =============================================================================
-- Test Mode policy
-- =============================================================================

MonetizationConfig.testMode = {
	-- Studio only by default: a live server should never hand out free perks.
	enabledInStudio = true,
	-- Optional extra allowlist for testing on a live (unpublished-to-others) server.
	enabledUserIds = {} :: { number },
}

-- =============================================================================
-- Lookups (the only way callers should read the tables above)
-- =============================================================================

function MonetizationConfig.FindPass(key: string): PassEntry?
	for _, entry in ipairs(MonetizationConfig.passes) do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

function MonetizationConfig.FindProduct(key: string): ProductEntry?
	for _, entry in ipairs(MonetizationConfig.products) do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

-- True only once a real id has been pasted in above.
function MonetizationConfig.IsConfigured(entry: { id: number }): boolean
	return entry.id > 0
end

--[[
	Resolves a developer-product id back to its entry, for ProcessReceipt.

	Ids that are not configured are skipped, which matters because every
	placeholder here is 0: without the guard an id of 0 would match the first
	entry and a stray receipt would grant a real product. An unset id must answer
	"I do not know that product", so the receipt is deferred instead.
]]
function MonetizationConfig.FindProductById(productId: number): ProductEntry?
	for _, entry in ipairs(MonetizationConfig.products) do
		if entry.id == productId and MonetizationConfig.IsConfigured(entry) then
			return entry
		end
	end
	return nil
end

function MonetizationConfig.FindPassById(passId: number): PassEntry?
	for _, entry in ipairs(MonetizationConfig.passes) do
		if entry.id == passId and MonetizationConfig.IsConfigured(entry) then
			return entry
		end
	end
	return nil
end

-- Cheap sanity surface the Lune harness asserts on: unique keys, one entry per
-- order slot, and no accidental duplicate ids once real ids are pasted in.
function MonetizationConfig.Describe(): { [string]: any }
	local configuredPasses = 0
	for _, entry in ipairs(MonetizationConfig.passes) do
		if MonetizationConfig.IsConfigured(entry) then
			configuredPasses += 1
		end
	end

	local configuredProducts = 0
	for _, entry in ipairs(MonetizationConfig.products) do
		if MonetizationConfig.IsConfigured(entry) then
			configuredProducts += 1
		end
	end

	return {
		passCount = #MonetizationConfig.passes,
		productCount = #MonetizationConfig.products,
		configuredPasses = configuredPasses,
		configuredProducts = configuredProducts,
	}
end

return MonetizationConfig
