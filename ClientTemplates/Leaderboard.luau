local Players = game:GetService("Players")
local Client = require(script.Parent.Parent.Client)
local Responsive = require(script.Parent.Parent.Responsive)
local FormatUtil = require(script.Parent.Parent.FormatUtil)

-- Front end for the global (OrderedDataStore) leaderboards declared server-side
-- (see the Leaderboard server module). Registered as an rbx menu ("_Leaderboard")
-- so it opens/closes through Client:SetMenu/CloseMenu like the other panels. It's
-- fully data-driven: on open it pulls the board snapshot from _GetLeaderboard and
-- builds a tab per board, then lists that board's top players (rank, name, value).
-- Values are formatted per the board's Format hint (short / long / duration), so
-- the same view renders net worth and time played correctly.
local Leaderboard = {}
Leaderboard.__index = Leaderboard

local MENU_NAME = "_Leaderboard"

local PANEL_COLOR = Color3.fromRGB(24, 24, 27)
local SECTION_COLOR = Color3.fromRGB(32, 32, 37)
local ROW_COLOR = Color3.fromRGB(40, 40, 46)
local ROW_ALT_COLOR = Color3.fromRGB(45, 45, 52)
local ACCENT_COLOR = Color3.fromRGB(245, 205, 90)
local TAB_ACTIVE = Color3.fromRGB(60, 60, 68)
local MEDAL = { Color3.fromRGB(245, 205, 90), Color3.fromRGB(200, 200, 210), Color3.fromRGB(205, 150, 95) }

-- How often to re-pull while the panel is open (the server cache itself only
-- moves on its own interval, so this is just to catch that).
local REFRESH_WHILE_OPEN = 15

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
	l.TextScaled = false
	l.TextSize = size or 15
	l.Parent = parent
	return l
end

local function formatValue(value, format)
	value = tonumber(value) or 0
	if format == "short" then
		return FormatUtil.formatShortNumber(value)
	elseif format == "duration" then
		return FormatUtil.formatDuration(value)
	end
	return FormatUtil.formatLongNumber(value)
end

function Leaderboard:_renderRows()
	for _, child in self.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local board = self.Boards[self.Selected]
	local entries = board and board.Entries or {}
	self.Empty.Visible = #entries == 0

	for i, entry in entries do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.BackgroundColor3 = (i % 2 == 0) and ROW_ALT_COLOR or ROW_COLOR
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, 34)
		corner(row, 6)

		local rank = label(row, "#" .. i, 15, true)
		rank.Name = "Rank"
		rank.TextColor3 = MEDAL[i] or Color3.fromRGB(170, 170, 178)
		rank.TextXAlignment = Enum.TextXAlignment.Center
		rank.Position = UDim2.fromOffset(6, 0)
		rank.Size = UDim2.fromOffset(40, 34)

		local name = label(row, entry.Name or "?", 15, false)
		name.Name = "Name"
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Position = UDim2.fromOffset(50, 0)
		name.Size = UDim2.new(1, -160, 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd

		local value = label(row, formatValue(entry.Value, board and board.Format), 15, true)
		value.Name = "Value"
		value.TextColor3 = ACCENT_COLOR
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.AnchorPoint = Vector2.new(1, 0)
		value.Position = UDim2.new(1, -12, 0, 0)
		value.Size = UDim2.new(0, 100, 1, 0)

		row.Parent = self.List
	end
end

function Leaderboard:_renderTabs()
	for _, child in self.Tabs:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	for i, board in self.Boards do
		local tab = Instance.new("TextButton")
		tab.Name = "Tab_" .. board.Id
		tab.LayoutOrder = i
		tab.Text = board.Title
		tab.Font = Enum.Font.GothamBold
		tab.TextScaled = true
		tab.TextColor3 = Color3.fromRGB(235, 235, 240)
		tab.BackgroundColor3 = (i == self.Selected) and TAB_ACTIVE or SECTION_COLOR
		tab.AutomaticSize = Enum.AutomaticSize.X
		tab.Size = UDim2.fromScale(0, 1)
		tab.Parent = self.Tabs
		corner(tab, 7)

		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 14)
		pad.PaddingRight = UDim.new(0, 14)
		pad.Parent = tab
		local tsc = Instance.new("UITextSizeConstraint")
		tsc.MaxTextSize = 15
		tsc.Parent = tab

		tab.Activated:Connect(function()
			self.Selected = i
			self:_renderTabs()
			self:_renderRows()
		end)
	end
end

-- Pull the latest snapshot and re-render.
function Leaderboard:Refresh()
	local snapshot = Client:InvokeServer("_GetLeaderboard") or { Boards = {} }
	self.Boards = snapshot.Boards or {}
	if self.Selected > #self.Boards then
		self.Selected = 1
	end
	if self.Selected < 1 then
		self.Selected = 1
	end
	self:_renderTabs()
	self:_renderRows()
end

function Leaderboard:Open()
	self:Refresh()
	Client:SetMenu(MENU_NAME)
end

function Leaderboard:Close()
	if Client.CurrentMenu == MENU_NAME then
		Client:CloseMenu()
	end
end

function Leaderboard:IsOpen()
	return Client.CurrentMenu == MENU_NAME
end

function Leaderboard:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function Leaderboard:Destroy()
	if self.RefreshConn then
		self.RefreshConn:Disconnect()
		self.RefreshConn = nil
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

-- config (optional): Title — panel heading (default "Leaderboard").
function Leaderboard.new(config)
	config = config or {}
	local self = setmetatable({}, Leaderboard)
	self.Boards = {}
	self.Selected = 1

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "Leaderboard"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	self.Gui.DisplayOrder = 20
	self.Gui.Enabled = false
	self.Gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(420, 460)
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

	local title = label(panel, config.Title or "Leaderboard", 24, true)
	title.Name = "Title"
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

	-- Tab strip.
	self.Tabs = Instance.new("Frame")
	self.Tabs.Name = "Tabs"
	self.Tabs.BackgroundTransparency = 1
	self.Tabs.Position = UDim2.fromOffset(0, 40)
	self.Tabs.Size = UDim2.new(1, 0, 0, 32)
	self.Tabs.Parent = panel

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.Parent = self.Tabs

	-- Rows list.
	self.List = Instance.new("ScrollingFrame")
	self.List.Name = "List"
	self.List.BackgroundColor3 = SECTION_COLOR
	self.List.BorderSizePixel = 0
	self.List.ScrollBarThickness = 4
	self.List.AutomaticCanvasSize = Enum.AutomaticSize.Y
	self.List.CanvasSize = UDim2.new()
	self.List.Position = UDim2.fromOffset(0, 80)
	self.List.Size = UDim2.new(1, 0, 1, -80)
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

	self.Empty = label(self.List, "No entries yet.", 15, false)
	self.Empty.Name = "Empty"
	self.Empty.TextColor3 = Color3.fromRGB(150, 150, 160)
	self.Empty.Size = UDim2.new(1, 0, 0, 40)
	self.Empty.Visible = false

	Client:CreateMenu(MENU_NAME, self.Gui)

	-- While open, re-pull periodically so the board reflects the server's latest
	-- cache without the player reopening it.
	local accum = 0
	self.RefreshConn = game:GetService("RunService").Heartbeat:Connect(function(dt)
		if not self:IsOpen() then
			accum = 0
			return
		end
		accum += dt
		if accum >= REFRESH_WHILE_OPEN then
			accum = 0
			self:Refresh()
		end
	end)

	return self
end

return Leaderboard
