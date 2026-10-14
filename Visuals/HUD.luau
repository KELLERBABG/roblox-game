--!strict
--[[
	Visuals.HUD
	===========
	World-class in-game HUD and user interface system designed in strict accordance
	with the Design Atlas MCP plugin specifications:
	  * Dark luxury near-black foundation (rgb 9, 11, 17)
	  * Glassmorphism panels with squircle corners (UICorner) and hairline strokes (UIStroke)
	  * Sol's RNG-inspired Bottom Action Bar (Roll, Auto, Fast, Low VFX, Codex)
	  * Sol's RNG-inspired Top Pity & Luck Multiplier Tracker
	  * Cinematic Center Roll Reveal Card with spring pop scale
	  * 66-Aura Collection Codex modal (Bento-grid with locked silhouettes & equip buttons)
	  * Global Pull Announcement Banner
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AuraCatalog = require(script.Parent:WaitForChild("AuraCatalog") :: ModuleScript)
local Audio = require(script.Parent:WaitForChild("Audio") :: ModuleScript)

-- =============================================================================
-- Design Atlas Theme Tokens
-- =============================================================================

local TOKENS = {
	-- Background & Surfaces
	bgCanvas = Color3.fromRGB(8, 10, 15),
	bgSurface = Color3.fromRGB(15, 18, 26),
	bgSurfaceRaised = Color3.fromRGB(24, 28, 40),
	bgSurfaceHover = Color3.fromRGB(36, 42, 60),

	-- Hairline Borders & Dividers
	borderSubtle = Color3.fromRGB(45, 52, 72),
	borderStrong = Color3.fromRGB(75, 85, 115),

	-- Text Scales
	textPrimary = Color3.fromRGB(240, 244, 255),
	textSecondary = Color3.fromRGB(145, 155, 180),
	textTertiary = Color3.fromRGB(90, 100, 125),
	textLocked = Color3.fromRGB(65, 72, 92),

	-- Semantic Accents
	accentBlue = Color3.fromRGB(80, 160, 255),
	accentBlueDeep = Color3.fromRGB(25, 70, 160),
	accentGold = Color3.fromRGB(255, 190, 50),
	accentGoldDeep = Color3.fromRGB(160, 100, 20),
	accentGreen = Color3.fromRGB(80, 230, 140),
	accentGreenDeep = Color3.fromRGB(20, 80, 45),
	accentPurple = Color3.fromRGB(180, 110, 255),
	accentPurpleDeep = Color3.fromRGB(80, 30, 140),
	accentRed = Color3.fromRGB(255, 75, 90),
}

local HUD = {}

-- Utility to apply props cleanly
local function setProps(inst: Instance, props: { [string]: any }): Instance
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	return inst
end

local function addCorner(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = parent
	return stroke
end

local function addGradient(parent: Instance, from: Color3, to: Color3, rotation: number): UIGradient
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(from, to)
	grad.Rotation = rotation
	grad.Parent = parent
	return grad
end

local function formatNumber(val: number): string
	local s = string.format("%d", math.floor(val + 0.5))
	local rev = string.reverse(s)
	local grouped = string.gsub(rev, "(%d%d%d)", "%1,")
	local formatted = string.reverse(grouped)
	if string.sub(formatted, 1, 1) == "," then
		formatted = string.sub(formatted, 2)
	end
	return formatted
end

-- =============================================================================
-- In-Game ScreenGui Constructor
-- =============================================================================

export type HUDInstance = {
	gui: ScreenGui,
	pityFill: Frame,
	pityLabel: TextLabel,
	pitySubLabel: TextLabel,
	statsLabel: TextLabel,
	rollButton: TextButton,
	cooldownFill: Frame,
	autoButton: TextButton,
	fastButton: TextButton,
	lowVfxButton: TextButton,
	codexButton: TextButton,
	revealFrame: Frame,
	revealName: TextLabel,
	revealTier: TextLabel,
	revealOdds: TextLabel,
	revealSubtitle: TextLabel,
	revealScale: UIScale,
	bannerFrame: Frame,
	bannerLabel: TextLabel,
	codexModal: Frame,
	codexScroll: ScrollingFrame,
	setCodexVisible: (visible: boolean) -> (),
	playReveal: (auraId: string, rarity: number, isGuaranteed: boolean) -> (),
	showBanner: (username: string, auraName: string, rarity: number, color: Color3) -> (),
}

function HUD.Create(playerGui: PlayerGui): HUDInstance
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SolsRNG_DesignAtlas_HUD"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 30
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	-- -------------------------------------------------------------------------
	-- 1. Top Pity & Multiplier Bar (Design Atlas Glassmorphic Header)
	-- -------------------------------------------------------------------------
	local topBar = Instance.new("Frame")
	topBar.Name = "TopPityBar"
	topBar.AnchorPoint = Vector2.new(0.5, 0)
	topBar.Position = UDim2.new(0.5, 0, 0, 16)
	topBar.Size = UDim2.fromOffset(520, 105)
	topBar.BackgroundColor3 = TOKENS.bgSurface
	topBar.BackgroundTransparency = 0.1
	topBar.BorderSizePixel = 0
	topBar.Parent = screenGui
	addCorner(topBar, 14)
	addStroke(topBar, TOKENS.borderSubtle, 1.2, 0.4)
	addGradient(topBar, TOKENS.bgSurfaceRaised, TOKENS.bgSurface, 90)

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Position = UDim2.fromOffset(18, 10)
	titleLabel.Size = UDim2.new(1, -36, 0, 14)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.Text = "PITY COUNTER"
	titleLabel.TextSize = 11
	titleLabel.TextColor3 = TOKENS.textSecondary
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Parent = topBar

	local pityLabel = Instance.new("TextLabel")
	pityLabel.Name = "PityLabel"
	pityLabel.Position = UDim2.fromOffset(18, 25)
	pityLabel.Size = UDim2.new(1, -36, 0, 18)
	pityLabel.BackgroundTransparency = 1
	pityLabel.Font = Enum.Font.GothamBold
	pityLabel.Text = "Rolls until Guaranteed Rare: 0 / 100"
	pityLabel.TextSize = 15
	pityLabel.TextColor3 = TOKENS.textPrimary
	pityLabel.TextXAlignment = Enum.TextXAlignment.Left
	pityLabel.Parent = topBar

	-- Pity ProgressBar Rail
	local rail = Instance.new("Frame")
	rail.Name = "ProgressRail"
	rail.Position = UDim2.fromOffset(18, 48)
	rail.Size = UDim2.new(1, -36, 0, 8)
	rail.BackgroundColor3 = TOKENS.bgCanvas
	rail.BorderSizePixel = 0
	rail.Parent = topBar
	addCorner(rail, 4)

	local pityFill = Instance.new("Frame")
	pityFill.Name = "ProgressFill"
	pityFill.Size = UDim2.new(0, 0, 1, 0)
	pityFill.BackgroundColor3 = TOKENS.accentBlue
	pityFill.BorderSizePixel = 0
	pityFill.Parent = rail
	addCorner(pityFill, 4)
	addGradient(pityFill, TOKENS.accentBlue, TOKENS.accentBlueDeep, 0)

	local pitySubLabel = Instance.new("TextLabel")
	pitySubLabel.Name = "PitySub"
	pitySubLabel.Position = UDim2.fromOffset(18, 60)
	pitySubLabel.Size = UDim2.new(1, -36, 0, 14)
	pitySubLabel.BackgroundTransparency = 1
	pitySubLabel.Font = Enum.Font.Gotham
	pitySubLabel.Text = "Soft Pity: Inactive  •  100 roll(s) to hard pity"
	pitySubLabel.TextSize = 11
	pitySubLabel.TextColor3 = TOKENS.textTertiary
	pitySubLabel.TextXAlignment = Enum.TextXAlignment.Left
	pitySubLabel.Parent = topBar

	local statsLabel = Instance.new("TextLabel")
	statsLabel.Name = "Stats"
	statsLabel.Position = UDim2.fromOffset(18, 78)
	statsLabel.Size = UDim2.new(1, -36, 0, 16)
	statsLabel.BackgroundTransparency = 1
	statsLabel.Font = Enum.Font.Gotham
	statsLabel.Text = "Total Rolls: 0   •   Luck: 1.00x   •   Unlocked: 0/66"
	statsLabel.TextSize = 12
	statsLabel.TextColor3 = TOKENS.textSecondary
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.Parent = topBar

	-- -------------------------------------------------------------------------
	-- 2. Bottom Action Bar (Sol's RNG Style Interactive Dock)
	-- -------------------------------------------------------------------------
	local dock = Instance.new("Frame")
	dock.Name = "ActionDock"
	dock.AnchorPoint = Vector2.new(0.5, 1)
	dock.Position = UDim2.new(0.5, 0, 1, -20)
	dock.Size = UDim2.fromOffset(780, 74)
	dock.BackgroundColor3 = TOKENS.bgSurface
	dock.BackgroundTransparency = 0.08
	dock.BorderSizePixel = 0
	dock.Parent = screenGui
	addCorner(dock, 16)
	addStroke(dock, TOKENS.borderSubtle, 1.4, 0.4)
	addGradient(dock, TOKENS.bgSurfaceRaised, TOKENS.bgSurface, 90)

	local dockLayout = Instance.new("UIListLayout")
	dockLayout.FillDirection = Enum.FillDirection.Horizontal
	dockLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	dockLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	dockLayout.Padding = UDim.new(0, 12)
	dockLayout.Parent = dock

	-- ROLL Button
	local rollBtn = Instance.new("TextButton")
	rollBtn.Name = "RollButton"
	rollBtn.Size = UDim2.fromOffset(190, 54)
	rollBtn.BackgroundColor3 = TOKENS.accentBlueDeep
	rollBtn.Font = Enum.Font.GothamBlack
	rollBtn.Text = "ROLL"
	rollBtn.TextSize = 22
	rollBtn.TextColor3 = TOKENS.textPrimary
	rollBtn.AutoButtonColor = false
	rollBtn.BorderSizePixel = 0
	rollBtn.Parent = dock
	addCorner(rollBtn, 12)
	addStroke(rollBtn, TOKENS.accentBlue, 1.4, 0.2)
	addGradient(rollBtn, TOKENS.accentBlue, TOKENS.accentBlueDeep, 90)

	local cooldownFill = Instance.new("Frame")
	cooldownFill.Name = "CooldownFill"
	cooldownFill.AnchorPoint = Vector2.new(0.5, 1)
	cooldownFill.Position = UDim2.new(0.5, 0, 1, -3)
	cooldownFill.Size = UDim2.new(1, -12, 0, 3)
	cooldownFill.BackgroundColor3 = TOKENS.textPrimary
	cooldownFill.BackgroundTransparency = 1
	cooldownFill.BorderSizePixel = 0
	cooldownFill.Parent = rollBtn
	addCorner(cooldownFill, 2)

	-- AUTO Button
	local autoBtn = Instance.new("TextButton")
	autoBtn.Name = "AutoButton"
	autoBtn.Size = UDim2.fromOffset(130, 54)
	autoBtn.BackgroundColor3 = TOKENS.bgSurfaceRaised
	autoBtn.Font = Enum.Font.GothamBold
	autoBtn.Text = "AUTO ROLL"
	autoBtn.TextSize = 13
	autoBtn.TextColor3 = TOKENS.textPrimary
	autoBtn.AutoButtonColor = false
	autoBtn.BorderSizePixel = 0
	autoBtn.Parent = dock
	addCorner(autoBtn, 12)
	addStroke(autoBtn, TOKENS.borderSubtle, 1.2, 0.5)

	-- FAST Button
	local fastBtn = Instance.new("TextButton")
	fastBtn.Name = "FastButton"
	fastBtn.Size = UDim2.fromOffset(130, 54)
	fastBtn.BackgroundColor3 = TOKENS.bgSurfaceRaised
	fastBtn.Font = Enum.Font.GothamBold
	fastBtn.Text = "FAST 2x"
	fastBtn.TextSize = 13
	fastBtn.TextColor3 = TOKENS.textPrimary
	fastBtn.AutoButtonColor = false
	fastBtn.BorderSizePixel = 0
	fastBtn.Parent = dock
	addCorner(fastBtn, 12)
	addStroke(fastBtn, TOKENS.borderSubtle, 1.2, 0.5)

	-- LOW VFX Button
	local lowVfxBtn = Instance.new("TextButton")
	lowVfxBtn.Name = "LowVfxButton"
	lowVfxBtn.Size = UDim2.fromOffset(120, 54)
	lowVfxBtn.BackgroundColor3 = TOKENS.bgSurfaceRaised
	lowVfxBtn.Font = Enum.Font.GothamBold
	lowVfxBtn.Text = "LOW VFX"
	lowVfxBtn.TextSize = 13
	lowVfxBtn.TextColor3 = TOKENS.textPrimary
	lowVfxBtn.AutoButtonColor = false
	lowVfxBtn.BorderSizePixel = 0
	lowVfxBtn.Parent = dock
	addCorner(lowVfxBtn, 12)
	addStroke(lowVfxBtn, TOKENS.borderSubtle, 1.2, 0.5)

	-- CODEX Button (Opens 66-Aura Collection Browser)
	local codexBtn = Instance.new("TextButton")
	codexBtn.Name = "CodexButton"
	codexBtn.Size = UDim2.fromOffset(130, 54)
	codexBtn.BackgroundColor3 = TOKENS.bgSurfaceRaised
	codexBtn.Font = Enum.Font.GothamBold
	codexBtn.Text = "COLLECTION"
	codexBtn.TextSize = 13
	codexBtn.TextColor3 = TOKENS.accentPurple
	codexBtn.AutoButtonColor = false
	codexBtn.BorderSizePixel = 0
	codexBtn.Parent = dock
	addCorner(codexBtn, 12)
	addStroke(codexBtn, TOKENS.accentPurple, 1.2, 0.4)

	-- -------------------------------------------------------------------------
	-- 3. Center Roll Reveal Card (Design Atlas High-Impact Presentation)
	-- -------------------------------------------------------------------------
	local revealFrame = Instance.new("Frame")
	revealFrame.Name = "RevealCard"
	revealFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	revealFrame.Position = UDim2.new(0.5, 0, 0.44, 0)
	revealFrame.Size = UDim2.fromOffset(580, 180)
	revealFrame.BackgroundColor3 = TOKENS.bgCanvas
	revealFrame.BackgroundTransparency = 1
	revealFrame.BorderSizePixel = 0
	revealFrame.Visible = false
	revealFrame.Parent = screenGui
	addCorner(revealFrame, 20)
	local revealStroke = addStroke(revealFrame, TOKENS.accentBlue, 2.0, 1)
	addGradient(revealFrame, TOKENS.bgSurfaceRaised, TOKENS.bgCanvas, 90)

	local revealScale = Instance.new("UIScale")
	revealScale.Scale = 1
	revealScale.Parent = revealFrame

	local revealTier = Instance.new("TextLabel")
	revealTier.Name = "Tier"
	revealTier.Position = UDim2.fromOffset(0, 16)
	revealTier.Size = UDim2.new(1, 0, 0, 16)
	revealTier.BackgroundTransparency = 1
	revealTier.Font = Enum.Font.GothamBlack
	revealTier.Text = "MYTHIC"
	revealTier.TextSize = 13
	revealTier.TextColor3 = TOKENS.accentGold
	revealTier.TextTransparency = 1
	revealTier.TextXAlignment = Enum.TextXAlignment.Center
	revealTier.Parent = revealFrame

	local revealName = Instance.new("TextLabel")
	revealName.Name = "AuraName"
	revealName.Position = UDim2.fromOffset(0, 36)
	revealName.Size = UDim2.new(1, 0, 0, 56)
	revealName.BackgroundTransparency = 1
	revealName.Font = Enum.Font.GothamBlack
	revealName.Text = "CELESTIAL SINGULARITY"
	revealName.TextSize = 40
	revealName.TextColor3 = TOKENS.textPrimary
	revealName.TextTransparency = 1
	revealName.TextXAlignment = Enum.TextXAlignment.Center
	revealName.Parent = revealFrame

	local revealSubtitle = Instance.new("TextLabel")
	revealSubtitle.Name = "Subtitle"
	revealSubtitle.Position = UDim2.fromOffset(0, 96)
	revealSubtitle.Size = UDim2.new(1, 0, 0, 20)
	revealSubtitle.BackgroundTransparency = 1
	revealSubtitle.Font = Enum.Font.Gotham
	revealSubtitle.Text = "The gravitational collapse of an entire celestial galaxy."
	revealSubtitle.TextSize = 14
	revealSubtitle.TextColor3 = TOKENS.textSecondary
	revealSubtitle.TextTransparency = 1
	revealSubtitle.TextXAlignment = Enum.TextXAlignment.Center
	revealSubtitle.Parent = revealFrame

	local revealOdds = Instance.new("TextLabel")
	revealOdds.Name = "Odds"
	revealOdds.Position = UDim2.fromOffset(0, 126)
	revealOdds.Size = UDim2.new(1, 0, 0, 28)
	revealOdds.BackgroundTransparency = 1
	revealOdds.Font = Enum.Font.GothamBold
	revealOdds.Text = "1 IN 100,000"
	revealOdds.TextSize = 16
	revealOdds.TextColor3 = TOKENS.accentGold
	revealOdds.TextTransparency = 1
	revealOdds.TextXAlignment = Enum.TextXAlignment.Center
	revealOdds.Parent = revealFrame

	-- -------------------------------------------------------------------------
	-- 4. Global Pull Announcement Banner
	-- -------------------------------------------------------------------------
	local bannerFrame = Instance.new("Frame")
	bannerFrame.Name = "GlobalPullBanner"
	bannerFrame.AnchorPoint = Vector2.new(0.5, 0)
	bannerFrame.Position = UDim2.new(0.5, 0, 0, -80)
	bannerFrame.Size = UDim2.fromOffset(560, 50)
	bannerFrame.BackgroundColor3 = TOKENS.bgSurface
	bannerFrame.BackgroundTransparency = 1
	bannerFrame.BorderSizePixel = 0
	bannerFrame.Visible = false
	bannerFrame.Parent = screenGui
	addCorner(bannerFrame, 12)
	local bannerStroke = addStroke(bannerFrame, TOKENS.accentGold, 1.6, 1)

	local bannerLabel = Instance.new("TextLabel")
	bannerLabel.Name = "BannerText"
	bannerLabel.Position = UDim2.fromOffset(14, 0)
	bannerLabel.Size = UDim2.new(1, -28, 1, 0)
	bannerLabel.BackgroundTransparency = 1
	bannerLabel.Font = Enum.Font.GothamBlack
	bannerLabel.Text = ""
	bannerLabel.TextSize = 15
	bannerLabel.TextColor3 = TOKENS.textPrimary
	bannerLabel.TextTransparency = 1
	bannerLabel.TextXAlignment = Enum.TextXAlignment.Center
	bannerLabel.Parent = bannerFrame

	-- -------------------------------------------------------------------------
	-- 5. 66-Aura Collection Codex Modal (Bento-Grid Showcase)
	-- -------------------------------------------------------------------------
	local codexModal = Instance.new("Frame")
	codexModal.Name = "AuraCodexModal"
	codexModal.AnchorPoint = Vector2.new(0.5, 0.5)
	codexModal.Position = UDim2.new(0.5, 0, 0.5, 0)
	codexModal.Size = UDim2.fromOffset(820, 540)
	codexModal.BackgroundColor3 = TOKENS.bgSurface
	codexModal.BackgroundTransparency = 0.05
	codexModal.BorderSizePixel = 0
	codexModal.Visible = false
	codexModal.Parent = screenGui
	addCorner(codexModal, 18)
	addStroke(codexModal, TOKENS.borderStrong, 1.4, 0.3)
	addGradient(codexModal, TOKENS.bgSurfaceRaised, TOKENS.bgSurface, 90)

	local codexHeader = Instance.new("TextLabel")
	codexHeader.Name = "Header"
	codexHeader.Position = UDim2.fromOffset(24, 18)
	codexHeader.Size = UDim2.new(1, -120, 0, 24)
	codexHeader.BackgroundTransparency = 1
	codexHeader.Font = Enum.Font.GothamBlack
	codexHeader.Text = "AURA CODEX (66 DISCOVERIES)"
	codexHeader.TextSize = 18
	codexHeader.TextColor3 = TOKENS.textPrimary
	codexHeader.TextXAlignment = Enum.TextXAlignment.Left
	codexHeader.Parent = codexModal

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -20, 0, 16)
	closeBtn.Size = UDim2.fromOffset(36, 36)
	closeBtn.BackgroundColor3 = TOKENS.bgSurfaceRaised
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.Text = "✕"
	closeBtn.TextSize = 16
	closeBtn.TextColor3 = TOKENS.textSecondary
	closeBtn.BorderSizePixel = 0
	closeBtn.Parent = codexModal
	addCorner(closeBtn, 10)
	closeBtn.Activated:Connect(function()
		codexModal.Visible = false
	end)

	local codexScroll = Instance.new("ScrollingFrame")
	codexScroll.Name = "CodexScroll"
	codexScroll.Position = UDim2.fromOffset(20, 56)
	codexScroll.Size = UDim2.new(1, -40, 1, -72)
	codexScroll.BackgroundTransparency = 1
	codexScroll.BorderSizePixel = 0
	codexScroll.ScrollBarThickness = 5
	codexScroll.ScrollBarImageColor3 = TOKENS.borderStrong
	codexScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	codexScroll.Parent = codexModal

	local codexGrid = Instance.new("UIGridLayout")
	codexGrid.CellSize = UDim2.fromOffset(180, 86)
	codexGrid.CellPadding = UDim2.fromOffset(10, 10)
	codexGrid.SortOrder = Enum.SortOrder.LayoutOrder
	codexGrid.Parent = codexScroll

	-- Populate all 66 Auras into Codex Grid
	for orderIdx, auraId in ipairs(AuraCatalog.ORDER) do
		local entry = AuraCatalog.Get(auraId)
		if entry ~= nil then
			local card = Instance.new("Frame")
			card.Name = "CodexCard_" .. auraId
			card.BackgroundColor3 = TOKENS.bgCanvas
			card.BorderSizePixel = 0
			card.LayoutOrder = orderIdx
			card.Parent = codexScroll
			addCorner(card, 10)
			local stroke = addStroke(card, TOKENS.borderSubtle, 1.0, 0.6)

			local tierBar = Instance.new("Frame")
			tierBar.Name = "TierBar"
			tierBar.Position = UDim2.fromOffset(0, 0)
			tierBar.Size = UDim2.new(0, 4, 1, 0)
			tierBar.BackgroundColor3 = Color3.fromRGB(entry.tierColor.r, entry.tierColor.g, entry.tierColor.b)
			tierBar.BorderSizePixel = 0
			tierBar.Parent = card
			addCorner(tierBar, 2)

			local nameLbl = Instance.new("TextLabel")
			nameLbl.Name = "AuraName"
			nameLbl.Position = UDim2.fromOffset(12, 8)
			nameLbl.Size = UDim2.new(1, -16, 0, 16)
			nameLbl.BackgroundTransparency = 1
			nameLbl.Font = Enum.Font.GothamBold
			nameLbl.Text = entry.displayName
			nameLbl.TextSize = 13
			nameLbl.TextColor3 = Color3.fromRGB(entry.tierColor.r, entry.tierColor.g, entry.tierColor.b)
			nameLbl.TextXAlignment = Enum.TextXAlignment.Left
			nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
			nameLbl.Parent = card

			local tierLbl = Instance.new("TextLabel")
			tierLbl.Name = "Tier"
			tierLbl.Position = UDim2.fromOffset(12, 26)
			tierLbl.Size = UDim2.new(1, -16, 0, 14)
			tierLbl.BackgroundTransparency = 1
			tierLbl.Font = Enum.Font.Gotham
			tierLbl.Text = string.upper(entry.tier)
			tierLbl.TextSize = 10
			tierLbl.TextColor3 = TOKENS.textSecondary
			tierLbl.TextXAlignment = Enum.TextXAlignment.Left
			tierLbl.Parent = card

			local oddsLbl = Instance.new("TextLabel")
			oddsLbl.Name = "Odds"
			oddsLbl.Position = UDim2.fromOffset(12, 42)
			oddsLbl.Size = UDim2.new(1, -16, 0, 14)
			oddsLbl.BackgroundTransparency = 1
			oddsLbl.Font = Enum.Font.Code
			oddsLbl.Text = "1 in " .. formatNumber(entry.rarity)
			oddsLbl.TextSize = 11
			oddsLbl.TextColor3 = TOKENS.textTertiary
			oddsLbl.TextXAlignment = Enum.TextXAlignment.Left
			oddsLbl.Parent = card

			local statusLbl = Instance.new("TextLabel")
			statusLbl.Name = "Status"
			statusLbl.Position = UDim2.fromOffset(12, 60)
			statusLbl.Size = UDim2.new(1, -16, 0, 16)
			statusLbl.BackgroundTransparency = 1
			statusLbl.Font = Enum.Font.GothamBold
			statusLbl.Text = "NOT DISCOVERED"
			statusLbl.TextSize = 10
			statusLbl.TextColor3 = TOKENS.textLocked
			statusLbl.TextXAlignment = Enum.TextXAlignment.Left
			statusLbl.Parent = card
		end
	end

	-- -------------------------------------------------------------------------
	-- Methods
	-- -------------------------------------------------------------------------
	local function setCodexVisible(visible: boolean)
		codexModal.Visible = visible
	end

	codexBtn.Activated:Connect(function()
		setCodexVisible(not codexModal.Visible)
	end)

	local function playReveal(auraId: string, rarity: number, isGuaranteed: boolean)
		local entry = AuraCatalog.Get(auraId)
		if entry == nil then
			return
		end

		revealFrame.Visible = true
		revealFrame.BackgroundTransparency = 0.08
		revealStroke.Color = Color3.fromRGB(entry.primary.r, entry.primary.g, entry.primary.b)
		revealStroke.Transparency = 0.1

		revealTier.Text = string.upper(entry.tier)
		revealTier.TextColor3 = Color3.fromRGB(entry.tierColor.r, entry.tierColor.g, entry.tierColor.b)
		revealTier.TextTransparency = 0

		revealName.Text = entry.displayName
		revealName.TextColor3 = Color3.fromRGB(entry.primary.r, entry.primary.g, entry.primary.b)
		revealName.TextTransparency = 0

		revealSubtitle.Text = entry.subtitle
		revealSubtitle.TextTransparency = 0

		if isGuaranteed then
			revealOdds.Text = string.format("1 IN %s  •  GUARANTEED BY PITY", formatNumber(rarity))
			revealOdds.TextColor3 = TOKENS.accentRed
		else
			revealOdds.Text = string.format("1 IN %s", formatNumber(rarity))
			revealOdds.TextColor3 = TOKENS.accentGold
		end
		revealOdds.TextTransparency = 0

		-- Spring Pop Animation
		revealScale.Scale = 0.72
		local tween = TweenService:Create(
			revealScale,
			TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1.08 }
		)
		tween:Play()
		tween.Completed:Once(function()
			TweenService:Create(
				revealScale,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = 1.0 }
			):Play()
		end)

		Audio.PlayRollReveal(entry.soundProfile, rarity)

		task.delay(2.6, function()
			TweenService:Create(revealFrame, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
			TweenService:Create(revealStroke, TweenInfo.new(0.35), { Transparency = 1 }):Play()
			TweenService:Create(revealName, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			TweenService:Create(revealTier, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			TweenService:Create(revealSubtitle, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			TweenService:Create(revealOdds, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			task.delay(0.4, function()
				revealFrame.Visible = false
			end)
		end)
	end

	local function showBanner(username: string, auraName: string, rarity: number, color: Color3)
		bannerLabel.Text = string.format("%s rolled %s  •  1 in %s", username, string.upper(auraName), formatNumber(rarity))
		bannerLabel.TextColor3 = color
		bannerStroke.Color = color
		bannerFrame.Visible = true

		bannerFrame.Position = UDim2.new(0.5, 0, 0, -80)
		bannerFrame.BackgroundTransparency = 0.08
		bannerLabel.TextTransparency = 0
		bannerStroke.Transparency = 0.2

		local drop = TweenService:Create(
			bannerFrame,
			TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, 0, 0, 130) }
		)
		drop:Play()

		task.delay(3.5, function()
			local ret = TweenService:Create(
				bannerFrame,
				TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Position = UDim2.new(0.5, 0, 0, -80), BackgroundTransparency = 1 }
			)
			ret:Play()
			ret.Completed:Once(function()
				bannerFrame.Visible = false
			end)
		end)
	end

	return {
		gui = screenGui,
		pityFill = pityFill,
		pityLabel = pityLabel,
		pitySubLabel = pitySubLabel,
		statsLabel = statsLabel,
		rollButton = rollBtn,
		cooldownFill = cooldownFill,
		autoButton = autoBtn,
		fastButton = fastBtn,
		lowVfxButton = lowVfxBtn,
		codexButton = codexBtn,
		revealFrame = revealFrame,
		revealName = revealName,
		revealTier = revealTier,
		revealOdds = revealOdds,
		revealSubtitle = revealSubtitle,
		revealScale = revealScale,
		bannerFrame = bannerFrame,
		bannerLabel = bannerLabel,
		codexModal = codexModal,
		codexScroll = codexScroll,
		setCodexVisible = setCodexVisible,
		playReveal = playReveal,
		showBanner = showBanner,
	}
end

return HUD
