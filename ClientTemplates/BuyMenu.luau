local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local Client = require(script.Parent.Parent.Client)
local Responsive = require(script.Parent.Parent.Responsive)
local Tooltip = require(script.Parent.Parent.Tooltip)

-- Buy menu for the developer products registered server-side with Server:AddProducts.
-- Registered as the rbx menu "_BuyMenu" and fully data-driven from Client:GetProducts():
-- one row per product, showing the product's OWN Roblox icon + display name and a BUY
-- button with its LIVE price.
--
-- Every price and label comes from MarketplaceService:GetProductInfoAsync, fetched on the
-- CLIENT — so PriceInRobux is the price THIS player actually pays under Roblox's dynamic /
-- regional / membership pricing (e.g. a Roblox Premium discount), never a number baked into
-- the game. When the discounted price is below the base price, the row shows the base
-- struck through. Rows sort cheapest-first as their prices arrive.
local BuyMenu = {}
BuyMenu.__index = BuyMenu

local MENU_NAME = "_BuyMenu"
local INFO_TYPE = Enum.InfoType.Product
-- LayoutOrder for a row whose price hasn't loaded yet, so it sinks to the bottom until it
-- resolves and takes its sorted slot.
local UNSORTED_ORDER = 1_000_000_000

local PANEL_COLOR = Color3.fromRGB(24, 24, 27)
local SECTION_COLOR = Color3.fromRGB(32, 32, 37)
local ROW_COLOR = Color3.fromRGB(40, 40, 46)
local BUY_COLOR = Color3.fromRGB(46, 122, 60)
local ACCENT_COLOR = Color3.fromRGB(245, 205, 90)
local MUTED_COLOR = Color3.fromRGB(150, 150, 160)

local ROW_HEIGHT = 60
local BUY_WIDTH = 108
-- Width reserved to the left of the BUY button for the struck-through base price.
local WAS_WIDTH = 74

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = instance
	return c
end

local function label(parent, text, size, bold)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.fromRGB(255, 255, 255)
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.GothamMedium
	l.TextSize = size or 15
	l.Parent = parent
	return l
end

-- 15000 -> "15,000". Robux prices read cleaner grouped, and are always shown in full (not
-- abbreviated) so the player sees the exact charge.
local function withCommas(n)
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- Fetch a product's info once and cache it. Runs on the client, so PriceInRobux is this
-- player's price. `callback` fires with the info table (only on success).
function BuyMenu:_fetch(productId, callback)
	local cached = self.Info[productId]
	if cached then
		callback(cached)
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfoAsync(productId, INFO_TYPE)
		end)
		if ok and type(info) == "table" then
			self.Info[productId] = info
			callback(info)
		end
	end)
end

-- Fill a built row from its (loaded) product info: icon, name, price, sort order.
function BuyMenu:_apply(row, info)
	if info.IconImageAssetId and info.IconImageAssetId ~= 0 then
		row.Icon.Image = "rbxassetid://" .. info.IconImageAssetId
	elseif info.DisplayIcon then
		row.Icon.Image = "rbxassetid://" .. tostring(info.DisplayIcon)
	end
	row.ProductName.Text = info.DisplayName or info.Name or "Product"

	local price = info.PriceInRobux or info.UserBasePriceInRobux
	local base = info.UserBasePriceInRobux
	if price then
		row.Buy.Text = "R$ " .. withCommas(price)
		row.Buy.AutoButtonColor = true
		row.LayoutOrder = price -- cheapest-first
	else
		row.Buy.Text = if info.IsForSale == false then "N/A" else "BUY"
	end

	-- Show the base price struck through when the player is getting it cheaper than list.
	local discounted = price and base and price < base
	row.WasPrice.Visible = discounted == true
	if discounted then
		row.WasPrice.Text = "<s>R$ " .. withCommas(base) .. "</s>"
	end
end

-- `rewards` is the product's reward list ({ { itemName, amount }, ... }) from
-- Client:GetProducts(), used only for the icon's what-you-get tooltip.
function BuyMenu:_buildRow(productId, rewards)
	local row = Instance.new("Frame")
	row.Name = "Product_" .. productId
	row.BackgroundColor3 = ROW_COLOR
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.LayoutOrder = UNSORTED_ORDER
	corner(row, 8)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = row

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	icon.Size = UDim2.fromOffset(44, 44)
	icon.Parent = row

	-- Hovering the icon shows what the product grants. Single-reward products (all the
	-- caps bundles) show that item's tooltip; for a multi-reward product the first is used.
	local reward = rewards and rewards[1]
	if reward and reward[1] then
		Tooltip.fromItemName(icon, reward[1], reward[2] or 1)
	end

	local name = label(row, "…", 17, true)
	name.Name = "ProductName"
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.AnchorPoint = Vector2.new(0, 0.5)
	name.Position = UDim2.new(0, 56, 0.5, 0)
	name.Size = UDim2.new(1, -(56 + BUY_WIDTH + WAS_WIDTH + 20), 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd

	-- Struck-through base price, shown to the left of the BUY button only when the live
	-- price is a discount on it.
	local was = label(row, "", 13, false)
	was.Name = "WasPrice"
	was.RichText = true
	was.TextColor3 = MUTED_COLOR
	was.TextXAlignment = Enum.TextXAlignment.Right
	was.AnchorPoint = Vector2.new(1, 0.5)
	was.Position = UDim2.new(1, -(BUY_WIDTH + 8), 0.5, 0)
	was.Size = UDim2.fromOffset(WAS_WIDTH, 20)
	was.Visible = false

	local buy = Instance.new("TextButton")
	buy.Name = "Buy"
	buy.Text = "BUY"
	buy.Font = Enum.Font.GothamBold
	buy.TextSize = 16
	buy.TextColor3 = Color3.fromRGB(255, 255, 255)
	buy.BackgroundColor3 = BUY_COLOR
	buy.AutoButtonColor = false
	buy.BorderSizePixel = 0
	buy.AnchorPoint = Vector2.new(1, 0.5)
	buy.Position = UDim2.fromScale(1, 0.5)
	buy.Size = UDim2.fromOffset(BUY_WIDTH, 36)
	buy.Parent = row
	corner(buy, 6)
	buy.Activated:Connect(function()
		Client:PromptPurchase(productId)
	end)

	row.Parent = self.List
	self:_fetch(productId, function(info)
		self:_apply(row, info)
	end)
	return row
end

function BuyMenu:_build()
	for _, child in self.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	self.Rows = {}

	local products = Client:GetProducts()
	local ids = {}
	for productId in products do
		table.insert(ids, productId)
	end
	table.sort(ids) -- stable initial order; prices re-sort via LayoutOrder as they load

	self.Empty.Visible = #ids == 0
	for _, productId in ids do
		self.Rows[productId] = self:_buildRow(productId, products[productId])
	end
end

function BuyMenu:Open()
	-- Rebuild if the product table arrived after construction.
	if not next(self.Rows) and next(Client:GetProducts()) then
		self:_build()
	end
	Client:SetMenu(MENU_NAME)
end

function BuyMenu:Close()
	if Client.CurrentMenu == MENU_NAME then
		Client:CloseMenu()
	end
end

function BuyMenu:IsOpen()
	return Client.CurrentMenu == MENU_NAME
end

function BuyMenu:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function BuyMenu:Destroy()
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

-- config (optional): Title — panel heading (default "Store").
function BuyMenu.new(config)
	config = config or {}
	local self = setmetatable({}, BuyMenu)
	self.Rows = {}
	self.Info = {} -- productId -> cached GetProductInfoAsync result

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "BuyMenu"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	self.Gui.DisplayOrder = 20
	self.Gui.Enabled = false
	self.Gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(440, 460)
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

	local title = label(panel, config.Title or "Store", 24, true)
	title.Name = "Title"
	title.TextColor3 = ACCENT_COLOR
	title.TextXAlignment = Enum.TextXAlignment.Left
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

	self.List = Instance.new("ScrollingFrame")
	self.List.Name = "List"
	self.List.BackgroundColor3 = SECTION_COLOR
	self.List.BorderSizePixel = 0
	self.List.ScrollBarThickness = 4
	self.List.AutomaticCanvasSize = Enum.AutomaticSize.Y
	self.List.CanvasSize = UDim2.new()
	self.List.Position = UDim2.fromOffset(0, 40)
	self.List.Size = UDim2.new(1, 0, 1, -40)
	self.List.Parent = panel
	corner(self.List, 8)

	local listPad = Instance.new("UIPadding")
	listPad.PaddingLeft = UDim.new(0, 8)
	listPad.PaddingRight = UDim.new(0, 8)
	listPad.PaddingTop = UDim.new(0, 8)
	listPad.PaddingBottom = UDim.new(0, 8)
	listPad.Parent = self.List

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = self.List

	self.Empty = label(self.List, "Nothing for sale.", 15, false)
	self.Empty.Name = "Empty"
	self.Empty.TextColor3 = MUTED_COLOR
	self.Empty.Size = UDim2.new(1, 0, 0, 40)
	self.Empty.Visible = false

	Client:CreateMenu(MENU_NAME, self.Gui)
	self:_build()

	return self
end

return BuyMenu
