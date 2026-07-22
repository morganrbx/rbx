local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Client = require(script.Parent.Parent.Client)
local Responsive = require(script.Parent.Parent.Responsive)
local FormatUtil = require(script.Parent.Parent.FormatUtil)

-- A stats panel: event totals listed as "name -> value" rows. Registered as an rbx menu
-- ("_Stats") so it opens/closes through Client:SetMenu/CloseMenu like the other panels,
-- and it's data-driven — with no config at all it lists every event it finds, so it
-- works out of the box.
--
-- Two scopes, shown as tabs:
--   You    — this player's own totals, read live from the replicated _EventTotals state.
--   Global — the cross-server totals (Client:GetEventTotals): every server's counts
--            folded together, fetched on open/refresh. Hide with ShowGlobal = false.
--
-- Pair it with the TopBar template for a button that opens it:
--   local stats = require(...ClientTemplates.StatsPage).new({
--       { "_TimePlayed", "Time Played", FormatUtil.formatDuration },
--   })
--   require(...ClientTemplates.TopBar).new({ Buttons = {
--       { Name = "Stats", Text = "\u{1F4CA}", OnClick = function() stats:Toggle() end },
--   } })
local StatsPage = {}
StatsPage.__index = StatsPage

local MENU_NAME = "_Stats"

local PANEL_COLOR = Color3.fromRGB(24, 24, 27)
local SECTION_COLOR = Color3.fromRGB(32, 32, 37)
local ROW_COLOR = Color3.fromRGB(40, 40, 46)
local ROW_ALT_COLOR = Color3.fromRGB(45, 45, 52)
local ACCENT_COLOR = Color3.fromRGB(245, 205, 90)
local TAB_ACTIVE = Color3.fromRGB(60, 60, 68)
local MUTED_COLOR = Color3.fromRGB(150, 150, 160)

-- How often to re-pull/re-render while the panel is open.
local REFRESH_WHILE_OPEN = 10

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

-- "_TimePlayed" -> "Time Played", so an auto-discovered page reads properly with no
-- config. Only used when a stat has no explicit Title.
local function humanize(key)
	local text = tostring(key)
	text = text:gsub("^_", "")
	text = text:gsub("(%l)(%u)", "%1 %2")
	text = text:gsub("^%l", string.upper)
	return text
end

-- `format` is the optional per-stat formatter from the config, called with the raw
-- value. Without one (or if it errors) the value renders as a plain long number, so a
-- bad formatter can never break the page.
local function formatValue(value, format)
	value = tonumber(value) or 0
	if type(format) == "function" then
		local ok, text = pcall(format, value)
		if ok and text ~= nil then
			return tostring(text)
		end
	end
	return FormatUtil.formatLongNumber(value)
end

-- Totals for the selected scope: the player's own replicated state, or the cross-server
-- snapshot fetched in Refresh.
function StatsPage:_totals()
	if self.Scopes[self.Selected] == "Global" then
		return self.GlobalTotals or {}
	end
	local data = Client.Data
	return (data and data:Get("_EventTotals")) or {}
end

-- The rows to draw: the configured Stats list (in its given order), or every key found
-- in the data sorted by name when no list was configured.
function StatsPage:_entries()
	local totals = self:_totals()
	local entries = {}

	if self.Stats then
		-- Each definition is { <_EventTotals key>, <display name>, <format function?> }.
		for _, def in self.Stats do
			local key, title, format = def[1], def[2], def[3]
			table.insert(entries, {
				Title = title or humanize(key),
				Value = totals[key] or 0,
				Format = format,
			})
		end
		return entries
	end

	for key, value in totals do
		table.insert(entries, {
			Title = humanize(key),
			Value = value,
		})
	end
	table.sort(entries, function(a, b)
		return a.Title < b.Title
	end)
	return entries
end

function StatsPage:_renderRows()
	for _, child in self.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local entries = self:_entries()
	self.Empty.Visible = #entries == 0

	for i, entry in entries do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.BackgroundColor3 = (i % 2 == 0) and ROW_ALT_COLOR or ROW_COLOR
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, 34)
		corner(row, 6)

		local name = label(row, entry.Title, 15, false)
		name.Name = "Name"
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Position = UDim2.fromOffset(12, 0)
		name.Size = UDim2.new(1, -130, 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd

		local value = label(row, formatValue(entry.Value, entry.Format), 15, true)
		value.Name = "Value"
		value.TextColor3 = ACCENT_COLOR
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.AnchorPoint = Vector2.new(1, 0)
		value.Position = UDim2.new(1, -12, 0, 0)
		value.Size = UDim2.fromOffset(110, 34)

		row.Parent = self.List
	end
end

function StatsPage:_renderTabs()
	for _, child in self.Tabs:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	-- A single scope needs no tab strip; give the rows that space instead.
	self.Tabs.Visible = #self.Scopes > 1
	if not self.Tabs.Visible then
		return
	end

	for i, scope in self.Scopes do
		local tab = Instance.new("TextButton")
		tab.Name = "Tab_" .. scope
		tab.LayoutOrder = i
		tab.Text = scope
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
			self:Refresh()
		end)
	end
end

-- Re-pull and re-render. The global snapshot is only fetched when that tab is showing,
-- so a player sitting on "You" never costs a round trip.
function StatsPage:Refresh()
	if self.Scopes[self.Selected] == "Global" then
		self.GlobalTotals = Client:GetEventTotals()
	end
	self:_renderTabs()
	self:_renderRows()
end

function StatsPage:Open()
	self:Refresh()
	Client:SetMenu(MENU_NAME)
end

function StatsPage:Close()
	if Client.CurrentMenu == MENU_NAME then
		Client:CloseMenu()
	end
end

function StatsPage:IsOpen()
	return Client.CurrentMenu == MENU_NAME
end

function StatsPage:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function StatsPage:Destroy()
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

-- config: an array of stat definitions, each
--   { <_EventTotals key>, <display name>, <format function (optional)> }
--
--   StatsPage.new({
--       { "_TimePlayed", "Time Played", FormatUtil.formatDuration },
--       { "Kills", "Kills" },
--   })
--
-- The formatter is called with the raw number and returns the text to show; without one
-- the value renders as a plain long number.
--
-- To pass options as well, use a table with the array under `Stats`:
--   Title      — panel heading (default "Stats").
--   ShowGlobal — include the cross-server "Global" tab (default true).
-- With no config at all, every event found in the data is listed, sorted by name.
function StatsPage.new(config)
	config = config or {}
	local self = setmetatable({}, StatsPage)
	-- An array argument IS the stats list; otherwise take it off the options table.
	self.Stats = if config[1] ~= nil then config else config.Stats
	self.Scopes = if config.ShowGlobal == false then { "You" } else { "You", "Global" }
	self.Selected = 1
	self.GlobalTotals = {}

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "StatsPage"
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

	local title = label(panel, config.Title or "Stats", 24, true)
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

	-- Scope tabs (You / Global).
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

	self.Empty = label(self.List, "No stats yet.", 15, false)
	self.Empty.Name = "Empty"
	self.Empty.TextColor3 = MUTED_COLOR
	self.Empty.Size = UDim2.new(1, 0, 0, 40)
	self.Empty.Visible = false

	Client:CreateMenu(MENU_NAME, self.Gui)

	-- While open, re-render periodically so the player's own totals tick up live and
	-- the global snapshot stays reasonably fresh.
	local accum = 0
	self.RefreshConn = RunService.Heartbeat:Connect(function(dt)
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

return StatsPage
