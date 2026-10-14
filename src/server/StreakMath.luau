--!strict
--[[
	StreakMath
	==========
	The session-streak curve: the passive luck a player earns by staying in the
	server, and nothing else.

	RNGService owns the session clock (it already owns every other piece of
	per-player session state); this module owns only the shape of the reward. Pure
	Luau, no Roblox, no state - so the Lune harness executes the curve and pins it
	instead of trusting it.

	A STAIRCASE, ON PURPOSE. A continuous ramp would be invisible in the HUD and
	untestable ("luck rose by how much, exactly?"); whole levels give the counter
	something to visibly step, the bar something to visibly fill, and the harness
	an exact boundary to assert. Luck is the ONLY thing a streak grants - it never
	touches the cooldown, the pity window, or the guaranteed pull.

	NOT PERSISTED, also on purpose: the streak measures time spent in THIS
	server, the way auto-roll deliberately does not survive a rejoin. Leaving and
	returning starts the clock again.

	WHERE IT PLUGS IN: RNGService multiplies its result inside `getLuckMultiplier`,
	the single luck point, so the roll path remains the only reader.
]]

export type StreakSnapshot = {
	seconds: number,
	level: number,
	maxLevel: number,
	levelSeconds: number,
	levelProgress: number,
	secondsToNextLevel: number,
	luckMultiplier: number,
	capped: boolean,
}

local CONSTANTS = {
	-- Live: one level per two minutes of presence, capped at fifteen levels
	-- (thirty minutes), +5% luck per level. That is 1.00x at the moment of
	-- joining and 1.75x at the cap.
	levelSeconds = 120,
	maxLevel = 15,
	luckPerLevel = 0.05,

	-- Studio only: the SAME curve against a twelve-times faster clock, so a
	-- playtest can watch the counter step and the bar fill without idling for
	-- half an hour. Same shape and same reward per level - only the clock differs.
	studioLevelSeconds = 10,
}

local StreakMath = {}

-- A non-number, a NaN or a negative duration is "no time served", and a runaway
-- duration is the cap: this is fed by an engine clock inside a hot path, so it
-- has to be total rather than throw.
local function sanitizeSeconds(value: number): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	if value < 0 then
		return 0
	end
	return value
end

local function sanitizeInterval(value: number): number
	if type(value) ~= "number" or value ~= value or value <= 0 then
		return CONSTANTS.levelSeconds
	end
	return value
end

-- The clock to run a session on. Live servers get the real one; Studio gets the
-- accelerated one so the curve is observable in a playtest.
function StreakMath.ClockSeconds(studio: boolean): number
	return if studio then CONSTANTS.studioLevelSeconds else CONSTANTS.levelSeconds
end

function StreakMath.Level(streakSeconds: number, levelSeconds: number?): number
	local interval = sanitizeInterval(levelSeconds or CONSTANTS.levelSeconds)
	local seconds = sanitizeSeconds(streakSeconds)

	local level = math.floor(seconds / interval)
	if level < 0 then
		return 0
	end
	if level > CONSTANTS.maxLevel then
		return CONSTANTS.maxLevel
	end
	return level
end

--[[
	LuckMultiplier(streakSeconds, levelSeconds?)

	1.00x at level 0, +5% per level, capped with the level. Additive on top of
	1.0 rather than exponential: `1 + 0.05 * level` is readable straight off the
	HUD ("level 4 -> +20% luck") and cannot quietly outgrow the perk multipliers
	it stacks with.
]]
function StreakMath.LuckMultiplier(streakSeconds: number, levelSeconds: number?): number
	return 1 + CONSTANTS.luckPerLevel * StreakMath.Level(streakSeconds, levelSeconds)
end

--[[
	Snapshot(streakSeconds, levelSeconds?)

	Everything the server publishes and the HUD renders, computed in one place so
	the counter, the bar and the luck number can never disagree.

	`seconds` is reported AT THE CAP once the streak maxes out. That is the honest
	reading (the reward stops growing there) and it also means an infinite or
	absurd duration can never reach a RemoteEvent.
]]
function StreakMath.Snapshot(streakSeconds: number, levelSeconds: number?): StreakSnapshot
	local interval = sanitizeInterval(levelSeconds or CONSTANTS.levelSeconds)
	local capSeconds = CONSTANTS.maxLevel * interval

	local served = sanitizeSeconds(streakSeconds)
	local effective = if served > capSeconds then capSeconds else served

	local level = StreakMath.Level(effective, interval)
	local capped = level >= CONSTANTS.maxLevel
	local secondsIntoLevel = effective - level * interval

	return {
		seconds = effective,
		level = level,
		maxLevel = CONSTANTS.maxLevel,
		levelSeconds = interval,
		levelProgress = if capped then 1 else secondsIntoLevel / interval,
		secondsToNextLevel = if capped then 0 else interval - secondsIntoLevel,
		-- Delegated, never re-derived: a second copy of `1 + perLevel * level` in
		-- here would let the published luck and the standalone accessor drift apart,
		-- and a negative control showed exactly that (flattening LuckMultiplier left
		-- this field still reporting the old cap).
		luckMultiplier = StreakMath.LuckMultiplier(effective, interval),
		capped = capped,
	}
end

-- Exposed for the harness and for anything that needs to reason about the curve
-- without duplicating its numbers (RollMath.Constants is exposed the same way).
StreakMath.Constants = CONSTANTS

return StreakMath
