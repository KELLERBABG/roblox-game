-- Mock Roblox Environment for Lupa / Python Visualization

local math = math
local table = table

function _IF(cond, t, f)
	if cond then return t else return f end
end

-- Vector3
Vector3 = {}
Vector3.__index = Vector3

function Vector3.new(x, y, z)
	local v = { X = x or 0, Y = y or 0, Z = z or 0 }
	setmetatable(v, Vector3)
	return v
end

function Vector3.__add(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end

function Vector3.__sub(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end

function Vector3.__mul(a, b)
	if type(a) == "number" then
		return Vector3.new(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return Vector3.new(a.X * b, a.Y * b, a.Z * b)
	else
		return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
	end
end

function Vector3.__div(a, b)
	if type(b) == "number" then
		return Vector3.new(a.X / b, a.Y / b, a.Z / b)
	end
	return Vector3.new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end

function Vector3:Lerp(other, alpha)
	alpha = alpha or 0
	return Vector3.new(
		self.X + (other.X - self.X) * alpha,
		self.Y + (other.Y - self.Y) * alpha,
		self.Z + (other.Z - self.Z) * alpha
	)
end

-- Vector2
Vector2 = {}
Vector2.__index = Vector2
function Vector2.new(x, y)
	return { X = x or 0, Y = y or 0 }
end

-- CFrame (3x3 rotation matrix + 3D position)
CFrame = {}
CFrame.__index = CFrame

local function makeMat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return {
		r00 = r00, r01 = r01, r02 = r02,
		r10 = r10, r11 = r11, r12 = r12,
		r20 = r20, r21 = r21, r22 = r22
	}
end

function CFrame.new(...)
	local args = { ... }
	local cf = {
		Position = Vector3.new(0, 0, 0),
		R = makeMat(1, 0, 0, 0, 1, 0, 0, 0, 1)
	}
	setmetatable(cf, CFrame)

	if #args == 0 then
		return cf
	elseif #args == 1 then
		local pos = args[1]
		if type(pos) == "table" and pos.X ~= nil then
			cf.Position = Vector3.new(pos.X, pos.Y, pos.Z)
		end
		return cf
	elseif #args == 3 then
		cf.Position = Vector3.new(args[1], args[2], args[3])
		return cf
	elseif #args == 12 then
		cf.Position = Vector3.new(args[1], args[2], args[3])
		cf.R = makeMat(args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12])
		return cf
	end
	return cf
end

function CFrame.Angles(rx, ry, rz)
	rx, ry, rz = rx or 0, ry or 0, rz or 0
	local cx, sx = math.cos(rx), math.sin(rx)
	local cy, sy = math.cos(ry), math.sin(ry)
	local cz, sz = math.cos(rz), math.sin(rz)

	-- Roblox CFrame.Angles applies rotations in Z * Y * X order:
	local r00 = cy * cz
	local r01 = -cy * sz
	local r02 = sy
	local r10 = cx * sz + sx * sy * cz
	local r11 = cx * cz - sx * sy * sz
	local r12 = -sx * cy
	local r20 = sx * sz - cx * sy * cz
	local r21 = sx * cz + cx * sy * sz
	local r22 = cx * cy

	local cf = CFrame.new()
	cf.R = makeMat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return cf
end

function CFrame.__mul(a, b)
	if type(b) == "table" and b.R ~= nil then
		-- CFrame * CFrame
		local pos = Vector3.new(
			a.Position.X + a.R.r00 * b.Position.X + a.R.r01 * b.Position.Y + a.R.r02 * b.Position.Z,
			a.Position.Y + a.R.r10 * b.Position.X + a.R.r11 * b.Position.Y + a.R.r12 * b.Position.Z,
			a.Position.Z + a.R.r20 * b.Position.X + a.R.r21 * b.Position.Y + a.R.r22 * b.Position.Z
		)
		local R = makeMat(
			a.R.r00 * b.R.r00 + a.R.r01 * b.R.r10 + a.R.r02 * b.R.r20,
			a.R.r00 * b.R.r01 + a.R.r01 * b.R.r11 + a.R.r02 * b.R.r21,
			a.R.r00 * b.R.r02 + a.R.r01 * b.R.r12 + a.R.r02 * b.R.r22,

			a.R.r10 * b.R.r00 + a.R.r11 * b.R.r10 + a.R.r12 * b.R.r20,
			a.R.r10 * b.R.r01 + a.R.r11 * b.R.r11 + a.R.r12 * b.R.r21,
			a.R.r10 * b.R.r02 + a.R.r11 * b.R.r12 + a.R.r12 * b.R.r22,

			a.R.r20 * b.R.r00 + a.R.r21 * b.R.r10 + a.R.r22 * b.R.r20,
			a.R.r20 * b.R.r01 + a.R.r21 * b.R.r11 + a.R.r22 * b.R.r21,
			a.R.r20 * b.R.r02 + a.R.r21 * b.R.r12 + a.R.r22 * b.R.r22
		)
		local cf = CFrame.new()
		cf.Position = pos
		cf.R = R
		return cf
	elseif type(b) == "table" and b.X ~= nil then
		-- CFrame * Vector3
		return Vector3.new(
			a.Position.X + a.R.r00 * b.X + a.R.r01 * b.Y + a.R.r02 * b.Z,
			a.Position.Y + a.R.r10 * b.X + a.R.r11 * b.Y + a.R.r12 * b.Z,
			a.Position.Z + a.R.r20 * b.X + a.R.r21 * b.Y + a.R.r22 * b.Z
		)
	end
	return a
end

-- Color3
Color3 = {}
Color3.__index = Color3
function Color3.fromRGB(r, g, b)
	return { R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255, r = r, g = g, b = b }
end
function Color3.new(r, g, b)
	return { R = r or 0, G = g or 0, B = b or 0, r = math.floor((r or 0) * 255), g = math.floor((g or 0) * 255), b = math.floor((b or 0) * 255) }
end

-- Sequences
ColorSequence = { new = function(...) return {} end }
NumberSequence = { new = function(...) return {} end }
NumberSequenceKeypoint = { new = function(...) return {} end }
NumberRange = { new = function(...) return {} end }

-- Enums
Enum = {
	PartType = { Block = "Block", Ball = "Ball", Cylinder = "Cylinder" },
	SurfaceType = { Smooth = "Smooth" },
	Material = {
		SmoothPlastic = "SmoothPlastic",
		Marble = "Marble",
		Granite = "Granite",
		Slate = "Slate",
		Wood = "Wood",
		Neon = "Neon",
		Metal = "Metal",
		Glass = "Glass",
		ForceField = "ForceField",
		LeafyGrass = "LeafyGrass",
		Cobblestone = "Cobblestone",
	},
	NormalId = { Bottom = "Bottom", Top = "Top" }
}

-- Instance hierarchy
local allParts = {}

local InstanceMeta = {}
InstanceMeta.__index = function(self, key)
	if key == "Position" then
		local cf = rawget(self, "_CFrame")
		if cf then return cf.Position end
		return Vector3.new(0, 0, 0)
	end
	return rawget(self, "_" .. key)
end
InstanceMeta.__newindex = function(self, key, val)
	if key == "Parent" then
		rawset(self, "_Parent", val)
		if val and val._Children then
			table.insert(val._Children, self)
		end
	elseif key == "Position" then
		local cf = rawget(self, "_CFrame") or CFrame.new()
		cf.Position = val
		rawset(self, "_CFrame", cf)
	else
		rawset(self, "_" .. key, val)
	end
end

Instance = {}
function Instance.new(className)
	local inst = {
		_ClassName = className,
		_Name = className,
		_Children = {},
		_Size = Vector3.new(1, 1, 1),
		_CFrame = CFrame.new(0, 0, 0),
		_Color = Color3.fromRGB(163, 162, 165),
		_Material = "SmoothPlastic",
		_Shape = "Block",
		_Transparency = 0,
		_CanCollide = true,
		_CastShadow = true,
	}
	if className == "WedgePart" then
		inst._ClassName = "WedgePart"
	elseif className == "CornerWedgePart" then
		inst._ClassName = "CornerWedgePart"
	end

	function inst:IsA(name)
		if name == "BasePart" then
			return inst._ClassName == "Part" or inst._ClassName == "WedgePart" or inst._ClassName == "CornerWedgePart" or inst._ClassName == "SpawnLocation"
		end
		return inst._ClassName == name
	end

	function inst:FindFirstChild(name, recursive)
		for _, child in ipairs(inst._Children) do
			if child._Name == name then
				return child
			end
			if recursive and child.FindFirstChild then
				local found = child:FindFirstChild(name, true)
				if found then return found end
			end
		end
		return nil
	end

	function inst:WaitForChild(name, timeout)
		return inst:FindFirstChild(name, false) or Instance.new("Folder")
	end

	setmetatable(inst, InstanceMeta)

	if inst:IsA("BasePart") then
		table.insert(allParts, inst)
	end

	return inst
end

Workspace = Instance.new("Folder")
Workspace._Name = "Workspace"

script = Instance.new("Folder")
script._Name = "Script"
script.Parent = Instance.new("Folder")
script.Parent.Parent = Instance.new("Folder")

local mockDecals = {
	Textures = { SakuraPetal = "rbxassetid://1" },
	ColorSequenceGradient = function(...) return {} end,
}

function require(mod)
	return mockDecals
end

game = {
	GetService = function(self, name)
		if name == "Workspace" then return Workspace end
		if name == "RunService" then
			return {
				Heartbeat = { Connect = function() end }
			}
		end
		return {}
	end
}

return {
	allParts = allParts,
	Workspace = Workspace
}
