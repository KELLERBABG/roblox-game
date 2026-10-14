--!strict
--[[
	ShopUI (client)
	===============
	The shop panel, as its own module so MainUI only has to mount it. MainUI owns
	the HUD; this file owns the shop's panel, its state and its buttons.

	WHAT IT IS ALLOWED TO DO
	------------------------
	Render, and ask. Every intent leaves through a remote:
	  * ShopAction   -> "RequestCatalog" | "PromptPass" | "PromptProduct" (keys)
	  * PerkAction   -> "RequestState" | "SetTestMode" | "SimulateProduct" (keys)
	Nothing here computes a perk, grants an item or decides ownership. The panel
	displays what the server said and re-renders when the server says something
	new, which is why the Test Mode toggle has no optimistic local state: the
	button shows what the server reports, not what was clicked.

	TWO SOURCES, ONE DATUM EACH
	---------------------------
	ShopCatalog carries the display catalog (names, perks *as numbers*, whether an
	id is configured). PerkState carries per-player truth (owned passes, Test
	Mode, potion charges, the server boost). The panel merges them; neither source
	repeats the other's facts.

	The perk numbers are sent, not the sentences: "+500% luck" is formatted here
	from `luckMultiplier = 6`, so editing balance in MonetizationConfig can never
	leave stale copy in this file.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 60) :: Folder

-- The two writing doors. Validation lives with the module that owns the state,
-- so the shop's prompt intents go to ShopService and the perk intents go to
-- PerkService - neither is trusted with a value it did not compute itself.
local ShopAction = Remotes:WaitForChild("ShopAction", 30) :: RemoteEvent
local ShopCatalog = Remotes:WaitForChild("ShopCatalog", 30) :: RemoteEvent
local ShopNotice = Remotes:WaitForChild("ShopNotice", 30) :: RemoteEvent
local PerkAction = Remotes:WaitForChild("PerkAction", 30) :: RemoteEvent
local PerkState = Remotes:WaitForChild("PerkState", 30) :: RemoteEvent

local PANEL_WIDTH: number = 764
local PANEL_HEIGHT: number = 600
local CARD_HEIGHT: number = 100

-- =============================================================================
-- Mount contract (MainUI passes its own UI helpers so the shop cannot drift
-- away from the HUD's look)
-- =============================================================================

type MountOptions = {
	parent: Instance,
	button: TextButton,
	theme: { [string]: Color3 },
	makeFrame: (Instance, { [string]: any }) -> Frame,
	makeLabel: (Instance, { [string]: any }) -> TextLabel,
	makeButton: (Instance, { [string]: any }) -> TextButton,
	addCorner: (Instance, number) -> any,
	addStroke: (Instance, Color3, number, number) -> any,
	addGradient: (Instance, Color3, Color3, number) -> any,
	wireHover: (TextButton, () -> Color3, Color3) -> (),
	showToast: (string, Color3?) -> (),
}

local ShopUI = {}

local theme: { [string]: Color3 } = nil :: any
local makeFrame: (Instance, { [string]: any }) -> Frame
local makeLabel: (Instance, { [string]: any }) -> TextLabel
local makeButton: (Instance, { [string]: any }) -> TextButton
local addCorner: (Instance, number) -> any
local addStroke: (Instance, Color3, number, number) -> any
local addGradient: (Instance, Color3, Color3, number) -> any
local wireHover: (TextButton, () -> Color3, Color3) -> ()
local showToast: (string, Color3?) -> ()

-- =============================================================================
-- State
-- =============================================================================

type Card = {
	key: string,
	kind: string,
	entry: { [string]: any },
	accent: Color3,
	frame: Frame,
	action: TextButton,
	actionStroke: UIStroke,
	-- GuiButton.Active is a rendering hint, not a gate: the handler checks this
	-- flag itself so a "disabled" button can never act.
	state: { clickable: boolean },
}

local catalog: { [string]: any }? = nil
local perks: { [string]: any }? = nil
local isOpen = false
local mounted = false

local panel: Frame = nil :: any
local testButton: TextButton = nil :: any
local testStroke: UIStroke = nil :: any
local noticeLabel: TextLabel = nil :: any
local statusLabels: { [string]: TextLabel } = {}
local cards: { Card } = {}

local DEFAULT_NOTICE: string =
	"Items marked NO ID YET are not on sale yet - the server still needs their real pass or product ids."

-- =============================================================================
-- Formatting (display policy, derived from numbers the server sends)
-- =============================================================================

local function formatMultiplier(value: number): string
	if value >= 10 then
		return string.format("%.0fx", value)
	end
	-- "1.00" -> "1x", "1.25" -> "1.25x": trailing zeros are noise on a chip.
	local text = string.gsub(string.format("%.2f", value), "0+$", "")
	text = string.gsub(text, "%.$", "")
	return text .. "x"
end

local function formatDuration(seconds: number): string
	if seconds % 60 == 0 then
		return string.format("%d MIN", seconds / 60)
	end
	return string.format("%d SEC", seconds)
end

local function chipText(entry: { [string]: any }, kind: string): string
	local parts: { string } = {}

	local luck = entry.luckMultiplier
	if type(luck) == "number" and luck > 1 then
		if kind == "product" then
			table.insert(parts, string.format("+%d%% LUCK", math.floor((luck - 1) * 100 + 0.5)))
		else
			table.insert(parts, formatMultiplier(luck) .. " LUCK")
		end
	end

	local cooldown = entry.cooldownMultiplier
	if type(cooldown) == "number" and cooldown > 0 and cooldown < 1 then
		table.insert(parts, string.format("-%d%% COOLDOWN", math.floor((1 - cooldown) * 100 + 0.5)))
	end
	if entry.unlocksAutoRoll == true then
		table.insert(parts, "AUTO-ROLL")
	end
	if entry.givesNametag == true then
		table.insert(parts, "GOLD NAMETAG")
	end

	local charges = entry.charges
	if type(charges) == "number" and charges > 0 then
		table.insert(parts, if charges == 1 then "NEXT ROLL ONLY" else string.format("%d ROLLS", charges))
	end

	local duration = entry.durationSeconds
	if type(duration) == "number" and duration > 0 then
		table.insert(parts, formatDuration(duration) .. ", SERVER-WIDE")
	end

	if entry.configured ~= true then
		table.insert(parts, "NO ID YET")
	end

	return table.concat(parts, "  \226\128\162  ")
end

-- =============================================================================
-- Panel construction
-- =============================================================================

local function setNotice(message: string, color: Color3?): ()
	noticeLabel.Text = message
	noticeLabel.TextColor3 = color or theme.textDim
end	local function buildStatusRow(parent: Instance, name: string, label: string, x: number, y: number): ()
	makeLabel(parent, {
		Name = name .. "Caption",
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(160, 16),
		Text = label,
		TextSize = 11,
		Font = Enum.Font.GothamBold,
		TextColor3 = theme.textDim,
	})
	statusLabels[name] = makeLabel(parent, {
		Name = name,
		Position = UDim2.fromOffset(x, y + 16),
		Size = UDim2.fromOffset(330, 22),
		Text = "-",
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		TextColor3 = theme.text,
	})
end

local function buildPanel(options: MountOptions): ()
	panel = makeFrame(options.parent, {
		Name = "ShopPanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -10),
		Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = 0.03,
		Visible = false,
	})
	addCorner(panel, 18)
	addStroke(panel, theme.stroke, 1.5, 0.3)
	addGradient(panel, theme.panelRaised, theme.panel, 90)

	makeLabel(panel, {
		Name = "Title",
		Position = UDim2.fromOffset(20, 14),
		Size = UDim2.fromOffset(300, 24),
		Text = "SHOP",
		TextSize = 22,
		Font = Enum.Font.GothamBlack,
		TextColor3 = theme.text,
	})
	makeLabel(panel, {
		Name = "Subtitle",
		Position = UDim2.fromOffset(20, 40),
		Size = UDim2.fromOffset(PANEL_WIDTH - 160, 18),
		Text = "Passes are permanent. Potions pay for one roll. Boosts apply to everyone in this server.",
		TextSize = 12,
		TextColor3 = theme.textDim,
	})

	local closeButton = makeButton(panel, {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 16),
		Size = UDim2.fromOffset(40, 32),
		Text = "X",
		TextSize = 16,
	})
	addCorner(closeButton, 9)
	addStroke(closeButton, theme.stroke, 1.2, 0.35)
	closeButton.Activated:Connect(function()
		ShopUI.Close()
	end)
	wireHover(closeButton, function(): Color3
		return theme.panelRaised
	end, theme.raisedHover)

	-- Status readout: what the server currently says about this player.
	local statusFrame = makeFrame(panel, {
		Name = "Status",
		Position = UDim2.fromOffset(18, 66),
		Size = UDim2.fromOffset(PANEL_WIDTH - 36, 72),
		BackgroundColor3 = Color3.fromRGB(12, 14, 21),
		BackgroundTransparency = 0.15,
	})
	addCorner(statusFrame, 12)
	addStroke(statusFrame, theme.stroke, 1, 0.55)

	buildStatusRow(statusFrame, "Luck", "LUCK NOW", 16, 8)
	buildStatusRow(statusFrame, "Cooldown", "ROLL COOLDOWN", 16, 40)
	buildStatusRow(statusFrame, "Potion", "ARMED POTION", 366, 8)
	buildStatusRow(statusFrame, "Boost", "SERVER BOOST", 366, 40)

	-- Test Mode row.
	testButton = makeButton(panel, {
		Name = "TestModeButton",
		Position = UDim2.fromOffset(18, 148),
		Size = UDim2.fromOffset(196, 36),
		Text = "TEST MODE: OFF",
		TextSize = 13,
	})
	addCorner(testButton, 10)
	testStroke = addStroke(testButton, theme.stroke, 1.2, 0.4)
	addGradient(testButton, theme.panelRaised, theme.panel, 90)
	testButton.Activated:Connect(function()
		local current = perks
		if current == nil or current.testModeAllowed ~= true then
			setNotice("Test Mode is not allowed on this server.", theme.warn)
			return
		end
		-- Ask, do not assume: the button reflects the server's answer.
		PerkAction:FireServer("SetTestMode", current.testMode ~= true)
		setNotice("Asked the server to switch Test Mode...", theme.textDim)
	end)
	wireHover(testButton, function(): Color3
		return theme.panelRaised
	end, theme.raisedHover)

	makeLabel(panel, {
		Name = "TestModeHint",
		Position = UDim2.fromOffset(226, 152),
		Size = UDim2.fromOffset(PANEL_WIDTH - 260, 30),
		Text = "Test Mode fakes ownership with a server-side flag, so every perk below can be tried in Studio with no published assets.",
		TextSize = 11,
		TextColor3 = theme.textDim,
		TextWrapped = true,
	})

	-- Catalog list.
	local list = Instance.new("ScrollingFrame") :: ScrollingFrame
	list.Name = "Catalog"
	list.Position = UDim2.fromOffset(18, 192)
	list.Size = UDim2.fromOffset(PANEL_WIDTH - 36, 366)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.ScrollBarImageColor3 = theme.stroke
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = panel

	local layout = Instance.new("UIListLayout") :: UIListLayout
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	noticeLabel = makeLabel(panel, {
		Name = "Notice",
		Position = UDim2.fromOffset(20, PANEL_HEIGHT - 32),
		Size = UDim2.fromOffset(PANEL_WIDTH - 40, 20),
		Text = DEFAULT_NOTICE,
		TextSize = 11,
		TextColor3 = theme.textDim,
	})
end

-- =============================================================================
-- Cards
-- =============================================================================

local updateCards: () -> () = nil :: any

local function createCard(kind: string, entry: { [string]: any }, order: number): ()
	local accent = Color3.fromRGB(entry.accent.r, entry.accent.g, entry.accent.b)
	local list = panel:FindFirstChild("Catalog") :: ScrollingFrame

	local card = makeFrame(list, {
		Name = string.format("%s_%s", kind, entry.key),
		Size = UDim2.new(1, -10, 0, CARD_HEIGHT),
		BackgroundColor3 = theme.panelRaised,
		BackgroundTransparency = 0.1,
		LayoutOrder = order,
	})
	addCorner(card, 12)
	addStroke(card, theme.stroke, 1.2, 0.5)

	local accentBar = makeFrame(card, {
		Name = "Accent",
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.fromOffset(4, CARD_HEIGHT - 28),
		BackgroundColor3 = accent,
	})
	addCorner(accentBar, 2)

	makeLabel(card, {
		Name = "Name",
		Position = UDim2.fromOffset(18, 12),
		Size = UDim2.new(1, -220, 0, 22),
		Text = entry.displayName,
		TextSize = 17,
		Font = Enum.Font.GothamBold,
	})

	makeLabel(card, {
		Name = "Chip",
		Position = UDim2.fromOffset(18, 34),
		Size = UDim2.new(1, -220, 0, 16),
		Text = chipText(entry, kind),
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		TextColor3 = accent,
	})

	makeLabel(card, {
		Name = "Description",
		Position = UDim2.fromOffset(18, 52),
		Size = UDim2.new(1, -230, 0, 36),
		Text = entry.description,
		TextSize = 12,
		TextColor3 = theme.textDim,
		TextWrapped = true,
	})

	local action = makeButton(card, {
		Name = "Action",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(158, 42),
		Text = "...",
		TextSize = 14,
	})
	addCorner(action, 10)
	local actionStroke = addStroke(action, accent, 1.3, 0.5)
	addGradient(action, theme.raisedHover, theme.panelRaised, 90)

	wireHover(action, function(): Color3
		return theme.panelRaised
	end, theme.raisedHover)

	local cardState = { clickable = true }

	action.Activated:Connect(function()
		if not cardState.clickable then
			return
		end

		local current = perks
		-- Test Mode is the server's flag, and only where the server allows it. If
		-- it says otherwise, this branch simply never runs.
		local inTestMode = current ~= nil and current.testMode == true and current.testModeAllowed == true

		if kind == "product" and inTestMode then
			-- The same grant path a real receipt runs, minus the receipt.
			PerkAction:FireServer("SimulateProduct", entry.key)
			return
		end

		if entry.configured ~= true then
			setNotice(string.format(
				"%s is not on sale yet. (Server: set its id in MonetizationConfig to sell it.)",
				entry.displayName
			), theme.warn)
			return
		end

		if kind == "product" then
			ShopAction:FireServer("PromptProduct", entry.key)
		else
			ShopAction:FireServer("PromptPass", entry.key)
		end
	end)

	table.insert(cards, {
		key = entry.key,
		kind = kind,
		entry = entry,
		accent = accent,
		frame = card,
		action = action,
		actionStroke = actionStroke,
		state = cardState,
	})
end

-- Cards are built once, from the catalog, and then only ever re-labelled. They
-- are parented into a UIListLayout, so `LayoutOrder` alone decides the order and
-- no absolute positioning is involved.
local function buildCards(): ()
	local current = catalog
	if current == nil then
		return
	end

	for _, card in ipairs(cards) do
		card.frame:Destroy()
	end
	table.clear(cards)

	local list = panel:FindFirstChild("Catalog") :: ScrollingFrame
	for _, stale in ipairs(list:GetChildren()) do
		if stale:IsA("TextLabel") then
			stale:Destroy()
		end
	end

	local order = 0
	local function caption(text: string): ()
		order += 1
		makeLabel(list, {
			Name = "Caption",
			Size = UDim2.new(1, -10, 0, 16),
			Text = text,
			TextSize = 11,
			Font = Enum.Font.GothamBold,
			TextColor3 = theme.textDim,
			LayoutOrder = order,
		})
	end

	caption("GAME PASSES \226\128\162 PERMANENT")
	for _, entry in ipairs(current.passes or {}) do
		order += 1
		createCard("pass", entry, order)
	end

	caption("DEVELOPER PRODUCTS \226\128\162 CONSUMABLE")
	for _, entry in ipairs(current.products or {}) do
		order += 1
		createCard("product", entry, order)
	end

	updateCards()
end

--[[
	One place decides what each button says, from the server's answers only:
	  * a pass the server reports as owned (really owned, or Test Mode) is OWNED;
	  * a product in Test Mode offers TEST, which runs the real grant code;
	  * a configured entry offers BUY, which prompts Roblox;
	  * an unconfigured entry says so instead of prompting an id of 0.
]]
updateCards = function(): ()
	local currentPerks = perks
	local ownedPassKeys: { [string]: boolean } = {}
	if currentPerks ~= nil and type(currentPerks.ownedPassKeys) == "table" then
		ownedPassKeys = currentPerks.ownedPassKeys
	end
	local testMode = currentPerks ~= nil and currentPerks.testMode == true
	local testAllowed = currentPerks ~= nil and currentPerks.testModeAllowed == true

	for _, card in ipairs(cards) do
		local text = "BUY"
		-- An unconfigured entry stays CLICKABLE on purpose: pressing it is how a
		-- developer finds out that the id still has to be pasted in. Only OWNED
		-- has nothing left to do.
		local clickable = true
		local color = card.accent

		if card.kind == "pass" and ownedPassKeys[card.key] == true then
			text = if testMode then "OWNED (TEST)" else "OWNED"
			clickable = false
			color = theme.success
		elseif card.kind == "product" and testMode and testAllowed then
			text = "TEST"
			color = theme.warm
		elseif card.entry.configured ~= true then
			text = "NO ID YET"
			color = theme.locked
		end

		card.state.clickable = clickable
		card.action.Text = text
		card.action.TextColor3 = if clickable then theme.text else color
		card.action.Active = clickable
		card.action.Selectable = clickable
		card.actionStroke.Color = color
		card.action.BackgroundTransparency = if clickable then 0 else 0.45
	end
end

-- =============================================================================
-- Rendering from server state
-- =============================================================================

local function renderPerks(): ()
	local current = perks
	if current == nil then
		return
	end

	local cooldownMultiplier = tonumber(current.cooldownMultiplier) or 1
	statusLabels.Luck.Text = formatMultiplier(tonumber(current.luckMultiplier) or 1) .. "  (passes, potion and boost combined)"
	-- A multiplier, not seconds: this panel does not know the base cooldown, and
	-- inventing one here would be a second copy of RNGService's number.
	statusLabels.Cooldown.Text = string.format(
		"%s  (%s)",
		formatMultiplier(cooldownMultiplier),
		if cooldownMultiplier < 1 then "Fast Roll pass engaged" else "base"
	)

	local charges = tonumber(current.potionCharges) or 0
	local potionMultiplier = tonumber(current.potionMultiplier) or 1
	statusLabels.Potion.Text = if charges > 0
		then string.format("%s for the next %d roll(s)", formatMultiplier(potionMultiplier), charges)
		else "none armed"
	statusLabels.Potion.TextColor3 = if charges > 0 then theme.warm else theme.textDim

	local boost = tonumber(current.boostMultiplier) or 1
	local remaining = tonumber(current.boostSecondsRemaining) or 0
	statusLabels.Boost.Text = if boost > 1
		then string.format("%s  %d:%02d left", formatMultiplier(boost), math.floor(remaining / 60), math.floor(remaining % 60))
		else "none active"
	statusLabels.Boost.TextColor3 = if boost > 1 then theme.success else theme.textDim

	local testMode = current.testMode == true
	local allowed = current.testModeAllowed == true
	testButton.Text = if testMode then "TEST MODE: ON" else "TEST MODE: OFF"
	testButton.TextColor3 = if testMode then theme.text else theme.textDim
	testStroke.Color = if testMode then theme.warm else theme.stroke
	testStroke.Transparency = if testMode then 0.05 else 0.4
	testButton.BackgroundTransparency = if allowed then 0 else 0.45
	testButton.Active = allowed

	updateCards()
end

-- =============================================================================
-- Public surface
-- =============================================================================

function ShopUI.Open(): ()
	panel.Visible = true
	isOpen = true
	noticeLabel.Text = DEFAULT_NOTICE
	noticeLabel.TextColor3 = theme.textDim

	-- Ask for both halves of the picture: a RemoteEvent fired before this script
	-- connected was dropped, so never assume the join-time push arrived.
	ShopAction:FireServer("RequestCatalog")
	PerkAction:FireServer("RequestState")
end

function ShopUI.Close(): ()
	panel.Visible = false
	isOpen = false
end

function ShopUI.Toggle(): ()
	if isOpen then
		ShopUI.Close()
	else
		ShopUI.Open()
	end
end

function ShopUI.Mount(options: MountOptions): ()
	if mounted then
		return
	end
	mounted = true

	theme = options.theme
	makeFrame = options.makeFrame
	makeLabel = options.makeLabel
	makeButton = options.makeButton
	addCorner = options.addCorner
	addStroke = options.addStroke
	addGradient = options.addGradient
	wireHover = options.wireHover
	showToast = options.showToast

	buildPanel(options)

	options.button.Activated:Connect(function()
		ShopUI.Toggle()
	end)

	ShopCatalog.OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		local firstCatalog = catalog == nil
		catalog = payload
		if firstCatalog then
			buildCards()
		end
		updateCards()
	end)

	PerkState.OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" then
			return
		end

		-- A server-wide boost has to be visible to EVERY player, not only the one
		-- with the shop open, so an increase announces itself through the HUD
		-- toast. Comparing against the previous value (rather than `boost > 1`)
		-- keeps the once-a-second boost ticks from repeating the toast.
		local previousBoost = if perks ~= nil then tonumber(perks.boostMultiplier) or 1 else 1
		local boost = tonumber(payload.boostMultiplier) or 1

		perks = payload
		renderPerks()

		if boost > 1 and boost > previousBoost then
			local remaining = tonumber(payload.boostSecondsRemaining) or 0
			showToast(
				string.format(
					"SERVER LUCK BOOST %s for everyone - %d:%02d",
					formatMultiplier(boost),
					math.floor(remaining / 60),
					math.floor(remaining % 60)
				),
				theme.success
			)
		end
	end)

	ShopNotice.OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" or type(payload.text) ~= "string" then
			return
		end
		local kind = payload.kind
		local color = if kind == "grant" then theme.success elseif kind == "warn" then theme.warn else theme.textDim
		setNotice(payload.text, color)
		showToast(payload.text, color)
	end)

	-- Ask rather than wait: this script may have connected after the server's
	-- join-time pushes.
	PerkAction:FireServer("RequestState")
	ShopAction:FireServer("RequestCatalog")
end

function ShopUI.IsOpen(): boolean
	return isOpen
end

return ShopUI
