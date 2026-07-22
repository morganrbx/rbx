local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Client = require(script.Parent.Parent.Client)
local Tooltip = require(script.Parent.Parent.Tooltip)
local FormatUtil = require(script.Parent.Parent.FormatUtil)
local Responsive = require(script.Parent.Parent.Responsive)
local Inventory = require(script.Parent.Parent.Inventory)

-- The trade WINDOW for the P2P trade system (see Trade.luau). A project opts in
-- with `require(...ClientTemplates.TradeMenu).new()`. It opens itself when the
-- server starts a session (_TradeStart) and drives the dual-column offer view:
-- everything shown is server-authoritative — it renders the broadcast snapshots and
-- pushes the player's intent (offer edits by uuid, ready toggle, cancel) back
-- through the trade remotes. Starting a trade and answering invites are handled by
-- the companion TradeInvites template, not here.
local TradeMenu = {}
TradeMenu.__index = TradeMenu

local PANEL_COLOR = Color3.fromRGB(26, 26, 28)
local SECTION_COLOR = Color3.fromRGB(34, 34, 38)
local ROW_COLOR = Color3.fromRGB(44, 44, 50)
local ACCENT_COLOR = Color3.fromRGB(120, 200, 130)
local DECLINE_COLOR = Color3.fromRGB(235, 110, 110)
local DISABLED_COLOR = Color3.fromRGB(70, 70, 76)
-- Neutral input fill for the stack-amount TextBox, kept distinct from the green
-- action buttons so it doesn't read as a button.
local INPUT_COLOR = Color3.fromRGB(58, 58, 66)
local READY_ON_COLOR = Color3.fromRGB(120, 200, 130)
local READY_OFF_COLOR = Color3.fromRGB(150, 150, 160)

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

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = instance
	return c
end

-- Owned item instances as a sorted list of { ID = uuid, Item = itemTable } from the
-- replicated inventory, used to populate the per-instance "add to offer" list. One
-- entry per stack/instance (not aggregated by name), so trading references the
-- exact uuid — preserving the instance's per-item data.
-- Only items with a Render icon can be offered (the server enforces the same via
-- Trade.SetItemFilter). Hiding the rest keeps blank/erroring chips out of the picker.
local function isTradeable(itemName)
	local info = Client.ItemTable and Client.ItemTable[itemName]
	return info ~= nil and info.Render ~= nil and (info.Render.Image or "") ~= ""
end

local function ownedInstances()
	local inventory = Client.Inventory
	local list = {}
	if not inventory then
		return list
	end
	for uuid, item in inventory:GetItems() do
		if type(item) == "table" and item.ItemName and isTradeable(item.ItemName) then
			table.insert(list, { ID = uuid, Item = item })
		end
	end
	return list
end

-- Display name for an item, falling back to its key.
local function itemDisplayName(itemName)
	local info = Client.ItemTable and Client.ItemTable[itemName]
	return (info and info.Name) or itemName
end

-- Push a fleeting status line at the bottom of the window (self-clearing).
function TradeMenu:_status(text, color)
	self.Status.Text = text or ""
	self.Status.TextColor3 = color or Color3.fromRGB(190, 190, 200)
	self._statusToken = (self._statusToken or 0) + 1
	local token = self._statusToken
	if text and text ~= "" then
		task.delay(3, function()
			if self._statusToken == token and self.Status then
				self.Status.Text = ""
			end
		end)
	end
end

-- Send the player's current pending offer to the server. Server validates and
-- echoes it back via _TradeUpdate; local edits are optimistic until then.
function TradeMenu:_pushOffer()
	Client:InvokeServer("_TradeSetOffer", self.PendingOffer)
end

-- Normalize PendingOffer ({ [uuid] = amount }) into wire-style entries
-- { {ID, ItemName, Amount}, ... }, resolving each uuid's name from the local
-- inventory so the "your offer" column renders like the server-sent "their" one.
function TradeMenu:_yourEntries()
	local inventory = Client.Inventory
	local entries = {}
	for uuid, amount in self.PendingOffer do
		local item = inventory and inventory:GetItem(uuid)
		table.insert(entries, { ID = uuid, ItemName = item and item.ItemName or uuid, Amount = amount })
	end
	return entries
end

-- Rebuild the two offer columns (yours from PendingOffer, theirs from the latest
-- snapshot) plus the ready indicators and the ready button state.
function TradeMenu:_renderOffers()
	local snap = self.Snapshot or {}

	self:_fillOfferColumn(self.YourColumn, self:_yourEntries(), true)
	self:_fillOfferColumn(self.TheirColumn, snap.TheirOffer or {}, false)

	self.YourReadyTag.Text = snap.YourReady and "READY" or "Not ready"
	self.YourReadyTag.TextColor3 = snap.YourReady and READY_ON_COLOR or READY_OFF_COLOR
	self.TheirReadyTag.Text = snap.TheirReady and "READY" or "Not ready"
	self.TheirReadyTag.TextColor3 = snap.TheirReady and READY_ON_COLOR or READY_OFF_COLOR

	self.ReadyButton.Text = snap.YourReady and "Unready" or "Ready"
	self.ReadyButton.BackgroundColor3 = snap.YourReady and READY_OFF_COLOR or ACCENT_COLOR
end

-- Render one column of { ID, ItemName, Amount } entries as chips. For the local
-- player's column, clicking a chip removes one of that instance from the offer
-- (keyed by uuid).
function TradeMenu:_fillOfferColumn(column, entries, editable)
	for _, child in column:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for i, entry in entries do
		local uuid, name, amount = entry.ID, entry.ItemName, entry.Amount or 1

		local chip = Instance.new("Frame")
		chip.Name = "Chip"
		chip.LayoutOrder = i
		chip.BackgroundColor3 = ROW_COLOR
		chip.BorderSizePixel = 0
		chip.Size = UDim2.new(1, 0, 0, 34)
		corner(chip, 6)

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		Inventory.renderItemImage(icon, name)
		icon.Position = UDim2.fromOffset(4, 3)
		icon.Size = UDim2.fromOffset(28, 28)
		icon.Parent = chip

		local label = createTextLabel(chip, itemDisplayName(name) .. "  x" .. FormatUtil.formatLongNumber(amount))
		label.Name = "Label"
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Position = UDim2.fromOffset(38, 0)
		label.Size = UDim2.new(1, -42, 1, 0)
		label.TextScaled = false
		label.TextSize = 15

		Tooltip.fromItemName(chip, name, amount)

		if editable then
			local button = Instance.new("TextButton")
			button.BackgroundTransparency = 1
			button.Text = ""
			button.Size = UDim2.fromScale(1, 1)
			button.Parent = chip
			button.Activated:Connect(function()
				local current = self.PendingOffer[uuid] or 0
				if current <= 1 then
					self.PendingOffer[uuid] = nil
				else
					self.PendingOffer[uuid] = current - 1
				end
				self:_pushOffer()
				self:_renderOffers()
				self:_renderInventory()
			end)
		end

		chip.Parent = column
	end
end

-- Rebuild the inventory picker: one row per owned instance (uuid), showing how many
-- of that stack are still available to add (its amount minus what's already
-- offered). Clicking + adds one of that specific instance to the offer.
function TradeMenu:_renderInventory()
	-- Don't rebuild while the user is typing an amount here — destroying the focused
	-- box would drop their input mid-edit (e.g. a server _TradeUpdate arriving). The
	-- next render after they commit (FocusLost) refreshes the list.
	local focused = UserInputService:GetFocusedTextBox()
	if focused and focused:IsDescendantOf(self.Inventory) then
		return
	end

	for _, child in self.Inventory:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local instances = ownedInstances()
	table.sort(instances, function(a, b)
		local an, bn = itemDisplayName(a.Item.ItemName), itemDisplayName(b.Item.ItemName)
		if an == bn then
			return a.ID < b.ID
		end
		return an < bn
	end)

	for i, entry in instances do
		local uuid = entry.ID
		local name = entry.Item.ItemName
		local owned = entry.Item.Amount or 0
		local offered = self.PendingOffer[uuid] or 0
		local available = owned - offered

		local row = Instance.new("Frame")
		row.Name = "Item_" .. uuid
		row.LayoutOrder = i
		row.BackgroundColor3 = ROW_COLOR
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, 34)
		corner(row, 6)

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		Inventory.renderItemImage(icon, name)
		icon.Position = UDim2.fromOffset(4, 3)
		icon.Size = UDim2.fromOffset(28, 28)
		icon.Parent = row

		local label =
			createTextLabel(row, itemDisplayName(name) .. "  (" .. FormatUtil.formatLongNumber(available) .. ")")
		label.Name = "Label"
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Position = UDim2.fromOffset(38, 0)
		label.Size = UDim2.new(1, owned > 1 and -104 or -80, 1, 0)
		label.TextScaled = false
		label.TextSize = 15
		label.TextColor3 = available > 0 and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(140, 140, 148)

		if owned > 1 then
			-- Stacks: type how many of this stack to offer. On commit, invalid text
			-- becomes 0 and more than you own is clamped to what's actually held now.
			local box = Instance.new("TextBox")
			box.Name = "Amount"
			box.Font = Enum.Font.GothamBold
			box.TextScaled = true
			box.TextColor3 = Color3.fromRGB(235, 235, 240)
			box.BackgroundColor3 = INPUT_COLOR
			box.AnchorPoint = Vector2.new(1, 0.5)
			box.Position = UDim2.new(1, -4, 0.5, 0)
			box.Size = UDim2.fromOffset(56, 26)
			-- Leave empty when nothing is offered so the "0" is placeholder text you can
			-- type over, not a literal "0" you'd have to delete first.
			box.Text = if offered > 0 then tostring(offered) else ""
			box.PlaceholderText = "0"
			box.ClearTextOnFocus = false
			corner(box, 6)
			local boxSize = Instance.new("UITextSizeConstraint")
			boxSize.MaxTextSize = 16
			boxSize.Parent = box
			box.Parent = row

			box.FocusLost:Connect(function()
				-- Re-read the live stack: it may have changed since this row rendered.
				local live = Client.Inventory and Client.Inventory:GetItem(uuid)
				local liveOwned = live and live.Amount or 0
				local n = math.clamp(math.floor(tonumber(box.Text) or 0), 0, liveOwned)
				self.PendingOffer[uuid] = if n > 0 then n else nil
				self:_pushOffer()
				self:_renderOffers()
				self:_renderInventory()
			end)
		else
			local add = Instance.new("TextButton")
			add.Name = "Add"
			add.Text = "+"
			add.Font = Enum.Font.GothamBold
			add.TextScaled = true
			add.TextColor3 = Color3.fromRGB(20, 20, 20)
			add.AnchorPoint = Vector2.new(1, 0.5)
			add.Position = UDim2.new(1, -4, 0.5, 0)
			add.Size = UDim2.fromOffset(32, 26)
			add.BackgroundColor3 = available > 0 and ACCENT_COLOR or DISABLED_COLOR
			add.AutoButtonColor = available > 0
			corner(add, 6)
			add.Parent = row

			add.Activated:Connect(function()
				-- Re-read live amount: the stack may have changed since this row rendered.
				local live = Client.Inventory and Client.Inventory:GetItem(uuid)
				local liveOwned = live and live.Amount or 0
				if liveOwned - (self.PendingOffer[uuid] or 0) <= 0 then
					return
				end
				self.PendingOffer[uuid] = (self.PendingOffer[uuid] or 0) + 1
				self:_pushOffer()
				self:_renderOffers()
				self:_renderInventory()
			end)
		end

		Tooltip.fromItemName(row, name, owned)
		row.Parent = self.Inventory
	end
end

function TradeMenu:_applySnapshot(snap)
	self.Snapshot = snap
	-- The server's echo of our own offer is authoritative (it may have rejected or
	-- clamped an edit), so re-seed PendingOffer from it before rendering.
	self.PendingOffer = {}
	for _, entry in snap.YourOffer or {} do
		self.PendingOffer[entry.ID] = entry.Amount
	end
	self:_renderOffers()
	self:_renderInventory()
end

function TradeMenu:_openWindow(snap)
	self.Window.Visible = true
	self.Title.Text = "Trade with " .. tostring(snap.PartnerName or "player")
	self:_applySnapshot(snap)
	self:_status("")
end

function TradeMenu:_closeWindow()
	self.Window.Visible = false
	self.Snapshot = nil
	self.PendingOffer = {}
end

-- A small banner for trade-outcome feedback (completed / cancelled / partner left)
-- shown briefly after the window closes.
function TradeMenu:_showToast(text, color)
	self.Toast.Text = text
	self.Toast.TextColor3 = color or Color3.fromRGB(235, 235, 240)
	self.ToastFrame.Visible = true
	self._toastToken = (self._toastToken or 0) + 1
	local token = self._toastToken
	task.delay(4, function()
		if self._toastToken == token and self.ToastFrame then
			self.ToastFrame.Visible = false
		end
	end)
end

function TradeMenu:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	self._connections = {}
	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end
end

-- `config` is optional (reserved for future styling fields).
function TradeMenu.new(_config)
	local self = setmetatable({}, TradeMenu)
	self.PendingOffer = {}
	self._connections = {}

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "TradeMenu"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	-- The active trade window must sit above everything, including menus (which are
	-- DisplayOrder 0), so a player can never lose the trade behind another screen.
	self.Gui.DisplayOrder = 100
	self.Gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- ── Toast banner (trade-outcome feedback shown after the window closes) ────
	local toastFrame = Instance.new("Frame")
	toastFrame.Name = "Toast"
	toastFrame.AnchorPoint = Vector2.new(0.5, 0)
	toastFrame.Position = UDim2.new(0.5, 0, 0, 60)
	toastFrame.Size = UDim2.fromOffset(320, 36)
	toastFrame.BackgroundColor3 = PANEL_COLOR
	toastFrame.BackgroundTransparency = 0.15
	toastFrame.BorderSizePixel = 0
	toastFrame.Visible = false
	toastFrame.Parent = self.Gui
	corner(toastFrame, 8)
	Responsive.apply(toastFrame)
	self.ToastFrame = toastFrame
	self.Toast = createTextLabel(toastFrame, "")
	self.Toast.Size = UDim2.fromScale(1, 1)
	self.Toast.TextScaled = false
	self.Toast.TextSize = 15

	-- ── Trade window ─────────────────────────────────────────────────────────
	local window = Instance.new("Frame")
	window.Name = "Window"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.fromOffset(560, 470)
	window.BackgroundColor3 = PANEL_COLOR
	window.BorderSizePixel = 0
	window.Visible = false
	window.Parent = self.Gui
	corner(window, 10)
	Responsive.apply(window)
	self.Window = window

	local windowPadding = Instance.new("UIPadding")
	windowPadding.PaddingLeft = UDim.new(0, 12)
	windowPadding.PaddingRight = UDim.new(0, 12)
	windowPadding.PaddingTop = UDim.new(0, 10)
	windowPadding.PaddingBottom = UDim.new(0, 12)
	windowPadding.Parent = window

	self.Title = createTextLabel(window, "Trade")
	self.Title.Name = "Title"
	self.Title.Font = Enum.Font.GothamBold
	self.Title.TextXAlignment = Enum.TextXAlignment.Left
	self.Title.Size = UDim2.new(1, -40, 0, 30)

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.Text = "\u{2715}"
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextScaled = true
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.BackgroundTransparency = 1
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Size = UDim2.fromOffset(32, 32)
	closeButton.Parent = window
	closeButton.Activated:Connect(function()
		Client:InvokeServer("_TradeCancel")
	end)

	-- Two offer columns. Each has a header (title + ready tag) and a chip list.
	local function buildColumn(name, headerText, xScale)
		local holder = Instance.new("Frame")
		holder.Name = name
		holder.BackgroundTransparency = 1
		holder.Position = UDim2.new(xScale, xScale == 0 and 0 or 6, 0, 40)
		holder.Size = UDim2.new(0.5, -6, 0, 190)
		holder.Parent = window

		local header = createTextLabel(holder, headerText)
		header.Name = "Header"
		header.Font = Enum.Font.GothamBold
		header.TextXAlignment = Enum.TextXAlignment.Left
		header.Size = UDim2.new(1, 0, 0, 20)
		header.TextScaled = false
		header.TextSize = 16

		local readyTag = createTextLabel(holder, "Not ready")
		readyTag.Name = "ReadyTag"
		readyTag.TextXAlignment = Enum.TextXAlignment.Right
		readyTag.AnchorPoint = Vector2.new(1, 0)
		readyTag.Position = UDim2.fromScale(1, 0)
		readyTag.Size = UDim2.fromOffset(90, 20)
		readyTag.TextScaled = false
		readyTag.TextSize = 14
		readyTag.TextColor3 = READY_OFF_COLOR

		local listHolder = Instance.new("ScrollingFrame")
		listHolder.Name = "List"
		listHolder.BackgroundColor3 = SECTION_COLOR
		listHolder.BorderSizePixel = 0
		listHolder.ScrollBarThickness = 4
		listHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
		listHolder.CanvasSize = UDim2.new()
		listHolder.Position = UDim2.fromOffset(0, 24)
		listHolder.Size = UDim2.new(1, 0, 1, -24)
		listHolder.Parent = holder
		corner(listHolder, 8)

		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.PaddingTop = UDim.new(0, 6)
		pad.PaddingBottom = UDim.new(0, 6)
		pad.Parent = listHolder

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 4)
		layout.Parent = listHolder

		return listHolder, readyTag
	end

	self.YourColumn, self.YourReadyTag = buildColumn("YourOffer", "Your offer", 0)
	self.TheirColumn, self.TheirReadyTag = buildColumn("TheirOffer", "Their offer", 0.5)

	-- Inventory picker.
	local invLabel = createTextLabel(window, "Your inventory — tap + to add")
	invLabel.Name = "InvLabel"
	invLabel.Font = Enum.Font.GothamBold
	invLabel.TextXAlignment = Enum.TextXAlignment.Left
	invLabel.Position = UDim2.fromOffset(0, 236)
	invLabel.Size = UDim2.new(1, 0, 0, 18)
	invLabel.TextScaled = false
	invLabel.TextSize = 15

	local inventoryList = Instance.new("ScrollingFrame")
	inventoryList.Name = "Inventory"
	inventoryList.BackgroundColor3 = SECTION_COLOR
	inventoryList.BorderSizePixel = 0
	inventoryList.ScrollBarThickness = 4
	inventoryList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	inventoryList.CanvasSize = UDim2.new()
	inventoryList.Position = UDim2.fromOffset(0, 256)
	inventoryList.Size = UDim2.new(1, 0, 1, -256 - 48)
	inventoryList.Parent = window
	corner(inventoryList, 8)

	local invPad = Instance.new("UIPadding")
	invPad.PaddingLeft = UDim.new(0, 6)
	invPad.PaddingRight = UDim.new(0, 6)
	invPad.PaddingTop = UDim.new(0, 6)
	invPad.PaddingBottom = UDim.new(0, 6)
	invPad.Parent = inventoryList

	local invLayout = Instance.new("UIListLayout")
	invLayout.FillDirection = Enum.FillDirection.Vertical
	invLayout.SortOrder = Enum.SortOrder.LayoutOrder
	invLayout.Padding = UDim.new(0, 4)
	invLayout.Parent = inventoryList
	self.Inventory = inventoryList

	-- Bottom bar: status line + ready button.
	self.Status = createTextLabel(window, "")
	self.Status.Name = "Status"
	self.Status.TextXAlignment = Enum.TextXAlignment.Left
	self.Status.AnchorPoint = Vector2.new(0, 1)
	self.Status.Position = UDim2.fromScale(0, 1)
	self.Status.Size = UDim2.new(1, -140, 0, 34)
	self.Status.TextScaled = false
	self.Status.TextSize = 15
	self.Status.TextColor3 = Color3.fromRGB(190, 190, 200)

	local readyButton = Instance.new("TextButton")
	readyButton.Name = "Ready"
	readyButton.Text = "Ready"
	readyButton.Font = Enum.Font.GothamBold
	readyButton.TextScaled = true
	readyButton.TextColor3 = Color3.fromRGB(20, 20, 20)
	readyButton.AnchorPoint = Vector2.new(1, 1)
	readyButton.Position = UDim2.fromScale(1, 1)
	readyButton.Size = UDim2.fromOffset(128, 38)
	readyButton.BackgroundColor3 = ACCENT_COLOR
	readyButton.Parent = window
	corner(readyButton, 6)
	local readySize = Instance.new("UITextSizeConstraint")
	readySize.MaxTextSize = 18
	readySize.Parent = readyButton
	self.ReadyButton = readyButton

	readyButton.Activated:Connect(function()
		local currentlyReady = self.Snapshot and self.Snapshot.YourReady
		Client:InvokeServer("_TradeSetReady", not currentlyReady)
	end)

	-- ── Server-driven events ─────────────────────────────────────────────────
	-- Invites (both incoming and outgoing feedback) are owned by the TradeInvites
	-- template; this template only drives the trade window itself.
	table.insert(
		self._connections,
		Client:ConnectRemote("_TradeStart", function(snap)
			self:_openWindow(snap)
		end)
	)
	table.insert(
		self._connections,
		Client:ConnectRemote("_TradeUpdate", function(snap)
			if self.Window.Visible then
				self:_applySnapshot(snap)
			end
		end)
	)
	table.insert(
		self._connections,
		Client:ConnectRemote("_TradeError", function(payload)
			self:_status("Trade failed: " .. tostring(payload and payload.Reason), DECLINE_COLOR)
		end)
	)
	table.insert(
		self._connections,
		Client:ConnectRemote("_TradeEnd", function(payload)
			local wasOpen = self.Window.Visible
			self:_closeWindow()
			if payload and payload.Success then
				self:_showToast("Trade complete!", ACCENT_COLOR)
			elseif wasOpen then
				local reason = payload and payload.Reason
				if reason == "Cancelled" then
					self:_showToast("Trade cancelled.", DECLINE_COLOR)
				elseif reason == "PlayerLeft" then
					self:_showToast("Your trade partner left.", DECLINE_COLOR)
				end
			end
		end)
	)

	return self
end

return TradeMenu
