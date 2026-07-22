local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Client = require(script.Parent.Parent.Client)
local Responsive = require(script.Parent.Parent.Responsive)

-- Front end for the settings declared server-side with Server:CreateSettings. Registered
-- as an rbx menu ("_Settings"), fully data-driven: it renders one row per definition, in
-- the order they were declared, with a control matched to the type:
--
--   Toggle — ON / OFF button
--   Choice — a button that cycles through Options
--   Number — a click/drag slider between Min and Max (snapped to Step)
--   String — a text box
--
-- Values come from Client:GetSetting, so a setting the player has never touched shows the
-- current default and follows it if the default later changes. The RESET button only
-- appears once they've actually overridden something (Client:HasChangedSettings), and
-- clears every override.
local SettingsMenu = {}
SettingsMenu.__index = SettingsMenu

local MENU_NAME = "_Settings"

local PANEL_COLOR = Color3.fromRGB(24, 24, 27)
local SECTION_COLOR = Color3.fromRGB(32, 32, 37)
local ROW_COLOR = Color3.fromRGB(40, 40, 46)
local CONTROL_COLOR = Color3.fromRGB(52, 52, 60)
local ACCENT_COLOR = Color3.fromRGB(245, 205, 90)
local TRACK_COLOR = Color3.fromRGB(60, 60, 68)
local MUTED_COLOR = Color3.fromRGB(150, 150, 160)

local ROW_HEIGHT = 40
local CONTROL_WIDTH = 150
-- Gap between the equal-width option buttons of a Choice.
local CHOICE_GAP = 4
-- Seconds between re-syncs while the panel is open.
local REFRESH_INTERVAL = 0.25

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

-- A control-sized button sitting at the right of a row.
local function controlButton(parent, text)
	local b = Instance.new("TextButton")
	b.Name = "Control"
	b.Text = text
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.BackgroundColor3 = CONTROL_COLOR
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, -10, 0.5, 0)
	b.Size = UDim2.fromOffset(CONTROL_WIDTH, 26)
	b.Parent = parent
	corner(b, 6)
	return b
end

-- Booleans render as ON/OFF rather than "true"/"false".
local function displayValue(value)
	if type(value) == "boolean" then
		return if value then "ON" else "OFF"
	end
	return tostring(value)
end

-- ── Controls ─────────────────────────────────────────────────────────────────
-- Each builds its control into `row` and returns a function that re-syncs it from the
-- current value (so a reset, or another client of the same data, redraws correctly).

function SettingsMenu:_buildToggle(row, setting)
	local button = controlButton(row, "")
	button.Activated:Connect(function()
		self:_commit(setting, not Client:GetSetting(setting.Name))
	end)
	return function(value)
		button.Text = displayValue(value)
		button.TextColor3 = if value then ACCENT_COLOR else MUTED_COLOR
	end
end

-- One button per option, all the same width, with the current one highlighted — so every
-- choice is visible and selectable in a single click.
function SettingsMenu:_buildChoice(row, setting)
	local options = setting.Options
	local count = #options

	local holder = Instance.new("Frame")
	holder.Name = "Control"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(1, 0.5)
	holder.Position = UDim2.new(1, -10, 0.5, 0)
	holder.Size = UDim2.fromOffset(CONTROL_WIDTH, 26)
	holder.Parent = row

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, CHOICE_GAP)
	layout.Parent = holder

	local buttons = {}
	for i, option in options do
		local button = Instance.new("TextButton")
		button.Name = "Option" .. i
		button.LayoutOrder = i
		button.Text = displayValue(option)
		button.Font = Enum.Font.GothamBold
		-- Scaled (capped) so a long option name shrinks to fit a narrow slice rather
		-- than overflowing when there are several options.
		button.TextScaled = true
		button.BackgroundColor3 = CONTROL_COLOR
		button.BorderSizePixel = 0
		button.AutoButtonColor = true
		-- Equal widths: each takes 1/count of the strip, less its share of the gaps.
		button.Size = UDim2.new(1 / count, -CHOICE_GAP * (count - 1) / count, 1, 0)
		button.Parent = holder
		corner(button, 6)

		local tsc = Instance.new("UITextSizeConstraint")
		tsc.MaxTextSize = 13
		tsc.Parent = button

		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 6)
		pad.PaddingBottom = UDim.new(0, 6)
		pad.PaddingLeft = UDim.new(0, 4)
		pad.PaddingRight = UDim.new(0, 4)
		pad.Parent = button

		button.Activated:Connect(function()
			self:_commit(setting, option)
		end)
		buttons[i] = button
	end

	return function(value)
		for i, option in options do
			local selected = option == value
			buttons[i].BackgroundColor3 = if selected then ACCENT_COLOR else CONTROL_COLOR
			buttons[i].TextColor3 = if selected then PANEL_COLOR else MUTED_COLOR
		end
	end
end

function SettingsMenu:_buildString(row, setting)
	local box = Instance.new("TextBox")
	box.Name = "Control"
	box.Font = Enum.Font.GothamMedium
	box.TextSize = 14
	box.TextColor3 = Color3.fromRGB(255, 255, 255)
	box.BackgroundColor3 = CONTROL_COLOR
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Center
	box.AnchorPoint = Vector2.new(1, 0.5)
	box.Position = UDim2.new(1, -10, 0.5, 0)
	box.Size = UDim2.fromOffset(CONTROL_WIDTH, 26)
	box.Parent = row
	corner(box, 6)

	-- Commit on Enter or focus loss; the server clamps to MaxLength.
	box.FocusLost:Connect(function()
		self:_commit(setting, box.Text)
	end)
	return function(value)
		if not box:IsFocused() then
			box.Text = tostring(value)
		end
	end
end

function SettingsMenu:_buildNumber(row, setting)
	local span = math.max(setting.Max - setting.Min, 1e-6)

	local readout = label(row, "", 14, true)
	readout.Name = "Readout"
	readout.TextColor3 = ACCENT_COLOR
	readout.TextXAlignment = Enum.TextXAlignment.Right
	readout.AnchorPoint = Vector2.new(1, 0.5)
	readout.Position = UDim2.new(1, -10, 0.5, 0)
	readout.Size = UDim2.fromOffset(44, 26)

	local track = Instance.new("TextButton") -- a button so it takes the click itself
	track.Name = "Control"
	track.Text = ""
	track.AutoButtonColor = false
	track.BackgroundColor3 = TRACK_COLOR
	track.BorderSizePixel = 0
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, -62, 0.5, 0)
	track.Size = UDim2.fromOffset(CONTROL_WIDTH - 52, 8)
	track.Parent = row
	corner(track, 4)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = ACCENT_COLOR
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = track
	corner(fill, 4)

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.BorderSizePixel = 0
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0, 0.5)
	knob.Size = UDim2.fromOffset(14, 14)
	knob.ZIndex = 2
	knob.Parent = track
	corner(knob, 7)

	-- Map an absolute X to a value along the track.
	local function valueAt(x)
		local alpha = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		return setting.Min + alpha * span
	end

	-- Integer-ish ranges read as whole numbers, fractional ones to two places.
	local wholeNumbers = (setting.Step and setting.Step >= 1)
		or (setting.Min % 1 == 0 and setting.Max % 1 == 0 and span >= 10)

	local function render(value)
		local alpha = math.clamp((value - setting.Min) / span, 0, 1)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		readout.Text = if wholeNumbers then tostring(math.round(value)) else string.format("%.2f", value)
	end

	-- A drag previews locally and commits ONCE on release: sending every mouse-move to
	-- the server would be dozens of round trips per second.
	local dragging = false
	local preview = nil

	track.InputBegan:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			preview = valueAt(input.Position.X)
			render(preview)
		end
	end)
	-- Tracked globally so a drag keeps working once the pointer leaves the track.
	table.insert(
		self.Connections,
		UserInputService.InputChanged:Connect(function(input)
			if
				dragging
				and (
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				preview = valueAt(input.Position.X)
				render(preview)
			end
		end)
	)
	table.insert(
		self.Connections,
		UserInputService.InputEnded:Connect(function(input)
			if
				dragging
				and (
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				dragging = false
				if preview then
					self:_commit(setting, preview)
					preview = nil
				end
			end
		end)
	)

	-- While dragging, keep showing the preview rather than the (not yet saved) stored value.
	return function(value)
		render(if dragging and preview then preview else value)
	end
end

-- Push a change to the server, then re-sync. `value` of nil clears the override.
function SettingsMenu:_commit(setting, value)
	task.spawn(function()
		Client:SetSetting(setting.Name, value)
		self:Refresh()
	end)
end

function SettingsMenu:_build()
	for _, child in self.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	self.Sync = {}

	local settings = Client.SettingTable or {}
	self.Empty.Visible = #settings == 0

	for i, setting in settings do
		local row = Instance.new("Frame")
		row.Name = "Row_" .. setting.Name
		row.LayoutOrder = i
		row.BackgroundColor3 = ROW_COLOR
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		corner(row, 6)

		local name = label(row, setting.Display or setting.Name, 15, false)
		name.Name = "Name"
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Position = UDim2.fromOffset(12, 0)
		name.Size = UDim2.new(1, -(CONTROL_WIDTH + 30), 1, 0)
		name.TextTruncate = Enum.TextTruncate.AtEnd

		local sync
		if setting.Type == "Toggle" then
			sync = self:_buildToggle(row, setting)
		elseif setting.Type == "Choice" then
			sync = self:_buildChoice(row, setting)
		elseif setting.Type == "Number" then
			sync = self:_buildNumber(row, setting)
		else
			sync = self:_buildString(row, setting)
		end
		self.Sync[setting.Name] = sync

		row.Parent = self.List
	end
end

-- Re-sync every control from the current values, and show RESET only when the player has
-- actually overridden something.
function SettingsMenu:Refresh()
	for name, sync in self.Sync do
		sync(Client:GetSetting(name))
	end
	self.Reset.Visible = Client:HasChangedSettings()
end

function SettingsMenu:Open()
	-- Rebuild if the definitions arrived after construction.
	if not next(self.Sync) and #(Client.SettingTable or {}) > 0 then
		self:_build()
	end
	self:Refresh()
	Client:SetMenu(MENU_NAME)
end

function SettingsMenu:Close()
	if Client.CurrentMenu == MENU_NAME then
		Client:CloseMenu()
	end
end

function SettingsMenu:IsOpen()
	return Client.CurrentMenu == MENU_NAME
end

function SettingsMenu:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function SettingsMenu:Destroy()
	for _, connection in self.Connections do
		connection:Disconnect()
	end
	self.Connections = {}
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

-- config (optional): Title — panel heading (default "Settings").
function SettingsMenu.new(config)
	config = config or {}
	local self = setmetatable({}, SettingsMenu)
	self.Sync = {}
	self.Connections = {}

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "SettingsMenu"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	self.Gui.DisplayOrder = 20
	self.Gui.Enabled = false
	self.Gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(460, 460)
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

	local title = label(panel, config.Title or "Settings", 24, true)
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

	-- Only shown once something has been overridden (see Refresh).
	self.Reset = Instance.new("TextButton")
	self.Reset.Name = "Reset"
	self.Reset.Text = "RESET"
	self.Reset.Font = Enum.Font.GothamBold
	self.Reset.TextSize = 13
	self.Reset.TextColor3 = Color3.fromRGB(255, 255, 255)
	self.Reset.BackgroundColor3 = CONTROL_COLOR
	self.Reset.BorderSizePixel = 0
	self.Reset.AnchorPoint = Vector2.new(1, 0)
	self.Reset.Position = UDim2.new(1, -38, 0, 2)
	self.Reset.Size = UDim2.fromOffset(70, 26)
	self.Reset.Visible = false
	self.Reset.Parent = panel
	corner(self.Reset, 6)
	self.Reset.Activated:Connect(function()
		task.spawn(function()
			Client:ResetSettings()
			self:Refresh()
		end)
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

	self.Empty = label(self.List, "No settings.", 15, false)
	self.Empty.Name = "Empty"
	self.Empty.TextColor3 = MUTED_COLOR
	self.Empty.Size = UDim2.new(1, 0, 0, 40)
	self.Empty.Visible = false

	Client:CreateMenu(MENU_NAME, self.Gui)
	self:_build()

	-- Keep the controls honest while open: the values live in replicated state, so they
	-- can change from elsewhere (another device, a server-side reset). Throttled — these
	-- only move on user action, so there's nothing to gain from a per-frame resync.
	local accum = 0
	table.insert(
		self.Connections,
		RunService.Heartbeat:Connect(function(dt)
			if not self:IsOpen() then
				accum = 0
				return
			end
			accum += dt
			if accum >= REFRESH_INTERVAL then
				accum = 0
				self:Refresh()
			end
		end)
	)

	return self
end

return SettingsMenu
