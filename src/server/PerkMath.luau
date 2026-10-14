--!strict
--[[
	PerkMath
	========
	The pure half of the monetization layer: how owned perks and consumables
	combine into the numbers a roll uses.

	NO ROBLOX, NO STATE, NO NUMBERS OF ITS OWN. Every multiplier, duration and
	price comes from MonetizationConfig; this module owns only the rules - fold
	the owned entries, multiply the contributions, and spend a potion charge on
	exactly one roll. That split is why a balance change is always a config edit,
	and why there is no second copy of "2x" or "-40%" to fall out of sync.

	The Lune harness executes all of it, which is the only way to prove claims
	like "the potion is consumed by exactly one roll" without a Roblox runtime.
	PerkService owns the state and calls in here; RNGService only ever sees the
	resulting numbers, and only through PerkService.
]]

-- The shape PerkMath needs from a config entry. Structural on purpose, so this
-- module never has to require the config (and stays loadable on its own).
export type PerkEntry = {
	key: string,
	luckMultiplier: number?,
	cooldownMultiplier: number?,
	unlocksAutoRoll: boolean?,
	givesNametag: boolean?,
}

export type Contributions = {
	luckMultiplier: number,
	cooldownMultiplier: number,
	unlocksAutoRoll: boolean,
	givesNametag: boolean,
}

export type Effects = {
	luckMultiplier: number,
	cooldownMultiplier: number,
	autoRollUnlocked: boolean,
	vipNametag: boolean,
}

-- An armed potion, or an empty one. `charges` is how many rolls it still pays
-- for; the potion product grants exactly one.
export type PotionState = {
	charges: number,
	multiplier: number,
}

local PerkMath = {}

function PerkMath.NoContributions(): Contributions
	return {
		luckMultiplier = 1,
		cooldownMultiplier = 1,
		unlocksAutoRoll = false,
		givesNametag = false,
	}
end

--[[
	Contributions(entries, owned)

	Folds the owned config entries into one bundle. A missing or non-positive
	multiplier contributes nothing rather than a surprise zero, so a typo in the
	config degrades to "no bonus" instead of "no luck at all".
]]
function PerkMath.Contributions(entries: { PerkEntry }, owned: { [string]: boolean }): Contributions
	local result = PerkMath.NoContributions()

	for _, entry in ipairs(entries) do
		if owned[entry.key] == true then
			local luck = entry.luckMultiplier
			if type(luck) == "number" and luck > 0 then
				result.luckMultiplier *= luck
			end

			local cooldown = entry.cooldownMultiplier
			if type(cooldown) == "number" and cooldown > 0 then
				result.cooldownMultiplier *= cooldown
			end

			if entry.unlocksAutoRoll == true then
				result.unlocksAutoRoll = true
			end
			if entry.givesNametag == true then
				result.givesNametag = true
			end
		end
	end

	return result
end

--[[
	Combine(contributions, potion, serverBoostMultiplier)

	Multipliers MULTIPLY, so the stacking is legible in one glance and in one
	place: 2x Luck * VIP 1.25 * potion 6 * server boost 2 = 30x. The neutral case
	is exactly 1.0, not an approximation of it.
]]
function PerkMath.Combine(
	contributions: Contributions,
	potion: PotionState?,
	serverBoostMultiplier: number?
): Effects
	local luck = contributions.luckMultiplier

	if PerkMath.IsArmed(potion) then
		luck *= (potion :: PotionState).multiplier
	end

	local boost = serverBoostMultiplier or 1
	if boost > 1 then
		luck *= boost
	end

	return {
		luckMultiplier = luck,
		cooldownMultiplier = contributions.cooldownMultiplier,
		autoRollUnlocked = contributions.unlocksAutoRoll,
		vipNametag = contributions.givesNametag,
	}
end

function PerkMath.EmptyPotion(): PotionState
	return { charges = 0, multiplier = 1 }
end

function PerkMath.ArmPotion(multiplier: number, charges: number): PotionState
	local safeCharges = math.max(0, math.floor(charges))
	local safeMultiplier = if multiplier > 1 then multiplier else 1
	return { charges = safeCharges, multiplier = safeMultiplier }
end

function PerkMath.IsArmed(potion: PotionState?): boolean
	return potion ~= nil and potion.charges > 0 and potion.multiplier > 1
end

--[[
	RollPotion(potion)

	The whole consumable rule, in one pure step: the multiplier this roll may use,
	and the state that follows it. An armed potion pays for the roll it was armed
	for and is then empty, so calling this twice yields the buff once and nothing
	afterwards.

	Spending lives here rather than inside a "read the multiplier" helper on
	purpose: the multiplier is read by the state sync, the attribute publish and
	the telemetry line as well as by the roll, and a potion must not be spent by a
	UI refresh.
]]
function PerkMath.RollPotion(potion: PotionState?): (number, PotionState)
	local active = potion
	if active == nil or active.charges <= 0 then
		return 1, active or PerkMath.EmptyPotion()
	end

	local spentMultiplier = if active.multiplier > 1 then active.multiplier else 1
	local remaining = active.charges - 1

	return spentMultiplier, {
		charges = remaining,
		multiplier = if remaining > 0 then active.multiplier else 1,
	}
end

-- Server-wide boost bookkeeping, also pure so expiry can be asserted.
function PerkMath.BoostMultiplier(activeMultiplier: number, endsAtClock: number, nowClock: number): number
	if activeMultiplier > 1 and nowClock < endsAtClock then
		return activeMultiplier
	end
	return 1
end

function PerkMath.BoostSecondsRemaining(endsAtClock: number, nowClock: number): number
	local remaining = endsAtClock - nowClock
	return if remaining > 0 then remaining else 0
end

return PerkMath
