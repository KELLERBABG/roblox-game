--!strict
--[[
	Visuals.World.Interactive
	=========================
	Handles interactive gameplay shrines and world props in Sol's Sanctuary:
	  * Cauldron of Fortune (Grants +0.5x Luck Bonus when brewed)
	  * Peak of Fortune Obby Altar (Grants +1.0x Luck Bonus and victory particles)
	  * Roll Altar Pulse (Expands and glows when a roll takes place)
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Interactive = {}

local activeBuffs: { [number]: { [string]: number } } = {}

-- Utility to safely apply or extend a player's temporary luck bonus
local function grantTemporaryLuck(player: Player, buffName: string, amount: number, durationSeconds: number)
	local userId = player.UserId
	if activeBuffs[userId] == nil then
		activeBuffs[userId] = {}
	end

	local now = os.clock()
	activeBuffs[userId][buffName] = now + durationSeconds

	-- Recalculate total LuckBonus attribute
	local totalBonus = 0
	for _, expiry in pairs(activeBuffs[userId]) do
		if expiry > now then
			totalBonus += amount
		end
	end

	player:SetAttribute("LuckBonus", totalBonus)

	task.delay(durationSeconds, function()
		if activeBuffs[userId] ~= nil and (activeBuffs[userId][buffName] or 0) <= os.clock() then
			activeBuffs[userId][buffName] = nil
			local remBonus = 0
			for _, exp in pairs(activeBuffs[userId]) do
				if exp > os.clock() then
					remBonus += amount
				end
			end
			player:SetAttribute("LuckBonus", remBonus)
		end
	end)
end

-- Wires up triggers on the world instances
function Interactive.WireTriggers(worldRoot: Folder): ()
	-- 1. Cauldron in Mystic Grotto
	local cauldronLiquid = worldRoot:FindFirstChild("CauldronLiquid", true)
	if cauldronLiquid ~= nil and cauldronLiquid:IsA("BasePart") then
		local cdPart = cauldronLiquid :: BasePart
		cdPart.Touched:Connect(function(hit: BasePart)
			local char = hit.Parent
			if char == nil then return end
			local player = Players:GetPlayerFromCharacter(char)
			if player ~= nil then
				grantTemporaryLuck(player, "StellaBrew", 0.5, 60)
			end
		end)
	end

	-- 2. Peak of Fortune Altar
	local treasureAltar = worldRoot:FindFirstChild("TreasureAltar", true)
	if treasureAltar ~= nil and treasureAltar:IsA("BasePart") then
		local altarPart = treasureAltar :: BasePart
		altarPart.Touched:Connect(function(hit: BasePart)
			local char = hit.Parent
			if char == nil then return end
			local player = Players:GetPlayerFromCharacter(char)
			if player ~= nil then
				grantTemporaryLuck(player, "ObbyReward", 1.0, 120)

				-- Victory spark burst
				local emitter = Instance.new("ParticleEmitter")
				emitter.Color = ColorSequence.new(Color3.fromRGB(255, 215, 0), Color3.fromRGB(255, 255, 255))
				emitter.Size = NumberSequence.new(0.6, 0)
				emitter.Speed = NumberRange.new(12, 24)
				emitter.Lifetime = NumberRange.new(0.5, 1.0)
				emitter.SpreadAngle = Vector2.new(180, 180)
				emitter.Rate = 0
				emitter.Parent = altarPart
				emitter:Emit(40)
				task.delay(1.5, function()
					emitter:Destroy()
				end)
			end
		end)
	end
end

-- Pulses the central roll altar ring
function Interactive.PulseAltar(worldRoot: Folder, color: Color3): ()
	local summonRune = worldRoot:FindFirstChild("SummonRuneDisc", true)
	if summonRune ~= nil and summonRune:IsA("BasePart") then
		local runePart = summonRune :: BasePart
		runePart.Color = color
		runePart.Transparency = 0.05

		TweenService:Create(runePart, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 0.35,
		}):Play()
	end
end

return Interactive
