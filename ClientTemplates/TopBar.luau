local Players = game:GetService("Players")

-- A HUD strip of small square buttons, centred along the top of the screen. It's purely
-- a launcher — each button just runs its OnClick — so a game wires them to whatever
-- panels it uses (e.g. the StatsPage template's :Toggle()).
--
--   local stats = require(...ClientTemplates.StatsPage).new({
--       { "_TimePlayed", "Time Played", FormatUtil.formatDuration },
--   })
--   require(...ClientTemplates.TopBar).new({ Buttons = {
--       { Name = "Stats", Text = "\u{1F4CA}", OnClick = function() stats:Toggle() end },
--   } })
--
-- Buttons can also be added later with :AddButton(def). A def is
--   { Name?, Text?, Icon?, OnClick?, Order? }
-- where Icon (an image asset id) wins over Text when both are given.
--
-- This is a persistent HUD, not a menu: it isn't registered with Client:CreateMenu, so
-- it stays visible while panels open and close. Hide it with :SetVisible(false).
local TopBar = {}
TopBar.__index = TopBar

local BUTTON_COLOR = Color3.fromRGB(32, 32, 37)
local BUTTON_HOVER = Color3.fromRGB(52, 52, 60)
local TEXT_COLOR = Color3.fromRGB(235, 235, 240)

local BUTTON_SIZE = 42 -- square, in pixels
local BUTTON_GAP = 8
local TOP_MARGIN = 8

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = instance
	return c
end

-- Append a square button to the row. Returns the TextButton so a caller can restyle it
-- or flip .Visible per-button.
function TopBar:AddButton(def)
	def = def or {}
	local index = #self.Buttons + 1

	local button = Instance.new("TextButton")
	button.Name = def.Name or ("Button" .. index)
	button.LayoutOrder = def.Order or index
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundColor3 = BUTTON_COLOR
	button.BorderSizePixel = 0
	button.Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE)
	button.Parent = self.Bar
	corner(button, 8)

	if def.Icon then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.Image = def.Icon
		icon.ScaleType = Enum.ScaleType.Fit
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.62, 0.62)
		icon.Parent = button
	else
		button.Text = def.Text or "?"
		button.Font = Enum.Font.GothamBold
		button.TextColor3 = TEXT_COLOR
		button.TextScaled = true
		local tsc = Instance.new("UITextSizeConstraint")
		tsc.MaxTextSize = 20
		tsc.Parent = button
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 9)
		pad.PaddingBottom = UDim.new(0, 9)
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = button
	end

	button.MouseEnter:Connect(function()
		button.BackgroundColor3 = BUTTON_HOVER
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundColor3 = BUTTON_COLOR
	end)
	if def.OnClick then
		button.Activated:Connect(def.OnClick)
	end

	table.insert(self.Buttons, button)
	return button
end

function TopBar:SetVisible(visible)
	if self.Gui then
		self.Gui.Enabled = visible ~= false
	end
end

function TopBar:Destroy()
	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end
	self.Buttons = {}
end

-- config (optional): Buttons — array of button defs (see :AddButton).
function TopBar.new(config)
	config = config or {}
	local self = setmetatable({}, TopBar)
	self.Buttons = {}

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "TopBar"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	-- Below the panels (which use 20), so an open menu draws over the bar.
	self.Gui.DisplayOrder = 15
	self.Gui.Parent = playerGui

	-- AutomaticSize.X + a centred anchor keeps the row centred as buttons are added.
	self.Bar = Instance.new("Frame")
	self.Bar.Name = "Bar"
	self.Bar.BackgroundTransparency = 1
	self.Bar.AnchorPoint = Vector2.new(0.5, 0)
	self.Bar.Position = UDim2.new(0.5, 0, 0, TOP_MARGIN)
	self.Bar.AutomaticSize = Enum.AutomaticSize.X
	self.Bar.Size = UDim2.fromOffset(0, BUTTON_SIZE)
	self.Bar.Parent = self.Gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, BUTTON_GAP)
	layout.Parent = self.Bar

	for _, def in config.Buttons or {} do
		self:AddButton(def)
	end

	return self
end

return TopBar
