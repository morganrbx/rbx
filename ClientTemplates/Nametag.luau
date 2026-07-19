local Players = game:GetService("Players")

-- Overhead nametags for every player, driven by a game-supplied resolver so the
-- template stays generic (it knows nothing about ranks, teams, or attributes).
-- A project opts in with `require(...ClientTemplates.Nametag).new({ Resolve = ... })`.
--
-- The resolver is called as `Resolve(player)` and returns a table describing what
-- to show over that player's head:
--   { Name, NameColor?, Tag?, TagColor?, SubText?, SubColor? }
-- Name is the main line; Tag (e.g. "[1]") is a coloured badge shown before it;
-- SubText is an optional smaller second line (e.g. a team or role name). Any
-- field may be omitted. The resolver runs again whenever one of the player
-- attributes in `Watch` changes and whenever their Team changes, so a rank/team
-- update reflects live.
--
-- config fields (all optional):
--   Resolve         — function(player) -> descriptor (default: just DisplayName)
--   Watch           — array of attribute names that trigger a refresh (e.g. {"GroupRank"})
--   MaxDistance     — BillboardGui.MaxDistance in studs (default 120)
--   HeightOffset    — studs above the head (default 2)
--   HideLocalPlayer — don't render a tag over yourself (default false)
--   HideDefaultName — hide Roblox's built-in name/health display (default true)
--   AlwaysOnTop     — draw through walls (default true)
local Nametag = {}
Nametag.__index = Nametag

local function defaultResolve(player)
	return { Name = player.DisplayName }
end

local function makeTextLabel(parent, order)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextScaled = false
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

-- Build the BillboardGui + labels for one character's head.
function Nametag:_build(player, head)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Nametag"
	gui.Adornee = head
	gui.AlwaysOnTop = self.AlwaysOnTop
	gui.LightInfluence = 0
	gui.MaxDistance = self.MaxDistance
	gui.Size = UDim2.fromOffset(200, 44)
	gui.StudsOffsetWorldSpace = Vector3.new(0, self.HeightOffset, 0)
	gui.ResetOnSpawn = false

	-- Main line: [Tag] Name, laid out horizontally and centred.
	local nameRow = Instance.new("Frame")
	nameRow.Name = "NameRow"
	nameRow.BackgroundTransparency = 1
	nameRow.Size = UDim2.new(1, 0, 0, 22)
	nameRow.Parent = gui

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0, 4)
	rowLayout.Parent = nameRow

	local tagLabel = makeTextLabel(nameRow, 1)
	tagLabel.Name = "Tag"
	tagLabel.TextSize = 18

	local nameLabel = makeTextLabel(nameRow, 2)
	nameLabel.Name = "Name"
	nameLabel.TextSize = 18

	-- Optional smaller second line.
	local subLabel = Instance.new("TextLabel")
	subLabel.Name = "Sub"
	subLabel.BackgroundTransparency = 1
	subLabel.Size = UDim2.new(1, 0, 0, 16)
	subLabel.Position = UDim2.fromOffset(0, 22)
	subLabel.Font = Enum.Font.GothamMedium
	subLabel.TextSize = 13
	subLabel.TextColor3 = Color3.fromRGB(210, 210, 216)
	subLabel.TextStrokeTransparency = 0.5
	subLabel.TextScaled = false
	subLabel.Parent = gui

	gui.Parent = head

	local record = self.Tags[player]
	if record then
		record.Gui = gui
		record.TagLabel = tagLabel
		record.NameLabel = nameLabel
		record.SubLabel = subLabel
	end

	self:Refresh(player)
end

-- Re-run the resolver for `player` and push the result into their labels.
function Nametag:Refresh(player)
	local record = self.Tags[player]
	if not record or not record.Gui then
		return
	end

	local ok, descriptor = pcall(self.Resolve, player)
	if not ok or type(descriptor) ~= "table" then
		descriptor = defaultResolve(player)
	end

	local tag = descriptor.Tag
	if tag and tag ~= "" then
		record.TagLabel.Text = tag
		record.TagLabel.TextColor3 = descriptor.TagColor or descriptor.Color or Color3.fromRGB(255, 255, 255)
		record.TagLabel.Visible = true
	else
		record.TagLabel.Visible = false
	end

	record.NameLabel.Text = descriptor.Name or player.DisplayName
	record.NameLabel.TextColor3 = descriptor.NameColor or Color3.fromRGB(255, 255, 255)

	local sub = descriptor.SubText
	if sub and sub ~= "" then
		record.SubLabel.Text = sub
		record.SubLabel.TextColor3 = descriptor.SubColor or Color3.fromRGB(210, 210, 216)
		record.SubLabel.Visible = true
	else
		record.SubLabel.Visible = false
	end
end

-- Refresh every currently-tracked player (e.g. after a global change).
function Nametag:RefreshAll()
	for player in self.Tags do
		self:Refresh(player)
	end
end

-- Hide Roblox's built-in overhead name/health so it doesn't double up with ours.
local function hideDefault(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
	end
end

function Nametag:_onCharacter(player, character)
	local record = self.Tags[player]
	if not record then
		return
	end
	if self.HideDefaultName then
		hideDefault(character)
	end
	local head = character:FindFirstChild("Head") or character:WaitForChild("Head", 10)
	if head and self.Tags[player] == record then
		self:_build(player, head)
	end
end

function Nametag:_track(player)
	if self.Tags[player] then
		return
	end
	if self.HideLocalPlayer and player == Players.LocalPlayer then
		return
	end

	local record = { Connections = {} }
	self.Tags[player] = record

	-- Refresh when any watched attribute or the player's team changes.
	for _, attribute in self.Watch do
		table.insert(
			record.Connections,
			player:GetAttributeChangedSignal(attribute):Connect(function()
				self:Refresh(player)
			end)
		)
	end
	table.insert(
		record.Connections,
		player:GetPropertyChangedSignal("Team"):Connect(function()
			self:Refresh(player)
		end)
	)

	table.insert(
		record.Connections,
		player.CharacterAdded:Connect(function(character)
			self:_onCharacter(player, character)
		end)
	)
	if player.Character then
		self:_onCharacter(player, player.Character)
	end
end

function Nametag:_untrack(player)
	local record = self.Tags[player]
	if not record then
		return
	end
	for _, connection in record.Connections do
		connection:Disconnect()
	end
	if record.Gui then
		record.Gui:Destroy()
	end
	self.Tags[player] = nil
end

function Nametag:Destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	self._connections = {}
	for player in self.Tags do
		self:_untrack(player)
	end
end

function Nametag.new(config)
	config = config or {}
	local self = setmetatable({}, Nametag)
	self.Resolve = config.Resolve or defaultResolve
	self.Watch = config.Watch or {}
	self.MaxDistance = config.MaxDistance or 120
	self.HeightOffset = config.HeightOffset or 2
	self.HideLocalPlayer = config.HideLocalPlayer == true
	self.HideDefaultName = config.HideDefaultName ~= false
	self.AlwaysOnTop = config.AlwaysOnTop ~= false
	self.Tags = {}
	self._connections = {}

	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player)
			self:_track(player)
		end)
	)
	table.insert(
		self._connections,
		Players.PlayerRemoving:Connect(function(player)
			self:_untrack(player)
		end)
	)
	for _, player in Players:GetPlayers() do
		self:_track(player)
	end

	return self
end

return Nametag
