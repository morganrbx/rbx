local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")
local Client = require(script.Parent.Parent.Client)
local Tooltip = require(script.Parent.Parent.Tooltip)
local FormatUtil = require(script.Parent.Parent.FormatUtil)
local Responsive = require(script.Parent.Parent.Responsive)
local Inventory = require(script.Parent.Parent.Inventory)

-- ContextActionService binding name for the gamepad/keyboard "close shop"
-- shortcut, bound while a shop is open and unbound on close (see Open/Close).
local CLOSE_ACTION = "ItemShopClose"

-- Base of the menu name each shop registers with the game's Client menu system
-- (an underscore prefix keeps it from clashing with a game menu). Open/Close route
-- through Client:SetMenu/CloseMenu, so opening a game menu closes the shop and vice
-- versa. Each ItemShop instance gets its OWN suffixed name (see the counter below):
-- a game may create several shop instances (one per pad/NPC), and the menu system
-- keys menus by name — a shared name would make every instance clobber the same
-- menu registration, so opening one pad would show another's (empty) panel.
local MENU_NAME = "_ItemShop"

-- Monotonic id handed to each new instance so its menu name is unique.
local nextInstanceId = 0

-- Shop UI for the data registered server-side via Server:AddShopInfo. A project
-- opts in with `require(...ClientTemplates.ItemShop).new()` and then calls
-- `:Open(shopId)` / `:Close()`. A shop is { Name, Trades = {trade, ...} } where
-- each trade is { Give = {{item, amount}, ...}, Cost = {{item, amount}, ...} }:
-- the player hands over every Cost and receives every Give. The server is the
-- source of truth — we additionally gray out trades the player can't afford,
-- recomputed on Heartbeat from the replicated inventory state.
local ItemShop = {}
ItemShop.__index = ItemShop

local PANEL_COLOR = Color3.fromRGB(26, 26, 28)
local SECTION_COLOR = Color3.fromRGB(34, 34, 38)
local ROW_COLOR = Color3.fromRGB(44, 44, 50)
local TRADE_COLOR = Color3.fromRGB(120, 200, 130)
local DISABLED_COLOR = Color3.fromRGB(70, 70, 76)

-- Added to a row's LayoutOrder while it isn't tradable, so unaffordable offers
-- sink below the tradable ones. Larger than any realistic trade count, so the
-- two groups never interleave while each keeps its own relative order.
local UNTRADABLE_ORDER_OFFSET = 100000

local function createTextLabel(parent, text)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.Font = Enum.Font.GothamMedium
	label.TextStrokeTransparency = 0.75
	label.Parent = parent
	return label
end

-- Render a list of {itemName, amount} entries as small icon + "xN" chips into a
-- horizontal strip, returning the strip frame.
local function createEntryStrip(entries)
	local strip = Instance.new("Frame")
	strip.BackgroundTransparency = 1
	strip.BorderSizePixel = 0

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = strip

	for i, entry in entries do
		local name, amount = entry[1], entry[2] or 1

		local chip = Instance.new("Frame")
		chip.Name = "Chip"
		chip.LayoutOrder = i
		chip.BackgroundTransparency = 1
		chip.Size = UDim2.fromOffset(54, 40)
		-- Selectable so a gamepad can land on the chip and surface its tooltip; on
		-- mouse/touch this is inert (Tooltip drives those off hover/press instead).
		chip.Selectable = true

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		Inventory.renderItemImage(icon, name)
		icon.Size = UDim2.new(1, 0, 1, -12)
		icon.Position = UDim2.fromScale(0, 0)
		icon.Parent = chip

		local count = createTextLabel(chip, FormatUtil.formatLongNumber(amount))
		count.Name = "Count"
		count.AnchorPoint = Vector2.new(0, 1)
		count.Position = UDim2.fromScale(0, 1)
		count.Size = UDim2.new(1, 0, 0, 12)
		count.Parent = chip

		chip.Parent = strip
		Tooltip.fromItemName(chip, name, amount)
	end

	return strip
end

-- Build one trade row. Returns the frame and a record the Heartbeat refresh uses
-- to toggle affordability.
function ItemShop:_createRow(index, trade)
	local costs = trade.Cost or {}
	local gives = trade.Give or {}

	local row = Instance.new("Frame")
	row.Name = "Trade_" .. tostring(index)
	row.LayoutOrder = index
	row.BackgroundColor3 = ROW_COLOR
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, 52)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = row

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = row

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = row

	-- What you receive.
	local giveStrip = createEntryStrip(gives)
	giveStrip.Name = "Give"
	giveStrip.LayoutOrder = 1
	giveStrip.Size = UDim2.new(0, math.max(#gives, 1) * 58, 1, 0)
	giveStrip.Parent = row

	local arrow = createTextLabel(row, "\u{2190}") -- ← (cost is on the right, reward on the left)
	arrow.Name = "Arrow"
	arrow.LayoutOrder = 2
	arrow.Size = UDim2.fromOffset(24, 24)

	-- What it costs.
	local costStrip = createEntryStrip(costs)
	costStrip.Name = "Cost"
	costStrip.LayoutOrder = 3
	costStrip.Size = UDim2.new(0, math.max(#costs, 1) * 58, 1, 0)
	costStrip.Parent = row

	local button = Instance.new("TextButton")
	button.Name = "Action"
	button.LayoutOrder = 4
	button.Text = self.TradeName
	button.Font = Enum.Font.GothamBold
	button.TextScaled = true
	button.TextColor3 = Color3.fromRGB(20, 20, 20)
	button.Size = UDim2.fromOffset(72, 36)
	button.BackgroundColor3 = TRADE_COLOR
	button.Parent = row

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 6)
	buttonCorner.Parent = button

	local buttonPadding = Instance.new("UITextSizeConstraint")
	buttonPadding.MaxTextSize = 18
	buttonPadding.Parent = button

	-- "Trade all" runs the trade as many times as the player can afford. Only shown
	-- when at least two copies are affordable (see _refresh); hidden by default.
	local tradeAllButton = Instance.new("TextButton")
	tradeAllButton.Name = "ActionAll"
	tradeAllButton.LayoutOrder = 5
	tradeAllButton.Text = self.TradeName .. " all"
	tradeAllButton.Font = Enum.Font.GothamBold
	tradeAllButton.TextScaled = true
	tradeAllButton.TextColor3 = Color3.fromRGB(20, 20, 20)
	tradeAllButton.Size = UDim2.fromOffset(72, 36)
	tradeAllButton.BackgroundColor3 = TRADE_COLOR
	tradeAllButton.Visible = false
	tradeAllButton.Parent = row

	local tradeAllCorner = Instance.new("UICorner")
	tradeAllCorner.CornerRadius = UDim.new(0, 6)
	tradeAllCorner.Parent = tradeAllButton

	local tradeAllPadding = Instance.new("UITextSizeConstraint")
	tradeAllPadding.MaxTextSize = 18
	tradeAllPadding.Parent = tradeAllButton

	local record = {
		Row = row,
		Button = button,
		TradeAllButton = tradeAllButton,
		Costs = costs,
		Trade = trade,
		Index = index,
		BaseColor = button.BackgroundColor3,
		Affordable = true,
		CanTradeAll = false,
	}

	button.Activated:Connect(function()
		if not record.Affordable then
			return
		end
		local result = Client:InvokeServer("_ShopTrade", self.ShopId, index)
		if result and not result.Success then
			warn("Shop trade failed: " .. tostring(result.Reason))
		end
		-- Re-evaluate rows now that the server has applied the trade, so affordability
		-- and any TradeFilter (e.g. "hide once owned"/"hide when none left") update
		-- immediately instead of waiting for the next Heartbeat refresh.
		self:_refresh()
	end)

	tradeAllButton.Activated:Connect(function()
		if not record.CanTradeAll then
			return
		end
		local result = Client:InvokeServer("_ShopTrade", self.ShopId, index, true)
		if result and not result.Success then
			warn("Shop trade failed: " .. tostring(result.Reason))
		end
		self:_refresh()
	end)

	return row, record
end

-- Refresh affordability of every visible row from the replicated inventory.
function ItemShop:_refresh()
	local inventory = Client.Inventory
	local anyAffordable = false
	for _, record in self.Rows do
		-- A dynamic TradeFilter (see .new) decides, per player and re-evaluated every
		-- refresh, whether a trade is shown — e.g. hiding a pickaxe purchase once it's
		-- owned. A hidden row is fully inert: not shown, not counted as affordable, and
		-- never eligible for "trade all". (The static trade.Hidden flag drops a row at
		-- build time instead; this is the live per-player counterpart.)
		if self.TradeFilter and not self.TradeFilter(record.Trade, record.Index) then
			record.Row.Visible = false
			record.Affordable = false
			record.CanTradeAll = false
			record.TradeAllButton.Visible = false
			continue
		end
		record.Row.Visible = true

		-- Max copies of this trade the player can afford, bounded by the scarcest
		-- cost item (matching the server's `true`/"trade all" computation). A trade
		-- with no costs has no such bound — always affordable, never "trade all".
		local maxAffordable = math.huge
		local hasCosts = false
		if inventory then
			-- Aggregate duplicate cost rows, matching the server check.
			local required = {}
			for _, entry in record.Costs do
				required[entry[1]] = (required[entry[1]] or 0) + (entry[2] or 1)
			end
			for name, amount in required do
				hasCosts = true
				local affordable = math.floor((inventory:CountItem(name) or 0) / amount)
				maxAffordable = math.min(maxAffordable, affordable)
			end
		else
			maxAffordable = 0
		end

		local affordable = maxAffordable >= 1
		record.Affordable = affordable
		anyAffordable = anyAffordable or affordable
		record.Button.AutoButtonColor = affordable
		record.Button.BackgroundColor3 = affordable and record.BaseColor or DISABLED_COLOR

		-- Float untradable offers below tradable ones. Each group keeps its
		-- original order because we offset from Index rather than replacing it.
		record.Row.LayoutOrder = record.Index + (affordable and 0 or UNTRADABLE_ORDER_OFFSET)

		-- "Trade all" appears only for opted-in shops, and only once two or more
		-- copies are affordable.
		local canTradeAll = self.TradeAllEnabled and hasCosts and maxAffordable >= 2
		record.CanTradeAll = canTradeAll
		record.TradeAllButton.Visible = canTradeAll
	end

	-- Gray out the mass-trade button when nothing is affordable, so it reads as
	-- disabled (and the handler bails) instead of firing a doomed server call.
	self.MassTradeAffordable = anyAffordable
	self.MassTradeButton.AutoButtonColor = anyAffordable
	self.MassTradeButton.BackgroundColor3 = anyAffordable and TRADE_COLOR or DISABLED_COLOR
end

-- Populate the trade list from the shop's Trades.
function ItemShop:_build()
	for _, child in self.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local shop = Client.ShopTable and Client.ShopTable[self.ShopId]
	local trades = shop and shop.Trades or {}
	for index, trade in trades do
		-- A trade flagged Hidden is left out of the UI entirely (no row, so it's never
		-- listed or counted for affordability/mass-trade). Its position in the Trades
		-- array — and therefore its trade index — is untouched, so the server can still
		-- run it by index if a game triggers it directly.
		if trade.Hidden then
			continue
		end
		local row, record = self:_createRow(index, trade)
		row.Parent = self.List
		table.insert(self.Rows, record)
	end
end

function ItemShop:Open(shopId)
	local shop = Client.ShopTable and Client.ShopTable[shopId]
	if not shop then
		warn("ItemShop:Open called with unknown shop: " .. tostring(shopId))
		return
	end

	self.ShopId = shopId
	self.Rows = {}
	self.Title.Text = shop.Name or shopId

	-- Per-row "Trade all" buttons only appear for shops that opt in; _refresh reads
	-- this alongside the per-row affordability check.
	self.TradeAllEnabled = shop.TradeAll == true

	-- Reveal the mass-trade button only for opted-in shops, reserving title width
	-- for it so the label can't run under the button.
	local massTrade = shop.MassTrade == true
	self.MassTradeButton.Visible = massTrade
	self.Title.Size = UDim2.new(1, massTrade and -140 or -40, 0, 32)

	self:_build()
	self:_refresh()
	Client:SetMenu(self.MenuName)
end

function ItemShop:Close()
	self.ShopId = nil
	self.Rows = {}
	-- Only close if the shop is the active menu, so we never yank a game menu the
	-- player has since switched to.
	if Client.CurrentMenu == self.MenuName then
		Client:CloseMenu()
	end
end

-- Gamepad entry point: hand the controller an initial selection so the D-pad can
-- drive the shop (Roblox auto-nav moves between the selectable buttons/chips from
-- here), and bind B to close it. Mouse/touch users just tap the ✕, so we only claim
-- these on a pure-gamepad device. Driven off the menu's shown transition (see the
-- Heartbeat in .new) so it re-runs whenever the shop becomes the active menu.
function ItemShop:_setupInput()
	if UserInputService.GamepadEnabled and not UserInputService.MouseEnabled then
		local first = self.Rows[1] and self.Rows[1].Button
		GuiService.SelectedObject = first or self.CloseButton
		ContextActionService:BindAction(CLOSE_ACTION, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				self:Close()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.ButtonB)
	end
end

-- Release the gamepad focus / B-binding when the shop is hidden — including when the
-- game switches to another menu without calling Close.
function ItemShop:_teardownInput()
	if GuiService.SelectedObject and self.Gui and GuiService.SelectedObject:IsDescendantOf(self.Gui) then
		GuiService.SelectedObject = nil
	end
	ContextActionService:UnbindAction(CLOSE_ACTION)
end

function ItemShop:Destroy()
	-- Drop the gamepad focus / B-binding first, in case we're torn down while open.
	self:_teardownInput()
	-- Drop our menu registration so the game's RenderUI stops touching a destroyed GUI.
	if Client.Menus[self.MenuName] and Client.Menus[self.MenuName].Instance == self.Gui then
		if Client.CurrentMenu == self.MenuName then
			Client:CloseMenu()
		end
		Client.Menus[self.MenuName] = nil
	end
	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end
	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end
end

function ItemShop.new(config)
	local self = setmetatable({}, ItemShop)
	self.Rows = {}
	self.TradeName = config.TradeName or "Trade"

	-- Optional per-player, live trade filter: filter(trade, index) -> boolean, called
	-- for every row on each refresh while the shop is open. Return false to hide the
	-- trade (e.g. a pickaxe already owned), true to show it. Re-evaluated continuously,
	-- so a trade appears/disappears as the player's inventory changes.
	self.TradeFilter = config.TradeFilter

	-- Unique per-instance menu name so multiple shops (e.g. a Buy pad and a Sell pad)
	-- each register their own menu instead of overwriting a shared one.
	nextInstanceId += 1
	self.MenuName = MENU_NAME .. "_" .. nextInstanceId

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "ItemShop"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	self.Gui.Enabled = false
	self.Gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(460, 420)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BorderSizePixel = 0
	panel.Parent = self.Gui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel

	-- The panel is authored in fixed offset pixels; scale it to the viewport so it
	-- fits a phone and reads from a couch. It's centered on pure-scale Position, so
	-- the UIScale only resizes it (around its own center) — it stays centered.
	Responsive.apply(panel)

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingLeft = UDim.new(0, 12)
	panelPadding.PaddingRight = UDim.new(0, 12)
	panelPadding.PaddingTop = UDim.new(0, 10)
	panelPadding.PaddingBottom = UDim.new(0, 12)
	panelPadding.Parent = panel

	self.Title = createTextLabel(panel, "Shop")
	self.Title.Name = "Title"
	self.Title.Font = Enum.Font.GothamBold
	self.Title.TextXAlignment = Enum.TextXAlignment.Left
	self.Title.Size = UDim2.new(1, -40, 0, 32)

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.Text = "\u{2715}" -- ✕
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextScaled = true
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.BackgroundTransparency = 1
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Size = UDim2.fromOffset(32, 32)
	closeButton.Parent = panel
	closeButton.Activated:Connect(function()
		self:Close()
	end)
	-- Kept for the gamepad fallback selection in Open (when a shop has no trades).
	self.CloseButton = closeButton

	-- "Mass trade" runs the server's _ShopMassTrade endpoint: a single "trade all"
	-- across every trade in the shop at once. Only shown for shops that opt in with
	-- MassTrade = true (toggled in Open); sits left of the close button.
	local massTradeButton = Instance.new("TextButton")
	massTradeButton.Name = "MassTrade"
	massTradeButton.Text = "Mass " .. string.lower(self.TradeName)
	massTradeButton.Font = Enum.Font.GothamBold
	massTradeButton.TextScaled = true
	massTradeButton.TextColor3 = Color3.fromRGB(20, 20, 20)
	massTradeButton.BackgroundColor3 = TRADE_COLOR
	massTradeButton.AnchorPoint = Vector2.new(1, 0.5)
	massTradeButton.Position = UDim2.new(1, -40, 0, 16)
	massTradeButton.Size = UDim2.fromOffset(96, 28)
	massTradeButton.Visible = false
	massTradeButton.Parent = panel

	local massTradeCorner = Instance.new("UICorner")
	massTradeCorner.CornerRadius = UDim.new(0, 6)
	massTradeCorner.Parent = massTradeButton

	local massTradeSize = Instance.new("UITextSizeConstraint")
	massTradeSize.MaxTextSize = 16
	massTradeSize.Parent = massTradeButton

	massTradeButton.Activated:Connect(function()
		if not self.ShopId or not self.MassTradeAffordable then
			return
		end
		local result = Client:InvokeServer("_ShopMassTrade", self.ShopId)
		if result and not result.Success then
			warn("Shop mass trade failed: " .. tostring(result.Reason))
		end
		-- Refresh immediately post-trade so filters/affordability reflect the result.
		self:_refresh()
	end)

	self.MassTradeButton = massTradeButton

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundColor3 = SECTION_COLOR
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Position = UDim2.fromOffset(0, 40)
	list.Size = UDim2.new(1, 0, 1, -40)
	list.Parent = panel

	local listCorner = Instance.new("UICorner")
	listCorner.CornerRadius = UDim.new(0, 8)
	listCorner.Parent = list

	local listPadding = Instance.new("UIPadding")
	listPadding.PaddingLeft = UDim.new(0, 8)
	listPadding.PaddingRight = UDim.new(0, 8)
	listPadding.PaddingTop = UDim.new(0, 8)
	listPadding.PaddingBottom = UDim.new(0, 8)
	listPadding.Parent = list

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = list

	self.List = list

	-- Register with the game's menu system; RenderUI now owns this GUI's Enabled /
	-- parenting based on Client.CurrentMenu.
	Client:CreateMenu(self.MenuName, self.Gui)

	self.Connection = RunService.Heartbeat:Connect(function()
		-- Track menu shown/hidden transitions so gamepad input setup/teardown runs
		-- however the shop was opened or closed (our Open/Close, another SetMenu, etc.).
		local shown = Client.CurrentMenu == self.MenuName
		if shown ~= self._shown then
			self._shown = shown
			if shown then
				self:_setupInput()
			else
				self:_teardownInput()
			end
		end
		if shown then
			self:_refresh()
		end
	end)

	return self
end

return ItemShop
