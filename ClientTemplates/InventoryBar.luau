local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Inventory = require(script.Parent.Parent.Inventory)
local State = require(script.Parent.Parent.State)
local FormatUtil = require(script.Parent.Parent.FormatUtil)
local Tooltip = require(script.Parent.Parent.Tooltip)
local Responsive = require(script.Parent.Parent.Responsive)

local InventoryBar = {}
InventoryBar.__index = InventoryBar

local function createTextLabel(parent, text)
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextScaled = true
    label.Font = Enum.Font.GothamMedium
    label.TextStrokeTransparency = 0.75
    label.TextWrapped = true
    label.Parent = parent
    return label
end

local function createStackFrame(itemId, amount, itemName)
    local frame = Instance.new("Frame")
    frame.Name = "Item_" .. tostring(itemId)
    frame.BackgroundTransparency = 1
    frame.BorderSizePixel = 0
    frame.Size = UDim2.fromOffset(64, 64)
    -- Selectable so a gamepad can land on the stack and surface its item tooltip.
    frame.Selectable = true

    local iconLabel = Instance.new("ImageLabel")
    iconLabel.Name = "Icon"
    iconLabel.BackgroundTransparency = 1
    Inventory.renderItemImage(iconLabel, itemName)
    iconLabel.Size = UDim2.fromScale(1, 0.72)
    iconLabel.Position = UDim2.fromScale(0, 0)
    iconLabel.Parent = frame

    local count = createTextLabel(frame, FormatUtil.formatShortNumber(amount))
    count.Name = "CountLabel"
    count.AnchorPoint = Vector2.new(0, 1)
    count.Position = UDim2.new(0, 0, 1, -8)
    count.Size = UDim2.fromScale(1, 0.22)
    count.TextScaled = true

    return frame
end

function InventoryBar:Refresh()
    if not self.State then
        return
    end

    local items = self.State:Get(self.Prefix .. "/Items") or {}
    local index = self.State:Get(self.Prefix .. "/Index") or {}
    local validFrames = {}
    local entries = {}

    for _, ids in index do
        for _, id in ids do
            local item = items[id]
            if item and item.LocalID then
                item.ItemId = id
                table.insert(entries, item)
            end
        end
    end

    for _, item in entries do
        local frameName = "Item_" .. tostring(item.ItemId)
        local stackFrame = self.Frame:FindFirstChild(frameName)

        if stackFrame then
            -- A stack frame is keyed by ItemId, whose ItemName (and thus icon) never
            -- changes, so only the count needs refreshing here — the icon is rendered
            -- once at creation below.
            local countLabel = stackFrame:FindFirstChild("CountLabel")
            if countLabel then
                countLabel.Text = FormatUtil.formatShortNumber(item.Amount)
            end
        else
            stackFrame = createStackFrame(item.ItemId, item.Amount, item.ItemName)
            stackFrame.Parent = self.Frame
            -- Live source: the tooltip re-reads this stack from state while shown,
            -- so its count/stats track the bar in real time. When the stack empties
            -- the frame is destroyed below, which tears the tooltip down with it.
            local id = item.ItemId
            Tooltip.fromItem(stackFrame, function()
                return self.State:Get(self.Prefix .. "/Items/" .. id)
            end)
        end

        stackFrame.LayoutOrder = item.LocalID
        validFrames[frameName] = true
    end

    for _, child in self.Frame:GetChildren() do
        if child:IsA("Frame") and not validFrames[child.Name] then
            child:Destroy()
        end
    end
end

function InventoryBar:BindState(state)
    if type(state) == "string" then
        self.State = State.newReplicated(state)
    else
        self.State = state
    end

    self.Prefix = "_Inventory"
    self.Inventory = Inventory.get(self.State, self.Prefix)

    self:Refresh()

    if self.UpdateConnection then
        self.UpdateConnection:Disconnect()
    end

    self.UpdateConnection = RunService.Heartbeat:Connect(function()
        self:Refresh()
    end)
end

function InventoryBar:Destroy()
    if self.UpdateConnection then
        self.UpdateConnection:Disconnect()
        self.UpdateConnection = nil
    end
    if self.Gui then
        self.Gui:Destroy()
        self.Gui = nil
    end
end

function InventoryBar.new()
    local self = setmetatable({}, InventoryBar)
    self.Prefix = "_Inventory"
    self.Gui = Instance.new("ScreenGui")
    self.Gui.Name = "InventoryBar"
    self.Gui.ResetOnSpawn = false
    self.Gui.IgnoreGuiInset = true
    self.Gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

    self.Frame = Instance.new("Frame")
    self.Frame.Name = "InventoryBarFrame"
    self.Frame.AnchorPoint = Vector2.new(0, 1)
    self.Frame.Position = UDim2.fromScale(0, 1)
    self.Frame.Size = UDim2.fromOffset(500, 64)
    self.Frame.BackgroundTransparency = 1
    self.Frame.BorderSizePixel = 0
    self.Frame.Parent = self.Gui

    local listLayout = Instance.new("UIListLayout")
    listLayout.FillDirection = Enum.FillDirection.Horizontal
    listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Padding = UDim.new(0, 0)
    listLayout.Parent = self.Frame

    -- Touch devices put the movement thumbstick at the bottom-left and the jump
    -- button at the bottom-right — right where a bottom-left hotbar would sit. Move
    -- it to the bottom-center and lift it clear of those controls on touch; keep the
    -- original bottom-left anchor for mouse and gamepad.
    if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
        self.Frame.AnchorPoint = Vector2.new(0.5, 1)
        self.Frame.Position = UDim2.new(0.5, 0, 1, -80)
        listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    end

    -- Scale the hotbar to the viewport / input device like the other UIs.
    Responsive.apply(self.Frame)

    self.UpdateConnection = nil

    local stateId = Players.LocalPlayer:GetAttribute("hex_stateid")
    if stateId then
        self:BindState(stateId)
    end

    return self
end

return InventoryBar
