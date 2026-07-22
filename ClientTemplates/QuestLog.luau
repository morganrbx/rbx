local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Client = require(script.Parent.Parent.Client)
local Responsive = require(script.Parent.Parent.Responsive)
local FormatUtil = require(script.Parent.Parent.FormatUtil)
local Inventory = require(script.Parent.Parent.Inventory)
local Tooltip = require(script.Parent.Parent.Tooltip)

-- Front end for the quests declared server-side with Server:CreateQuests and handed out
-- with Server:GiveQuest. Registered as an rbx menu ("_Quests"), fully data-driven: it
-- lists the player's live quests, each showing its current stage's tasks with a progress
-- bar and reward item squares, and a CLAIM button wherever a reward is waiting.
--
-- Rewards render as up to three item squares (icon + amount, with a hover tooltip),
-- right-aligned in a fixed column so they line up down the panel. They stay visible after
-- claiming (dimmed) so a completed task still shows what it gave. A task with no reward
-- auto-completes server-side and just shows a tick; a stage's own reward previews from the
-- start behind a lock and only becomes claimable once every task is done.
local QuestLog = {}
QuestLog.__index = QuestLog

local MENU_NAME = "_Quests"

local PANEL_COLOR = Color3.fromRGB(24, 24, 27)
local SECTION_COLOR = Color3.fromRGB(32, 32, 37)
local CARD_COLOR = Color3.fromRGB(40, 40, 46)
local ROW_COLOR = Color3.fromRGB(48, 48, 56)
local TRACK_COLOR = Color3.fromRGB(60, 60, 68)
local ACCENT_COLOR = Color3.fromRGB(245, 205, 90)
local DONE_COLOR = Color3.fromRGB(120, 220, 140)
local MUTED_COLOR = Color3.fromRGB(150, 150, 160)

local ROW_HEIGHT = 44
local SQUARE = 30 -- reward icon square
local MAX_SQUARES = 3 -- how many reward squares before collapsing the rest into "+N"
local SQUARE_GAP = 4
local STATUS_WIDTH = 74 -- fixed column for the count / CLAIM / tick
local REWARDS_WIDTH = MAX_SQUARES * SQUARE + (MAX_SQUARES - 1) * SQUARE_GAP
local COLUMN_GAP = 8
-- Right area of every row: [status][gap][rewards], both sub-columns fixed so the reward
-- squares line up at the same X down the whole panel.
local RIGHT_WIDTH = STATUS_WIDTH + COLUMN_GAP + REWARDS_WIDTH

-- Rebuilt on a throttle while open; quests only move on server events.
local REFRESH_INTERVAL = 0.5

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

-- One reward as a square: the item's icon with its amount in the corner, plus a hover
-- tooltip. `dim` fades a reward that's already been claimed. The tooltip self-destroys
-- with the square (parent.Destroying), so it's safe under the rebuild loop.
local function rewardSquare(parent, itemName, amount, dim)
	local sq = Instance.new("Frame")
	sq.Name = "Reward_" .. itemName
	sq.BackgroundColor3 = TRACK_COLOR
	sq.BackgroundTransparency = if dim then 0.5 else 0
	sq.BorderSizePixel = 0
	sq.Size = UDim2.fromOffset(SQUARE, SQUARE)
	sq.Parent = parent
	corner(sq, 4)

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.ImageTransparency = if dim then 0.5 else 0
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.45)
	icon.Size = UDim2.fromScale(0.72, 0.72)
	icon.Parent = sq
	-- renderItemImage errors on an item without a Render table; a reward can reference
	-- anything, so guard it and just fall through to the amount label if there's no icon.
	pcall(function()
		Inventory.renderItemImage(icon, itemName)
	end)

	local amt = label(sq, FormatUtil.formatShortNumber(amount), 11, true)
	amt.Name = "Amount"
	amt.AnchorPoint = Vector2.new(1, 1)
	amt.Position = UDim2.new(1, -2, 1, 1)
	amt.Size = UDim2.fromOffset(SQUARE, 12)
	amt.TextXAlignment = Enum.TextXAlignment.Right
	amt.TextStrokeTransparency = 0.4
	amt.TextTransparency = if dim then 0.4 else 0

	Tooltip.fromItemName(sq, itemName, amount)
	return sq
end

-- Fill a rewards holder with up to MAX_SQUARES squares; extras collapse into "+N".
local function fillRewards(holder, rewards, dim)
	local count = #rewards
	local shown = if count > MAX_SQUARES then MAX_SQUARES - 1 else count
	for i = 1, shown do
		local entry = rewards[i]
		rewardSquare(holder, entry[1], entry[2] or 1, dim)
	end
	if count > shown then
		local more = Instance.new("Frame")
		more.Name = "More"
		more.LayoutOrder = shown + 1
		more.BackgroundColor3 = TRACK_COLOR
		more.BackgroundTransparency = if dim then 0.5 else 0
		more.BorderSizePixel = 0
		more.Size = UDim2.fromOffset(SQUARE, SQUARE)
		more.Parent = holder
		corner(more, 4)
		local l = label(more, "+" .. (count - shown), 13, true)
		l.Size = UDim2.fromScale(1, 1)
		l.TextXAlignment = Enum.TextXAlignment.Center
	end
end

-- The reserved right area of a row, split into a fixed status sub-column (left) and a
-- fixed rewards sub-column (right, squares right-aligned). Returns both so callers fill
-- them. Fixed widths keep the reward squares aligned across every row.
local function rightColumn(parent)
	local column = Instance.new("Frame")
	column.Name = "Right"
	column.BackgroundTransparency = 1
	column.AnchorPoint = Vector2.new(1, 0.5)
	column.Position = UDim2.new(1, -10, 0.5, 0)
	column.Size = UDim2.fromOffset(RIGHT_WIDTH, ROW_HEIGHT)
	column.Parent = parent

	local status = Instance.new("Frame")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromOffset(0, 0)
	status.Size = UDim2.fromOffset(STATUS_WIDTH, ROW_HEIGHT)
	status.Parent = column

	local rewards = Instance.new("Frame")
	rewards.Name = "Rewards"
	rewards.BackgroundTransparency = 1
	rewards.AnchorPoint = Vector2.new(1, 0)
	rewards.Position = UDim2.fromScale(1, 0)
	rewards.Size = UDim2.fromOffset(REWARDS_WIDTH, ROW_HEIGHT)
	rewards.Parent = column

	local rlayout = Instance.new("UIListLayout")
	rlayout.FillDirection = Enum.FillDirection.Horizontal
	rlayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rlayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rlayout.SortOrder = Enum.SortOrder.LayoutOrder
	rlayout.Padding = UDim.new(0, SQUARE_GAP)
	rlayout.Parent = rewards

	return status, rewards
end

-- A CLAIM button pinned to the right of the status sub-column.
local function claimButton(status, onClick)
	local b = Instance.new("TextButton")
	b.Name = "Claim"
	b.Text = "CLAIM"
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = PANEL_COLOR
	b.BackgroundColor3 = ACCENT_COLOR
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.fromScale(1, 0.5)
	b.Size = UDim2.fromOffset(70, 24)
	b.Parent = status
	corner(b, 5)
	b.Activated:Connect(onClick)
	return b
end

-- One task row: name + progress bar on the left, reward squares + status on the right.
function QuestLog:_buildTask(parent, questId, index, taskInfo, points, claimed)
	local done = points >= taskInfo.Points
	local hasReward = type(taskInfo.Rewards) == "table" and #taskInfo.Rewards > 0

	local row = Instance.new("Frame")
	row.Name = "Task" .. index
	row.LayoutOrder = index
	row.BackgroundColor3 = ROW_COLOR
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.Parent = parent
	corner(row, 5)

	local name = label(row, taskInfo.Display, 14, false)
	name.Name = "Name"
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Position = UDim2.fromOffset(12, 5)
	name.Size = UDim2.new(1, -(RIGHT_WIDTH + 24), 0, 18)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.TextColor3 = if claimed then MUTED_COLOR else Color3.fromRGB(255, 255, 255)

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundColor3 = TRACK_COLOR
	track.BorderSizePixel = 0
	track.Position = UDim2.fromOffset(12, 30)
	track.Size = UDim2.new(1, -(RIGHT_WIDTH + 24), 0, 6)
	track.Parent = row
	corner(track, 3)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = if done then DONE_COLOR else ACCENT_COLOR
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(math.clamp(points / math.max(taskInfo.Points, 1), 0, 1), 1)
	fill.Parent = track
	corner(fill, 3)

	local status, rewards = rightColumn(row)

	-- Reward squares stay visible even once claimed (dimmed), so a done task still shows
	-- what it gave.
	if hasReward then
		fillRewards(rewards, taskInfo.Rewards, claimed)
	end

	-- Exactly one status control, in its own fixed column — never stacked on the count.
	if claimed then
		local tick = label(status, "\u{2713}", 20, true)
		tick.Name = "Done"
		tick.TextColor3 = DONE_COLOR
		tick.TextXAlignment = Enum.TextXAlignment.Right
		tick.AnchorPoint = Vector2.new(1, 0.5)
		tick.Position = UDim2.fromScale(1, 0.5)
		tick.Size = UDim2.fromOffset(26, ROW_HEIGHT)
	elseif done then
		-- Finished but unclaimed — only reward-bearing tasks reach this (rewardless ones
		-- auto-complete server-side).
		claimButton(status, function()
			-- Claiming yields on the round trip, so it can't run inline.
			task.spawn(function()
				Client:ClaimQuestTask(questId, index)
				self:Refresh()
			end)
		end)
	else
		local count = label(status, points .. " / " .. taskInfo.Points, 13, false)
		count.Name = "Count"
		count.TextColor3 = MUTED_COLOR
		count.TextXAlignment = Enum.TextXAlignment.Right
		count.AnchorPoint = Vector2.new(1, 0.5)
		count.Position = UDim2.fromScale(1, 0.5)
		count.Size = UDim2.fromOffset(STATUS_WIDTH, 18)
	end
end

-- The stage reward row: always shown as a preview once a stage carries a reward; the
-- CLAIM only appears when every task is done, and claiming it advances the quest.
function QuestLog:_buildStageReward(card, questId, quest, stage, allClaimed, lastStage, order)
	local reward = stage.Reward
	if type(reward) ~= "table" or #reward == 0 or quest.StageClaimed then
		return
	end

	local row = Instance.new("Frame")
	row.Name = "StageReward"
	row.LayoutOrder = order
	row.BackgroundColor3 = SECTION_COLOR
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.Parent = card
	corner(row, 5)

	local text = label(row, if lastStage then "QUEST REWARD" else "STAGE REWARD", 13, true)
	text.Name = "Label"
	text.TextColor3 = ACCENT_COLOR
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Position = UDim2.fromOffset(12, 0)
	text.Size = UDim2.new(1, -(RIGHT_WIDTH + 24), 1, 0)

	local status, rewards = rightColumn(row)
	fillRewards(rewards, reward, false)

	if allClaimed then
		claimButton(status, function()
			task.spawn(function()
				Client:ClaimQuestStage(questId)
				self:Refresh()
			end)
		end)
	else
		-- Not yet claimable: a muted lock instead of a button, so the preview reads as
		-- locked rather than actionable.
		local lock = label(status, "\u{1F512}", 16, false)
		lock.Name = "Locked"
		lock.TextColor3 = MUTED_COLOR
		lock.TextXAlignment = Enum.TextXAlignment.Right
		lock.AnchorPoint = Vector2.new(1, 0.5)
		lock.Position = UDim2.fromScale(1, 0.5)
		lock.Size = UDim2.fromOffset(26, ROW_HEIGHT)
	end
end

function QuestLog:_buildQuest(questId, quest, order)
	local template = Client.QuestTable and Client.QuestTable[quest.Template]
	local stage = template and template.Stages and template.Stages[quest.Stage]
	if not stage then
		return
	end

	local card = Instance.new("Frame")
	card.Name = "Quest_" .. questId
	card.LayoutOrder = order
	card.BackgroundColor3 = CARD_COLOR
	card.BorderSizePixel = 0
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.Size = UDim2.fromScale(1, 0)
	card.Parent = self.List
	corner(card, 8)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = card

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = card

	-- Header: quest name + "Stage 1/3".
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.LayoutOrder = 0
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 22)
	header.Parent = card

	local title = label(header, template.Display or quest.Template, 16, true)
	title.Name = "Title"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Size = UDim2.new(1, -80, 1, 0)
	title.TextTruncate = Enum.TextTruncate.AtEnd

	local stageCount = #template.Stages
	if stageCount > 1 then
		local step = label(header, "STAGE " .. quest.Stage .. "/" .. stageCount, 12, true)
		step.Name = "Stage"
		step.TextColor3 = MUTED_COLOR
		step.TextXAlignment = Enum.TextXAlignment.Right
		step.AnchorPoint = Vector2.new(1, 0)
		step.Position = UDim2.fromScale(1, 0)
		step.Size = UDim2.fromOffset(80, 22)
	end

	local allClaimed = true
	for index, taskInfo in stage.Tasks do
		local points = (quest.Progress or {})[index] or 0
		local claimed = (quest.Claimed or {})[index] == true
		allClaimed = allClaimed and claimed
		self:_buildTask(card, questId, index, taskInfo, points, claimed)
	end

	self:_buildStageReward(card, questId, quest, stage, allClaimed, quest.Stage >= stageCount, #stage.Tasks + 1)
end

function QuestLog:Refresh()
	for _, child in self.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local quests = Client:GetQuests()
	local order = 0
	for questId, quest in quests do
		order += 1
		self:_buildQuest(questId, quest, order)
	end
	self.Empty.Visible = order == 0
end

function QuestLog:Open()
	self:Refresh()
	Client:SetMenu(MENU_NAME)
end

function QuestLog:Close()
	if Client.CurrentMenu == MENU_NAME then
		Client:CloseMenu()
	end
end

function QuestLog:IsOpen()
	return Client.CurrentMenu == MENU_NAME
end

function QuestLog:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

function QuestLog:Destroy()
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

-- config (optional): Title — panel heading (default "Quests").
function QuestLog.new(config)
	config = config or {}
	local self = setmetatable({}, QuestLog)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "QuestLog"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	self.Gui.DisplayOrder = 20
	self.Gui.Enabled = false
	self.Gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	-- Wide enough to fit a full task row: name + three reward squares + a CLAIM button.
	panel.Size = UDim2.fromOffset(560, 460)
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

	local title = label(panel, config.Title or "Quests", 24, true)
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
	listLayout.Padding = UDim.new(0, 8)
	listLayout.Parent = self.List

	self.Empty = label(self.List, "No active quests.", 15, false)
	self.Empty.Name = "Empty"
	self.Empty.TextColor3 = MUTED_COLOR
	self.Empty.Size = UDim2.new(1, 0, 0, 40)
	self.Empty.Visible = false

	Client:CreateMenu(MENU_NAME, self.Gui)

	-- Rebuild on a throttle while open, so progress from the server shows up live.
	local accum = 0
	self.RefreshConn = RunService.Heartbeat:Connect(function(dt)
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

	return self
end

return QuestLog
