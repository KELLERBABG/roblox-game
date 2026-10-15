--!strict
--[[
	LeaderboardMath
	===============
	The pure half of the Top Rollers board: how one player's numbers become the
	integer an OrderedDataStore can hold, how that integer is read back, how
	entries are ranked, how ties are broken, and how the list is bounded.

	NO ROBLOX, NO STORE. Nothing here reads or writes anything: it turns values
	into entries and entries into a ranked, bounded list, so the ordering rules are
	executable in the terminal harness (ordering, ties, bounds, damaged input,
	the no-store path) rather than only observable against a live DataStore.

	THE PAIR OF NUMBERS, and why they fit in ONE integer. A board of "top rollers"
	wants both what a player DID (total rolls) and what they FOUND (the rarest
	rung of the ladder they own the discovery of). An OrderedDataStore stores one
	integer per key, so the score carries both:

	    score = rolls * (maxRarity + 1) + rarestRarity

	which ranks primarily by rolls and breaks a rolls-tie by the rarer find, and
	decodes both numbers exactly (no approximation, no precision loss: see the
	headroom note below). The alternative - two ordered stores - cannot fill both
	columns of one list without an extra read per row, so the encoding is the
	simpler and the more honest of the two.

	HEADROOM: maxRolls (1e9) * (maxRarity + 1) = 1e15, comfortably inside the
	integer range Roblox's DataStores carry exactly (2^53 ~ 9.0e15).

	RARITIES ARE UNIQUE (AuraRegistry refuses to load two rungs with the same
	odds), so `RarestAura` can name the aura from the decoded rarity alone - which
	is why the rarest find survives a round trip through one integer.
]]

export type RaritySource = {
	ORDER: { string },
	Get: (string) -> any?,
}

export type Constants = {
	-- How many entries the server keeps and sends. The panel shows fewer; this is
	-- the bound on what leaves the server.
	maxEntries: number,
	-- The roll ceiling the encoding can carry (see HEADROOM). A roll count above
	-- it is clamped, not rejected: a legitimately huge number must not error.
	maxRolls: number,
	-- OrderedDataStore keys are capped at 50 characters, and the key carries the
	-- player's name so an offline player still has one on the board.
	maxNameLength: number,
	-- Ordered-store writes are rate limited, so a score is submitted on a cadence
	-- rather than per roll (which would be one write per second per player).
	writeIntervalSeconds: number,
	-- How often the persisted board is read back into memory for the payload.
	refreshIntervalSeconds: number,
}

export type Entry = {
	userId: number,
	name: string,
	rolls: number,
	rarestRarity: number,
	-- The encoded integer: what the store holds and what ranking uses.
	score: number,
}

export type Row = {
	rank: number,
	userId: number,
	name: string,
	rolls: number,
	rarestRarity: number,
	rarestAura: string?,
	rarestDisplayName: string?,
	tier: string?,
}

local CONSTANTS: Constants = {
	maxEntries = 10,
	maxRolls = 1e9,
	maxNameLength = 20,
	writeIntervalSeconds = 30,
	refreshIntervalSeconds = 20,
}

local LeaderboardMath = {}

LeaderboardMath.Constants = CONSTANTS

local function finite(value: any): number?
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	local magnitude = math.abs(value)
	if magnitude == math.huge then
		return nil
	end
	return value
end

-- A count of rolls: whole, non-negative, capped at what the encoding can carry.
function LeaderboardMath.SanitizeRolls(value: any): number
	local number = finite(value)
	if number == nil or number <= 0 then
		return 0
	end
	local whole = math.floor(number)
	if whole > CONSTANTS.maxRolls then
		return CONSTANTS.maxRolls
	end
	return whole
end

-- A Roblox user id: a positive integer. Deliberately NOT clamped by maxRolls -
-- that ceiling is about how many rolls a player can log, and user ids pass 1e9.
function LeaderboardMath.SanitizeUserId(value: any): number
	local number = finite(value)
	if number == nil or number <= 0 then
		return 0
	end
	local whole = math.floor(number)
	-- Kept exactly representable so the key always round-trips through %d.
	if whole > 2 ^ 53 then
		return 0
	end
	return whole
end

-- [[score = rolls * span + rarity]] The span is the number's radix: one more than
-- the rarest rung the ladder has. A missing or damaged ceiling degrades to 1,
-- which is the "rolls only, no rarity component" encoding.
local function spanFor(maxRarity: any): number
	local ceiling = finite(maxRarity)
	if ceiling == nil or ceiling <= 0 then
		return 1
	end
	return math.floor(ceiling) + 1
end

--[[
	SanitizeRarity(value, maxRarity)

	A rarity score: whole, non-negative, and never above the rarest rung the ladder
	actually has. Unknown or damaged input is 0, which reads as "nothing rare yet"
	rather than as a bogus rung.
]]
function LeaderboardMath.SanitizeRarity(value: any, maxRarity: number): number
	local ceiling = finite(maxRarity)
	if ceiling == nil or ceiling < 0 then
		ceiling = 0
	end
	ceiling = math.floor(ceiling)

	local number = finite(value)
	if number == nil or number <= 0 then
		return 0
	end
	local whole = math.floor(number)
	if whole > ceiling then
		return ceiling
	end
	return whole
end

--[[
	Encode / Decode - one integer holding both numbers. Decode is total: a score
	that is not a number, or is negative, decodes to zeros rather than throwing,
	because a damaged store row must not take the board down.
]]
function LeaderboardMath.Encode(rolls: number, rarestRarity: number, maxRarity: number): number
	local span = spanFor(maxRarity)
	local safeRolls = LeaderboardMath.SanitizeRolls(rolls)
	local safeRarity = LeaderboardMath.SanitizeRarity(rarestRarity, span - 1)
	return safeRolls * span + safeRarity
end

function LeaderboardMath.Decode(score: any, maxRarity: number): (number, number)
	local span = spanFor(maxRarity)
	local number = finite(score)
	if number == nil or number <= 0 then
		return 0, 0
	end
	number = math.floor(number)

	local rolls = math.floor(number / span)
	if rolls > CONSTANTS.maxRolls then
		rolls = CONSTANTS.maxRolls
	end
	local rarestRarity = number - rolls * span
	if rarestRarity < 0 then
		rarestRarity = 0
	end
	return rolls, rarestRarity
end

-- =============================================================================
-- Keys
-- =============================================================================

--[[
	Names are carried in the KEY, not the value: an OrderedDataStore value is a
	single integer, and a board that cannot name an offline player is not a board.
	The name is sanitised so the key stays inside the store's 50-character limit
	and can always be parsed back - a separator inside a name would split it in the
	wrong place.
]]
function LeaderboardMath.SanitizeName(value: any): string
	if type(value) ~= "string" then
		return ""
	end

	local cleaned = string.gsub(value, "[|%c]", "_")
	cleaned = string.gsub(cleaned, "^%s+", "")
	cleaned = string.gsub(cleaned, "%s+$", "")
	if #cleaned > CONSTANTS.maxNameLength then
		cleaned = string.sub(cleaned, 1, CONSTANTS.maxNameLength)
	end
	return cleaned
end

function LeaderboardMath.Key(userId: number, name: string): string
	return string.format("%d|%s", LeaderboardMath.SanitizeUserId(userId), LeaderboardMath.SanitizeName(name))
end

-- Total: a foreign or damaged key parses to (nil, ""), and the caller skips it.
function LeaderboardMath.ParseKey(key: any): (number?, string)
	if type(key) ~= "string" then
		return nil, ""
	end

	local separator = string.find(key, "|", 1, true)
	if separator == nil then
		return nil, ""
	end

	local idText = string.sub(key, 1, separator - 1)
	local name = string.sub(key, separator + 1)
	local parsed = tonumber(idText)
	if parsed == nil then
		return nil, ""
	end
	local userId = LeaderboardMath.SanitizeUserId(parsed)
	if userId <= 0 then
		return nil, ""
	end
	return userId, LeaderboardMath.SanitizeName(name)
end

-- =============================================================================
-- Entries
-- =============================================================================

function LeaderboardMath.Entry(userId: number, name: string, rolls: number, rarestRarity: number, maxRarity: number): Entry
	local safeRolls = LeaderboardMath.SanitizeRolls(rolls)
	local safeRarity = LeaderboardMath.SanitizeRarity(rarestRarity, maxRarity)
	return {
		userId = LeaderboardMath.SanitizeUserId(userId),
		name = LeaderboardMath.SanitizeName(name),
		rolls = safeRolls,
		rarestRarity = safeRarity,
		score = LeaderboardMath.Encode(safeRolls, safeRarity, maxRarity),
	}
end

-- A store row ({ key, value } as GetSortedAsync returns them) as an entry, or nil
-- for anything that is not one. The score comes straight from the store, so a
-- damaged value is skipped rather than silently ranked as zero.
function LeaderboardMath.FromRow(row: any, maxRarity: number): Entry?
	if type(row) ~= "table" then
		return nil
	end
	local userId, name = LeaderboardMath.ParseKey(row.key)
	if userId == nil then
		return nil
	end
	local score = finite(row.value)
	if score == nil or score <= 0 then
		return nil
	end

	local rolls, rarestRarity = LeaderboardMath.Decode(score, maxRarity)
	return {
		userId = userId,
		name = name,
		rolls = rolls,
		rarestRarity = rarestRarity,
		score = math.floor(score),
	}
end

--[[
	Rank(entries, maxEntries)

	The ordering, stated once: the higher score first (which is more rolls, then the
	rarer find - see Encode), and an exact tie broken by USER ID ascending so the
	order is deterministic rather than "whatever the sort did". Then truncated: the
	board is bounded here, in one place.
]]
function LeaderboardMath.Rank(entries: { Entry }, maxEntries: number?): { Entry }
	local limit = maxEntries
	if limit == nil then
		limit = CONSTANTS.maxEntries
	end
	if finite(limit) == nil or (limit :: number) < 0 then
		limit = CONSTANTS.maxEntries
	end
	limit = math.min(math.floor(limit :: number), CONSTANTS.maxEntries)

	local copy: { Entry } = {}
	for _, entry in ipairs(entries) do
		if type(entry) == "table" and type(entry.userId) == "number" then
			table.insert(copy, entry)
		end
	end

	table.sort(copy, function(left: Entry, right: Entry): boolean
		if left.score ~= right.score then
			return left.score > right.score
		end
		return left.userId < right.userId
	end)

	local bounded: { Entry } = {}
	for index = 1, #copy do
		if index > limit then
			break
		end
		bounded[index] = copy[index]
	end
	return bounded
end

--[[
	Merge(persisted, live, maxEntries)

	The board a player sees is the persisted one with THIS server's players folded
	in, so the numbers move while you play instead of appearing 20 seconds later.
	One entry per user: the better score wins, and a live entry is preferred when
the scores are equal (it carries the current name, and a rename must not leave
two rows for one person).

	An entry with no score cannot join at all (see `absorb`): the board is what
	players DID, so a player who has not rolled yet is absent rather than a zero.
]]
function LeaderboardMath.Merge(persisted: { Entry }, live: { Entry }, maxEntries: number?): { Entry }
	local byId: { [number]: Entry } = {}
	local order: { number } = {}

	local function absorb(entry: any, override: boolean): ()
		if type(entry) ~= "table" or type(entry.userId) ~= "number" then
			return
		end
		--[[
			NOTHING THAT HAS DONE NOTHING IS ON THE BOARD.

			The live half is built from every connected player, so a player who has
			just joined would otherwise occupy a row worth `0 rolls` - and on a fresh
			server that row is the WHOLE board, which reads as data about the server
			rather than as "nobody has rolled yet". A zero score means no rolls, so
			this is also the rule that lets the HUD's empty state be reached at all.

			It lives here, in the pure half, rather than at the call site: it is a
			property of what a board IS, the harness executes it, and both halves of
			the merge get it for free.
		]]
		-- `finite` and not a bare `<= 0`: a NaN score is a number and is not `<= 0`, so
		-- it would join the board and then make the sort's comparator answer false both
		-- ways for one pair - the module's own binding rule for damaged input applies
		-- here too, and an infinite score is not a rank either.
		local score = finite(entry.score)
		if score == nil or score <= 0 then
			return
		end
		local existing = byId[entry.userId]
		if existing == nil then
			byId[entry.userId] = entry
			table.insert(order, entry.userId)
			return
		end
		--[[
			THE BETTER SCORE WINS, and a live entry only breaks an EXACT tie (it
			carries the current name, so a rename must not leave two rows for one
			person). "Live wins" on its own would be wrong in the other direction: a
			player's in-memory state is this session's, and a previous session's board
			row is not something a rejoin may lower.
		]]
		if entry.score > existing.score or (override and entry.score == existing.score) then
			byId[entry.userId] = entry
		end
	end

	for _, entry in ipairs(persisted) do
		absorb(entry, false)
	end
	for _, entry in ipairs(live) do
		absorb(entry, true)
	end

	local merged: { Entry } = {}
	for _, userId in ipairs(order) do
		local entry = byId[userId]
		if entry ~= nil then
			table.insert(merged, entry)
		end
	end

	return LeaderboardMath.Rank(merged, maxEntries)
end

-- =============================================================================
-- Reading an entry against the ladder
-- =============================================================================

-- The rarest rung a given rarity resolves to, by scanning the ladder. Rarities are
-- unique (AuraRegistry enforces it), so this is exact rather than a nearest match.
function LeaderboardMath.AuraAtRarity(ladder: RaritySource?, rarity: number): any?
	if ladder == nil or rarity <= 0 then
		return nil
	end
	for _, id in ipairs(ladder.ORDER) do
		local config = ladder.Get(id)
		if config ~= nil and config.rarity == rarity then
			return config
		end
	end
	return nil
end

-- The name to print for an entry. A player whose name the key could not carry
-- (an id-only key, or a damaged one) still gets a stable label.
function LeaderboardMath.DisplayName(entry: Entry): string
	if entry.name ~= "" then
		return entry.name
	end
	return string.format("Player %d", entry.userId)
end

--[[
	Rows(entries, ladder, maxEntries)

	What the client is sent: rank, both numbers, and the rarest rung resolved to
	the ladder's own label and tier. Derived here rather than in the UI so the
	panel never has to know that the rarest find travelled as an integer.
]]
function LeaderboardMath.Rows(entries: { Entry }, ladder: RaritySource?, maxEntries: number?): { Row }
	local ranked = LeaderboardMath.Rank(entries, maxEntries)
	local rows: { Row } = table.create(#ranked)

	for index, entry in ipairs(ranked) do
		local config = LeaderboardMath.AuraAtRarity(ladder, entry.rarestRarity)
		table.insert(rows, {
			rank = index,
			userId = entry.userId,
			name = LeaderboardMath.DisplayName(entry),
			rolls = entry.rolls,
			rarestRarity = entry.rarestRarity,
			rarestAura = if config ~= nil then config.id else nil,
			rarestDisplayName = if config ~= nil then config.displayName else nil,
			tier = if config ~= nil then config.tier else nil,
		})
	end

	return rows
end

return LeaderboardMath
