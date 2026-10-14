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
