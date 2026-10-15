--!strict
--[[
	AuraFilter
	==========
	The auto-filter's entire policy, in one pure place: which rungs a player may
	choose between, what a chosen threshold means for one pull, and how a junk
	setting from a client or an old save degrades.

	WHY IT LIVES HERE, AND WHY IT IS PURE: the decision has to happen inside the
	single roll path (RNGService.resolveRoll), after the draw and before anything
	reaches the inventory. Keeping it free of Roblox and of state means the Lune
	harness executes the real policy instead of inspecting it, and that the server
	is the only caller - a client can ask for a filter, never apply one.

	THE THRESHOLD IS THE LADDER. Rungs() derives the selectable thresholds from
	AuraRegistry's own ORDER + Get, so the control can only ever offer rungs that
	exist. There is no second tier list to keep in sync: add an aura to
	AuraLadder and the filter offers it.

	"BELOW" MEANS STRICTLY BELOW. A pull at exactly the chosen rung is kept; only
	less-rare pulls are suppressed. Modes:
	  * "off"    - nothing is filtered (the default, and the state before a player
	               ever touches the control).
	  * "skip"   - a below-threshold pull never enters the inventory, and is not
	               tallied per aura: the AFK farmer's quiet mode.
	  * "delete" - the same suppression, but the throwaway is tallied per aura so
	               the panel can say how much the filter has eaten.

	WHAT IT DELIBERATELY DOES NOT TOUCH: the draw, the odds, the pity counter and
	the roll's rarity tally. The filter is a storage-and-notification policy, so a
	suppressed pull advances pity exactly like a kept one. A filter that changed
	the pity outcome would be a second, hidden balance system - and RNGService
	applies this only after the pity bookkeeping precisely so that cannot happen.
]]

-- One selectable rung: a rarity that exists on the ladder, with the label data
-- the panel renders. Structural, so this module never has to require the
-- registry and the harness can feed it anything with the same shape.
export type Rung = {
	rarity: number,
	tier: string,
	auraId: string,
	displayName: string,
}

-- The slice of AuraRegistry.Rungs need. Structural for the same reason.
export type RungSource = {
	ORDER: { string },
	Get: (string) -> any?,
}

local AuraFilter = {}

-- Values, not annotated fields: Luau rejects a type annotation on a table field
-- assignment, so the annotation lives in the type above and the values here.
AuraFilter.OFF = "off"
AuraFilter.SKIP = "skip"
AuraFilter.DELETE = "delete"

-- Not a mode: the answer Decide returns for a pull that is kept. Separate from
-- the modes so a caller cannot mistake "keep" for something a client can set.
AuraFilter.KEEP = "keep"

AuraFilter.MODES = { AuraFilter.OFF, AuraFilter.SKIP, AuraFilter.DELETE }

-- 0 means "no threshold". Also what a save with no filter field loads as.
AuraFilter.NO_THRESHOLD = 0

-- =============================================================================
-- The ladder, as filter options
-- =============================================================================

--[[
	Rungs(source)

	Every rung of the ladder, ascending rarity. ORDER is already sorted that way
	by AuraRegistry, and each id is resolved through Get so an entry that has been
	removed from the ladder simply stops being offered.

	A rarity is offered once: if two auras ever claimed the same rarity (the
	registry's own integrity guard already refuses that at load), the filter would
	still show one option rather than two identical ones.
]]
function AuraFilter.Rungs(source: RungSource): { Rung }
	local rungs: { Rung } = {}
	local seen: { [number]: boolean } = {}

	for _, auraId in ipairs(source.ORDER) do
		local config = source.Get(auraId)
		if config ~= nil then
			local rarity = (config :: any).rarity
			if type(rarity) == "number" and rarity > 0 and rarity == rarity then
				if seen[rarity] ~= true then
					seen[rarity] = true
					table.insert(rungs, {
						rarity = rarity,
						tier = tostring((config :: any).tier or ""),
						auraId = auraId,
						displayName = tostring((config :: any).displayName or auraId),
					})
				end
			end
		end
	end

	table.sort(rungs, function(left: Rung, right: Rung): boolean
		return left.rarity < right.rarity
	end)

	return rungs
end

--[[
	IsRung(value, rungs)

	Exact membership, not a range check: a threshold has to be one of the offered
	rungs. This is what makes "the client cannot invent a threshold" true rather
	than aspirational - 499 is refused even though it sits between two rungs.
]]
function AuraFilter.IsRung(value: number, rungs: { Rung }): boolean
	for _, rung in ipairs(rungs) do
		if rung.rarity == value then
			return true
		end
	end
	return false
end

-- The rung at a rarity, or nil when that rarity is not offered.
function AuraFilter.RungAt(rarity: number, rungs: { Rung }): Rung?
	for _, rung in ipairs(rungs) do
		if rung.rarity == rarity then
			return rung
		end
	end
	return nil
end

-- =============================================================================
-- Sanitizing (two callers, two different fallbacks - on purpose)
-- =============================================================================

--[[
	SanitizeMode(value, fallback)

	Returns `fallback` for anything that is not one of the three modes. The save
	path passes AuraFilter.OFF (an old or damaged save loads as "no filter"); the
	remote handler passes nil (a client sending junk gets no change at all).
]]
function AuraFilter.SanitizeMode(value: any, fallback: string?): string?
	if type(value) ~= "string" then
		return fallback
	end
	for _, mode in ipairs(AuraFilter.MODES) do
		if mode == value then
			return mode
		end
	end
	return fallback
end

--[[
	SanitizeThreshold(value, rungs)

	0 for anything that is not an offered rung - including a NaN, a string, a
	negative number and a rarity that is not on the ladder. Never throws: this is
	fed by a save file and by a remote.
]]
function AuraFilter.SanitizeThreshold(value: any, rungs: { Rung }): number
	if type(value) ~= "number" or value ~= value or value <= 0 then
		return AuraFilter.NO_THRESHOLD
	end
	local floored = math.floor(value)
	if floored ~= value then
		return AuraFilter.NO_THRESHOLD
	end
	if AuraFilter.IsRung(floored, rungs) then
		return floored
	end
	return AuraFilter.NO_THRESHOLD
end

-- =============================================================================
-- The decision
-- =============================================================================

--[[
	Decide(mode, threshold, rarity)

	The whole rule, in one call: keep, skip or delete.

	Two things return KEEP deliberately rather than failing open into a delete:
	  * no filter (mode "off", or a zero threshold), and
	  * a rarity the caller could not read (nil, a string, a NaN).

	An unreadable rarity must never be destroyed, so the failure direction is to
	keep it.
]]
function AuraFilter.Decide(mode: string, threshold: number, rarity: any): string
	local action = AuraFilter.SanitizeMode(mode, AuraFilter.OFF)
	if action == AuraFilter.OFF or action == nil then
		return AuraFilter.KEEP
	end

	if type(threshold) ~= "number" or threshold ~= threshold or threshold <= 0 then
		return AuraFilter.KEEP
	end

	if type(rarity) ~= "number" or rarity ~= rarity then
		return AuraFilter.KEEP
	end

	if rarity < threshold then
		return action
	end

	return AuraFilter.KEEP
end

-- True when the answer is not KEEP. Callers read better with this than with a
-- comparison against KEEP inlined at every call site.
function AuraFilter.Suppresses(action: string): boolean
	return action ~= AuraFilter.KEEP
end

return AuraFilter
