local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")
local Client = require(script.Parent.Parent.Client)
local Responsive = require(script.Parent.Parent.Responsive)

-- Invite front end for the P2P trade system (see Trade.luau), the companion to
-- TradeMenu (which owns the trade window). A project opts in with
-- `require(...ClientTemplates.TradeInvites).new()`. It provides two things:
--   1. A player-list panel (registered with the game's menu system as "_TradePlayers"):
--      open it with :Open() / a keybind; each row has a Trade button that sends a
--      request to that player. Opening/closing goes through Client:SetMenu/CloseMenu.
--   2. A stacked queue of incoming invites: each raises a card with Accept / Decline
--      and a countdown bar; several can be pending at once. Accepting invokes
--      _TradeRespond, and the server then opens the window (TradeMenu handles that).
-- Outgoing feedback (waiting / declined / expired) shows as a small toast.
local TradeInvites = {}
TradeInvites.__index = TradeInvites

local PANEL_COLOR = Color3.fromRGB(26, 26, 28)
local SECTION_COLOR = Color3.fromRGB(34, 34, 38)
local ROW_COLOR = Color3.fromRGB(44, 44, 50)
local ACCENT_COLOR = Color3.fromRGB(120, 200, 130)
local DECLINE_COLOR = Color3.fromRGB(235, 110, 110)
local BAR_COLOR = Color3.fromRGB(150, 150, 160)

-- Registered with the game's Client menu system under this underscore-prefixed name
-- so it can't clash with a game menu (and opening a game menu closes the panel).
local MENU_NAME = "_TradePlayers"
local CLOSE_ACTION = "TradeInvitesClose"
-- Used only if the server's invite payload omits a Duration (it shouldn't).
local FALLBACK_TTL = 30

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

-- Fleeting outgoing-feedback banner (waiting / declined / expired), self-clearing.
function TradeInvites:_toast(text, color)
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

-- ── Incoming invite queue ────────────────────────────────────────────────────

function TradeInvites:_removeInvite(card)
	local index = table.find(self.Invites, card)
	if not index then
		return
	end
	table.remove(self.Invites, index)
	if card.Frame then
		card.Frame:Destroy()
	end
end

-- Add (or, if one from the same player is already showing, refresh) an invite card.
function TradeInvites:_addInvite(from, fromName, duration)
	if typeof(from) ~= "Instance" or not from:IsA("Player") then
		return
	end
	duration = tonumber(duration) or FALLBACK_TTL

	for _, card in self.Invites do
		if card.From == from then
			card.Duration = duration
			card.Deadline = os.clock() + duration
			return
		end
	end

	local card = { From = from, Duration = duration, Deadline = os.clock() + duration }

	local frame = Instance.new("Frame")
	frame.Name = "Invite"
	frame.LayoutOrder = #self.Invites + 1
	frame.BackgroundColor3 = PANEL_COLOR
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(300, 74)
	corner(frame, 10)

	local label = createTextLabel(frame, (fromName or from.DisplayName) .. " wants to trade")
	label.Name = "Label"
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Position = UDim2.fromOffset(12, 8)
	label.Size = UDim2.new(1, -24, 0, 22)
	label.TextScaled = false
	label.TextSize = 16

	local accept = Instance.new("TextButton")
	accept.Name = "Accept"
	accept.Text = "Accept"
	accept.Font = Enum.Font.GothamBold
	accept.TextScaled = true
	accept.TextColor3 = Color3.fromRGB(20, 20, 20)
	accept.BackgroundColor3 = ACCENT_COLOR
	accept.Position = UDim2.fromOffset(12, 34)
	accept.Size = UDim2.new(0.5, -18, 0, 28)
	accept.Parent = frame
	corner(accept, 6)
	local acceptSize = Instance.new("UITextSizeConstraint")
	acceptSize.MaxTextSize = 16
	acceptSize.Parent = accept

	local decline = Instance.new("TextButton")
	decline.Name = "Decline"
	decline.Text = "Decline"
	decline.Font = Enum.Font.GothamBold
	decline.TextScaled = true
	decline.TextColor3 = Color3.fromRGB(20, 20, 20)
	decline.BackgroundColor3 = DECLINE_COLOR
	decline.AnchorPoint = Vector2.new(1, 0)
	decline.Position = UDim2.new(1, -12, 0, 34)
	decline.Size = UDim2.new(0.5, -18, 0, 28)
	decline.Parent = frame
	corner(decline, 6)
	local declineSize = Instance.new("UITextSizeConstraint")
	declineSize.MaxTextSize = 16
	declineSize.Parent = decline

	-- Countdown bar along the bottom, shrinking over the invite's lifetime.
	local barTrack = Instance.new("Frame")
	barTrack.Name = "Bar"
	barTrack.BackgroundColor3 = SECTION_COLOR
	barTrack.BorderSizePixel = 0
	barTrack.AnchorPoint = Vector2.new(0.5, 1)
	barTrack.Position = UDim2.new(0.5, 0, 1, -6)
	barTrack.Size = UDim2.new(1, -24, 0, 3)
	barTrack.Parent = frame
	corner(barTrack, 2)

	card.BarFill = Instance.new("Frame")
	card.BarFill.Name = "Fill"
	card.BarFill.BackgroundColor3 = BAR_COLOR
	card.BarFill.BorderSizePixel = 0
	card.BarFill.Size = UDim2.fromScale(1, 1)
	card.BarFill.Parent = barTrack
	corner(card.BarFill, 2)

	accept.Activated:Connect(function()
		self:_removeInvite(card)
		local result = Client:InvokeServer("_TradeRespond", from, true)
		if result and not result.Success then
			self:_toast("Couldn't open trade: " .. tostring(result.Reason), DECLINE_COLOR)
		end
	end)
	decline.Activated:Connect(function()
		self:_removeInvite(card)
		Client:InvokeServer("_TradeRespond", from, false)
	end)

	card.Frame = frame
	frame.Parent = self.InviteList
	table.insert(self.Invites, card)
end

-- Drop every pending invite (e.g. once a trade actually starts and we're busy).
function TradeInvites:_clearInvites()
	for i = #self.Invites, 1, -1 do
		self:_removeInvite(self.Invites[i])
	end
end

-- ── Player-list panel ────────────────────────────────────────────────────────

-- Friendly wording for the reasons _TradeRequest can fail with.
local REQUEST_FAIL_MESSAGES = {
	Busy = "That player is already trading.",
	TooFar = "Get closer to trade with them.",
	InvalidTarget = "Can't trade with that player.",
}

-- Send a trade request to `player` and reflect the result.
function TradeInvites:_request(player)
	local result = Client:InvokeServer("_TradeRequest", player)
	if result and result.Success then
		self:_toast("Waiting for " .. player.DisplayName .. "…", ACCENT_COLOR)
		self:Close()
	else
		local reason = result and result.Reason
		self:_toast(REQUEST_FAIL_MESSAGES[reason] or ("Couldn't trade: " .. tostring(reason)), DECLINE_COLOR)
	end
end

-- Rebuild the list of other players in the server, each with a Trade button.
function TradeInvites:_buildList()
	for _, child in self.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- When a trade range is set (workspace hex_trade_range, replicated by
	-- Trade.SetMaxRequestDistance), only list players actually invitable from here;
	-- the server enforces the same range on the request. 0/absent = unlimited.
	local range = workspace:GetAttribute("hex_trade_range")
	range = (type(range) == "number" and range > 0) and range or nil
	local localCharacter = Players.LocalPlayer.Character
	local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")

	local others = {}
	for _, player in Players:GetPlayers() do
		if player ~= Players.LocalPlayer then
			if range then
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if localRoot and root and (localRoot.Position - root.Position).Magnitude <= range then
					table.insert(others, player)
				end
			else
				table.insert(others, player)
			end
		end
	end
	table.sort(others, function(a, b)
		return a.DisplayName < b.DisplayName
	end)

	-- Empty-state wording reflects whether proximity is required.
	self.Empty.Text = range and ("No other players within " .. math.floor(range) .. " studs.")
		or "No other players here."
	self.Empty.Visible = #others == 0

	for i, player in others do
		local row = Instance.new("Frame")
		row.Name = "Player_" .. player.UserId
		row.LayoutOrder = i
		row.BackgroundColor3 = ROW_COLOR
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, 40)
		corner(row, 6)

		local name = createTextLabel(row, player.DisplayName)
		name.Name = "Name"
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Position = UDim2.fromOffset(10, 0)
		name.Size = UDim2.new(1, -100, 1, 0)
		name.TextScaled = false
		name.TextSize = 16

		local trade = Instance.new("TextButton")
		trade.Name = "Trade"
		trade.Text = "Trade"
		trade.Font = Enum.Font.GothamBold
		trade.TextScaled = true
		trade.TextColor3 = Color3.fromRGB(20, 20, 20)
		trade.BackgroundColor3 = ACCENT_COLOR
		trade.AnchorPoint = Vector2.new(1, 0.5)
		trade.Position = UDim2.new(1, -6, 0.5, 0)
		trade.Size = UDim2.fromOffset(76, 28)
		trade.Parent = row
		corner(trade, 6)
		local tradeSize = Instance.new("UITextSizeConstraint")
		tradeSize.MaxTextSize = 16
		tradeSize.Parent = trade

		trade.Activated:Connect(function()
			self:_request(player)
		end)

		row.Parent = self.List
	end
end

-- Gamepad entry: select a first button and bind B-to-close while the panel is the
-- active menu (see the Heartbeat in .new for how this is triggered).
function TradeInvites:_setupInput()
	if UserInputService.GamepadEnabled and not UserInputService.MouseEnabled then
		local firstRow = self.List:FindFirstChildWhichIsA("Frame")
		local firstButton = firstRow and firstRow:FindFirstChild("Trade")
		GuiService.SelectedObject = firstButton or self.CloseButton
		ContextActionService:BindAction(CLOSE_ACTION, function(_, inputState)
			if inputState == Enum.UserInputState.Begin then
				self:Close()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.ButtonB)
	end
end

function TradeInvites:_teardownInput()
	if GuiService.SelectedObject and self.PanelGui and GuiService.SelectedObject:IsDescendantOf(self.PanelGui) then
		GuiService.SelectedObject = nil
	end
	ContextActionService:UnbindAction(CLOSE_ACTION)
end

function TradeInvites:Open()
	self:_buildList()
	Client:SetMenu(MENU_NAME)
end

function TradeInvites:Close()
	if Client.CurrentMenu == MENU_NAME then
		Client:CloseMenu()
	end
end

function TradeInvites:IsOpen()
	return Client.CurrentMenu == MENU_NAME
end

-- Convenience for a single toggle key/button.
function TradeInvites:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function TradeInvites:Destroy()
	self:_teardownInput()
	self:_clearInvites()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	self._connections = {}
	if Client.Menus[MENU_NAME] and Client.Menus[MENU_NAME].Instance == self.PanelGui then
		if Client.CurrentMenu == MENU_NAME then
			Client:CloseMenu()
		end
		Client.Menus[MENU_NAME] = nil
	end
	if self.HeartbeatConn then
		self.HeartbeatConn:Disconnect()
		self.HeartbeatConn = nil
	end
	if self.PanelGui then
		self.PanelGui:Destroy()
		self.PanelGui = nil
	end
	if self.InviteGui then
		self.InviteGui:Destroy()
		self.InviteGui = nil
	end
end

-- `config` is optional. Supported field:
--   Title — player-list panel heading (default "Trade with…").
function TradeInvites.new(config)
	config = config or {}
	local self = setmetatable({}, TradeInvites)
	self.Invites = {}
	self._connections = {}

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- ── Player-list panel (a menu) ────────────────────────────────────────────
	self.PanelGui = Instance.new("ScreenGui")
	self.PanelGui.Name = "TradePlayers"
	self.PanelGui.ResetOnSpawn = false
	self.PanelGui.IgnoreGuiInset = true
	self.PanelGui.Enabled = false
	self.PanelGui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(360, 420)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BorderSizePixel = 0
	panel.Parent = self.PanelGui
	corner(panel, 10)
	Responsive.apply(panel)

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingLeft = UDim.new(0, 12)
	panelPadding.PaddingRight = UDim.new(0, 12)
	panelPadding.PaddingTop = UDim.new(0, 10)
	panelPadding.PaddingBottom = UDim.new(0, 12)
	panelPadding.Parent = panel

	self.Title = createTextLabel(panel, config.Title or "Trade with…")
	self.Title.Name = "Title"
	self.Title.Font = Enum.Font.GothamBold
	self.Title.TextXAlignment = Enum.TextXAlignment.Left
	self.Title.Size = UDim2.new(1, -40, 0, 32)

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
	closeButton.Parent = panel
	closeButton.Activated:Connect(function()
		self:Close()
	end)
	self.CloseButton = closeButton

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
	corner(list, 8)

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

	self.Empty = createTextLabel(list, "No other players here.")
	self.Empty.Name = "Empty"
	self.Empty.TextColor3 = Color3.fromRGB(150, 150, 160)
	self.Empty.Size = UDim2.new(1, 0, 0, 40)
	self.Empty.TextScaled = false
	self.Empty.TextSize = 15
	self.Empty.Visible = false

	-- ── Invite queue + outgoing toast (an always-on overlay, not a menu) ──────
	self.InviteGui = Instance.new("ScreenGui")
	self.InviteGui.Name = "TradeInvites"
	self.InviteGui.ResetOnSpawn = false
	self.InviteGui.IgnoreGuiInset = true
	-- Above menus (DisplayOrder 0) so invites/feedback are visible over an open
	-- menu, but below the active trade window (100).
	self.InviteGui.DisplayOrder = 50
	self.InviteGui.Parent = playerGui

	local inviteHolder = Instance.new("Frame")
	inviteHolder.Name = "Invites"
	inviteHolder.AnchorPoint = Vector2.new(1, 0)
	inviteHolder.Position = UDim2.new(1, -12, 0, GuiService:GetGuiInset().Y + 12)
	inviteHolder.Size = UDim2.fromOffset(300, 400)
	inviteHolder.BackgroundTransparency = 1
	inviteHolder.Parent = self.InviteGui
	Responsive.apply(inviteHolder)

	local inviteLayout = Instance.new("UIListLayout")
	inviteLayout.FillDirection = Enum.FillDirection.Vertical
	inviteLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	inviteLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	inviteLayout.SortOrder = Enum.SortOrder.LayoutOrder
	inviteLayout.Padding = UDim.new(0, 8)
	inviteLayout.Parent = inviteHolder
	self.InviteList = inviteHolder

	self.ToastFrame = Instance.new("Frame")
	self.ToastFrame.Name = "Toast"
	self.ToastFrame.AnchorPoint = Vector2.new(0.5, 0)
	self.ToastFrame.Position = UDim2.new(0.5, 0, 0, GuiService:GetGuiInset().Y + 12)
	self.ToastFrame.Size = UDim2.fromOffset(320, 36)
	self.ToastFrame.BackgroundColor3 = PANEL_COLOR
	self.ToastFrame.BackgroundTransparency = 0.15
	self.ToastFrame.BorderSizePixel = 0
	self.ToastFrame.Visible = false
	self.ToastFrame.Parent = self.InviteGui
	corner(self.ToastFrame, 8)
	Responsive.apply(self.ToastFrame)
	self.Toast = createTextLabel(self.ToastFrame, "")
	self.Toast.Size = UDim2.fromScale(1, 1)
	self.Toast.TextScaled = false
	self.Toast.TextSize = 15

	-- ── Register the panel as a menu and wire server events ───────────────────
	Client:CreateMenu(MENU_NAME, self.PanelGui)

	table.insert(
		self._connections,
		Client:ConnectRemote("_TradeInvite", function(payload)
			self:_addInvite(payload.From, payload.FromName, payload.Duration)
		end)
	)
	table.insert(
		self._connections,
		Client:ConnectRemote("_TradeDeclined", function(payload)
			local reason = payload and payload.Reason
			local name = payload and payload.By and payload.By.DisplayName or "Player"
			if reason == "Expired" then
				self:_toast("Trade request expired.", DECLINE_COLOR)
			else
				self:_toast(name .. " declined your trade.", DECLINE_COLOR)
			end
		end)
	)
	table.insert(
		self._connections,
		-- A trade actually started (TradeMenu opens the window); we're now busy, so
		-- clear any queued invites and close the panel.
		Client:ConnectRemote("_TradeStart", function()
			self:_clearInvites()
			self:Close()
		end)
	)
	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function()
			if self:IsOpen() then
				self:_buildList()
			end
		end)
	)
	table.insert(
		self._connections,
		Players.PlayerRemoving:Connect(function()
			if self:IsOpen() then
				self:_buildList()
			end
		end)
	)

	self.HeartbeatConn = RunService.Heartbeat:Connect(function()
		-- Menu shown/hidden transition drives gamepad input setup/teardown.
		local shown = Client.CurrentMenu == MENU_NAME
		if shown ~= self._shown then
			self._shown = shown
			if shown then
				self:_setupInput()
			else
				self:_teardownInput()
			end
		end
		-- Advance each invite card's countdown bar; drop any that lapse.
		for i = #self.Invites, 1, -1 do
			local card = self.Invites[i]
			local remaining = card.Deadline - os.clock()
			if remaining <= 0 then
				self:_removeInvite(card)
			elseif card.BarFill then
				card.BarFill.Size = UDim2.fromScale(math.clamp(remaining / card.Duration, 0, 1), 1)
			end
		end
	end)

	return self
end

return TradeInvites
