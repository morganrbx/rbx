local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local Client = require(script.Parent.Parent.Client)
local FormatUtil = require(script.Parent.Parent.FormatUtil)
local Responsive = require(script.Parent.Parent.Responsive)
local Inventory = require(script.Parent.Parent.Inventory)

-- Default renderer for "_ItemNotification" remotes fired by Inventory on the
-- server (item Added / Removed). A project opts in with
-- `require(...ClientTemplates.ItemNotifications).new()`. Toasts are thin banner
-- bars stacked at the top-center of the screen with the item icon on the left;
-- they slide down + fade in, auto-dismiss, and the stack is trimmed once it
-- exceeds MAX_VISIBLE.
local ItemNotifications = {}
ItemNotifications.__index = ItemNotifications

local TOAST_WIDTH = 320
local TOAST_HEIGHT = 34
local MAX_VISIBLE = 4
local LIFETIME = 3
local TWEEN_TIME = 0.25
local BANNER_TRANSPARENCY = 0.15
local ADDED_COLOR = Color3.fromRGB(120, 220, 130)
local REMOVED_COLOR = Color3.fromRGB(235, 110, 110)

local function createTextLabel(parent, text)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextScaled = true
	label.Font = Enum.Font.GothamMedium
	label.TextStrokeTransparency = 0.75
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

-- Build a single toast for `payload` ({Kind, ItemName, Amount}). The outer slot
-- is laid out by the UIListLayout and stays transparent; the inner banner is
-- what we tween, so the slide doesn't fight the layout. Returns the slot.
function ItemNotifications:_createToast(payload)
	local info = Client.ItemTable and Client.ItemTable[payload.ItemName] or {}
	local added = payload.Kind == "Added"
	local sign = added and "+" or "-"
	local displayName = info.Name or payload.ItemName

	local slot = Instance.new("Frame")
	slot.Name = "Toast"
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	slot.Size = UDim2.fromOffset(TOAST_WIDTH, TOAST_HEIGHT)
	slot.ClipsDescendants = false

	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	-- Start above the slot; tweened down to y=0 on insert.
	banner.Position = UDim2.new(0.5, 0, 0, -TOAST_HEIGHT)
	banner.Size = UDim2.fromScale(1, 1)
	banner.BackgroundColor3 = Color3.fromRGB(26, 26, 28)
	banner.BackgroundTransparency = 1
	banner.BorderSizePixel = 0
	banner.Parent = slot

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = banner

	-- Item icon pinned to the left edge, square (height-driven).
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	Inventory.renderItemImage(icon, payload.ItemName)
	icon.ImageTransparency = 1
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 5, 0.5, 0)
	icon.Size = UDim2.new(1, -8, 1, -8)
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	icon.Parent = banner

	local label =
		createTextLabel(banner, sign .. FormatUtil.formatLongNumber(payload.Amount) .. " " .. tostring(displayName))
	label.Name = "Label"
	label.TextTransparency = 1
	label.TextColor3 = added and ADDED_COLOR or REMOVED_COLOR
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.new(0, TOAST_HEIGHT + 4, 0.5, 0)
	label.Size = UDim2.new(1, -(TOAST_HEIGHT + 12), 0.6, 0)

	return slot
end

-- Slide the banner down + fade in, hold for LIFETIME, then slide up + fade out
-- and destroy the slot.
function ItemNotifications:_animateToast(slot)
	local banner = slot:FindFirstChild("Banner")
	if not banner then
		return
	end
	local icon = banner:FindFirstChild("Icon")
	local label = banner:FindFirstChild("Label")

	local tweenIn = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(banner, tweenIn, {
		BackgroundTransparency = BANNER_TRANSPARENCY,
		Position = UDim2.fromScale(0.5, 0),
	}):Play()
	if icon then
		TweenService:Create(icon, tweenIn, { ImageTransparency = 0 }):Play()
	end
	if label then
		TweenService:Create(label, tweenIn, { TextTransparency = 0 }):Play()
	end

	task.delay(LIFETIME, function()
		if not slot.Parent then
			return
		end
		local tweenOut = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(banner, tweenOut, {
			BackgroundTransparency = 1,
			Position = UDim2.new(0.5, 0, 0, -TOAST_HEIGHT),
		}):Play()
		if icon then
			TweenService:Create(icon, tweenOut, { ImageTransparency = 1 }):Play()
		end
		if label then
			local fade = TweenService:Create(label, tweenOut, { TextTransparency = 1 })
			fade.Completed:Connect(function()
				slot:Destroy()
			end)
			fade:Play()
		else
			task.delay(TWEEN_TIME, function()
				slot:Destroy()
			end)
		end
	end)
end

function ItemNotifications:Push(payload)
	if typeof(payload) ~= "table" or not payload.ItemName then
		return
	end
	-- Optional gate: a project can pass `Filter = function(payload) ... end` to
	-- `.new`; the toast is only shown when the callback returns truthy. Lets a game
	-- suppress noise (e.g. hide currency toasts, only surface "Removed" events).
	-- Errors are caught so a bad filter can't break the pipe — on error we fall
	-- through and show the toast rather than silently dropping it.
	if self.Filter then
		local ok, show = pcall(self.Filter, payload)
		if ok and not show then
			return
		end
	end
	-- Trim the oldest toasts so the stack never grows without bound.
	local existing = {}
	for _, child in self.Frame:GetChildren() do
		if child:IsA("Frame") then
			table.insert(existing, child)
		end
	end
	for i = 1, #existing - (MAX_VISIBLE - 1) do
		existing[i]:Destroy()
	end

	local toast = self:_createToast(payload)
	toast.Parent = self.Frame
	self:_animateToast(toast)
end

function ItemNotifications:Destroy()
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
--   Filter(payload) -> boolean — return false to suppress that toast. payload is
--   { Kind = "Added"|"Removed", ItemName, Amount, Source? }, where Source tags the
--   cause of the change when set (e.g. "Trade") so a game can drop those toasts:
--   `Filter = function(p) return p.Source ~= "Trade" end`. Omit config for the old
--   behavior (`.new()` with no args still shows every notification).
function ItemNotifications.new(config)
	local self = setmetatable({}, ItemNotifications)
	self.Filter = config and config.Filter

	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "ItemNotifications"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	self.Gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Frame = Instance.new("Frame")
	self.Frame.Name = "ItemNotificationsFrame"
	-- Anchored top-center, pushed below the Roblox topbar. The ScreenGui ignores the
	-- GUI inset (so toast offsets are simple screen pixels), which would otherwise let
	-- toasts slide under the topbar / mobile menu button — so add the inset back here.
	self.Frame.AnchorPoint = Vector2.new(0.5, 0)
	self.Frame.Position = UDim2.new(0.5, 0, 0, GuiService:GetGuiInset().Y + 12)
	self.Frame.Size = UDim2.fromOffset(TOAST_WIDTH, (TOAST_HEIGHT + 6) * MAX_VISIBLE)
	self.Frame.BackgroundTransparency = 1
	self.Frame.BorderSizePixel = 0
	self.Frame.Parent = self.Gui

	-- Scale the toast stack to the viewport / input device like the other UIs.
	Responsive.apply(self.Frame)

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = self.Frame

	self.Connection = Client:ConnectRemote("_ItemNotification", function(payload)
		self:Push(payload)
	end)

	return self
end

return ItemNotifications
