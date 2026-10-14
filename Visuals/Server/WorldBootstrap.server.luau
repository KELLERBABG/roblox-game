--!strict
--[[
	Visuals.Server.WorldBootstrap
	=============================
	Server-authoritative world initializer. Ensures the floating celestial sanctuary
	island, altar, obby, and spawn point are generated in Workspace on startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local visualsModule = ReplicatedStorage:WaitForChild("Visuals", 30)
if visualsModule == nil then
	error("[WorldBootstrap] ReplicatedStorage.Visuals missing.")
end

local Visuals = require(visualsModule :: ModuleScript)

-- Instantiate physical world into Workspace
local worldFolder = Visuals.World.EnsureWorld()

print(string.format(
	"[WorldBootstrap] Sol's Sanctuary loaded. Island, Altar, Spire, Grotto, and Obby active in Workspace.%s",
	worldFolder.Name
))
