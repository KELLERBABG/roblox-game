--!strict
--[[
	ServerRemotes
	=============
	One owner for the "find the Remotes folder, reuse the remote if it already
	exists" plumbing that every server module needs.

	Why it exists: RNGService, PerkService and ShopService all publish remotes
	into ReplicatedStorage.Remotes, and the client reaches them by name with
	WaitForChild. Three copies of that create-or-reuse logic is three chances for
	a script to spell a folder differently and leave a client waiting forever.
	Here it is written once and every module asks for a remote by name.

	Creation is idempotent, so load order does not matter and a place file that
	already contains these remotes keeps them untouched.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ServerRemotes = {}

local function remotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing ~= nil then
		return existing :: Folder
	end

	local created = Instance.new("Folder") :: Folder
	created.Name = "Remotes"
	created.Parent = ReplicatedStorage
	return created
end

function ServerRemotes.EnsureRemote(className: string, name: string): Instance
	local folder = remotesFolder()

	local existing = folder:FindFirstChild(name)
	if existing ~= nil then
		return existing
	end

	local created = Instance.new(className)
	created.Name = name
	created.Parent = folder
	return created
end

return ServerRemotes
