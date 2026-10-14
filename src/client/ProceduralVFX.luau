--!strict
--[[
	ProceduralVFX (client)
	======================
	A modular, fully procedural VFX engine. It builds every visual at runtime -
	no mesh, no pre-made ScreenGui, no particle authored in Studio.

	Contract with the server
	------------------------
	The server only ever publishes `Player:SetAttribute("EquippedAura", auraId)`.
	This module watches that attribute for *every* player, tears down the previous
	effect and rebuilds a brand new one from AuraRegistry data.

	Rendering model
	---------------
	  * ONE centralized `RunService.RenderStepped` connection drives every orbit,
	    trail and shard rotation for every player. There is no per-player loop.
	  * Orbiting shards are Lissajous-modulated rings: a tilted, precessing ring
	    frame with a per-shard harmonic vertical offset and a breathing radius.
	  * Camera shake is the single exception to that loop and is deliberately
	    bound through `BindToRenderStep` at `RenderPriority.Camera + 1`, because
	    the default camera script overwrites `Camera.CFrame` at priority 200 and
	    would otherwise erase a shake applied from RenderStepped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local sharedInstance = ReplicatedStorage:WaitForChild("Shared", 30)
if sharedInstance == nil then
	error("[ProceduralVFX] ReplicatedStorage.Shared is missing.")
end
local auraRegistryModule = (sharedInstance :: Folder):WaitForChild("AuraRegistry", 30)
if auraRegistryModule == nil then
	error("[ProceduralVFX] Shared.AuraRegistry is missing.")
end

local AuraRegistry: any = require(auraRegistryModule :: ModuleScript)

local TAU: number = math.pi * 2
local VFX_ROOT_NAME: string = "AuraVFX_Runtime"
local SHAKE_BINDING_NAME: string = "AuraRollCameraShake"

-- =============================================================================
-- Types
-- =============================================================================

type Effect = {
	player: Player,
	auraId: string,
	materialized: any,
	container: Folder,
	anchor: Part,
	light: PointLight,
	highlight: Highlight,
	emitters: { ParticleEmitter },
	shards: { Part },
	trails: { Trail },
	spins: { number },
	phase: number,
	root: BasePart?,
	suppressed: boolean,
}

type Watcher = {
	attribute: RBXScriptConnection,
	characterAdded: RBXScriptConnection,
	characterRemoving: RBXScriptConnection,
}

-- =============================================================================
-- Module state
-- =============================================================================

local ProceduralVFX = {}

local effects: { [Player]: Effect } = {}
local effectList: { Effect } = {}
local watchers: { [Player]: Watcher } = {}
local buildTokens: { [Player]: number } = {}

local localPlayerCache: Player? = nil
local lowSpecMode: boolean = false
local started: boolean = false
local renderConnection: RBXScriptConnection? = nil
local vfxRoot: Folder? = nil

local shakeBound: boolean = false
local shakeMagnitude: number = 0
local shakeDuration: number = 0
local shakeEndClock: number = 0

local fovRestoreValue: number? = nil
local colorCorrection: ColorCorrectionEffect? = nil

-- =============================================================================
-- Small helpers
-- =============================================================================

local function getLocalPlayer(): Player?
	local cached = localPlayerCache
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end
	local resolved: Player? = Players.LocalPlayer
	localPlayerCache = resolved
	return resolved
end

local function getVFXRuntimeRoot(): Folder
	local cached = vfxRoot
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end
	local existing = Workspace:FindFirstChild(VFX_ROOT_NAME)
	if existing ~= nil then
		local folder = existing :: Folder
		vfxRoot = folder
		return folder
	end
	local created = Instance.new("Folder") :: Folder
	created.Name = VFX_ROOT_NAME
	created.Parent = Workspace
	vfxRoot = created
	return created
end

local function resolveRoot(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local rootInstance = character:FindFirstChild("HumanoidRootPart")
	if rootInstance == nil then
		return nil
	end
	return rootInstance :: BasePart
end

local function makeShardPart(materialized: any, index: number): Part
	local config = materialized.config
	local shard = Instance.new("Part") :: Part
	shard.Name = string.format("Shard_%02d", index)
	shard.Shape = materialized.shardPartType
	shard.Size = materialized.shardSize
	shard.Color = if index % 2 == 0 then materialized.shardColorB else materialized.shardColorA
	shard.Material = Enum.Material.Neon
	shard.Anchored = true
	shard.CanCollide = false
	shard.CanQuery = false
	shard.CanTouch = false
	shard.CastShadow = false
	shard.Massless = true
	shard.TopSurface = Enum.SurfaceType.Smooth
	shard.BottomSurface = Enum.SurfaceType.Smooth
	shard.Transparency = config.highlightFillTransparency * 0.35
	return shard
end

local function attachTrail(shard: Part, materialized: any): Trail?
	local config = materialized.config
	if not config.trailEnabled then
		return nil
	end

	local halfLength = materialized.shardSize.Z * 0.5

	local attachmentA = Instance.new("Attachment") :: Attachment
	attachmentA.Name = "TrailA"
	attachmentA.Position = Vector3.new(0, 0, halfLength)
	attachmentA.Parent = shard

	local attachmentB = Instance.new("Attachment") :: Attachment
	attachmentB.Name = "TrailB"
	attachmentB.Position = Vector3.new(0, 0, -halfLength)
	attachmentB.Parent = shard

	local trail = Instance.new("Trail") :: Trail
	trail.Name = "ShardTrail"
	trail.Attachment0 = attachmentA
	trail.Attachment1 = attachmentB
	trail.Color = materialized.trailColor
	trail.Transparency = materialized.trailTransparency
	trail.WidthScale = materialized.trailWidth
	trail.Lifetime = config.trailLifetime
	trail.LightEmission = config.trailLightEmission
	trail.FaceCamera = true
	trail.MinLength = 0
	trail.Parent = shard

	return trail
end

-- Layered emitters: 1 = dense core sparks, 2 = soft ambient smoke,
-- 3 = slow halo motes (high tiers only, driven by config.particleLayers).
local function createEmitter(name: string, parent: Instance, materialized: any, layer: number): ParticleEmitter
	local config = materialized.config

	local emitter = Instance.new("ParticleEmitter") :: ParticleEmitter
	emitter.Name = name
	emitter.Enabled = true
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Color = materialized.particleColor
	emitter.Lifetime = materialized.particleLifetime
	emitter.Size = materialized.particleSize
	emitter.Transparency = materialized.particleTransparency
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.LightEmission = config.particleLightEmission
	emitter.SpreadAngle = Vector2.new(config.particleSpread, config.particleSpread)
	emitter.ZOffset = 0.2

	if layer == 1 then
		emitter.Speed = materialized.particleSpeed
		emitter.Rate = config.particleRate
		emitter.Texture = config.particleTexture
		emitter.Acceleration = Vector3.new(0, 4, 0)
		emitter.Drag = 1.5
	elseif layer == 2 then
		emitter.Speed = NumberRange.new(config.particleSpeedMin * 0.35, config.particleSpeedMax * 0.5)
		emitter.Rate = config.particleRate * 0.6
		emitter.Texture = config.smokeTexture
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, config.particleSizeStart * 2.4),
			NumberSequenceKeypoint.new(1, config.particleSizeStart * 3.6),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Acceleration = Vector3.new(0, 1.2, 0)
		emitter.Drag = 2.5
		emitter.LightEmission = config.particleLightEmission * 0.4
	else
		emitter.Speed = NumberRange.new(0.05, 0.3)
		emitter.Rate = config.particleRate * 0.35
		emitter.Texture = config.particleTexture
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, config.particleSizeStart * 1.6),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Acceleration = Vector3.new(0, 0.6, 0)
		emitter.Drag = 3
		emitter.ZOffset = 1
	end

	emitter.Parent = parent
	return emitter
end

local function createHighlight(character: Model, materialized: any): Highlight
	local config = materialized.config

	local highlight = Instance.new("Highlight") :: Highlight
	highlight.Name = "AuraHighlight"
	highlight.Adornee = character
	highlight.FillColor = materialized.primary
	highlight.OutlineColor = materialized.rim
	highlight.FillTransparency = config.highlightFillTransparency
	highlight.OutlineTransparency = config.highlightOutlineTransparency
	highlight.DepthMode = materialized.highlightDepthMode
	highlight.Enabled = true
	highlight.Parent = character
	return highlight
end

-- =============================================================================
-- Effect construction / teardown
-- =============================================================================

local function buildEffect(player: Player, character: Model, root: BasePart, materialized: any): Effect
	local config = materialized.config

	local container = Instance.new("Folder") :: Folder
	container.Name = string.format("Aura_%s_%d", player.Name, player.UserId)
	container.Parent = getVFXRuntimeRoot()

	local anchor = Instance.new("Part") :: Part
	anchor.Name = "EmissionAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Massless = true
	anchor.Parent = container

	local light = Instance.new("PointLight") :: PointLight
	light.Name = "AuraLight"
	light.Color = materialized.lightColor
	light.Range = config.lightRange
	light.Brightness = config.lightBrightness
	light.Shadows = false
	light.Parent = anchor

	local emitters: { ParticleEmitter } = {}
	local layerCount = math.clamp(math.floor(config.particleLayers), 1, 3)
	for layer = 1, layerCount do
		table.insert(emitters, createEmitter(string.format("Layer%d", layer), anchor, materialized, layer))
	end

	local shards: { Part } = {}
	local trails: { Trail } = {}
	local spins: { number } = {}

	for index = 1, config.shardCount do
		local shard = makeShardPart(materialized, index)
		shard.Parent = container

		local trail = attachTrail(shard, materialized)
		if trail ~= nil then
			table.insert(trails, trail)
		end

		-- Deterministic per-shard spin variation keeps the cluster from looking mechanical.
		table.insert(spins, config.shardSpin * (0.75 + 0.5 * ((index % 5) / 4)))
		table.insert(shards, shard)
	end

	local effect: Effect = {
		player = player,
		auraId = materialized.config.id,
		materialized = materialized,
		container = container,
		anchor = anchor,
		light = light,
		highlight = createHighlight(character, materialized),
		emitters = emitters,
		shards = shards,
		trails = trails,
		spins = spins,
		phase = (player.UserId % 360) * 0.0174,
		root = root,
		suppressed = false,
	}

	return effect
end

local function unregisterEffect(effect: Effect): ()
	if effects[effect.player] == effect then
		effects[effect.player] = nil
	end
	for index = #effectList, 1, -1 do
		if effectList[index] == effect then
			table.remove(effectList, index)
			break
		end
	end
end

local function destroyEffect(effect: Effect): ()
	unregisterEffect(effect)
	effect.container:Destroy()
	effect.highlight:Destroy()
end

local function clearEffect(player: Player): ()
	local existing = effects[player]
	if existing ~= nil then
		destroyEffect(existing)
	end
end

-- =============================================================================
-- Low spec mode (AFK farming): other players' particles are paused and their
-- shard containers are detached in a single reparent instead of being destroyed,
-- so switching back is instant and allocation free.
-- =============================================================================

local function applySuppression(effect: Effect): ()
	local localPlayer = getLocalPlayer()
	local suppress = lowSpecMode and (localPlayer == nil or effect.player ~= localPlayer)
	if suppress == effect.suppressed then
		return
	end

	effect.suppressed = suppress

	for _, emitter in ipairs(effect.emitters) do
		emitter.Enabled = not suppress
	end
	for _, trail in ipairs(effect.trails) do
		trail.Enabled = not suppress
	end
	effect.light.Enabled = not suppress

	if suppress then
		effect.container.Parent = nil
	else
		effect.container.Parent = getVFXRuntimeRoot()
	end
end

function ProceduralVFX.SetLowSpecMode(enabled: boolean): ()
	lowSpecMode = enabled
	for _, effect in pairs(effects) do
		applySuppression(effect)
	end
end

function ProceduralVFX.IsLowSpecMode(): boolean
	return lowSpecMode
end

-- =============================================================================
-- The single centralized render loop
-- =============================================================================

local function updateEffect(effect: Effect, now: number): ()
	if effect.suppressed then
		return
	end

	local root = effect.root
	if root == nil or root.Parent == nil then
		root = resolveRoot(effect.player)
		effect.root = root
		if root == nil then
			return
		end
	end

	local config = effect.materialized.config

	-- Tilted ring that precesses like a gyroscope around the character.
	local ringCFrame = CFrame.Angles(math.rad(config.tiltDegrees), 0, 0)
		* CFrame.Angles(0, now * config.precessionSpeed, 0)

	local originCFrame = root.CFrame
	local ringOrigin = originCFrame * ringCFrame

	local baseAngle = now * config.orbitSpeed * config.harmonicRatioA
	local verticalHarmonic = now * config.orbitSpeed * config.harmonicFrequency
	local breathingHarmonic = now * config.orbitSpeed * config.harmonicFrequency * 0.5

	local count = #effect.shards
	local step = TAU / count

	for index = 1, count do
		local shard = effect.shards[index]
		local offset = index - 1

		local angle = baseAngle + offset * step
		local radius = config.orbitRadius
			* (1 + math.sin(breathingHarmonic + offset * 0.9) * config.lissajousAmplitude)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		local y = math.sin(verticalHarmonic + offset * step * 1.5) * config.orbitHeight

		local spin = now * effect.spins[index]
		shard.CFrame = ringOrigin
			* CFrame.new(x, y, z)
			* CFrame.Angles(spin, spin * 1.31, spin * 0.77)
	end

	effect.anchor.CFrame = originCFrame
	effect.light.Brightness = config.lightBrightness * (0.85 + 0.15 * math.sin(now * 3 + effect.phase))
end

local function ensureRenderLoop(): ()
	if renderConnection ~= nil then
		return
	end
	renderConnection = RunService.RenderStepped:Connect(function(_deltaTime: number)
		local now = os.clock()
		for index = #effectList, 1, -1 do
			local effect = effectList[index]
			if effect == nil then
				continue
			end
			updateEffect(effect, now)
		end
	end)
end

-- =============================================================================
-- Equip watching
-- =============================================================================

local function requestBuild(player: Player): ()
	local token = (buildTokens[player] or 0) + 1
	buildTokens[player] = token

	local auraId: any = player:GetAttribute("EquippedAura")
	if type(auraId) ~= "string" then
		clearEffect(player)
		return
	end

	local materialized: any = AuraRegistry.Materialize(auraId)
	if materialized == nil then
		clearEffect(player)
		return
	end

	local character = player.Character
	if character == nil then
		clearEffect(player)
		return
	end

	task.spawn(function()
		local rootInstance = character:WaitForChild("HumanoidRootPart", 5)
		-- Superseded by a newer request, or the character swapped under us.
		if buildTokens[player] ~= token or player.Character ~= character then
			return
		end
		if rootInstance == nil then
			return
		end
		if player.Parent == nil then
			return
		end

		clearEffect(player)
		local effect = buildEffect(player, character, rootInstance :: BasePart, materialized)
		effects[player] = effect
		table.insert(effectList, effect)
		applySuppression(effect)
	end)
end

local function unwatchPlayer(player: Player): ()
	local watcher = watchers[player]
	if watcher ~= nil then
		watcher.attribute:Disconnect()
		watcher.characterAdded:Disconnect()
		watcher.characterRemoving:Disconnect()
		watchers[player] = nil
	end
	buildTokens[player] = nil
	clearEffect(player)
end

local function watchPlayer(player: Player): ()
	if watchers[player] ~= nil then
		return
	end

	watchers[player] = {
		attribute = player:GetAttributeChangedSignal("EquippedAura"):Connect(function()
			requestBuild(player)
		end),
		characterAdded = player.CharacterAdded:Connect(function()
			requestBuild(player)
		end),
		characterRemoving = player.CharacterRemoving:Connect(function()
			buildTokens[player] = (buildTokens[player] or 0) + 1
			clearEffect(player)
		end),
	}

	requestBuild(player)
end

-- =============================================================================
-- Roll cutscene
-- =============================================================================

local function ensureColorCorrection(): ColorCorrectionEffect
	local existing = colorCorrection
	if existing ~= nil and existing.Parent ~= nil then
		return existing
	end

	local created = Instance.new("ColorCorrectionEffect") :: ColorCorrectionEffect
	created.Name = "AuraRollFlash"
	created.Brightness = 0
	created.Contrast = 0
	created.Saturation = 0
	created.TintColor = Color3.fromRGB(255, 255, 255)
	created.Enabled = true
	created.Parent = Lighting
	colorCorrection = created
	return created
end

local function flashScreen(materialized: any, intensity: number): ()
	local postEffect = ensureColorCorrection()

	postEffect.TintColor = materialized.primary
	TweenService:Create(postEffect, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 0.08 + 0.22 * intensity,
		Contrast = 0.05 + 0.15 * intensity,
		Saturation = 0.1 + 0.3 * intensity,
	}):Play()

	task.delay(0.12, function()
		TweenService:Create(postEffect, TweenInfo.new(0.7 + 0.3 * intensity, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Brightness = 0,
			Contrast = 0,
			Saturation = 0,
		}):Play()
	end)
end

local function ensureShakeBinding(): ()
	if shakeBound then
		return
	end
	shakeBound = true

	-- Runs *after* the default camera script (priority 200) so the offset survives.
	RunService:BindToRenderStep(SHAKE_BINDING_NAME, Enum.RenderPriority.Camera.Value + 1, function(_deltaTime: number)
		local remaining = shakeEndClock - os.clock()
		if remaining <= 0 then
			shakeMagnitude = 0
			return
		end

		local camera: Camera? = Workspace.CurrentCamera
		if camera == nil then
			return
		end

		local decay = remaining / math.max(shakeDuration, 0.001)
		local magnitude = shakeMagnitude * decay * decay
		if magnitude <= 0 then
			return
		end

		local jitter = Vector3.new(
			(math.random() * 2 - 1) * magnitude,
			(math.random() * 2 - 1) * magnitude,
			(math.random() * 2 - 1) * magnitude
		)
		local twist = CFrame.Angles(
			(math.random() * 2 - 1) * magnitude * 0.02,
			(math.random() * 2 - 1) * magnitude * 0.02,
			(math.random() * 2 - 1) * magnitude * 0.01
		)

		camera.CFrame = camera.CFrame * CFrame.new(jitter) * twist
	end)
end

local function startCameraShake(magnitude: number, duration: number): ()
	local scaled = if lowSpecMode then magnitude * 0.35 else magnitude
	if scaled <= 0 then
		return
	end
	shakeMagnitude = scaled
	shakeDuration = duration
	shakeEndClock = os.clock() + duration
	ensureShakeBinding()
end

--[[
	PlayRollCutscene(materialized)

	FOV punch, ColourCorrection flash and (for high rarity) a decayed camera
	shake. Intensity is derived from the aura's `cutsceneIntensity`, so an Ember
	roll is a whisper and a Celestial Singularity roll is an event.
]]
function ProceduralVFX.PlayRollCutscene(materialized: any): ()
	if materialized == nil then
		return
	end

	local camera: Camera? = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local activeCamera = camera :: Camera

	local config = materialized.config
	local intensity = math.clamp(config.cutsceneIntensity, 0, 1)

	-- Remember the pre-cutscene FOV so back-to-back rolls never drift.
	if fovRestoreValue == nil then
		fovRestoreValue = activeCamera.FieldOfView
	end
	local restoreFov = fovRestoreValue :: number

	local punchFov = math.max(30, restoreFov - materialized.cutsceneFovDelta * intensity)
	TweenService:Create(
		activeCamera,
		TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FieldOfView = punchFov }
	):Play()

	task.delay(0.3 + 0.35 * intensity, function()
		local current: Camera? = Workspace.CurrentCamera
		if current == nil then
			fovRestoreValue = nil
			return
		end
		TweenService:Create(
			current :: Camera,
			TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ FieldOfView = restoreFov }
		):Play()
		fovRestoreValue = nil
	end)

	flashScreen(materialized, intensity)

	if intensity > 0.25 then
		startCameraShake(config.cutsceneShakeMagnitude * intensity, 0.35 + 0.5 * intensity)
	end
end

-- =============================================================================
-- Lifecycle
-- =============================================================================

function ProceduralVFX.Start(): ()
	if started then
		return
	end
	started = true

	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(unwatchPlayer)

	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end

	ensureRenderLoop()
end

function ProceduralVFX.IsRunning(): boolean
	return started
end

function ProceduralVFX.GetActiveEffectCount(): number
	return #effectList
end

function ProceduralVFX.GetEffectForPlayer(player: Player): any
	return effects[player]
end

-- Full teardown; mainly useful when hot-reloading during development.
function ProceduralVFX.ClearAll(): ()
	for _, effect in pairs(effects) do
		destroyEffect(effect)
	end
	effects = {}
	effectList = {}
	for _, watcher in pairs(watchers) do
		watcher.attribute:Disconnect()
		watcher.characterAdded:Disconnect()
		watcher.characterRemoving:Disconnect()
	end
	watchers = {}
	buildTokens = {}
end

-- Self-starting: VFX must not depend on the UI loading successfully.
ProceduralVFX.Start()

return ProceduralVFX
