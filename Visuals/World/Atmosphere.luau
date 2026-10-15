--!strict
--[[
	Visuals.World.Atmosphere
	========================
	Balanced cosmic celestial lighting engine for Sol's Sanctuary.
	Eliminates neon white-out glare while preserving rich bioluminescence,
	crisp moonlight architectural contrast, and shooting star streaks.
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Atmosphere = {}

function Atmosphere.ApplyLighting(): ()
	-- Crisp twilight/moonlit angle so marble, grass, and rock crevices have 3D shading
	Lighting.ClockTime = 21.2
	Lighting.GeographicLatitude = 32
	Lighting.Brightness = 2.0
	Lighting.OutdoorAmbient = Color3.fromRGB(78, 90, 135)
	Lighting.Ambient = Color3.fromRGB(52, 60, 95)
	Lighting.ColorShift_Top = Color3.fromRGB(175, 205, 255)
	Lighting.ColorShift_Bottom = Color3.fromRGB(55, 45, 95)
	Lighting.ExposureCompensation = 0.05
	Lighting.EnvironmentDiffuseScale = 0.85
	Lighting.EnvironmentSpecularScale = 0.9
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.25

	-- High-Resolution 4K Nebula Space Skybox
	local existingSky = Lighting:FindFirstChildOfClass("Sky")
	local sky = existingSky or Instance.new("Sky")
	sky.Name = "CelestialNebulaSky"
	sky.SkyboxBk = "rbxassetid://171410628"
	sky.SkyboxDn = "rbxassetid://171410649"
	sky.SkyboxFt = "rbxassetid://171410620"
	sky.SkyboxLf = "rbxassetid://171410666"
	sky.SkyboxRt = "rbxassetid://171410657"
	sky.SkyboxUp = "rbxassetid://171410636"
	sky.StarCount = 5000
	sky.MoonAngularSize = 14
	sky.CelestialBodiesShown = true
	sky.Parent = Lighting

	-- Ethereal Celestial God-Rays (Moonlight Beams)
	local existingSunRays = Lighting:FindFirstChildOfClass("SunRaysEffect")
	local sunRays = (existingSunRays or Instance.new("SunRaysEffect")) :: SunRaysEffect
	sunRays.Name = "CelestialSunRays"
	sunRays.Intensity = 0.16
	sunRays.Spread = 0.72
	sunRays.Enabled = true
	sunRays.Parent = Lighting

	-- Dreamy Deep-Indigo Horizon Haze
	local existingAtmo = Lighting:FindFirstChildOfClass("Atmosphere")
	local atmo = existingAtmo or Instance.new("Atmosphere")
	atmo.Density = 0.28
	atmo.Offset = 0.15
	atmo.Color = Color3.fromRGB(58, 65, 115)
	atmo.Decay = Color3.fromRGB(28, 24, 58)
	atmo.Glare = 0.12
	atmo.Haze = 1.6
	atmo.Parent = Lighting

	-- Controlled Soft Bloom (prevents neon parts from blowing out into solid white)
	local existingBloom = Lighting:FindFirstChild("CelestialBloom")
	local bloom = (existingBloom or Instance.new("BloomEffect")) :: BloomEffect
	bloom.Name = "CelestialBloom"
	bloom.Intensity = 0.42
	bloom.Size = 36
	bloom.Threshold = 0.95
	bloom.Enabled = true
	bloom.Parent = Lighting

	-- Rich Cinematic Color Grading
	local existingCC = Lighting:FindFirstChild("CelestialCC")
	local cc = (existingCC or Instance.new("ColorCorrectionEffect")) :: ColorCorrectionEffect
	cc.Name = "CelestialCC"
	cc.Brightness = 0.03
	cc.Contrast = 0.14
	cc.Saturation = 0.22
	cc.TintColor = Color3.fromRGB(242, 246, 255)
	cc.Enabled = true
	cc.Parent = Lighting
end

-- Spawns a shooting star beam across the sky
function Atmosphere.SpawnShootingStar(): ()
	local camera = Workspace.CurrentCamera
	local originPos = if camera ~= nil
		then camera.CFrame.Position + Vector3.new(math.random(-180, 180), 130 + math.random(0, 50), math.random(-180, 180))
		else Vector3.new(0, 150, 0)

	local endPos = originPos + Vector3.new(math.random(-110, 110), -45, math.random(-110, 110))

	local starPart = Instance.new("Part")
	starPart.Name = "ShootingStar"
	starPart.Shape = Enum.PartType.Ball
	starPart.Size = Vector3.new(0.7, 0.7, 0.7)
	starPart.CFrame = CFrame.new(originPos)
	starPart.Material = Enum.Material.Neon
	starPart.Color = Color3.fromRGB(220, 240, 255)
	starPart.Anchored = true
	starPart.CanCollide = false
	starPart.CanTouch = false
	starPart.CanQuery = false
	starPart.CastShadow = false
	starPart.Parent = Workspace

	local att0 = Instance.new("Attachment")
	att0.Position = Vector3.new(0, 0, 0.35)
	att0.Parent = starPart

	local att1 = Instance.new("Attachment")
	att1.Position = Vector3.new(0, 0, -0.35)
	att1.Parent = starPart

	local trail = Instance.new("Trail")
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(130, 195, 255))
	trail.Transparency = NumberSequence.new(0, 1)
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.Lifetime = 0.55
	trail.LightEmission = 1
	trail.Parent = starPart

	local duration = 0.8 + math.random() * 0.45
	local tween = TweenService:Create(starPart, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(endPos),
	})
	tween:Play()
	tween.Completed:Once(function()
		task.wait(0.6)
		starPart:Destroy()
	end)
end

function Atmosphere.StartShootingStarCycle(): ()
	task.spawn(function()
		while true do
			task.wait(3.5 + math.random() * 5.0)
			Atmosphere.SpawnShootingStar()
		end
	end)
end

return Atmosphere
