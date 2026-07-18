local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Client = require(script.Parent.Client)
local FormatUtil = require(script.Parent.FormatUtil)
local Responsive = require(script.Parent.Responsive)

-- Hover tooltips. `Tooltip.new(parent, frame)` attaches an arbitrary content
-- `frame` to any GuiObject `parent`: it shows on hover, follows the cursor, hides
-- on leave, and tears itself down when `parent` goes away. `fromItem` /
-- `fromItemName` build a styled item tooltip from Client.ItemTable. Every tooltip
-- lives in one shared, high-DisplayOrder host so it draws above all other UI and
-- only one is ever visible at a time.
--
-- Item tooltips update in real time: pass `fromItem` a function source instead of
-- a static item table and, while the tooltip is visible, it polls that source on
-- Heartbeat and refreshes the count/stat labels in place when the amount changes.
local Tooltip = {}
Tooltip.__index = Tooltip

local WIDTH = 220
-- Cursor-follow placement (mirrors the legacy tooltip module): the frame's
-- top-left is pinned OFFSET away from the cursor and clamped so the whole frame
-- always stays BORDER pixels inside the viewport.
local OFFSET = Vector2.new(20, 20)
local BORDER = 5
local BG_COLOR = Color3.fromRGB(20, 20, 24)
local TITLE_COLOR = Color3.fromRGB(255, 255, 255)
local BODY_COLOR = Color3.fromRGB(190, 190, 200)
local STAT_COLOR = Color3.fromRGB(235, 215, 150)

local host

-- The single tooltip currently shown. Only one is ever visible at a time, so
-- showing a new one hides this; Hide clears it when it points at the closer.
local activeTooltip

-- Lazily create (or recreate after a respawn) the shared host ScreenGui.
local function getHost()
	if host and host.Parent then
		return host
	end
	host = Instance.new("ScreenGui")
	host.Name = "Tooltips"
	host.ResetOnSpawn = false
	host.IgnoreGuiInset = true
	-- Content frames are authored under Sibling behaviour (children always draw in
	-- front of their parent). Instance.new defaults to Global, where layering is by
	-- ZIndex number alone, so a semi-transparent parent panel can draw over its own
	-- text and dim it. Match the authored GUIs to keep cloned frames rendering right.
	host.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Above everything: nothing else in these games sets DisplayOrder this high,
	-- so the tooltip never renders under another ScreenGui's panel.
	host.DisplayOrder = 2_000_000_000
	host.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return host
end

-- Pin the tooltip's top-left OFFSET away from the cursor and clamp it fully into
-- the viewport, exactly like the legacy module. Driven every RenderStepped while
-- visible (see Show) so it tracks the cursor smoothly. The host is IgnoreGuiInset,
-- so its AbsoluteSize and GetMouseLocation share the same coordinate space.
function Tooltip:_position()
	local frame = self.Frame
	local hostGui = frame.Parent
	local guiSize = (hostGui and hostGui.AbsoluteSize)
		or (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize)
		or Vector2.new(1920, 1080)
	local size = frame.AbsoluteSize

	-- Anchor source: normally the cursor (a mouse hover and a touch press both
	-- report a usable location). A gamepad has no cursor over the element, so when
	-- shown via selection we anchor to the right edge of the selected element
	-- instead; the clamp below keeps it on-screen if that would overflow.
	local anchorX, anchorY
	if self._anchorMode == "parent" and self.Parent then
		local parentPos = self.Parent.AbsolutePosition
		local parentSize = self.Parent.AbsoluteSize
		anchorX = parentPos.X + parentSize.X
		anchorY = parentPos.Y
	else
		local mouse = UserInputService:GetMouseLocation()
		anchorX = mouse.X
		anchorY = mouse.Y
	end

	local x = math.clamp(anchorX + OFFSET.X, BORDER, math.max(BORDER, guiSize.X - BORDER - size.X))
	local y = math.clamp(anchorY + OFFSET.Y, BORDER, math.max(BORDER, guiSize.Y - BORDER - size.Y))

	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = UDim2.fromOffset(x, y)
end

-- True only while `gui` is still in the tree and neither it nor any GuiObject
-- ancestor is hidden, and its containing ScreenGui (etc.) is still enabled -- i.e.
-- the cursor could plausibly still be over it. Roblox does NOT fire MouseLeave when
-- a GuiObject is hidden/destroyed or its ScreenGui is disabled out from under the
-- cursor, so a shown tooltip whose parent vanishes that way would otherwise linger;
-- the Show render loop polls this to tear itself down.
local function parentOnScreen(gui)
	if not gui or not gui:IsDescendantOf(game) then
		return false
	end
	local node = gui
	while node and node:IsA("GuiObject") do
		if not node.Visible then
			return false
		end
		node = node.Parent
	end
	-- We've walked past the GuiObjects to the LayerCollector (ScreenGui/SurfaceGui/
	-- BillboardGui). Disabling it hides everything beneath without firing MouseLeave,
	-- which is exactly how the shop closes (`Gui.Enabled = false`).
	if node and node:IsA("LayerCollector") and not node.Enabled then
		return false
	end
	return true
end

function Tooltip:Show()
	-- Only one tooltip is visible at a time, so displace whoever is currently shown.
	-- This also covers a previous tooltip whose parent vanished without a MouseLeave
	-- (e.g. the shop closed under the cursor) and would otherwise linger behind us.
	if activeTooltip and activeTooltip ~= self then
		activeTooltip:Hide()
	end
	activeTooltip = self

	self.Frame.Visible = true
	self:_position()
	-- Follow the cursor every frame while visible (legacy behaviour), and hide as
	-- soon as the parent leaves the screen without a MouseLeave (menu closed, item
	-- button removed under the cursor, …) so no dead tooltip is left behind.
	if not self._renderConnection then
		self._renderConnection = RunService.RenderStepped:Connect(function()
			if not parentOnScreen(self.Parent) then
				self:Hide()
				return
			end
			self:_position()
		end)
	end
	-- Only poll a live source while actually visible, so a hidden tooltip costs
	-- nothing. A fresh poll on show also catches changes made since it last closed.
	if (self._itemSource or self._refreshOwned) and not self._pollConnection then
		self:_pollSource()
		self._pollConnection = RunService.Heartbeat:Connect(function()
			self:_pollSource()
		end)
	end
end

function Tooltip:Hide()
	if activeTooltip == self then
		activeTooltip = nil
	end
	if self.Frame then
		self.Frame.Visible = false
	end
	if self._renderConnection then
		self._renderConnection:Disconnect()
		self._renderConnection = nil
	end
	if self._pollConnection then
		self._pollConnection:Disconnect()
		self._pollConnection = nil
	end
end

-- Refresh the displayed amount (and dependent stats) without rebuilding the frame.
function Tooltip:SetAmount(amount)
	amount = amount or 1
	if amount == self._lastAmount then
		return
	end
	self._lastAmount = amount
	if self._update then
		self._update(amount)
	end
end

-- Pull the current item from a live source and refresh if its amount changed. A
-- nil result means the stack is gone; the owner destroys the parent frame (which
-- tears us down via Destroying), so we just leave the last values shown until then.
function Tooltip:_pollSource()
	if self._itemSource then
		local item = self._itemSource()
		if item and item.Amount then
			self:SetAmount(item.Amount)
		end
	end
	if self._refreshOwned then
		self._refreshOwned()
	end
end

-- Drop the "You own" line (used by fromItem, where it would only echo the stack
-- the tooltip already shows).
function Tooltip:_hideOwned()
	self._refreshOwned = nil
	local label = self.Frame and self.Frame:FindFirstChild("Owned")
	if label then
		label.Visible = false
	end
end

function Tooltip:Destroy()
	self:Hide()
	for _, connection in self.Connections do
		connection:Disconnect()
	end
	table.clear(self.Connections)
	if self.Frame then
		self.Frame:Destroy()
		self.Frame = nil
	end
end

function Tooltip.new(parent, frame)
	local self = setmetatable({}, Tooltip)
	self.Parent = parent
	self.Frame = frame
	self.Connections = {}

	frame.Visible = false
	frame.Parent = getHost()
	-- Scale the tooltip content to the viewport / input device, same as the panels.
	-- Applied to the frame itself (not the host) so the cursor-follow positioning in
	-- _position, which sets the frame's own offset, is unaffected by the scale.
	Responsive.apply(frame)

	-- Mouse hover (also fired by a touch press, giving "hold to inspect" on phones).
	table.insert(
		self.Connections,
		parent.MouseEnter:Connect(function()
			self._anchorMode = nil
			self:Show()
		end)
	)
	table.insert(
		self.Connections,
		parent.MouseLeave:Connect(function()
			self:Hide()
		end)
	)
	-- Gamepad: a controller selecting this element (it must be Selectable) shows the
	-- tooltip anchored beside it, since there's no cursor to follow.
	table.insert(
		self.Connections,
		parent.SelectionGained:Connect(function()
			self._anchorMode = "parent"
			self:Show()
		end)
	)
	table.insert(
		self.Connections,
		parent.SelectionLost:Connect(function()
			self:Hide()
		end)
	)
	-- Follow the parent out of existence so the orphaned tooltip frame and its
	-- connections don't leak in the shared host.
	table.insert(
		self.Connections,
		parent.Destroying:Connect(function()
			self:Destroy()
		end)
	)

	return self
end

local function createTextLabel(text, color, size)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextSize = size
	label.Font = Enum.Font.GothamMedium
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Size = UDim2.fromScale(1, 0)
	return label
end

local function formatWeight(weight)
	if weight == math.floor(weight) then
		return tostring(weight)
	end
	return string.format("%.1f", weight)
end

-- Build the styled content frame for an item. Width is fixed; height grows with
-- the (optional) description and stat lines via AutomaticSize. `itemName` is the
-- inventory key used for the "You own" line; pass nil to omit it.
local function buildItemFrame(info, amount, itemName)
	local frame = Instance.new("Frame")
	frame.Name = "ItemTooltip"
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Size = UDim2.fromOffset(WIDTH, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = BG_COLOR
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 70, 80)
	stroke.Thickness = 1
	stroke.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = frame

	-- Header: optional icon + name, with the count when stacked.
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.LayoutOrder = 1
	header.BackgroundTransparency = 1
	header.AutomaticSize = Enum.AutomaticSize.Y
	header.Size = UDim2.fromScale(1, 0)
	header.Parent = frame

	local headerLayout = Instance.new("UIListLayout")
	headerLayout.FillDirection = Enum.FillDirection.Horizontal
	headerLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	headerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	headerLayout.Padding = UDim.new(0, 6)
	headerLayout.Parent = header

	-- Item icon. Every item has a .Render table (with at least .Image); spread it
	-- onto the label so per-item styling (ImageColor3, ScaleType, …) carries over,
	-- the same way Inventory.renderItemImage applies it elsewhere. Fit is the default
	-- (an ImageLabel otherwise stretches); a render-supplied ScaleType overrides it.
	local render = info.Render
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.LayoutOrder = 1
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	for key, value in render do
		icon[key] = value
	end
	icon.Size = UDim2.fromOffset(24, 24)
	icon.Parent = header

	local name = createTextLabel("", TITLE_COLOR, 16)
	name.Name = "Name"
	name.LayoutOrder = 2
	name.Font = Enum.Font.GothamBold
	name.Size = UDim2.new(1, -30, 0, 0)
	name.Parent = header

	if info.Description and info.Description ~= "" then
		local description = createTextLabel(info.Description, BODY_COLOR, 13)
		description.Name = "Description"
		description.LayoutOrder = 2
		description.Parent = frame
	end

	local stats = createTextLabel("", STAT_COLOR, 13)
	stats.Name = "Stats"
	stats.LayoutOrder = 3
	stats.Parent = frame

	-- The name's count and the value/weight stats are the only amount-dependent
	-- bits, so updating just these two labels keeps real-time refreshes flicker-free.
	local baseName = info.Name or "Unknown"
	local value = info.Value or 0
	local weight = info.Weight or 0
	local function update(newAmount)
		newAmount = newAmount or 1
		name.Text = if newAmount > 1 then baseName .. "  x" .. FormatUtil.formatLongNumber(newAmount) else baseName

		-- Only surface the stats that are non-zero: a value-less item shows just
		-- Weight, a weightless item shows just Value, and an item with neither
		-- hides the label entirely.
		local parts = {}
		if value > 0 then
			parts[#parts + 1] = if newAmount > 1
				then ("Value %s (%s ea)"):format(
					FormatUtil.formatShortNumber(value * newAmount),
					FormatUtil.formatShortNumber(value)
				)
				else ("Value %s"):format(FormatUtil.formatShortNumber(value))
		end
		if weight > 0 then
			parts[#parts + 1] = if newAmount > 1
				then ("Weight %s (%s ea)"):format(formatWeight(weight * newAmount), formatWeight(weight))
				else ("Weight %s"):format(formatWeight(weight))
		end

		stats.Text = table.concat(parts, " · ")
		stats.Visible = #parts > 0
	end
	update(amount)

	-- "You own: N" — the player's current inventory count of this item, independent
	-- of the trade amount above. Sits under the stat line and refreshes live while
	-- the tooltip is visible (see Show/_pollSource). Skipped when we have no item key.
	local refreshOwned
	if itemName then
		local owned = createTextLabel("", BODY_COLOR, 13)
		owned.Name = "Owned"
		owned.LayoutOrder = 4
		owned.Parent = frame

		function refreshOwned()
			local inventory = Client.Inventory
			local count = inventory and inventory:CountItem(itemName) or 0
			owned.Text = "You own: " .. FormatUtil.formatLongNumber(count)
		end
		refreshOwned()
	end

	return frame, update, refreshOwned
end

-- Resolve an item source (a static item table, or a function returning the
-- current item) to its name and amount for the initial build.
local function resolveItem(source)
	local item = if type(source) == "function" then source() else source
	item = item or {}
	return item.ItemName or item.Name, item.Amount or 1
end

function Tooltip.fromItemName(parent, itemName, amount)
	amount = amount or 1
	local info = Client.ItemTable and Client.ItemTable[itemName] or {}
	local frame, update, refreshOwned = buildItemFrame(info, amount, itemName)
	local self = Tooltip.new(parent, frame)
	self._update = update
	self._refreshOwned = refreshOwned
	self._lastAmount = amount
	return self
end

-- `source` is either an item table {ItemName/Name, Amount} or a function returning
-- one. A function makes the tooltip live: it re-reads the amount while visible.
function Tooltip.fromItem(parent, source)
	local itemName, amount = resolveItem(source)
	local self = Tooltip.fromItemName(parent, itemName, amount)
	-- This tooltip already represents the player's own stack, so a "You own" line
	-- would just echo the count already shown — drop it.
	self:_hideOwned()
	if type(source) == "function" then
		self._itemSource = source
	end
	return self
end

-- Build a compact single-line tooltip frame that hugs its text (shares the item
-- tooltip's background/stroke/corner styling). Used by fromText for plain label
-- tooltips like the HUD menu buttons.
local function buildTextFrame(text)
	local frame = Instance.new("Frame")
	frame.Name = "TextTooltip"
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.fromOffset(0, 0)
	frame.BackgroundColor3 = BG_COLOR
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 70, 80)
	stroke.Thickness = 1
	stroke.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = TITLE_COLOR
	label.TextSize = 14
	label.Font = Enum.Font.GothamMedium
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)
	label.Parent = frame

	return frame
end

-- Plain text hover tooltip — e.g. naming a HUD icon button. No live source.
function Tooltip.fromText(parent, text)
	return Tooltip.new(parent, buildTextFrame(text))
end

return Tooltip
