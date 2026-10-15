--!strict
--[[
	MainUI (client)
	===============
	Every pixel of this interface is generated at runtime: a dark themed ScreenGui
	built from Frames, UICorner, UIStroke, UIGradient, UIGridLayout and UIScale.
	Nothing is expected to exist inside PlayerGui.

	Layout
	------
	  * Bottom center : ROLL / AUTO ROLL / FAST ROLL / LOW VFX / SHOP
	                    (the SHOP button opens the shop panel, which lives in
	                    `ShopUI` - this file only mounts it and hands over the
	                    button and the theme)
	  * Center        : roulette card - cycles aura names for 0.8s, then snaps to
	                    the server's authoritative result with a pop tween
	  * Top center    : pity + streak panel - the countdown to the guaranteed 2x-luck
	                    roll (RollMath's soft-pity interval), the 100-roll Rare+
	                    guarantee on its own line, and the server-owned session
	                    streak with its progress bar; the global pull banner flies
	                    in below it
	  * Top right     : the Top Rollers board - the server's persisted board with
	                    this session's players folded in. It prints no rows and no
	                    zeroes until the server says it has actually read one
	  * Left          : the inventory drawer - the collection grid (equip, or delete
	                    one copy) and the auto-filter control - which lives in
	                    `InventoryUI`; this file only mounts it

The Luck Shrine's status is a row on the pity panel (see `updateShrineView`): the
+15% and the seconds it buys are the server's numbers, and the client never claims
to be inside a zone the server has not placed it in.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
-- Used only to mark this player's own row on the Top Rollers board. The board
-- itself comes from the server; this is a display concern, not a claim.
local localUserId: number = player.UserId

-- =============================================================================
-- Shared modules & remotes
-- =============================================================================

local sharedInstance = ReplicatedStorage:WaitForChild("Shared", 30)
if sharedInstance == nil then
	error("[MainUI] ReplicatedStorage.Shared is missing. Is `rojo serve` syncing src/shared?")
end
local Shared = sharedInstance :: Folder

local auraRegistryModule = Shared:WaitForChild("AuraRegistry", 30)
local rollMathModule = Shared:WaitForChild("RollMath", 30)
if auraRegistryModule == nil or rollMathModule == nil then
	error("[MainUI] Shared.AuraRegistry / Shared.RollMath are missing.")
end

local AuraRegistry: any = require(auraRegistryModule :: ModuleScript)
local RollMath: any = require(rollMathModule :: ModuleScript)
local ProceduralVFX: any = require(script.Parent:WaitForChild("ProceduralVFX") :: ModuleScript)
local ShopUI: any = require(script.Parent:WaitForChild("ShopUI") :: ModuleScript)
local InventoryUI: any = require(script.Parent:WaitForChild("InventoryUI") :: ModuleScript)

local remotesInstance = ReplicatedStorage:WaitForChild("Remotes", 60)
if remotesInstance == nil then
	error("[MainUI] ReplicatedStorage.Remotes never appeared. Is RNGService running?")
end
local Remotes = remotesInstance :: Folder

local RequestRoll = Remotes:WaitForChild("RequestRoll", 30) :: RemoteFunction
local RollBroadcast = Remotes:WaitForChild("RollBroadcast", 30) :: RemoteEvent
local ToggleAutoRoll = Remotes:WaitForChild("ToggleAutoRoll", 30) :: RemoteEvent
local StateSync = Remotes:WaitForChild("StateSync", 30) :: RemoteEvent

-- =============================================================================
-- Theme
-- =============================================================================

local THEME = {
	backdrop = Color3.fromRGB(9, 11, 17),
	panel = Color3.fromRGB(19, 22, 31),
	panelRaised = Color3.fromRGB(29, 33, 45),
	raisedHover = Color3.fromRGB(40, 46, 63),
	stroke = Color3.fromRGB(76, 86, 112),
	accent = Color3.fromRGB(96, 168, 255),
	accentDeep = Color3.fromRGB(40, 84, 178),
	warm = Color3.fromRGB(255, 176, 92),
	warmDeep = Color3.fromRGB(168, 96, 32),
	text = Color3.fromRGB(246, 249, 255),
	textDim = Color3.fromRGB(172, 184, 206),
	danger = Color3.fromRGB(255, 108, 108),
	success = Color3.fromRGB(122, 232, 160),
	locked = Color3.fromRGB(128, 138, 160),
}

local ROULETTE_DURATION: number = 0.8
local AUTO_ROULETTE_DURATION: number = 0.16
local REVEAL_HOLD: number = 2.4
local BANNER_HOLD: number = 3.6
-- How often an auto-rolling session is told about the pulls its filter dropped.
-- The server sends the running total; this only decides how often it is spoken.
local FILTERED_SUMMARY_INTERVAL: number = 25

-- The top-centre stack, stated once. These three numbers have to agree: the
-- pity panel's height decides where the pull banner rests, and the banner
-- decides where the reveal card hangs. They used to be independent literals
-- (148 / 208 elsewhere), which is how a taller panel ends up under a banner.
-- The panel grew to 178 when the biome strip was added below the stats line, so
-- the two rest positions moved with it - all three, together, as the rule says.
local HUD_TOP_Y: number = 14
local PITY_PANEL_HEIGHT: number = 196
local BANNER_REST_Y: number = 220
local REVEAL_REST_Y: number = 280
-- Where the biome strip's rows sit, relative to the top panel.
local BIOME_NAME_Y: number = 134
local BIOME_RUNGS_Y: number = 150
local BIOME_RAIL_Y: number = 166
-- The shrine's own line, the panel's last row, below the biome rail. The panel
-- grew from 178 to 196 to hold it - the three numbers above moved with it, as the
-- rule in the comment above says they must.
local SHRINE_ROW_Y: number = 178

-- Top right: the Top Rollers board. One row per entry the server sends, sized so
-- the tallest board the server can send always fits the panel.
local BOARD_PANEL_WIDTH: number = 240
local BOARD_TITLE_Y: number = 10
local BOARD_STATUS_Y: number = 26
local BOARD_ROW_TOP: number = 46
local BOARD_ROW_HEIGHT: number = 15
-- Mirrors LeaderboardMath.Constants.maxEntries. The server never sends more, and
-- the harness checks these two numbers agree so a bigger board cannot silently
-- lose its last rows.
local BOARD_ROWS: number = 10
local BOARD_PANEL_HEIGHT: number = 56 + BOARD_ROWS * BOARD_ROW_HEIGHT
-- =============================================================================
-- Tiny UI helpers
-- =============================================================================

local function applyProps(instance: Instance, props: { [string]: any }): Instance
	for key, value in pairs(props) do
		(instance :: any)[key] = value
	end
	return instance
end

local function addCorner(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner") :: UICorner
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number): UIStroke
	local stroke = Instance.new("UIStroke") :: UIStroke
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = parent
	return stroke
end

local function addGradient(parent: Instance, from: Color3, to: Color3, rotation: number): UIGradient
	local gradient = Instance.new("UIGradient") :: UIGradient
	gradient.Color = ColorSequence.new(from, to)
	gradient.Rotation = rotation
	gradient.Parent = parent
	return gradient
end

local function makeFrame(parent: Instance, props: { [string]: any }): Frame
	local frame = Instance.new("Frame") :: Frame
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = THEME.panel
	applyProps(frame, props)
	frame.Parent = parent
	return frame
end

local function makeLabel(parent: Instance, props: { [string]: any }): TextLabel
	local label = Instance.new("TextLabel") :: TextLabel
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.Gotham
	label.TextColor3 = THEME.text
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	applyProps(label, props)
	label.Parent = parent
	return label
end

local function makeButton(parent: Instance, props: { [string]: any }): TextButton
	local button = Instance.new("TextButton") :: TextButton
	button.BackgroundColor3 = THEME.panelRaised
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = THEME.text
	button.TextSize = 15
	applyProps(button, props)
	button.Parent = parent
	return button
end

local function formatNumber(value: number): string
	local text = string.format("%d", math.floor(value + 0.5))
	local reversed = string.reverse(text)
	local grouped = string.gsub(reversed, "(%d%d%d)", "%1,")
	local formatted = string.reverse(grouped)
	if string.sub(formatted, 1, 1) == "," then
		formatted = string.sub(formatted, 2)
	end
	return formatted
end

-- "8m 12s" / "42s" - session clock, never a date.
local function formatClock(value: number): string
	local total = math.max(0, math.floor(value + 0.5))
	local minutes = math.floor(total / 60)
	local seconds = total % 60
	if minutes <= 0 then
		return string.format("%ds", seconds)
	end
	return string.format("%dm %02ds", minutes, seconds)
end

-- =============================================================================
-- ScreenGui
-- =============================================================================

local screenGui = Instance.new("ScreenGui") :: ScreenGui
screenGui.Name = "AuraCollectorUI"
screenGui.IgnoreGuiInset = true
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 20
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- Everything the player can hide lives under this one container, which turns the
-- "hide UI" toggle into a single Visible assignment instead of a dozen.
local hud = Instance.new("Frame") :: Frame
hud.Name = "HUD"
hud.Size = UDim2.fromScale(1, 1)
hud.BackgroundTransparency = 1
hud.BorderSizePixel = 0
hud.Active = false
hud.Parent = screenGui

-- -----------------------------------------------------------------------------
-- Bottom action bar
-- -----------------------------------------------------------------------------

local bottomBar = makeFrame(hud, {
	Name = "ActionBar",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -18),
	-- Wide enough for five buttons plus the layout's padding (the shop added one).
	Size = UDim2.fromOffset(830, 76),
	BackgroundColor3 = THEME.panel,
	BackgroundTransparency = 0.05,
})
addCorner(bottomBar, 16)
addStroke(bottomBar, THEME.stroke, 1.4, 0.35)
addGradient(bottomBar, THEME.panelRaised, THEME.panel, 90)

local buttonLayout = Instance.new("UIListLayout") :: UIListLayout
buttonLayout.FillDirection = Enum.FillDirection.Horizontal
buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
buttonLayout.Padding = UDim.new(0, 10)
buttonLayout.Parent = bottomBar

local function styleActionButton(button: TextButton, from: Color3, to: Color3, accent: Color3): UIStroke
	addCorner(button, 11)
	addGradient(button, from, to, 90)
	return addStroke(button, accent, 1.3, 0.5)
end

-- `getBaseColor` is a provider rather than a captured constant so hovering a
-- toggle never resets its active colour when the pointer leaves.
local function wireHover(button: TextButton, getBaseColor: () -> Color3, hoverColor: Color3): ()
	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.14), { BackgroundColor3 = hoverColor }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.14), { BackgroundColor3 = getBaseColor() }):Play()
	end)
end

local rollButton = makeButton(bottomBar, {
	Name = "RollButton",
	Size = UDim2.fromOffset(190, 56),
	Text = "ROLL",
	TextSize = 20,
	LayoutOrder = 1,
})
local rollStroke = styleActionButton(rollButton, THEME.accent, THEME.accentDeep, THEME.accent)

local cooldownFill = makeFrame(rollButton, {
	Name = "CooldownFill",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -3),
	Size = UDim2.new(0, 0, 0, 3),
	BackgroundColor3 = THEME.text,
	BackgroundTransparency = 0.35,
	ZIndex = 2,
})
addCorner(cooldownFill, 2)

local autoButton = makeButton(bottomBar, {
	Name = "AutoButton",
	Size = UDim2.fromOffset(132, 56),
	Text = "AUTO ROLL",
	TextSize = 14,
	LayoutOrder = 2,
})
local autoStroke = styleActionButton(autoButton, THEME.raisedHover, THEME.panelRaised, THEME.stroke)

local fastButton = makeButton(bottomBar, {
	Name = "FastButton",
	Size = UDim2.fromOffset(158, 56),
	-- Not "(SIM)" any more: the -40% cooldown is owned by the Fast Roll pass and
	-- the server only honours this toggle for a player who has it (or Test Mode).
	Text = "FAST ROLL",
	TextSize = 14,
	LayoutOrder = 3,
})
local fastStroke = styleActionButton(fastButton, THEME.raisedHover, THEME.panelRaised, THEME.stroke)

local lowVfxButton = makeButton(bottomBar, {
	Name = "LowVfxButton",
	Size = UDim2.fromOffset(132, 56),
	Text = "LOW VFX",
	TextSize = 14,
	LayoutOrder = 4,
})
local lowVfxStroke = styleActionButton(lowVfxButton, THEME.raisedHover, THEME.panelRaised, THEME.stroke)

-- The shop's own button. MainUI creates it (so it matches the bar) and hands it
-- to ShopUI, which owns everything the button opens.
local shopButton = makeButton(bottomBar, {
	Name = "ShopButton",
	Size = UDim2.fromOffset(132, 56),
	Text = "SHOP",
	TextSize = 15,
	LayoutOrder = 5,
})
-- No local for the stroke: this button is not a toggle, so nothing updates it.
styleActionButton(shopButton, THEME.panelRaised, Color3.fromRGB(14, 16, 24), THEME.success)
wireHover(shopButton, function(): Color3
	return THEME.panelRaised
end, THEME.raisedHover)

-- -----------------------------------------------------------------------------
-- Top center: pity tracker + stats
-- -----------------------------------------------------------------------------

local topPanel = makeFrame(hud, {
	Name = "PityPanel",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, HUD_TOP_Y),
	Size = UDim2.fromOffset(448, PITY_PANEL_HEIGHT),
	BackgroundColor3 = THEME.panel,
	BackgroundTransparency = 0.06,
})
addCorner(topPanel, 14)
addStroke(topPanel, THEME.stroke, 1.3, 0.4)
addGradient(topPanel, THEME.panelRaised, THEME.panel, 90)

makeLabel(topPanel, {
	Name = "Title",
	Position = UDim2.fromOffset(16, 10),
	Size = UDim2.new(1, -32, 0, 14),
	-- The panel carries both halves now: the pity countdowns and the session streak.
	Text = "PITY + STREAK",
	TextSize = 12,
	TextColor3 = THEME.textDim,
	Font = Enum.Font.GothamBold,
})

-- The tier this label names is the ladder's (via RollMath's pity floor) and the
-- window is RollMath's, so neither is spelled out here: rename the tier or move
-- the guarantee and the label follows.
local GUARANTEED_TIER_NAME: string = AuraRegistry.TierOf(RollMath.HardPityMinRarity())

--[[
	Two countdowns, two mechanics, one panel - and they must not be confused for
	each other:

	  * the PRIMARY line counts to the SOFT-PITY point: `SoftPityInterval()`
	    consecutive rolls without a Rare+ and the pity multiplier becomes exactly
	    x2 (and keeps ramping in the same steps after that). That is the vision's
	    "Guaranteed 2x Luck ... X/50", and it is literally true: reaching the
	    interval guarantees the x2, because the multiplier is a function of the
	    counter, not a dice roll;
	  * the SECOND line is the hard guarantee at `HardPityRolls()` (100), a
	    different mechanic that restricts the pool to Rare-or-better. It keeps the
	    copy it always had and simply gets a line of its own.

	Both numbers are read from RollMath. Spell either one out here and renaming
	or moving the pity window in that module would leave this panel lying.
]]
local softPity2xLabel = makeLabel(topPanel, {
	Name = "SoftPityCountdown",
	Position = UDim2.fromOffset(16, 24),
	Size = UDim2.new(1, -32, 0, 20),
	Text = string.format("Rolls until Guaranteed 2x Luck: 0/%d", RollMath.SoftPityInterval()),
	TextSize = 15,
	Font = Enum.Font.GothamBold,
})

local pityRail = makeFrame(topPanel, {
	Name = "PityRail",
	Position = UDim2.fromOffset(16, 46),
	Size = UDim2.new(1, -32, 0, 10),
	BackgroundColor3 = Color3.fromRGB(6, 8, 13),
	BackgroundTransparency = 0,
})
addCorner(pityRail, 5)
addStroke(pityRail, THEME.stroke, 1, 0.45)

local pityFill = makeFrame(pityRail, {
	Name = "PityFill",
	Size = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = THEME.accent,
})
addCorner(pityFill, 5)
addGradient(pityFill, THEME.accent, THEME.accentDeep, 0)

-- The bar spans the whole 100-roll guarantee window; this notch marks where the
-- 2x point falls inside it, so the bar, the primary line and the guarantee line
-- cannot tell three different stories.
local softPityNotch = makeFrame(pityRail, {
	Name = "SoftPityNotch",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(RollMath.SoftPityInterval() / RollMath.HardPityRolls(), 0, 0, -1),
	Size = UDim2.fromOffset(2, 12),
	BackgroundColor3 = THEME.warm,
	BackgroundTransparency = 0.15,
	ZIndex = 2,
})
addCorner(softPityNotch, 1)

local guaranteeLabel = makeLabel(topPanel, {
	Name = "GuaranteeCountdown",
	Position = UDim2.fromOffset(16, 59),
	Size = UDim2.new(1, -32, 0, 15),
	Text = string.format("Rolls until Guaranteed %s: 0/%d", GUARANTEED_TIER_NAME, RollMath.HardPityRolls()),
	TextSize = 12,
	TextColor3 = THEME.textDim,
})

-- Session streak: server state, rendered exactly as sent. The counter, the luck
-- bonus and the bar all come from one snapshot, so they cannot disagree with each
-- other - or with the Luck number in the stats line below, which is the streak
-- already folded in by the server.
-- Two labels on one row, sized so the widest real strings fit at their sizes
-- ("STREAK | Lv 15/15 | 30m 00s" and "+75% luck | MAX LEVEL") without clipping.
local streakLabel = makeLabel(topPanel, {
	Name = "Streak",
	Position = UDim2.fromOffset(16, 76),
	Size = UDim2.fromOffset(230, 16),
	Text = "STREAK  \226\128\162  connecting...",
	TextSize = 13,
	Font = Enum.Font.GothamBold,
	TextColor3 = THEME.textDim,
})

local streakNextLabel = makeLabel(topPanel, {
	Name = "StreakNext",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, 77),
	Size = UDim2.fromOffset(178, 14),
	Text = "",
	TextSize = 12,
	TextColor3 = THEME.textDim,
	TextXAlignment = Enum.TextXAlignment.Right,
})

local streakRail = makeFrame(topPanel, {
	Name = "StreakRail",
	Position = UDim2.fromOffset(16, 94),
	Size = UDim2.new(1, -32, 0, 6),
	BackgroundColor3 = Color3.fromRGB(6, 8, 13),
})
addCorner(streakRail, 3)
addStroke(streakRail, THEME.stroke, 1, 0.6)

local streakFill = makeFrame(streakRail, {
	Name = "StreakFill",
	Size = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = THEME.success,
})
addCorner(streakFill, 3)
addGradient(streakFill, THEME.success, Color3.fromRGB(38, 128, 78), 0)

local statsLabel = makeLabel(topPanel, {
	Name = "Stats",
	Position = UDim2.fromOffset(16, 104),
	Size = UDim2.new(1, -32, 0, 26),
	-- Denominator comes from the registry: the ladder grew to 12 rungs and a
	-- hardcoded "6" here went stale the moment it did.
	Text = string.format(
		"Rolls: 0   \226\128\162   Luck: 1.00x   \226\128\162   Collection: 0/%d",
		AuraRegistry.Count
	),
	TextSize = 12,
	TextColor3 = THEME.textDim,
	TextWrapped = true,
})

--[[
	BIOME EVENT STRIP.

	One compact row of server state: which event is running, its countdown, and the
	rungs it favours - all of it straight out of the payload. The panel does not know
	the schedule, does not know the event list, and never guesses the next event: if
	the local countdown runs out it says "switching..." and waits for the server to
	say what happened, because the server owns the clock and a client that named the
	next event itself could disagree with the server it is playing on.

	THIS IS THE ONLY PLACE THE BIOME IS RENDERED. The world and atmosphere layer
	reads the same payload and drives Lighting from it; nothing in this file writes
	to Lighting, Atmosphere, Workspace or Camera.
]]
local biomeNameLabel = makeLabel(topPanel, {
	Name = "BiomeName",
	Position = UDim2.fromOffset(16, BIOME_NAME_Y),
	Size = UDim2.new(1, -104, 0, 15),
	Text = "BIOME  \226\128\162  connecting...",
	TextSize = 12,
	Font = Enum.Font.GothamBlack,
	TextColor3 = THEME.textDim,
	TextTruncate = Enum.TextTruncate.AtEnd,
})

local biomeCountdownLabel = makeLabel(topPanel, {
	Name = "BiomeCountdown",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, BIOME_NAME_Y - 1),
	Size = UDim2.fromOffset(84, 16),
	Text = "",
	TextSize = 13,
	Font = Enum.Font.Code,
	TextColor3 = THEME.textDim,
	TextXAlignment = Enum.TextXAlignment.Right,
})

local biomeRungsLabel = makeLabel(topPanel, {
	Name = "BiomeRungs",
	Position = UDim2.fromOffset(16, BIOME_RUNGS_Y),
	Size = UDim2.new(1, -32, 0, 13),
	Text = "",
	TextSize = 10,
	TextColor3 = THEME.textDim,
	TextTruncate = Enum.TextTruncate.AtEnd,
})

local biomeRail = makeFrame(topPanel, {
	Name = "BiomeRail",
	Position = UDim2.fromOffset(16, BIOME_RAIL_Y),
	Size = UDim2.new(1, -32, 0, 6),
	BackgroundColor3 = Color3.fromRGB(6, 8, 13),
})
addCorner(biomeRail, 3)
addStroke(biomeRail, THEME.stroke, 1, 0.6)

local biomeFill = makeFrame(biomeRail, {
	Name = "BiomeFill",
	Size = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = THEME.accent,
})
addCorner(biomeFill, 3)

--[[
	THE LUCK SHRINE ROW.

	One line of server state: whether THIS player is in the zone, what being in it
	is worth, and how many players are in it. The client knows none of that on its
	own - it is sent, decided server-side from the server's own read of the
	character - and it says "connecting..." until the first payload arrives rather
	rather than reporting "outside" as though it had checked.

	The +15% and the effective cooldown are printed from the payload's own numbers
	(`bonusPercent` and the composed `cooldown`), so retuning ShrineConfig changes
	the copy with no edit here.
]]
local shrineStatusLabel = makeLabel(topPanel, {
	Name = "ShrineStatus",
	Position = UDim2.fromOffset(16, SHRINE_ROW_Y),
	Size = UDim2.new(1, -76, 0, 14),
	Text = "LUCK SHRINE  \226\128\162  connecting...",
	TextSize = 11,
	Font = Enum.Font.GothamBold,
	TextColor3 = THEME.textDim,
	TextTruncate = Enum.TextTruncate.AtEnd,
})

local shrineCrowdLabel = makeLabel(topPanel, {
	Name = "ShrineCrowd",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, SHRINE_ROW_Y),
	Size = UDim2.fromOffset(60, 14),
	Text = "",
	TextSize = 11,
	TextColor3 = THEME.textDim,
	TextXAlignment = Enum.TextXAlignment.Right,
})

-- -----------------------------------------------------------------------------
-- Top right: the Top Rollers board
-- -----------------------------------------------------------------------------

--[[
	The board, and the one rule it exists to keep: NO FAKE ZEROS.

	`ready` is the server's own "I have actually read the board" flag. Until it is
	true the panel prints "connecting..." and no rows at all, because an unread
	board and an empty one look identical on screen except that one of them is a
	lie about the whole server. That is the same class of first-frame bug the
	collection stat had once, and this panel is built so it cannot happen again.

	Row count is fixed (BOARD_ROWS) and the layout is created once: a sync arriving
	every two seconds must not be building Instances.
]]
local boardPanel = makeFrame(hud, {
	Name = "TopRollers",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -14, 0, HUD_TOP_Y),
	Size = UDim2.fromOffset(BOARD_PANEL_WIDTH, BOARD_PANEL_HEIGHT),
	BackgroundColor3 = THEME.panel,
	BackgroundTransparency = 0.06,
})
addCorner(boardPanel, 14)
addStroke(boardPanel, THEME.stroke, 1.3, 0.4)
addGradient(boardPanel, THEME.panelRaised, THEME.panel, 90)

makeLabel(boardPanel, {
	Name = "Title",
	Position = UDim2.fromOffset(14, BOARD_TITLE_Y),
	Size = UDim2.new(1, -28, 0, 14),
	Text = "TOP ROLLERS",
	TextSize = 12,
	TextColor3 = THEME.textDim,
	Font = Enum.Font.GothamBlack,
})

local boardStatusLabel = makeLabel(boardPanel, {
	Name = "Status",
	Position = UDim2.fromOffset(14, BOARD_STATUS_Y),
	Size = UDim2.new(1, -28, 0, 14),
	-- Filled from the payload: the backend the board is really on. A session-only
	-- board that does not say so reads exactly like a global one.
	Text = "connecting...",
	TextSize = 10,
	TextColor3 = THEME.textDim,
	TextTruncate = Enum.TextTruncate.AtEnd,
})

-- One label per row, created once. `Visible = false` until a row is sent, so the
-- panel's first frame is a title and a status line - never a list of zeroes.
local boardRowLabels: { TextLabel } = {}
for index = 1, BOARD_ROWS do
	boardRowLabels[index] = makeLabel(boardPanel, {
		Name = string.format("Row%d", index),
		Position = UDim2.fromOffset(14, BOARD_ROW_TOP + (index - 1) * BOARD_ROW_HEIGHT),
		Size = UDim2.new(1, -28, 0, BOARD_ROW_HEIGHT),
		Text = "",
		TextSize = 10,
		TextColor3 = THEME.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = false,
	})
end

-- -----------------------------------------------------------------------------
-- Global pull banner
-- -----------------------------------------------------------------------------

local bannerFrame = makeFrame(hud, {
	Name = "PullBanner",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, BANNER_REST_Y - 60),
	Size = UDim2.fromOffset(540, 50),
	BackgroundColor3 = THEME.panel,
	BackgroundTransparency = 1,
	Visible = false,
})
addCorner(bannerFrame, 12)
local bannerStroke = addStroke(bannerFrame, THEME.warm, 1.6, 1)
addGradient(bannerFrame, Color3.fromRGB(46, 36, 22), THEME.panel, 90)

local bannerLabel = makeLabel(bannerFrame, {
	Name = "BannerText",
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(1, -28, 1, 0),
	Text = "",
	TextSize = 15,
	TextTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Center,
	Font = Enum.Font.GothamBold,
})

-- -----------------------------------------------------------------------------
-- Center: roulette / reveal card
-- -----------------------------------------------------------------------------

local revealFrame = makeFrame(hud, {
	Name = "RollReveal",
	-- Hangs below the pity panel and above the character, so the reveal never
	-- buries the aura you just pulled.
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, REVEAL_REST_Y),
	Size = UDim2.fromOffset(492, 118),
	BackgroundColor3 = THEME.backdrop,
	BackgroundTransparency = 1,
	Visible = false,
})
addCorner(revealFrame, 16)
local revealStroke = addStroke(revealFrame, THEME.accent, 1.6, 1)
addGradient(revealFrame, THEME.panelRaised, THEME.backdrop, 90)

local revealScale = Instance.new("UIScale") :: UIScale
revealScale.Scale = 1
revealScale.Parent = revealFrame

-- Colour bloom behind the card, flashed at the snap moment.
local revealFlash = makeFrame(revealFrame, {
	Name = "Flash",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = THEME.accent,
	BackgroundTransparency = 1,
	ZIndex = 0,
})
addCorner(revealFlash, 16)

local revealCaption = makeLabel(revealFrame, {
	Name = "Caption",
	Position = UDim2.fromOffset(0, 10),
	Size = UDim2.new(1, 0, 0, 14),
	Text = "ROLLING...",
	TextSize = 12,
	TextColor3 = THEME.textDim,
	TextXAlignment = Enum.TextXAlignment.Center,
	TextTransparency = 1,
	Font = Enum.Font.GothamBold,
})

local revealName = makeLabel(revealFrame, {
	Name = "AuraName",
	Position = UDim2.fromOffset(0, 26),
	Size = UDim2.new(1, 0, 0, 46),
	Text = "",
	TextSize = 36,
	TextTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Center,
	Font = Enum.Font.GothamBlack,
})

local revealMeta = makeLabel(revealFrame, {
	Name = "AuraMeta",
	Position = UDim2.fromOffset(0, 74),
	Size = UDim2.new(1, 0, 0, 36),
	Text = "",
	TextSize = 13,
	TextColor3 = THEME.textDim,
	TextTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Center,
	TextWrapped = true,
	Font = Enum.Font.Gotham,
})

local revealNewBadge = makeLabel(revealFrame, {
	Name = "NewBadge",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 10),
	Size = UDim2.fromOffset(62, 20),
	Text = "NEW!",
	TextSize = 12,
	TextColor3 = THEME.backdrop,
	BackgroundColor3 = THEME.success,
	BackgroundTransparency = 0,
	TextXAlignment = Enum.TextXAlignment.Center,
	Font = Enum.Font.GothamBlack,
	Visible = false,
})
addCorner(revealNewBadge, 10)

-- -----------------------------------------------------------------------------
-- Toast (transient errors)
-- -----------------------------------------------------------------------------

local toastLabel = makeLabel(hud, {
	Name = "Toast",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -104),
	Size = UDim2.fromOffset(460, 26),
	Text = "",
	TextSize = 14,
	TextColor3 = THEME.danger,
	TextTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Center,
	Font = Enum.Font.GothamBold,
})

-- -----------------------------------------------------------------------------
-- Left: the inventory drawer (owned elsewhere)
-- -----------------------------------------------------------------------------

-- The collection grid, its cells, its equip/delete buttons and the auto-filter
-- control are `InventoryUI`. MainUI only mounts it (see the bottom of this file)
-- and hands it every server payload, the same way it mounts `ShopUI`. The grid
-- used to live here; moving it out is what kept this file from becoming the
-- home of every panel in the game.

-- =============================================================================
-- View state
-- =============================================================================

local autoEnabled: boolean = false
local fastEnabled: boolean = false
local lowVfxEnabled: boolean = false
local uiHidden: boolean = false

local currentCooldown: number = 1.2
local localCooldownUntil: number = 0

local function setToggleVisual(button: TextButton, stroke: UIStroke, enabled: boolean, activeColor: Color3, activeDeep: Color3): ()
	if enabled then
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		stroke.Color = activeColor
		stroke.Transparency = 0.05
		TweenService:Create(button, TweenInfo.new(0.18), { BackgroundColor3 = activeDeep }):Play()
	else
		-- Inactive labels must still be legible: contrast was the weakest part of
		-- the first pass.
		button.TextColor3 = THEME.textDim
		stroke.Color = THEME.stroke
		stroke.Transparency = 0.35
		TweenService:Create(button, TweenInfo.new(0.18), { BackgroundColor3 = THEME.panelRaised }):Play()
	end
end

local toastToken: number = 0

local function showToast(message: string, color: Color3?): ()
	toastToken += 1
	local token = toastToken
	toastLabel.Text = message
	toastLabel.TextColor3 = color or THEME.danger

	TweenService:Create(toastLabel, TweenInfo.new(0.12), { TextTransparency = 0 }):Play()
	task.delay(1.8, function()
		if token ~= toastToken then
			return
		end
		TweenService:Create(toastLabel, TweenInfo.new(0.35), { TextTransparency = 1 }):Play()
	end)
end

--[[
	Biome strip rendering.

	Two halves, deliberately split:

	  * `updateBiomeView` is the only thing that can change WHICH event is shown. It runs
	    when the server pushes state and at no other time, so a client cannot invent a
	    switch. An event it does not recognise (or a missing field) blanks the strip
	    rather than showing the previous event as though it were current.
	  * `paintBiomeCountdown` only re-draws the number, once per displayed second,
	    between pushes. When the local countdown reaches zero it stops naming anything
	    and says "switching..." until the server's next push arrives - one second later
	    at the sync cadence - so the worst case is a brief, honest "switching".
]]
local biomeServerSeconds: number = 0
local biomeSyncedAt: number = 0
local biomeHasState: boolean = false
local biomeDisplayedSecond: number = -1
local biomeColor: Color3 = THEME.textDim
local biomeProgress: number = 0
-- Which rungs the CURRENT event favours, by id, plus the words to name it on a
-- reveal. Both come from the payload's boosted list - the client never decides
-- for itself that an aura "should" be boosted.
local biomeBoostedIds: { [string]: boolean } = {}
local biomeBadgeText: string = ""

local function paintBiomeCountdown(): ()
	if not biomeHasState then
		return
	end

	-- Clamp the client's belief to what the server last said: interpolation may only
	-- count down towards the next event, never past it (a client-side clock jump
	-- backwards would otherwise make the countdown grow).
	local elapsed = math.max(0, os.clock() - biomeSyncedAt)
	local remaining = math.max(0, biomeServerSeconds - elapsed)
	local whole = math.floor(remaining + 0.5)

	if whole == biomeDisplayedSecond then
		return
	end
	biomeDisplayedSecond = whole

	if whole <= 0 then
		biomeCountdownLabel.Text = "switching..."
		biomeCountdownLabel.TextColor3 = THEME.textDim
		biomeFill.Size = UDim2.new(1, 0, 1, 0)
		return
	end

	biomeCountdownLabel.Text = string.format("%d:%02d", math.floor(whole / 60), whole % 60)
	biomeCountdownLabel.TextColor3 = biomeColor
	biomeFill.Size = UDim2.new(math.clamp(biomeProgress, 0, 1), 0, 1, 0)
end

local function formatBoostedRungs(boosted: any): string
	local names: { string } = {}
	if type(boosted) == "table" then
		for _, rung in ipairs(boosted) do
			if type(rung) == "table" and type(rung.displayName) == "string" and rung.displayName ~= "" then
				table.insert(names, rung.displayName)
			end
		end
	end
	if #names == 0 then
		return ""
	end
	return table.concat(names, ", ")
end

local function updateBiomeView(payload: any): ()
	local biome = payload.biome
	if type(biome) ~= "table" or type(biome.displayName) ~= "string" or biome.displayName == "" then
		-- No state yet (or an unknown event). Say so instead of leaving the last event
		-- standing, and drop the boosted set so a later reveal cannot be badged with it.
		biomeHasState = false
		biomeBoostedIds = {}
		biomeBadgeText = ""
		biomeNameLabel.Text = "BIOME  \226\128\162  connecting..."
		biomeNameLabel.TextColor3 = THEME.textDim
		biomeRungsLabel.Text = ""
		biomeCountdownLabel.Text = ""
		biomeFill.Size = UDim2.new(0, 0, 1, 0)
		return
	end

	local accent = biome.accent
	if type(accent) == "table" then
		biomeColor = Color3.fromRGB(
			math.clamp(tonumber(accent.r) or 96, 0, 255),
			math.clamp(tonumber(accent.g) or 168, 0, 255),
			math.clamp(tonumber(accent.b) or 255, 0, 255)
		)
	else
		biomeColor = THEME.accent
	end

	biomeHasState = true
	biomeServerSeconds = math.max(0, tonumber(biome.secondsRemaining) or 0)
	biomeSyncedAt = os.clock()
	biomeProgress = math.clamp(tonumber(biome.progress) or 0, 0, 1)
	biomeDisplayedSecond = -1 -- force a repaint even if the second has not changed

	-- The multiplier is the server's number, printed as it arrives: if the design
	-- changes to 2x or 5x, this line follows the payload without an edit here.
	local multiplierText = formatNumber(tonumber(biome.multiplier) or 1)
	biomeNameLabel.Text = string.format(
		"%s  \226\128\162  x%s ON THEMED RUNGS",
		biome.displayName,
		multiplierText
	)
	biomeNameLabel.TextColor3 = biomeColor
	biomeFill.BackgroundColor3 = biomeColor

	biomeBoostedIds = {}
	local boosted = biome.boosted
	if type(boosted) == "table" then
		for _, rung in ipairs(boosted) do
			if type(rung) == "table" and type(rung.id) == "string" then
				biomeBoostedIds[rung.id] = true
			end
		end
	end
	biomeBadgeText = string.format("%s x%s", string.upper(biome.displayName), multiplierText)

	local rungs = formatBoostedRungs(boosted)
	biomeRungsLabel.Text = if rungs == "" then "" else "Boosted: " .. rungs

	paintBiomeCountdown()
end

--[[
	The shrine row's rendering.

	Everything on it is the server's: `inside` came from a read of this player's
	own character on the server, and `bonusPercent` is ShrineConfig's number as the
	server resolved it. Before the first payload the
	row says "connecting..." rather than "outside" - the client has not checked
	anything and must not imply that it has.
]]
local function updateShrineView(payload: any): ()
	local shrine = payload.shrine
	if type(shrine) ~= "table" or type(shrine.displayName) ~= "string" then
		shrineStatusLabel.Text = "LUCK SHRINE  \226\128\162  connecting..."
		shrineStatusLabel.TextColor3 = THEME.textDim
		shrineCrowdLabel.Text = ""
		return
	end

	local accent = shrine.accent
	local colour = THEME.textDim
	if type(accent) == "table" then
		colour = Color3.fromRGB(
			math.clamp(tonumber(accent.r) or 255, 0, 255),
			math.clamp(tonumber(accent.g) or 214, 0, 255),
			math.clamp(tonumber(accent.b) or 140, 0, 255)
		)
	end

	local bonus = math.floor(tonumber(shrine.bonusPercent) or 0)
	local inside = shrine.inside == true

	if inside then
		-- The cooldown on screen is the payload's `cooldown` - the composed number
		-- the roll path will actually use - so the +15% cannot be advertised without
		-- the seconds it really buys.
		local cooldown = tonumber(payload.cooldown)
		local secondsInside = math.max(0, math.floor(tonumber(shrine.secondsInside) or 0))
		local cooldownText = if cooldown ~= nil then string.format("  \226\128\162  %.2fs", cooldown) else ""
		shrineStatusLabel.Text = string.format(
			"%s  \226\128\162  INSIDE  \226\128\162  +%d%% ROLL SPEED  %ds%s",
			string.upper(shrine.displayName),
			bonus,
			secondsInside,
			cooldownText
		)
		shrineStatusLabel.TextColor3 = colour
	else
		shrineStatusLabel.Text = string.format(
			"%s  \226\128\162  +%d%% ROLL SPEED WHILE INSIDE",
			string.upper(shrine.displayName),
			bonus
		)
		shrineStatusLabel.TextColor3 = THEME.textDim
	end

	local crowd = math.max(0, math.floor(tonumber(shrine.playersInside) or 0))
	-- "1 IN ZONE" reads as this player; the count is the server's.
	shrineCrowdLabel.Text = if crowd <= 0 then "" else string.format("%d IN ZONE", crowd)
	shrineCrowdLabel.TextColor3 = colour
end

--[[
	The board's rendering, with the no-fake-zeros rule stated in one place.

	`ready` false means the server has not read a board yet - so the panel says
	"connecting..." and hides every row. An empty board after a real read is
	different state and says so with words, not with ten rows of "0 rolls".
]]
local function formatBoardRow(row: any, isSelf: boolean): string
	local rank = math.max(0, math.floor(tonumber(row.rank) or 0))
	local name = if type(row.name) == "string" and row.name ~= "" then row.name else "?"
	local rolls = math.max(0, math.floor(tonumber(row.rolls) or 0))
	local rarest = math.max(0, math.floor(tonumber(row.rarestRarity) or 0))

	-- "nothing rare yet" rather than "1 in 0", and the aura's own label when the
	-- server resolved one.
	local findText = "no rare find yet"
	if rarest > 0 then
		local auraName = if type(row.rarestDisplayName) == "string" and row.rarestDisplayName ~= ""
			then row.rarestDisplayName
			else "?"
		findText = string.format("%s 1 in %s", auraName, formatNumber(rarest))
	end

	local prefix = if isSelf then ">" else " "
	return string.format("%s%d. %s  \226\128\162  %s  \226\128\162  %s", prefix, rank, name, formatNumber(rolls), findText)
end

local function updateLeaderboardView(payload: any): ()
	local board = payload.leaderboard

	-- The unread case, first and unconditionally: nothing below this line runs on
	-- a board that has not been read.
	if type(board) ~= "table" or board.ready ~= true then
		boardStatusLabel.Text = "connecting..."
		boardStatusLabel.TextColor3 = THEME.textDim
		for _, label in ipairs(boardRowLabels) do
			label.Text = ""
			label.Visible = false
		end
		return
	end

	local entries = board.entries
	local shown = 0
	if type(entries) == "table" then
		for index, row in ipairs(entries) do
			local label = boardRowLabels[index]
			if label == nil or type(row) ~= "table" then
				break
			end
			local isSelf = tonumber(row.userId) == localUserId
			label.Text = formatBoardRow(row, isSelf)
			label.Visible = true
			-- A border, not colour alone: the highlight has to survive being read by
			-- someone who cannot tell the accent colour from the text colour.
			label.Font = if isSelf then Enum.Font.GothamBold else Enum.Font.Gotham
			shown += 1
		end
	end

	for index = shown + 1, #boardRowLabels do
		boardRowLabels[index].Text = ""
		boardRowLabels[index].Visible = false
	end

	-- The status line says which board this is: a session-only fallback must not
	-- read like a global ladder, and an empty one must not read like a bug.
	local backend = if type(board.backend) == "string" then board.backend else "unknown"
	if shown == 0 then
		boardStatusLabel.Text = if board.sessionOnly == true
			then "no rolls yet  \226\128\162  session only (no Data Store)"
			else "no rolls yet on this board"
	elseif board.sessionOnly == true then
		boardStatusLabel.Text = string.format("%d rollers  \226\128\162  session only", shown)
	else
		boardStatusLabel.Text = string.format("%d rollers  \226\128\162  %s", shown, backend)
	end
	boardStatusLabel.TextColor3 = THEME.textDim
end

-- Renders the pity countdowns and the session streak from one server payload.
-- Named for what it shows, not for what it used to show.
local function updateProgressionView(payload: any): ()
	local hardPityRolls = tonumber(payload.hardPityRolls) or RollMath.HardPityRolls()
	local pity = math.clamp(tonumber(payload.pityCounter) or 0, 0, hardPityRolls)
	local progress = pity / hardPityRolls

	local softPityInterval = RollMath.SoftPityInterval()
	local softPityStacks = RollMath.SoftPityStacks(pity)

	if progress > 0 and progress <= 1 then
		TweenService:Create(pityFill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(progress, 0, 1, 0),
		}):Play()
	else
		pityFill.Size = UDim2.new(progress, 0, 1, 0)
	end

	-- Reserve the final stretch of the bar in warning colour so the guarantee reads at a glance.
	if progress >= 0.99 then
		pityFill.BackgroundColor3 = THEME.danger
	elseif payload.softPityActive then
		pityFill.BackgroundColor3 = THEME.warm
	else
		pityFill.BackgroundColor3 = THEME.accent
	end

	-- PRIMARY: the countdown to the guaranteed 2x-luck roll. The interval comes
	-- from RollMath, so this line says "50" only because that is where the pity
	-- multiplier really reaches x2 - move the interval and the copy follows.
	if softPityStacks <= 0 then
		softPity2xLabel.Text = string.format(
			"Rolls until Guaranteed 2x Luck: %d/%d",
			pity,
			softPityInterval
		)
		softPity2xLabel.TextColor3 = THEME.text
	else
		-- The countdown is finished, so it reports the multiplier the roll is
		-- actually using rather than pretending the clock is still running.
		softPity2xLabel.Text = string.format(
			"2x Luck ACTIVE  \226\128\162  pity x%.2f  \226\128\162  stack %d/%d",
			RollMath.SoftPityMultiplier(pity),
			softPityStacks,
			RollMath.Constants.maxSoftPityStacks
		)
		softPity2xLabel.TextColor3 = THEME.warm
	end

	-- OWN LINE: the hard guarantee, a different mechanic from the line above.
	guaranteeLabel.Text = string.format(
		"Rolls until Guaranteed %s: %d/%d",
		GUARANTEED_TIER_NAME,
		pity,
		hardPityRolls
	)
	guaranteeLabel.TextColor3 = if progress >= 0.99 then THEME.warm else THEME.textDim

	-- SESSION STREAK, straight from the server. If the snapshot is missing (the
	-- HUD's first frame, before the first sync lands) say so rather than showing
	-- a zero that looks like real state.
	local streak = payload.streak
	if type(streak) ~= "table" then
		streakLabel.Text = "STREAK  \226\128\162  connecting..."
		streakLabel.TextColor3 = THEME.textDim
		streakNextLabel.Text = ""
		streakFill.Size = UDim2.new(0, 0, 1, 0)
	else
		local level = math.max(0, math.floor(tonumber(streak.level) or 0))
		local maxLevel = math.max(0, math.floor(tonumber(streak.maxLevel) or 0))
		local streakLuck = tonumber(streak.luckMultiplier) or 1
		local bonusPercent = math.floor(math.max(0, streakLuck - 1) * 100 + 0.5)

		streakLabel.Text = string.format(
			"STREAK  \226\128\162  Lv %d/%d  \226\128\162  %s",
			level,
			maxLevel,
			formatClock(tonumber(streak.seconds) or 0)
		)

		if streak.capped == true then
			streakNextLabel.Text = string.format("+%d%% luck  \226\128\162  MAX LEVEL", bonusPercent)
			streakLabel.TextColor3 = THEME.warm
		else
			streakNextLabel.Text = string.format(
				"+%d%% luck  \226\128\162  next in %s",
				bonusPercent,
				formatClock(tonumber(streak.secondsToNextLevel) or 0)
			)
			streakLabel.TextColor3 = THEME.success
		end

		streakFill.Size = UDim2.new(math.clamp(tonumber(streak.levelProgress) or 0, 0, 1), 0, 1, 0)
	end

	local rarest = payload.rarestAura
	local rarestName = "None"
	if type(rarest) == "string" then
		local rarestConfig = AuraRegistry.Get(rarest)
		if rarestConfig ~= nil then
			rarestName = rarestConfig.displayName
		end
	end

	-- Count straight from the payload rather than from the drawer's mirror of it.
	-- Reading a cache here used to make this stat lag exactly one StateSync behind,
	-- which is why a player who clearly owned an aura still read an empty
	-- collection. The drawer keeps that cache now, so this reads the source.
	local ownedCount = 0
	if type(payload.inventory) == "table" then
		for auraId, count in pairs(payload.inventory :: { [any]: any }) do
			if type(auraId) == "string" and type(count) == "number" and count > 0 then
				ownedCount += 1
			end
		end
	end

	statsLabel.Text = string.format(
		"Rolls: %s   \226\128\162   Luck: %.2fx   \226\128\162   Collection: %d/%d   \226\128\162   Rarest: %s",
		formatNumber(tonumber(payload.totalRolls) or 0),
		tonumber(payload.luckMultiplier) or 1,
		ownedCount,
		AuraRegistry.Count,
		rarestName
	)
end

--[[
	The drawer's grid, cells and caches are InventoryUI's now (it mounts below with
	the rest of the panels). MainUI hands every payload straight through, so there
	is exactly one copy of "what does this player own" on the client - and it is
the drawer's.
]]
local function updateInventoryView(payload: any): ()
	InventoryUI.ApplyState(payload)
end

-- =============================================================================
-- Roll reveal
-- =============================================================================

local NAME_POOL: { { name: string, color: Color3 } } = {}
for _, auraId in ipairs(AuraRegistry.ORDER) do
	local config = AuraRegistry.Get(auraId)
	if config ~= nil then
		table.insert(NAME_POOL, {
			name = config.displayName,
			color = AuraRegistry.ToColor3(config.tierColor),
		})
	end
end

local revealToken: number = 0

local function hideReveal(token: number): ()
	if token ~= revealToken then
		return
	end
	TweenService:Create(revealFrame, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(revealStroke, TweenInfo.new(0.35), { Transparency = 1 }):Play()
	TweenService:Create(revealName, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
	TweenService:Create(revealMeta, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
	TweenService:Create(revealCaption, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
	task.delay(0.4, function()
		if token == revealToken then
			revealFrame.Visible = false
		end
	end)
end

local function popReveal(): ()
	revealScale.Scale = 0.74
	local rise = TweenService:Create(
		revealScale,
		TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1.12 }
	)
	rise:Play()
	rise.Completed:Once(function()
		TweenService:Create(
			revealScale,
			TweenInfo.new(0.13, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	end)
end

local function playRollReveal(payload: any, quick: boolean): ()
	local auraId = payload.auraId
	if type(auraId) ~= "string" then
		return
	end
	local materialized: any = AuraRegistry.Materialize(auraId)
	if materialized == nil then
		return
	end

	revealToken += 1
	local token = revealToken
	local config = materialized.config

	-- A first-ever copy is the most satisfying outcome, so call it out.
	revealNewBadge.Visible = (tonumber(payload.ownedCount) or 1) <= 1

	revealFrame.Visible = not uiHidden
	revealFrame.BackgroundTransparency = 0.14
	revealFlash.BackgroundColor3 = materialized.primary
	revealFlash.BackgroundTransparency = 1
	revealStroke.Color = materialized.primary
	revealStroke.Transparency = 0.15
	revealStroke.Thickness = 1.6 + 1.8 * math.clamp(config.cutsceneIntensity, 0, 1)
	revealName.TextTransparency = 0
	revealMeta.TextTransparency = 0
	revealCaption.TextTransparency = 0
	revealCaption.Text = if payload.source == "Auto" then "AUTO ROLLING..." else "ROLLING..."
	revealCaption.TextColor3 = THEME.textDim
	revealMeta.Text = ""
	revealScale.Scale = 1

	local duration = if quick then AUTO_ROULETTE_DURATION else ROULETTE_DURATION

	task.spawn(function()
		-- Roulette: accelerate through the aura names, then snap to the truth.
		local elapsed = 0
		local interval = 0.042
		local index = math.random(1, #NAME_POOL)

		while elapsed < duration and token == revealToken do
			index = index % #NAME_POOL + 1
			local entry = NAME_POOL[index]
			revealName.Text = entry.name
			revealName.TextColor3 = entry.color
			revealName.TextTransparency = 0.25

			task.wait(interval)
			elapsed += interval
			interval = math.min(0.16, interval * 1.18)
		end

		if token ~= revealToken then
			return
		end

		revealName.Text = config.displayName
		revealName.TextColor3 = materialized.primary
		revealName.TextTransparency = 0
		revealCaption.Text = string.upper(config.tier)
		revealCaption.TextColor3 = AuraRegistry.ToColor3(config.tierColor)

		local rarityText = formatNumber(math.floor(config.rarity))
		if payload.hardPityTriggered then
			revealMeta.Text = string.format("1 in %s   \226\128\162   GUARANTEED BY PITY", rarityText)
			revealMeta.TextColor3 = THEME.danger
		else
			revealMeta.Text = string.format(
				"1 in %s   \226\128\162   pulled in %d roll%s   \226\128\162   owned x%d",
				rarityText,
				tonumber(payload.ownedCount) or 1,
				(tonumber(payload.ownedCount) or 1) == 1 and "" or "s",
				tonumber(payload.ownedCount) or 1
			)
			revealMeta.TextColor3 = THEME.textDim
		end

		-- A boosted pull says why it was worth more. The check is membership in the
		-- server's boosted set, so no tier is special-cased here.
		if biomeBadgeText ~= "" and biomeBoostedIds[config.id] == true then
			revealMeta.Text = revealMeta.Text .. "   \226\128\162   " .. biomeBadgeText
		end

		popReveal()
		revealFlash.BackgroundTransparency = 0.55
		TweenService:Create(revealFlash, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
		ProceduralVFX.PlayRollCutscene(materialized)

		task.delay(REVEAL_HOLD, function()
			hideReveal(token)
		end)
	end)
end

-- =============================================================================
-- Global banner queue
-- =============================================================================

local bannerQueue: { any } = {}
local bannerBusy: boolean = false

local function pumpBannerQueue(): ()
	if bannerBusy or #bannerQueue == 0 then
		return
	end
	bannerBusy = true

	local payload = table.remove(bannerQueue, 1)
	local materialized: any = AuraRegistry.Materialize(payload.auraId)
	local color = THEME.warm
	local auraName = tostring(payload.displayName or payload.auraId)

	if materialized ~= nil then
		color = materialized.primary
		bannerStroke.Color = materialized.rim
	end

	bannerLabel.Text = string.format(
		"%s rolled %s   \226\128\162   1 in %s",
		tostring(payload.username or "Someone"),
		string.upper(auraName),
		formatNumber(tonumber(payload.rarity) or 0)
	)
	bannerLabel.TextColor3 = color

	bannerFrame.Visible = true
	bannerFrame.Position = UDim2.new(0.5, 0, 0, BANNER_REST_Y - 60)
	bannerStroke.Transparency = 0.25

	TweenService:Create(bannerFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, BANNER_REST_Y),
		BackgroundTransparency = 0.08,
	}):Play()
	TweenService:Create(bannerLabel, TweenInfo.new(0.25), { TextTransparency = 0 }):Play()
	TweenService:Create(bannerStroke, TweenInfo.new(0.25), { Transparency = 0.05 }):Play()

	task.delay(BANNER_HOLD, function()
		TweenService:Create(bannerFrame, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 0, BANNER_REST_Y - 60),
			BackgroundTransparency = 1,
		}):Play()
		TweenService:Create(bannerLabel, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		TweenService:Create(bannerStroke, TweenInfo.new(0.3), { Transparency = 1 }):Play()

		task.delay(0.4, function()
			bannerFrame.Visible = false
			bannerBusy = false
			pumpBannerQueue()
		end)
	end)
end

local function queueBanner(payload: any): ()
	table.insert(bannerQueue, payload)
	if #bannerQueue > 4 then
		table.remove(bannerQueue, 1)
	end
	pumpBannerQueue()
end

-- -----------------------------------------------------------------------------
-- Hide UI
-- -----------------------------------------------------------------------------

local hideButton = makeButton(screenGui, {
	Name = "HideUIButton",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, 14),
	Size = UDim2.fromOffset(84, 32),
	Text = "HIDE UI",
	TextSize = 13,
})
addCorner(hideButton, 9)
local hideStroke = addStroke(hideButton, THEME.stroke, 1.2, 0.3)
addGradient(hideButton, THEME.panelRaised, THEME.panel, 90)

local function setUIHidden(hidden: boolean): ()
	uiHidden = hidden
	hud.Visible = not hidden
	hideButton.Text = if hidden then "SHOW UI" else "HIDE UI"
	hideStroke.Color = if hidden then THEME.accent else THEME.stroke
	if hidden then
		revealFrame.Visible = false
		bannerFrame.Visible = false
	end
end

hideButton.Activated:Connect(function()
	setUIHidden(not uiHidden)
end)
wireHover(hideButton, function(): Color3
	return THEME.panelRaised
end, THEME.raisedHover)

-- =============================================================================
-- Remote wiring
-- =============================================================================

local lastPersonalSequence: number = 0
local lastGlobalSequence: number = 0

RollBroadcast.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end

	local sequence = tonumber(payload.sequence) or 0
	local isMine = tonumber(payload.userId) == player.UserId

	if isMine and sequence > lastPersonalSequence then
		lastPersonalSequence = sequence

		--[[
			A FILTERED PULL IS NOT A REWARD, so it does not get the reveal, the
			cutscene or the VFX: the player never owned it. It must still not vanish
			silently, so it is announced - with the rung it fell below - and the
			guaranteed-pity case is called out loudly, because dropping a guaranteed
			Rare+ is exactly the thing a player would not expect and must be told.

			The threshold's NAME comes from the ladder, not from a table here.
		]]
		if payload.filtered == true then
			local threshold = tonumber(payload.filterRarity) or 0
			local action = if payload.filterAction == "delete" then "DELETED" else "AUTO-SKIPPED"
			local total = tonumber(payload.filteredTotal) or 0
			-- Manual: say it every time. Auto: only every Nth, because an auto-rolling
			-- player would otherwise toast once a second. The drawer's live tally is
			-- the channel in between, so nothing is hidden either way.
			local worthSaying = payload.source ~= "Auto"
				or payload.hardPityTriggered == true
				or (total > 0 and total % FILTERED_SUMMARY_INTERVAL == 0)

			if worthSaying then
				showToast(
					string.format(
						"%s %s (1 in %s) - below your %s%s filter%s",
						action,
						tostring(payload.displayName or payload.auraId),
						formatNumber(tonumber(payload.rarity) or 0),
						AuraRegistry.TierOf(threshold),
						if payload.hardPityTriggered then " - that was the GUARANTEED pull" else "",
						if payload.source == "Auto" then string.format("   \226\128\162   %d filtered", total) else ""
					),
					if payload.hardPityTriggered then THEME.danger else THEME.warm
				)
			end
		else
			playRollReveal(payload, payload.source == "Auto")

			if payload.autoEquipped then
				showToast(
					string.format("Auto equipped %s", tostring(payload.displayName or payload.auraId)),
					THEME.success
				)
			end
		end
	end

	if payload.global == true and sequence > lastGlobalSequence then
		lastGlobalSequence = sequence
		queueBanner(payload)
	end
end)

--[[
	The last payload the server sent, kept for one reason: the join-time StateSync
	can land BEFORE the drawer is mounted (the connection below is set up before the
	panels at the bottom of this file are). Without a replay the drawer would open
	showing "NOT FOUND" everywhere and "filter off" for up to a second or two, which
	reads as data rather than as "not loaded yet" - the same class of lie the
	collection stat had once.
]]
local lastStatePayload: any = nil

StateSync.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end

	lastStatePayload = payload

	currentCooldown = tonumber(payload.cooldown) or 1.2

	local serverAuto = payload.autoEnabled == true
	local serverFast = payload.fastEnabled == true

	if serverAuto ~= autoEnabled then
		autoEnabled = serverAuto
		setToggleVisual(autoButton, autoStroke, autoEnabled, THEME.success, Color3.fromRGB(28, 62, 46))
	end
	if serverFast ~= fastEnabled then
		fastEnabled = serverFast
		setToggleVisual(fastButton, fastStroke, fastEnabled, THEME.warm, THEME.warmDeep)
	end

	-- Inventory first so the grid and the collection stat are always consistent.
	updateInventoryView(payload)
	updateProgressionView(payload)
	updateBiomeView(payload)
	updateShrineView(payload)
	updateLeaderboardView(payload)
end)

-- =============================================================================
-- Button behaviour
-- =============================================================================

local function requestRoll(): ()
	local now = os.clock()
	if now < localCooldownUntil then
		return
	end

	-- Optimistic local gate; the server re-checks authoritatively.
	localCooldownUntil = now + currentCooldown

	local invoked, response = pcall(function(): any
		return RequestRoll:InvokeServer("manual")
	end)

	if not invoked then
		localCooldownUntil = 0
		showToast("Roll request failed")
		return
	end

	if type(response) == "table" then
		if response.ok ~= true then
			local reason = tostring(response.reason or "Unknown")
			if reason == "Cooldown" then
				localCooldownUntil = os.clock() + (tonumber(response.remaining) or currentCooldown)
			elseif reason == "RateLimited" then
				localCooldownUntil = os.clock() + 0.25
			else
				localCooldownUntil = 0
				showToast("Roll rejected: " .. reason)
			end
		end
	end
end

rollButton.Activated:Connect(requestRoll)
wireHover(rollButton, function(): Color3
	return THEME.accent
end, Color3.fromRGB(124, 188, 255))

autoButton.Activated:Connect(function()
	local nextState = not autoEnabled
	autoEnabled = nextState
	setToggleVisual(autoButton, autoStroke, autoEnabled, THEME.success, Color3.fromRGB(28, 62, 46))
	ToggleAutoRoll:FireServer("Auto", autoEnabled)
	-- The server decides: without the Auto-Roll pass (or Test Mode) it drops this
	-- request and the synced toggle snaps back off a moment later.
	if autoEnabled then
		showToast("Auto-roll ON (needs the Auto-Roll pass)", THEME.success)
	else
		showToast("Auto-roll OFF", THEME.textDim)
	end
end)
wireHover(autoButton, function(): Color3
	return if autoEnabled then Color3.fromRGB(28, 62, 46) else THEME.panelRaised
end, THEME.raisedHover)

fastButton.Activated:Connect(function()
	local nextState = not fastEnabled
	fastEnabled = nextState
	setToggleVisual(fastButton, fastStroke, fastEnabled, THEME.warm, THEME.warmDeep)
	ToggleAutoRoll:FireServer("Fast", fastEnabled)
	showToast(
		if fastEnabled then "Fast Roll ON (needs the Fast Roll pass)" else "Fast Roll OFF",
		if fastEnabled then THEME.warm else THEME.textDim
	)
end)
wireHover(fastButton, function(): Color3
	return if fastEnabled then THEME.warmDeep else THEME.panelRaised
end, THEME.raisedHover)

lowVfxButton.Activated:Connect(function()
	lowVfxEnabled = not lowVfxEnabled
	setToggleVisual(lowVfxButton, lowVfxStroke, lowVfxEnabled, THEME.accent, Color3.fromRGB(28, 48, 88))
	ProceduralVFX.SetLowSpecMode(lowVfxEnabled)
	showToast(
		if lowVfxEnabled then "Low VFX mode ON (other players' particles paused)" else "Low VFX mode OFF",
		if lowVfxEnabled then THEME.accent else THEME.textDim
	)
end)
wireHover(lowVfxButton, function(): Color3
	return if lowVfxEnabled then Color3.fromRGB(28, 48, 88) else THEME.panelRaised
end, THEME.raisedHover)

-- =============================================================================
-- Cooldown indicator
-- =============================================================================

task.spawn(function()
	local lastFill = -1
	while true do
		local now = os.clock()
		local remaining = localCooldownUntil - now
		local fill = 0

		if remaining > 0 then
			fill = math.clamp(remaining / math.max(currentCooldown, 0.001), 0, 1)
		end

		if math.abs(fill - lastFill) > 0.01 then
			lastFill = fill
			cooldownFill.Size = UDim2.new(fill, 0, 0, 3)
			cooldownFill.BackgroundTransparency = if fill <= 0 then 1 else 0.3
			rollStroke.Transparency = if fill > 0.02 then 0.75 else 0.35
		end

		-- The biome countdown ticks inside this existing loop rather than a task of
		-- its own: painting only happens when the displayed second changes, so the
		-- added cost is a comparison per frame.
		paintBiomeCountdown()

		task.wait(0.05)
	end
end)

-- Initial visual state before the first StateSync lands.
updateProgressionView({
	hardPityRolls = RollMath.HardPityRolls(),
	pityCounter = 0,
	softPityActive = false,
	softPityStacks = 0,
	rollsUntilGuaranteed = 100,
	totalRolls = 0,
	luckMultiplier = 1,
	inventory = {},
	rarestAura = nil,
})
-- Same rule for the biome strip: no event is invented for the gap before the
-- first push. It reads "connecting..." until the server names the event and the
-- countdown it is actually running.
updateBiomeView({})
-- And the same rule twice more: the shrine row does not claim "outside" before
-- the server has read this player's character, and the board shows no rows and
-- no zeroes until the server says it has read one.
updateShrineView({})
updateLeaderboardView({})

-- The drawer paints its own empty state when it mounts (below), so there is no
-- local "what does this player own" guess here: it is all server truth or blank.
setToggleVisual(autoButton, autoStroke, false, THEME.success, Color3.fromRGB(28, 62, 46))
setToggleVisual(fastButton, fastStroke, false, THEME.warm, THEME.warmDeep)
setToggleVisual(lowVfxButton, lowVfxStroke, false, THEME.accent, Color3.fromRGB(28, 48, 88))

-- The shop is mounted, not rebuilt: MainUI hands ShopUI the HUD container it
-- should live in, the button that opens it, and its own UI helpers and theme, so
-- the panel cannot drift away from the interface around it. ShopUI keeps every
-- pixel of shop layout and every shop remote to itself.
ShopUI.Mount({
	parent = hud,
	button = shopButton,
	theme = THEME,
	makeFrame = makeFrame,
	makeLabel = makeLabel,
	makeButton = makeButton,
	addCorner = addCorner,
	addStroke = addStroke,
	addGradient = addGradient,
	wireHover = wireHover,
	showToast = showToast,
})

-- The drawer is mounted the same way, and owns its own toggle: MainUI hands over
-- the HUD, the theme and the same helpers, and nothing else. `formatNumber` goes
-- along so "1 in 500000" is formatted by one function for the whole interface.
InventoryUI.Mount({
	parent = hud,
	theme = THEME,
	makeFrame = makeFrame,
	makeLabel = makeLabel,
	makeButton = makeButton,
	addCorner = addCorner,
	addStroke = addStroke,
	addGradient = addGradient,
	wireHover = wireHover,
	formatNumber = formatNumber,
})

-- Replay the join-time sync if it already arrived (nil-safe: ApplyState ignores
-- anything that is not a table), so the drawer's first frame is the truth.
InventoryUI.ApplyState(lastStatePayload)

-- Keyboard shortcuts: R rolls, L toggles low VFX, H hides the interface, B opens
-- the shop.
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.R then
		requestRoll()
	elseif input.KeyCode == Enum.KeyCode.L then
		lowVfxEnabled = not lowVfxEnabled
		setToggleVisual(lowVfxButton, lowVfxStroke, lowVfxEnabled, THEME.accent, Color3.fromRGB(28, 48, 88))
		ProceduralVFX.SetLowSpecMode(lowVfxEnabled)
	elseif input.KeyCode == Enum.KeyCode.H then
		setUIHidden(not uiHidden)
	elseif input.KeyCode == Enum.KeyCode.B then
		ShopUI.Toggle()
	elseif input.KeyCode == Enum.KeyCode.I then
		InventoryUI.ToggleDrawer()
	end
end)

print(
	string.format(
		"[MainUI] Ready. %d auras registered. Hard pity at %d rolls. Shop: press SHOP or B. "
			.. "Inventory + auto-filter: press the AURAS drawer handle or I.",
		AuraRegistry.Count,
		RollMath.HardPityRolls()
	)
)
