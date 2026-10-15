--!strict
--[[
	InventoryMath
	=============
	The pure half of inventory mutation: what "delete one copy" means, and when it
	is refused.

	WHY IT IS SEPARATE FROM THE HANDLER THAT USES IT: the same reason PerkMath is
	separate from PerkService. The rule has edges - nothing owned, one copy left,
	a corrupted count, a count so large it cannot be real - and there is no Roblox
	runtime in the harness to try them on. Here they are plain numbers, so the Lune
	harness executes every edge instead of reading the handler and hoping.

	RNGService owns the state and the remote; this module owns only the arithmetic
	of taking one away. It mutates nothing: it takes a count and answers.

	ONE COPY, NEVER A STACK. Deleting always removes exactly one, so a player with
	412 Embers who presses X has 411 - they cannot lose the lot by mis-clicking.
	Refusal is the other half of the contract: a count of zero (or a count that is
	not a positive number at all) is not deletable, which is what makes a stale
	grid unable to delete anything it does not actually own.
]]

local InventoryMath = {}

--[[
	RemoveOne(owned) -> (removed, remaining)

	`removed` is false only when there was nothing to remove, in which case
	`remaining` is 0 and the caller must change nothing. `remaining` is always a
	whole number: a fractional count from a damaged save is floored rather than
	propagated, and a non-number (nil, a string, a NaN) is treated as nothing
	owned.
]]
function InventoryMath.RemoveOne(owned: any): (boolean, number)
	if type(owned) ~= "number" or owned ~= owned then
		return false, 0
	end
	if owned < 1 then
		return false, 0
	end

	local whole = math.floor(owned)
	if whole < 1 then
		return false, 0
	end

	return true, whole - 1
end

-- The count a delete leaves behind, or nil when the last copy is gone and the
-- entry should stop existing in the save. Kept here so the handler does not have
-- to remember which of the two is which.
function InventoryMath.KeySurvives(remaining: number): boolean
	return remaining > 0
end

return InventoryMath
