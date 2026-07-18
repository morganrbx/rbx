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

-- ContextActionService binding name for the gamepad "close" shortcut, bound while
-- the panel is open and unbound on close (mirrors ItemShop).
local CLOSE_ACTION = "DailyRewardsClose"

-- Daily play-time reward UI for the tiers registered server-side via
-- Server:AddDailyPlayTimeRewards. A project opts in with
-- `require(...ClientTemplates.DailyRewards).new()` then calls `:Open()` / `:Close()`.
-- The tier config is `{ [secondsRequired] = { {item, amount}, ... } }`, replicated
-- to the client as Client.DailyRewardTable; live progress (PlayTime / Claimed /
-- NextEnd) is read from the player's replicated state each Heartbeat. The server is
-- the source of truth — the Claim button just invokes _ClaimDailyReward and the
-- reward + grant toast flow back through normal replication.
local DailyRewards = {}
DailyRewards.__index = DailyRewards

local PANEL_COLOR = Color3.fromRGB(26, 26, 28)
local SECTION_COLOR = Color3.fromRGB(34, 34, 38)
local ROW_COLOR = Color3.fromRGB(44, 44, 50)
local CLAIM_COLOR = Color3.fromRGB(120, 200, 130)
local CLAIMED_COLOR = Color3.fromRGB(70, 70, 76)
local LOCKED_COLOR = Color3.fromRGB(70, 70, 76)
local BAR_FILL_COLOR = Color3.fromRGB(120, 200, 130)

local STATE_PATH = "_DailyPlayTimeRewards"

-- Registered with the game's Client menu system under this underscore-prefixed name
-- (so it can't clash with a game menu). Opening/closing goes through
-- Client:SetMenu/CloseMenu, so opening a game menu closes this and vice versa.
local MENU_NAME = "_DailyRewards"

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

-- Render a tier's reward entries ({itemName, amount}) as icon + "xN" chips.
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

-- The replicated tier config with keys coerced to numbers. Roblox can deliver a
-- dictionary's integer keys ([30]/[60]/[90]) as strings across a remote, which
-- would make the "seconds" compare against numeric PlayTime blow up — so normalize
-- once here and key everything (rows, claims, progress) off real numbers.
local function normalizedConfig()
	local raw = Client.DailyRewardTable or {}
	local config = {}
	for seconds, rewards in raw do
		config[tonumber(seconds) or seconds] = rewards
	end
	return config
end

-- Live { NextEnd, PlayTime, Claimed } for the local player, or nil.
function DailyRewards:_data()
	return Client.Data and Client.Data:Get(STATE_PATH) or nil
end

-- Build one tier row. Returns the row frame and a record :_refresh toggles.
function DailyRewards:_createRow(seconds, rewards)
	local row = Instance.new("Frame")
	row.Name = "Tier_" .. tostring(seconds)
	row.LayoutOrder = seconds
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
	layout.Padding = UDim.new(0, 8)
	layout.Parent = row

	-- Required play-time for the tier.
	local timeLabel = createTextLabel(row, FormatUtil.formatDuration(seconds))
	timeLabel.Name = "Time"
	timeLabel.LayoutOrder = 1
	timeLabel.Font = Enum.Font.GothamBold
	timeLabel.TextXAlignment = Enum.TextXAlignment.Left
	timeLabel.Size = UDim2.fromOffset(64, 24)

	-- What the tier grants.
	local rewardStrip = createEntryStrip(rewards)
	rewardStrip.Name = "Rewards"
	rewardStrip.LayoutOrder = 2
	rewardStrip.Size = UDim2.new(0, math.max(#rewards, 1) * 58, 1, 0)
	rewardStrip.Parent = row

	local button = Instance.new("TextButton")
	button.Name = "Claim"
	button.LayoutOrder = 3
	button.Text = "Claim"
	button.Font = Enum.Font.GothamBold
	button.TextScaled = true
	button.TextColor3 = Color3.fromRGB(20, 20, 20)
	button.Size = UDim2.fromOffset(96, 36)
	button.BackgroundColor3 = CLAIM_COLOR
	button.Parent = row

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 6)
	buttonCorner.Parent = button

	local buttonSize = Instance.new("UITextSizeConstraint")
	buttonSize.MaxTextSize = 16
	buttonSize.Parent = button

	local record = {
		Row = row,
		Button = button,
		Seconds = seconds,
		State = nil, -- "claim" | "claimed" | "locked", set by _refresh
	}

	button.Activated:Connect(function()
		if record.State ~= "claim" then
			return
		end
		local result = Client:InvokeServer("_ClaimDailyReward", seconds)
		if result and not result.Success then
			warn("Daily reward claim failed: " .. tostring(result.Reason))
		end
		-- Refresh immediately so the button reflects the claim before the next tick.
		self:_refresh()
	end)

	return row, record
end

-- Recompute the header (countdown + progress) and every row's button from live
-- replicated state.
function DailyRewards:_refresh()
	local data = self:_data()
	local playTime = data and data.PlayTime or 0
	local claimed = data and data.Claimed or {}
	local nextEnd = data and data.NextEnd or 0

	-- Countdown to the daily reset. os.time() is UTC, matching the server's NextEnd.
	local remaining = nextEnd - os.time()
	if nextEnd <= 0 or remaining < 0 then
		remaining = 0
	end
	self.Reset.Text = "Resets in " .. FormatUtil.formatDuration(remaining)

	-- Progress toward the largest tier.
	local fraction = self.MaxSeconds > 0 and math.clamp(playTime / self.MaxSeconds, 0, 1) or 0
	self.BarFill.Size = UDim2.fromScale(fraction, 1)
	self.BarLabel.Text = FormatUtil.formatDuration(playTime) .. " / " .. FormatUtil.formatDuration(self.MaxSeconds)

	for _, record in self.Rows do
		local isClaimed = table.find(claimed, record.Seconds) ~= nil
		local unlocked = playTime >= record.Seconds

		if isClaimed then
			record.State = "claimed"
			record.Button.Text = "Claimed"
			record.Button.AutoButtonColor = false
			record.Button.BackgroundColor3 = CLAIMED_COLOR
		elseif unlocked then
			record.State = "claim"
			record.Button.Text = "Claim"
			record.Button.AutoButtonColor = true
			record.Button.BackgroundColor3 = CLAIM_COLOR
		else
			record.State = "locked"
			record.Button.Text = FormatUtil.formatDuration(record.Seconds - playTime)
			record.Button.AutoButtonColor = false
			record.Button.BackgroundColor3 = LOCKED_COLOR
		end
	end
end

-- (Re)build the tier rows from the current config.
function DailyRewards:_build()
	for _, child in self.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	self.Rows = {}

	local config = normalizedConfig()
	local tiers = {}
	for seconds in config do
		table.insert(tiers, seconds)
	end
	table.sort(tiers)

	self.MaxSeconds = 0
	for _, seconds in tiers do
		self.MaxSeconds = math.max(self.MaxSeconds, seconds)
		local row, record = self:_createRow(seconds, config[seconds])
		row.Parent = self.List
		table.insert(self.Rows, record)
	end
end

-- Gamepad entry: hand the controller an initial selection and bind B-to-close.
-- Driven off the menu's shown transition (see the Heartbeat in .new), so it re-runs
-- whenever the menu becomes active — however it was opened.
function DailyRewards:_setupInput()
	if UserInputService.GamepadEnabled and not UserInputService.MouseEnabled then
		GuiService.SelectedObject = (self.Rows[1] and self.Rows[1].Button) or self.CloseButton
		ContextActionService:BindAction(CLOSE_ACTION, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				self:Close()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.ButtonB)
	end
end

-- Release the gamepad focus / B-binding when the menu is hidden — including when
-- the game switches to another menu without calling Close.
function DailyRewards:_teardownInput()
	if GuiService.SelectedObject and self.Gui and GuiService.SelectedObject:IsDescendantOf(self.Gui) then
		GuiService.SelectedObject = nil
	end
	ContextActionService:UnbindAction(CLOSE_ACTION)
end

function DailyRewards:Open()
	if not Client.DailyRewardTable then
		warn("DailyRewards:Open — no daily rewards configured (call Server:AddDailyPlayTimeRewards).")
		return
	end
	-- Populate before showing so the panel appears fully built (no empty frame).
	self:_build()
	self:_refresh()
	Client:SetMenu(MENU_NAME)
end

function DailyRewards:Close()
	-- Only close if we're the active menu, so we never yank a game menu the player
	-- switched to.
	if Client.CurrentMenu == MENU_NAME then
		Client:CloseMenu()
	end
end

function DailyRewards:IsOpen()
	return Client.CurrentMenu == MENU_NAME
end

-- Convenience for a single toggle key/button: open when closed, close when open.
function DailyRewards:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function DailyRewards:Destroy()
	self:_teardownInput()
	-- Drop our menu registration so the game's RenderUI stops touching a destroyed GUI.
	if Client.Menus[MENU_NAME] and Client.Menus[MENU_NAME].Instance == self.Gui then
		if Client.CurrentMenu == MENU_NAME then
			Client:CloseMenu()
		end
		Client.Menus[MENU_NAME] = nil
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

-- `config` is optional. Supported field:
--   Title — panel heading (default "Daily Rewards").
function DailyRewards.new(config)
	config = config or {}
	local self = setmetatable({}, DailyRewards)
	self.Rows = {}
	self.MaxSeconds = 0

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "DailyRewards"
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

	Responsive.apply(panel)

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingLeft = UDim.new(0, 12)
	panelPadding.PaddingRight = UDim.new(0, 12)
	panelPadding.PaddingTop = UDim.new(0, 10)
	panelPadding.PaddingBottom = UDim.new(0, 12)
	panelPadding.Parent = panel

	self.Title = createTextLabel(panel, config.Title or "Daily Rewards")
	self.Title.Name = "Title"
	self.Title.Font = Enum.Font.GothamBold
	self.Title.TextXAlignment = Enum.TextXAlignment.Left
	self.Title.Size = UDim2.new(1, -40, 0, 28)

	-- Reset countdown, right-aligned under the close button.
	self.Reset = createTextLabel(panel, "")
	self.Reset.Name = "Reset"
	self.Reset.TextXAlignment = Enum.TextXAlignment.Right
	self.Reset.TextColor3 = Color3.fromRGB(190, 190, 200)
	self.Reset.AnchorPoint = Vector2.new(1, 0)
	self.Reset.Position = UDim2.new(1, -36, 0, 4)
	self.Reset.Size = UDim2.fromOffset(150, 20)

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
	self.CloseButton = closeButton

	-- Progress bar: total play-time this window toward the largest tier.
	local bar = Instance.new("Frame")
	bar.Name = "Progress"
	bar.BackgroundColor3 = SECTION_COLOR
	bar.BorderSizePixel = 0
	bar.Position = UDim2.fromOffset(0, 34)
	bar.Size = UDim2.new(1, 0, 0, 22)
	bar.Parent = panel

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 6)
	barCorner.Parent = bar

	self.BarFill = Instance.new("Frame")
	self.BarFill.Name = "Fill"
	self.BarFill.BackgroundColor3 = BAR_FILL_COLOR
	self.BarFill.BorderSizePixel = 0
	self.BarFill.Size = UDim2.fromScale(0, 1)
	self.BarFill.Parent = bar

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = self.BarFill

	self.BarLabel = createTextLabel(bar, "")
	self.BarLabel.Name = "BarLabel"
	self.BarLabel.TextScaled = false
	self.BarLabel.TextSize = 14
	self.BarLabel.ZIndex = 2
	self.BarLabel.Size = UDim2.fromScale(1, 1)

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundColor3 = SECTION_COLOR
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Position = UDim2.fromOffset(0, 64)
	list.Size = UDim2.new(1, 0, 1, -64)
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
	Client:CreateMenu(MENU_NAME, self.Gui)

	self.Connection = RunService.Heartbeat:Connect(function()
		-- Track menu shown/hidden transitions so input setup/teardown runs however
		-- the menu was opened or closed (our Open/Close, another SetMenu, etc.).
		local shown = Client.CurrentMenu == MENU_NAME
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

return DailyRewards
