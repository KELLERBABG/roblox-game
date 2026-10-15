--!strict
--[[
	SaveBackend
	===========
	One owner for the "DataStore when it works, memory when it does not" policy,
	so player saves and purchase receipts cannot drift apart in behaviour.

	Extracted from RNGService, which had this policy inline. It is the same
	policy, unchanged: try DataStoreService once at startup, warn once on any
	failure, and keep everything working in memory for the session. Keys are
	built by `PlayerKey`, which still produces exactly `player_<userId>` - the
	existing format - so previously saved progress loads as before.

	Roblox is resolved LAZILY, inside functions, never at module scope. That keeps
	this module loadable from Lune, which is what lets the harness execute the
	memory fallback and the receipt guard without a Roblox runtime.
]]

export type Backend = {
	kind: string,
	load: (key: string) -> any,
	save: (key: string, data: any) -> boolean,
}

local SaveBackend = {}

-- =============================================================================
-- Keys
-- =============================================================================

-- Unchanged from the original save path: `player_<userId>`.
function SaveBackend.PlayerKey(userId: number): string
	return string.format("player_%d", userId)
end

function SaveBackend.ReceiptKey(receiptId: string): string
	return string.format("receipt_%s", receiptId)
end

-- =============================================================================
-- Lazily resolved Roblox service
-- =============================================================================

local dataStoreServiceResolved = false
local dataStoreService: any = nil

local function getDataStoreService(): any
	if not dataStoreServiceResolved then
		dataStoreServiceResolved = true
		local ok, service = pcall(function()
			return (game :: any):GetService("DataStoreService")
		end)
		dataStoreService = if ok then service else nil
	end
	return dataStoreService
end

-- =============================================================================
-- Backends
-- =============================================================================

local warnedAboutDataStore = false

local function createMemoryBackend(storeName: string): Backend
	local memoryStore: { [string]: any } = {}

	return {
		kind = string.format("Memory(%s/datastore-unavailable)", storeName),
		load = function(key: string): any
			local stored = memoryStore[key]
			if stored == nil then
				return nil
			end
			-- Shallow copy: callers get their own table and cannot write through
			-- into the store by mutating the top level.
			local copy: { [string]: any } = {}
			for field, value in pairs(stored :: { [string]: any }) do
				copy[field] = value
			end
			return copy
		end,
		save = function(key: string, data: any): boolean
			memoryStore[key] = data
			return true
		end,
	}
end

local function createDataStoreBackend(storeName: string): Backend?
	local service = getDataStoreService()
	if service == nil then
		return nil
	end

	local ok, store = pcall(function()
		return service:GetDataStore(storeName)
	end)
	if not ok or store == nil then
		return nil
	end

	local dataStore: any = store

	return {
		kind = "DataStore",
		load = function(key: string): any
			local success, result = pcall(function()
				return dataStore:GetAsync(key)
			end)
			if not success then
				if not warnedAboutDataStore then
					warnedAboutDataStore = true
					warn(string.format(
						"[SaveBackend] DataStore read failed for %s (Studio API access off, or offline). "
							.. "Continuing with in-memory data.",
						storeName
					))
				end
				return nil
			end
			if type(result) ~= "table" then
				return nil
			end
			return result
		end,
		save = function(key: string, data: any): boolean
			local success = pcall(function()
				dataStore:SetAsync(key, data)
			end)
			if not success then
				if not warnedAboutDataStore then
					warnedAboutDataStore = true
					warn(string.format(
						"[SaveBackend] DataStore write failed for %s; data kept in memory for this session.",
						storeName
					))
				end
				return false
			end
			return true
		end,
	}
end

local backends: { [string]: Backend } = {}

-- One backend per store name, created on first use so a failed DataStore read
-- never blocks a different store from working.
function SaveBackend.Get(storeName: string): Backend
	local cached = backends[storeName]
	if cached ~= nil then
		return cached
	end

	local dataStoreBackend = createDataStoreBackend(storeName)
	local backend = if dataStoreBackend ~= nil then dataStoreBackend else createMemoryBackend(storeName)
	backends[storeName] = backend
	return backend
end

-- =============================================================================
-- Ordered backends (leaderboards)
-- =============================================================================

--[[
	An ORDERED store is a different API and a different budget from the key/value
	one above: one integer per key, and reads come back sorted. It gets the same
	policy, though - a DataStore when it works, memory when it does not - so a
	Studio session without API access shows this session's board instead of an
error, exactly like the saves do.

	The memory fallback is the harness's subject: `test_perks` exercises it as the
	"no DataStore" case (submitting, ordering, the bound, ties) without a Roblox
	runtime, which is the only way that path is ever executed before Studio.
]]
export type OrderedRow = { key: string, value: number }

export type OrderedBackend = {
	kind: string,
	-- One score. `true` when it was recorded; a DataStore write can legitimately
	-- fail (a rate limit), and the caller keeps a session copy either way.
	submit: (key: string, score: number) -> boolean,
	--[[
		The highest `count` entries, highest first, ties broken by key ascending so
		two runs of the same data cannot disagree about the order.

		`nil` means THE READ FAILED - which is not the same as an empty board, and the
		difference matters: a caller that replaced a good board with `{}` on a
		transient store error would show an empty leaderboard during an outage and
		call it read. An in-memory board never fails, so it always returns a table.
	]]
	top: (count: number) -> { OrderedRow }?,
}

local function sanitizeScore(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	if value == math.huge then
		return 0
	end
	local whole = math.floor(value)
	if whole < 0 then
		return 0
	end
	return whole
end

local function rankRows(rows: { OrderedRow }, count: number): { OrderedRow }
	table.sort(rows, function(left: OrderedRow, right: OrderedRow): boolean
		if left.value ~= right.value then
			return left.value > right.value
		end
		-- A tie is broken by the KEY, ascending, which is the only part of a row that
		-- is stable: two reads of the same data must not disagree about the order of
		-- two equal scores.
		return left.key < right.key
	end)

	local bounded: { OrderedRow } = {}
	for index = 1, count do
		local row = rows[index]
		if row == nil then
			break
		end
		bounded[index] = row
	end
	return bounded
end

local function createMemoryOrderedBackend(storeName: string): OrderedBackend
	local memoryScores: { [string]: number } = {}

	return {
		kind = string.format("Memory(%s/ordered-unavailable)", storeName),
		submit = function(key: string, score: number): boolean
			if type(key) ~= "string" or key == "" then
				return false
			end
			local safe = sanitizeScore(score)
			local existing = memoryScores[key]
			-- Never lower a recorded score: a board that can move DOWN when a store
			-- read fails would look like a demotion rather than a stale value.
			if existing == nil or safe > existing then
				memoryScores[key] = safe
			end
			return true
		end,
		top = function(count: number): { OrderedRow }
			local rows: { OrderedRow } = {}
			for key, value in pairs(memoryScores) do
				table.insert(rows, { key = key, value = value })
			end
			return rankRows(rows, math.max(0, math.floor(count)))
		end,
	}
end

local function createDataStoreOrderedBackend(storeName: string): OrderedBackend?
	local service = getDataStoreService()
	if service == nil then
		return nil
	end

	local ok, store = pcall(function()
		return service:GetOrderedDataStore(storeName)
	end)
	if not ok or store == nil then
		return nil
	end

	local orderedStore: any = store

	return {
		kind = "OrderedDataStore",
		submit = function(key: string, score: number): boolean
			if type(key) ~= "string" or key == "" then
				return false
			end
			local success = pcall(function()
				orderedStore:SetAsync(key, sanitizeScore(score))
			end)
			if not success then
				if not warnedAboutDataStore then
					warnedAboutDataStore = true
					warn(string.format(
						"[SaveBackend] Ordered write failed for %s (Studio API access off, or rate limited). "
							.. "The session's board stays in memory.",
						storeName
					))
				end
				return false
			end
			return true
		end,
		top = function(count: number): { OrderedRow }
			local wanted = math.max(0, math.floor(count))
			if wanted == 0 then
				return {}
			end

			local rows: { OrderedRow } = {}
			local success = pcall(function()
				-- ascending = false: highest first. Page size is the bound we want, so
				-- the read cannot pull the whole store into memory.
				local pages = orderedStore:GetSortedAsync(false, wanted)
				for _, row in ipairs(pages:GetCurrentPage()) do
					if type(row) == "table" and type(row.key) == "string" then
						table.insert(rows, { key = row.key, value = sanitizeScore(row.value) })
					end
				end
			end)
			if not success then
				if not warnedAboutDataStore then
					warnedAboutDataStore = true
					warn(string.format(
						"[SaveBackend] Ordered read failed for %s; the last board read stays in use.",
						storeName
					))
				end
				-- NOT an empty board: the caller keeps whatever it last read.
				return nil
			end
			return rankRows(rows, wanted)
		end,
	}
end

local orderedBackends: { [string]: OrderedBackend } = {}

-- One ordered backend per store name, same lazy selection as `Get`, so a failure
-- to open one store never blocks another.
function SaveBackend.GetOrdered(storeName: string): OrderedBackend
	local cached = orderedBackends[storeName]
	if cached ~= nil then
		return cached
	end

	local dataStoreBackend = createDataStoreOrderedBackend(storeName)
	local backend = if dataStoreBackend ~= nil then dataStoreBackend else createMemoryOrderedBackend(storeName)
	orderedBackends[storeName] = backend
	return backend
end

-- =============================================================================
-- Receipt claims (idempotency)
-- =============================================================================

--[[
	Receipts are re-delivered by Roblox until they are granted, and a Studio
	session without DataStore access must still not double-grant. So a claim is
	recorded twice: once in this session's table, and once durably through the
	backend.

	The session flag is set BEFORE the first call that can yield, which makes the
	claim atomic under Luau's cooperative scheduling - a second receipt arriving
	while the first is still awaiting a DataStore read sees the flag and is
	refused rather than racing it.

	Returns true only for the caller that won the claim; that caller grants.
]]
local sessionClaims: { [string]: boolean } = {}

function SaveBackend.ClaimReceipt(backend: Backend, receiptKey: string): boolean
	if sessionClaims[receiptKey] ~= nil then
		return false
	end
	sessionClaims[receiptKey] = true

	local claimedBefore = backend.load(receiptKey)
	if claimedBefore ~= nil then
		return false
	end

	backend.save(receiptKey, {
		receipt = receiptKey,
		claimedAt = os.time(),
	})
	return true
end

function SaveBackend.IsReceiptClaimed(receiptKey: string): boolean
	return sessionClaims[receiptKey] ~= nil
end

return SaveBackend
