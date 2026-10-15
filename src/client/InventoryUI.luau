--!strict
--[[
	InventoryUI (client)
	====================
	The left-hand drawer: the collection grid (equip or delete one copy, per aura)
	and the Auto-Filter that keeps an AFK session from filling up with junk.

	Its own module so MainUI only has to mount it, exactly like ShopUI: MainUI owns
	the HUD and the roll presentation, this file owns every pixel and every remote
	of the drawer.

	WHAT IT IS ALLOWED TO DO
	------------------------
	Render, and ask. Three intents leave through remotes:
	  * EquipAura  (auraId)          - equip an owned aura
	  * DeleteAura (auraId)          - delete exactly one owned copy
	  * SetFilter  (mode, rarity)    - set the auto-filter
	Nothing here decides ownership, counts copies, or validates a threshold. There
	is no optimistic local state anywhere: clicking SKIP does not light SKIP up,
	the server does, by syncing the setting back. That is why a refused request
	looks like nothing happening rather than like a lie.

	THE OPTIONS ARE THE SERVER'S
	----------------------------
	The threshold control offers `payload.filter.options` - the ladder rungs the
	server derived from AuraRegistry - and renders their labels. This file has no
	tier list of its own, so it cannot offer a threshold the game does not contain,
	and adding an aura to the ladder adds an option here with no edit.

	"BELOW" IS STRICT
	-----------------
	A pull at exactly the chosen rung is kept; only less-rare pulls are dropped.
	The copy below the control says so, because a player setting "below Rare" and
	losing a Rare would rightly call that a bug.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 30) :: Folder
local auraRegistryModule = Shared:WaitForChild("AuraRegistry", 30)
if auraRegistryModule == nil then
	error("[InventoryUI] ReplicatedStorage.Shared.AuraRegistry is missing.")
end
local AuraRegistry: any = require(auraRegistryModule :: ModuleScript)

local remotesInstance = ReplicatedStorage:WaitForChild("Remotes", 60)
if remotesInstance == nil then
	error("[InventoryUI] ReplicatedStorage.Remotes never appeared. Is RNGService running?")
end
local Remotes = remotesInstance :: Folder

local EquipAura = Remotes:WaitForChild("EquipAura", 30) :: RemoteEvent
local DeleteAura = Remotes:WaitForChild("DeleteAura", 30) :: RemoteEvent
local SetFilter = Remotes:WaitForChild("SetFilter", 30) :: RemoteEvent

--[[
	Geometry, stated once because the numbers have to agree. The drawer is
	centred vertically on the left, so its height decides both ends: at 720p the
	action bar starts 94px above the bottom, and 504 tall leaves the last grid row
	clear of it instead of tucked behind it. The grid takes whatever is left
	(`1, -152`), so the four visible rows survive any taller screen.
]]
local PANEL_WIDTH: number = 286
local PANEL_HEIGHT: number = 504
local HEADER_HEIGHT: number = 36

-- =============================================================================
-- Mount contract (MainUI passes its own UI helpers, so the drawer cannot drift
-- away from the HUD's look)
-- =============================================================================

type MountOptions = {
	parent: Instance,
	theme: { [string]: Color3 },
	makeFrame: (Instance, { [string]: any }) -> Frame,
	makeLabel: (Instance, { [string]: any }) -> TextLabel,
	makeButton: (Instance, { [string]: any }) -> TextButton,
	addCorner: (Instance, number) -> any,
	addStroke: (Instance, Color3, number, number) -> any,
	addGradient: (Instance, Color3, Color3, number) -> any,
	wireHover: (TextButton, () -> Color3, Color3) -> (),
	formatNumber: (number) -> string,
}

-- One offered threshold. Mirrors the shape RNGService sends; the harness pins
-- that shape server-side, so this mirror cannot drift unnoticed.
type FilterOption = {
	rarity: number,
	tier: string,
	auraId: string,
	displayName: string,
}

type Cell = {
	button: TextButton,
	stroke: UIStroke,
	nameLabel: TextLabel,
	tierLabel: TextLabel,
	countLabel: TextLabel,
	badge: TextLabel,
	deleteButton: TextButton,
	deleteStroke: UIStroke,
}

local InventoryUI = {}

local theme: { [string]: Color3 } = nil :: any
local makeFrame: (Instance, { [string]: any }) -> Frame
local makeLabel: (Instance, { [string]: any }) -> TextLabel
local makeButton: (Instance, { [string]: any }) -> TextButton
local addCorner: (Instance, number) -> any
local addStroke: (Instance, Color3, number, number) -> any
local wireHover: (TextButton, () -> Color3, Color3) -> ()
local formatNumber: (number) -> string

-- =============================================================================
-- State (all of it a mirror of the last server payload)
-- =============================================================================

local mounted = false
local isOpen = true

local panel: Frame = nil :: any
local body: Frame = nil :: any
local drawerButton: TextButton = nil :: any
local drawerStroke: UIStroke = nil :: any
local grid: ScrollingFrame = nil :: any

local owned: { [string]: number } = {}
local equipped: string? = nil
local cells: { [string]: Cell } = {}

-- The filter as the SERVER last described it.
local filterMode: string = "off"
local filterRarity: number = 0
local filterOptions: { FilterOption } = {}
local filteredPulls: number = 0
local lastFiltered: any = nil

local modeButtons: { [string]: TextButton } = {}
local modeStrokes: { [string]: UIStroke } = {}
local thresholdLabel: TextLabel = nil :: any
local thresholdCaption: TextLabel = nil :: any
local tallyLabel: TextLabel = nil :: any
local prevButton: TextButton = nil :: any
local nextButton: TextButton = nil :: any

local function optionFor(rarity: number): FilterOption?
	for _, option in ipairs(filterOptions) do
		if option.rarity == rarity then
			return option
		end
	end
	return nil
end

local function optionIndex(rarity: number): number
	for index, option in ipairs(filterOptions) do
		if option.rarity == rarity then
			return index
		end
	end
	return 0
end

-- The rung the stepper shows: the chosen one, or the first rung when nothing is
-- chosen yet (the panel then shows what pressing "next" would select).
local function shownOption(): FilterOption?
	local chosen = optionFor(filterRarity)
	if chosen ~= nil then
		return chosen
	end
	return filterOptions[1]
end

local function thresholdName(): string
	local option = shownOption()
	if option == nil then
		return "the ladder"
	end
	return string.format("%s (1 in %s)", option.tier, formatNumber(option.rarity))
end

-- =============================================================================
-- The collection grid
-- =============================================================================

local function refreshCell(auraId: string): ()
	local cell = cells[auraId]
	if cell == nil then
		return
	end

	local config = AuraRegistry.Get(auraId)
	if config == nil then
		return
	end

	local count = owned[auraId] or 0
	local isEquipped = equipped == auraId

	if count > 0 then
		cell.button.BackgroundColor3 = theme.panelRaised
		cell.button.TextColor3 = theme.text
		cell.stroke.Color = if isEquipped then theme.success else theme.stroke
		cell.stroke.Transparency = if isEquipped then 0.05 else 0.45
		cell.nameLabel.TextColor3 = AuraRegistry.ToColor3(config.tierColor)
		cell.countLabel.Text = string.format("OWNED x%d", count)
		cell.countLabel.TextColor3 = theme.textDim
		cell.badge.Text = if isEquipped then "EQUIPPED" else "1 in " .. formatNumber(config.rarity)
		cell.badge.TextColor3 = if isEquipped then theme.success else theme.textDim
		-- Delete is only ever offered for something that is owned. Pressing it
		-- removes exactly one copy; the server refuses anything else.
		cell.deleteButton.Visible = true
		cell.deleteButton.Active = true
		cell.deleteStroke.Transparency = 0.35
	else
		cell.button.BackgroundColor3 = theme.backdrop
		cell.button.TextColor3 = theme.locked
		cell.stroke.Color = theme.locked
		cell.stroke.Transparency = 0.7
		cell.nameLabel.TextColor3 = theme.locked
		cell.countLabel.Text = "NOT FOUND"
		cell.countLabel.TextColor3 = theme.locked
		cell.badge.Text = "1 in " .. formatNumber(config.rarity)
		cell.badge.TextColor3 = theme.locked
		cell.deleteButton.Visible = false
		cell.deleteButton.Active = false
		cell.deleteStroke.Transparency = 1
	end
end

local function buildCell(auraId: string, order: number): ()
	local config = AuraRegistry.Get(auraId)
	if config == nil then
		return
	end

	local button = makeButton(grid, {
		Name = "Cell_" .. auraId,
		Text = "",
		BackgroundColor3 = theme.panelRaised,
		LayoutOrder = order,
	})
	addCorner(button, 10)
	local stroke = addStroke(button, theme.stroke, 1.2, 0.45)

	local colorStrip = makeFrame(button, {
		Name = "Accent",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(0, 4, 1, 0),
		BackgroundColor3 = AuraRegistry.ToColor3(config.tierColor),
	})
	addCorner(colorStrip, 2)

	local nameLabel = makeLabel(button, {
		Name = "AuraName",
		Position = UDim2.fromOffset(12, 7),
		Size = UDim2.new(1, -44, 0, 15),
		Text = config.displayName,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local tierLabel = makeLabel(button, {
		Name = "AuraTier",
		Position = UDim2.fromOffset(12, 23),
		Size = UDim2.new(1, -20, 0, 12),
		Text = config.tier,
		TextSize = 11,
		TextColor3 = theme.textDim,
	})

	local countLabel = makeLabel(button, {
		Name = "Owned",
		Position = UDim2.fromOffset(12, 37),
		Size = UDim2.new(1, -20, 0, 12),
		Text = "NOT FOUND",
		TextSize = 11,
		TextColor3 = theme.textDim,
		Font = Enum.Font.GothamBold,
	})

	local badge = makeLabel(button, {
		Name = "Badge",
		Position = UDim2.fromOffset(12, 49),
		Size = UDim2.new(1, -20, 0, 12),
		Text = "",
		TextSize = 10,
		TextColor3 = theme.textDim,
		Font = Enum.Font.Code,
	})

	--[[
		Delete is a separate button on the cell rather than a mode of the cell
		itself. Equipping is the common action and must stay one click; deleting
		must be deliberate, and it must not be possible to delete by mis-clicking
		the card. It still only ever asks - the server decides.
	]]
	local deleteButton = makeButton(button, {
		Name = "Delete",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(22, 20),
		Text = "X",
		TextSize = 12,
		BackgroundColor3 = theme.backdrop,
		BackgroundTransparency = 0.25,
	})
	addCorner(deleteButton, 6)
	local deleteStroke = addStroke(deleteButton, theme.danger, 1, 0.35)
	deleteButton.TextColor3 = theme.danger
	deleteButton.Visible = false

	cells[auraId] = {
		button = button,
		stroke = stroke,
		nameLabel = nameLabel,
		tierLabel = tierLabel,
		countLabel = countLabel,
		badge = badge,
		deleteButton = deleteButton,
		deleteStroke = deleteStroke,
	}

	button.MouseEnter:Connect(function()
		if (owned[auraId] or 0) > 0 then
			TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = theme.raisedHover }):Play()
		end
	end)
	button.MouseLeave:Connect(function()
		refreshCell(auraId)
	end)
	button.Activated:Connect(function()
		if (owned[auraId] or 0) <= 0 then
			return
		end
		if equipped == auraId then
			return
		end
		EquipAura:FireServer(auraId)
	end)

	deleteButton.Activated:Connect(function()
		if not deleteButton.Visible then
			return
		end
		-- One copy, named explicitly. The server checks ownership again; a stale
		-- grid can therefore never delete anything.
		DeleteAura:FireServer(auraId)
	end)

	refreshCell(auraId)
end

-- =============================================================================
-- The auto-filter controls
-- =============================================================================

local MODE_LABELS: { { mode: string, text: string } } = {
	{ mode = "off", text = "OFF" },
	{ mode = "skip", text = "AUTO-SKIP" },
	{ mode = "delete", text = "AUTO-DELETE" },
}

local function renderFilter(): ()
	-- Mode buttons show the SERVER's mode, not the last thing clicked.
	for _, entry in ipairs(MODE_LABELS) do
		local button = modeButtons[entry.mode]
		local stroke = modeStrokes[entry.mode]
		if button ~= nil and stroke ~= nil then
			local active = filterMode == entry.mode
			button.TextColor3 = if active then theme.text else theme.textDim
			button.BackgroundColor3 = if active then theme.panelRaised else theme.backdrop
			button.BackgroundTransparency = if active then 0 else 0.35
			stroke.Color = if active then theme.warm else theme.stroke
			stroke.Transparency = if active then 0.05 else 0.6
		end
	end

	thresholdLabel.Text = string.format("Below  %s", thresholdName())
	thresholdLabel.TextColor3 = if filterMode == "off" then theme.locked else theme.warm

	-- What the current setting DOES, in the player's terms, including the part
	-- that is easy to get wrong: a pull at exactly the rung is kept.
	if filterMode == "off" then
		thresholdCaption.Text = "Off - every pull is kept. Choose one of the modes to start filtering."
	else
		local head = if filterMode == "delete"
			then "Below this rung: deleted, and counted in the filtered tally."
			else "Below this rung: dropped without ever being stored."
		thresholdCaption.Text = head .. " A pull at the rung itself is KEPT."
	end
	thresholdCaption.TextColor3 = theme.textDim

	local filteredText = if filteredPulls > 0
		then string.format("filtered this session: %d", filteredPulls)
		else "nothing filtered yet"
	local lastText = ""
	if type(lastFiltered) == "table" and type(lastFiltered.displayName) == "string" then
		lastText = string.format(
			"   \226\128\162   last: %s (1 in %s)%s",
			lastFiltered.displayName,
			formatNumber(tonumber(lastFiltered.rarity) or 0),
			if lastFiltered.hardPity == true then " - guaranteed pull" else ""
		)
	end
	tallyLabel.Text = filteredText .. lastText
	tallyLabel.TextColor3 = if filteredPulls > 0 then theme.warm else theme.textDim

	-- Stepping is always offered; with the filter off the rung is remembered for
	-- whenever it is switched on.
	local steppable = #filterOptions > 1
	prevButton.Active = steppable
	nextButton.Active = steppable
	prevButton.TextColor3 = if steppable then theme.text else theme.locked
	nextButton.TextColor3 = if steppable then theme.text else theme.locked
end

local function buildFilterControls(parent: Frame): ()
	local caption = makeLabel(parent, {
		Name = "FilterCaption",
		Position = UDim2.fromOffset(14, 4),
		Size = UDim2.new(1, -28, 0, 14),
		Text = "AUTO-FILTER \226\128\162 AFK PROTECTION",
		TextSize = 11,
		Font = Enum.Font.GothamBold,
		TextColor3 = theme.textDim,
	})
	caption.TextXAlignment = Enum.TextXAlignment.Left

	for index, entry in ipairs(MODE_LABELS) do
		local button = makeButton(parent, {
			Name = "Mode_" .. entry.mode,
			Position = UDim2.fromOffset(14 + (index - 1) * 88, 22),
			Size = UDim2.fromOffset(82, 22),
			Text = entry.text,
			TextSize = 11,
			BackgroundColor3 = theme.backdrop,
		})
		addCorner(button, 6)
		local stroke = addStroke(button, theme.stroke, 1, 0.6)
		modeButtons[entry.mode] = button
		modeStrokes[entry.mode] = stroke
		wireHover(button, function(): Color3
			return if filterMode == entry.mode then theme.panelRaised else theme.backdrop
		end, theme.raisedHover)

		button.Activated:Connect(function()
			-- Ask for this mode at the currently shown rung. The server validates
			-- both and answers with a sync, so the button state can only ever
			-- follow the server.
			local option = shownOption()
			local rarity = if option ~= nil then option.rarity else 0
			if entry.mode == "off" then
				SetFilter:FireServer("off", filterRarity)
			else
				SetFilter:FireServer(entry.mode, rarity)
			end
		end)
	end

	prevButton = makeButton(parent, {
		Name = "ThresholdPrev",
		Position = UDim2.fromOffset(14, 50),
		Size = UDim2.fromOffset(24, 22),
		Text = "<",
		TextSize = 13,
		BackgroundColor3 = theme.backdrop,
	})
	addCorner(prevButton, 6)
	addStroke(prevButton, theme.stroke, 1, 0.6)

	thresholdLabel = makeLabel(parent, {
		Name = "ThresholdValue",
		Position = UDim2.fromOffset(42, 50),
		Size = UDim2.new(1, -84, 0, 22),
		Text = "Below  the ladder",
		TextSize = 12,
		Font = Enum.Font.GothamBold,
	})

	nextButton = makeButton(parent, {
		Name = "ThresholdNext",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 50),
		Size = UDim2.fromOffset(24, 22),
		Text = ">",
		TextSize = 13,
		BackgroundColor3 = theme.backdrop,
	})
	addCorner(nextButton, 6)
	addStroke(nextButton, theme.stroke, 1, 0.6)

	prevButton.Activated:Connect(function()
		local index = optionIndex(filterRarity)
		local nextIndex = if index <= 0 then 1 else index - 1
		local option = filterOptions[nextIndex]
		if option ~= nil then
			SetFilter:FireServer(filterMode, option.rarity)
		end
	end)

	nextButton.Activated:Connect(function()
		local index = optionIndex(filterRarity)
		local nextIndex = if index <= 0 then 1 else math.min(#filterOptions, index + 1)
		local option = filterOptions[nextIndex]
		if option ~= nil then
			SetFilter:FireServer(filterMode, option.rarity)
		end
	end)

	thresholdCaption = makeLabel(parent, {
		Name = "ThresholdCaption",
		Position = UDim2.fromOffset(14, 76),
		Size = UDim2.new(1, -28, 0, 26),
		Text = "",
		TextSize = 10,
		TextColor3 = theme.textDim,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	thresholdCaption.TextXAlignment = Enum.TextXAlignment.Left

	tallyLabel = makeLabel(parent, {
		Name = "FilterTally",
		Position = UDim2.fromOffset(14, 102),
		Size = UDim2.new(1, -28, 0, 12),
		Text = "nothing filtered yet",
		TextSize = 10,
		Font = Enum.Font.Code,
		TextColor3 = theme.textDim,
	})
	tallyLabel.TextXAlignment = Enum.TextXAlignment.Left
	tallyLabel.TextTruncate = Enum.TextTruncate.AtEnd
end

-- =============================================================================
-- Panel
-- =============================================================================

local function setOpen(open: boolean): ()
	isOpen = open
	body.Visible = open
	panel.Size = if open then UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT) else UDim2.fromOffset(PANEL_WIDTH, HEADER_HEIGHT)
	drawerButton.Text = if open then "AURAS  \226\150\188" else "AURAS  \226\150\184"
	drawerStroke.Color = if open then theme.accent else theme.stroke
	drawerStroke.Transparency = if open then 0.15 else 0.5
end

local function buildPanel(options: MountOptions): ()
	panel = makeFrame(options.parent, {
		Name = "InventoryPanel",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 18, 0.5, 8),
		Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
		BackgroundColor3 = theme.panel,
		BackgroundTransparency = 0.06,
	})
	addCorner(panel, 14)
	addStroke(panel, theme.stroke, 1.3, 0.4)
	addGradient(panel, theme.panelRaised, theme.panel, 90)

	-- The drawer handle. It lives in the panel header rather than the bottom bar
	-- so the whole drawer - handle included - is this module's, and MainUI keeps
	-- only the mount.
	drawerButton = makeButton(panel, {
		Name = "DrawerHandle",
		Position = UDim2.fromOffset(8, 7),
		Size = UDim2.fromOffset(PANEL_WIDTH - 16, 22),
		Text = "AURAS  \226\150\188",
		TextSize = 12,
		Font = Enum.Font.GothamBlack,
		BackgroundColor3 = theme.backdrop,
		BackgroundTransparency = 0.2,
	})
	addCorner(drawerButton, 7)
	drawerStroke = addStroke(drawerButton, theme.accent, 1, 0.15)
	drawerButton.Activated:Connect(function()
		setOpen(not isOpen)
	end)

	body = makeFrame(panel, {
		Name = "Body",
		Position = UDim2.fromOffset(0, HEADER_HEIGHT),
		Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT),
		BackgroundTransparency = 1,
	})
	body.Active = false

	-- Filter controls first: they describe what happens to future pulls, which is
	-- what an AFK player actually came here to change.
	local filterPanel = makeFrame(body, {
		Name = "FilterPanel",
		Position = UDim2.fromOffset(8, 2),
		Size = UDim2.new(1, -16, 0, 118),
		BackgroundColor3 = theme.backdrop,
		BackgroundTransparency = 0.35,
	})
	addCorner(filterPanel, 10)
	addStroke(filterPanel, theme.stroke, 1, 0.6)
	buildFilterControls(filterPanel)

	local gridTitle = makeLabel(body, {
		Name = "GridTitle",
		Position = UDim2.fromOffset(16, 126),
		Size = UDim2.new(1, -32, 0, 14),
		Text = "COLLECTION \226\128\162 click a card to equip, X to delete one",
		TextSize = 10,
		Font = Enum.Font.GothamBold,
		TextColor3 = theme.textDim,
	})
	gridTitle.TextXAlignment = Enum.TextXAlignment.Left

	grid = Instance.new("ScrollingFrame") :: ScrollingFrame
	grid.Name = "InventoryScroll"
	grid.Position = UDim2.fromOffset(10, 142)
	grid.Size = UDim2.new(1, -20, 1, -152)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.CanvasSize = UDim2.new(0, 0, 0, 0)
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.ScrollBarThickness = 4
	grid.ScrollBarImageColor3 = theme.stroke
	grid.ScrollingDirection = Enum.ScrollingDirection.Y
	grid.Parent = body

	local gridLayout = Instance.new("UIGridLayout") :: UIGridLayout
	gridLayout.CellSize = UDim2.fromOffset(126, 66)
	gridLayout.CellPadding = UDim2.fromOffset(8, 8)
	gridLayout.FillDirection = Enum.FillDirection.Horizontal
	gridLayout.FillDirectionMaxCells = 2
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	gridLayout.Parent = grid

	local gridPadding = Instance.new("UIPadding") :: UIPadding
	gridPadding.PaddingTop = UDim.new(0, 2)
	gridPadding.PaddingLeft = UDim.new(0, 2)
	gridPadding.PaddingBottom = UDim.new(0, 8)
	gridPadding.Parent = grid

	-- One cell per rung of the ladder, not per owned aura: the grid doubles as the
	-- "what is still out there" view, which is why locked cells stay visible.
	for index, auraId in ipairs(AuraRegistry.ORDER) do
		buildCell(auraId, index)
	end

	setOpen(true)
	renderFilter()
end

-- =============================================================================
-- Public surface
-- =============================================================================

--[[
	ApplyState(payload)

	Called by MainUI on every StateSync. It is the only writer of this module's
	state: ownership, the equipped aura and the filter all come from the server,
	so nothing here can drift from what the roll path believes.
]]
function InventoryUI.ApplyState(payload: any): ()
	if not mounted or type(payload) ~= "table" then
		return
	end

	owned = {}
	if type(payload.inventory) == "table" then
		for auraId, count in pairs(payload.inventory :: { [any]: any }) do
			if type(auraId) == "string" and type(count) == "number" and AuraRegistry.Get(auraId) ~= nil then
				owned[auraId] = math.floor(count)
			end
		end
	end

	equipped = if type(payload.equippedAura) == "string" then payload.equippedAura else nil

	local filter = payload.filter
	if type(filter) == "table" then
		local mode = filter.mode
		filterMode = if mode == "skip" or mode == "delete" then mode else "off"

		local rarity = tonumber(filter.rarity) or 0
		filterRarity = if rarity > 0 then math.floor(rarity) else 0

		if type(filter.options) == "table" then
			local options: { FilterOption } = {}
			for _, raw in ipairs(filter.options :: { any }) do
				if type(raw) == "table" and type(raw.rarity) == "number" and raw.rarity > 0 then
					table.insert(options, {
						rarity = math.floor(raw.rarity),
						tier = tostring(raw.tier or ""),
						auraId = tostring(raw.auraId or ""),
						displayName = tostring(raw.displayName or ""),
					})
				end
			end
			if #options > 0 then
				filterOptions = options
			end
		end

		filteredPulls = math.max(0, math.floor(tonumber(filter.filteredPulls) or 0))
		lastFiltered = filter.lastFiltered
	end

	for auraId in pairs(cells) do
		refreshCell(auraId)
	end
	renderFilter()
end

function InventoryUI.ToggleDrawer(): ()
	if not mounted then
		return
	end
	setOpen(not isOpen)
end

function InventoryUI.IsOpen(): boolean
	return isOpen
end

function InventoryUI.Mount(options: MountOptions): ()
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
	formatNumber = options.formatNumber

	buildPanel(options)
end

return InventoryUI
