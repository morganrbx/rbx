local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Client = require(script.Parent.Parent.Client)
local Inventory = require(script.Parent.Parent.Inventory)
local State = require(script.Parent.Parent.State)
local FormatUtil = require(script.Parent.Parent.FormatUtil)
local Tooltip = require(script.Parent.Parent.Tooltip)
local Responsive = require(script.Parent.Parent.Responsive)

-- Full-inventory menu: the same item stacks the InventoryBar shows, but laid out as
-- a grid inside a panel with a close button, registered with the game's Client menu
-- system (so opening it closes any other menu, and vice versa). A project opts in
-- with `require(...ClientTemplates.InventoryMenu).new()` and opens it via a keybind
-- or button (Client.<yours>:Toggle()). Each slot renders an item icon + short count
-- and carries the shared item Tooltip, kept live from replicated state.
local InventoryMenu = {}
InventoryMenu.__index = InventoryMenu

local MENU_NAME = "_Inventory"

local PANEL_COLOR = Color3.fromRGB(24, 24, 27)
local SECTION_COLOR = Color3.fromRGB(32, 32, 37)
local SLOT_COLOR = Color3.fromRGB(44, 44, 50)

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = instance
	return c
end

local function createTextLabel(parent, text)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.Font = Enum.Font.GothamMedium
	label.TextStrokeTransparency = 0.75
	label.TextWrapped = true
	label.Parent = parent
	return label
end

-- One grid slot: a rounded background with the item icon and its short-formatted
-- count. Keyed by ItemId (its ItemName/icon never changes), so refresh only updates
-- the count.
local function createSlot(itemId, amount, itemName)
	local frame = Instance.new("Frame")
	frame.Name = "Item_" .. tostring(itemId)
	frame.BackgroundColor3 = SLOT_COLOR
	frame.BorderSizePixel = 0
	frame.Selectable = true
	corner(frame, 8)

	local iconLabel = Instance.new("ImageLabel")
	iconLabel.Name = "Icon"
	iconLabel.BackgroundTransparency = 1
	Inventory.renderItemImage(iconLabel, itemName)
	iconLabel.AnchorPoint = Vector2.new(0.5, 0)
	iconLabel.Position = UDim2.fromScale(0.5, 0.06)
	iconLabel.Size = UDim2.fromScale(0.8, 0.64)
	iconLabel.Parent = frame

	local count = createTextLabel(frame, FormatUtil.formatShortNumber(amount))
	count.Name = "CountLabel"
	count.AnchorPoint = Vector2.new(0.5, 1)
	count.Position = UDim2.new(0.5, 0, 1, -6)
	count.Size = UDim2.fromScale(1, 0.22)
	count.TextScaled = true

	return frame
end

-- Rebuild the grid from replicated inventory state, reusing existing slots (keyed by
-- ItemId) so only counts change frame-to-frame. Mirrors InventoryBar:Refresh.
function InventoryMenu:Refresh()
	if not self.State then
		return
	end

	local items = self.State:Get(self.Prefix .. "/Items") or {}
	local index = self.State:Get(self.Prefix .. "/Index") or {}
	local validFrames = {}
	local entries = {}

	for _, ids in index do
		for _, id in ids do
			local item = items[id]
			if item and item.LocalID then
				item.ItemId = id
				table.insert(entries, item)
			end
		end
	end

	for _, item in entries do
		local frameName = "Item_" .. tostring(item.ItemId)
		local slot = self.Grid:FindFirstChild(frameName)

		if slot then
			local countLabel = slot:FindFirstChild("CountLabel")
			if countLabel then
				countLabel.Text = FormatUtil.formatShortNumber(item.Amount)
			end
		else
			slot = createSlot(item.ItemId, item.Amount, item.ItemName)
			slot.Parent = self.Grid
			-- Live source: the tooltip re-reads this stack from state while shown.
			local id = item.ItemId
			Tooltip.fromItem(slot, function()
				return self.State:Get(self.Prefix .. "/Items/" .. id)
			end)
		end

		slot.LayoutOrder = item.LocalID
		validFrames[frameName] = true
	end

	for _, child in self.Grid:GetChildren() do
		if child:IsA("Frame") and not validFrames[child.Name] then
			child:Destroy()
		end
	end

	self.Empty.Visible = next(validFrames) == nil
end

function InventoryMenu:BindState(state)
	if type(state) == "string" then
		self.State = State.newReplicated(state)
	else
		self.State = state
	end
	self.Prefix = "_Inventory"
	self.Inventory = Inventory.get(self.State, self.Prefix)
	self:Refresh()
end

function InventoryMenu:Open()
	self:Refresh()
	Client:SetMenu(MENU_NAME)
end

function InventoryMenu:Close()
	if Client.CurrentMenu == MENU_NAME then
		Client:CloseMenu()
	end
end

function InventoryMenu:IsOpen()
	return Client.CurrentMenu == MENU_NAME
end

function InventoryMenu:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function InventoryMenu:Destroy()
	if self.RefreshConnection then
		self.RefreshConnection:Disconnect()
		self.RefreshConnection = nil
	end
	if Client.Menus[MENU_NAME] and Client.Menus[MENU_NAME].Instance == self.Gui then
		if self:IsOpen() then
			Client:CloseMenu()
		end
		Client.Menus[MENU_NAME] = nil
	end
	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end
end

-- config (optional): Title — panel heading (default "Inventory").
function InventoryMenu.new(config)
	config = config or {}
	local self = setmetatable({}, InventoryMenu)
	self.Prefix = "_Inventory"

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "InventoryMenu"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	self.Gui.DisplayOrder = 20
	self.Gui.Enabled = false
	self.Gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(500, 460)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BorderSizePixel = 0
	panel.Parent = self.Gui
	corner(panel, 12)
	Responsive.apply(panel)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 14)
	padding.Parent = panel

	local title = createTextLabel(panel, config.Title or "Inventory")
	title.Name = "Title"
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextScaled = false
	title.TextSize = 24
	title.Size = UDim2.new(1, -40, 0, 30)

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.Text = "\u{2715}"
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextScaled = true
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.BackgroundTransparency = 1
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Size = UDim2.fromOffset(30, 30)
	closeButton.Parent = panel
	closeButton.Activated:Connect(function()
		self:Close()
	end)

	local grid = Instance.new("ScrollingFrame")
	grid.Name = "Grid"
	grid.BackgroundColor3 = SECTION_COLOR
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 4
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.CanvasSize = UDim2.new()
	grid.Position = UDim2.fromOffset(0, 40)
	grid.Size = UDim2.new(1, 0, 1, -40)
	grid.Parent = panel
	corner(grid, 8)
	self.Grid = grid

	local gridPadding = Instance.new("UIPadding")
	gridPadding.PaddingLeft = UDim.new(0, 10)
	gridPadding.PaddingRight = UDim.new(0, 10)
	gridPadding.PaddingTop = UDim.new(0, 10)
	gridPadding.PaddingBottom = UDim.new(0, 10)
	gridPadding.Parent = grid

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(76, 76)
	gridLayout.CellPadding = UDim2.fromOffset(10, 10)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid

	-- Parented to the panel (not the grid) so the UIGridLayout doesn't turn the
	-- notice into a cell; it overlays the (empty) grid region.
	self.Empty = createTextLabel(panel, "Your inventory is empty.")
	self.Empty.Name = "Empty"
	self.Empty.TextColor3 = Color3.fromRGB(150, 150, 160)
	self.Empty.TextScaled = false
	self.Empty.TextSize = 15
	self.Empty.Position = UDim2.fromOffset(0, 40)
	self.Empty.Size = UDim2.new(1, 0, 1, -40)
	self.Empty.Visible = false

	Client:CreateMenu(MENU_NAME, self.Gui)

	-- Refresh continuously while open so counts track pickups/spends/trades live.
	self.RefreshConnection = RunService.Heartbeat:Connect(function()
		if self:IsOpen() then
			self:Refresh()
		end
	end)

	local stateId = Players.LocalPlayer:GetAttribute("hex_stateid")
	if stateId then
		self:BindState(stateId)
	else
		-- Bind as soon as the state id replicates (client may construct this early).
		local conn
		conn = Players.LocalPlayer:GetAttributeChangedSignal("hex_stateid"):Connect(function()
			local id = Players.LocalPlayer:GetAttribute("hex_stateid")
			if id then
				conn:Disconnect()
				self:BindState(id)
			end
		end)
	end

	return self
end

return InventoryMenu
