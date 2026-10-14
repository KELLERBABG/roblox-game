--!strict
--[[
	Visuals.Client.WorldClient
	==========================
	Client-side environmental controller.
	Applies midnight cosmic atmosphere, bloom lighting, shooting stars, and ambient audio.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local visualsModule = ReplicatedStorage:WaitForChild("Visuals", 30)
if visualsModule == nil then
	error("[WorldClient] ReplicatedStorage.Visuals missing.")
end

local Visuals = require(visualsModule :: ModuleScript)

-- Ensure physical world is visible and start client atmosphere
Visuals.World.EnsureWorld()
Visuals.World.StartClientAmbience()

print("[WorldClient] Sol's Sanctuary environmental ambience & shooting stars online.")
