local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if RunService:IsServer() then
	warn("This module is not meant to be required on the server.")
	return {}
end

local Client = {
	Started = false,
	Running = false,

	Scenes = {},
	SceneParts = {},
	Menus = {},
	CurrentScene = nil,
	CurrentMenu = nil,

	EventResponses = {},
	EventConnections = {},
}

local remoteEvent = script.Parent.Server:WaitForChild("RemoteEvent", 99)
local remoteFunction = script.Parent.Server:WaitForChild("RemoteFunction", 99)

function Client:FireServer(...)
	remoteEvent:FireServer(...)
end
function Client:InvokeServer(...)
	return remoteFunction:InvokeServer(...)
end

function Client:ConnectRemote(func, callback)
	self.EventConnections[func] = self.EventConnections[func] or {}
	table.insert(self.EventConnections[func], callback)

	local function disconnect()
		local tree = self.EventConnections[func]
		if not tree then
			return
		end
		local index = table.find(tree, callback)
		if not index then
			return
		end
		table.remove(tree, index)
		if #tree == 0 then
			self.EventConnections[func] = nil
		end
	end

	return {
		Disconnect = disconnect,
		Destroy = disconnect,
	}
end

function Client:SetRemoteResponse(func, callback)
	self.EventResponses[func] = callback

	local function disconnect()
		if self.EventResponses[func] ~= callback then
			return
		end
		self.EventResponses[func] = nil
	end

	return {
		Disconnect = disconnect,
		Destroy = disconnect,
	}
end

remoteEvent.OnClientEvent:Connect(function(func, ...)
	for _, callback in Client.EventConnections[func] or {} do
		task.spawn(callback, ...)
	end
	if Client.EventResponses[func] then
		task.spawn(Client.EventResponses[func], ...)
	end
end)
remoteFunction.OnClientInvoke = function(func, ...)
	for _, callback in Client.EventConnections[func] or {} do
		task.spawn(callback, ...)
	end
	if Client.EventResponses[func] then
		return Client.EventResponses[func](...)
	end
end

function Client:Start()
	local State = require(script.Parent.State)
	local Inventory = require(script.Parent.Inventory)

	self:SetRemoteResponse("_GetGameInfo", function()
		return { Items = self.ItemTable, Shops = self.ShopTable, DailyRewards = self.DailyRewardTable }
	end)

	self:FireServer("_ClientReady")
	if self.Started then
		return false
	end
	self.Started = true
	local gameInfo = self:InvokeServer("_GetGameInfo") or {}
	self.ItemTable = gameInfo.Items or {}
	self.ShopTable = gameInfo.Shops or {}
	self.DailyRewardTable = gameInfo.DailyRewards

	while workspace:GetAttribute("hex_server") ~= true do
		task.wait()
	end
	while not Players.LocalPlayer:GetAttribute("hex_stateid") do
		task.wait()
	end
	self.Data = State.newReplicated(Players.LocalPlayer:GetAttribute("hex_stateid"))
	self.Inventory = Inventory.get(self.Data, "_Inventory")

	self.Running = true
	workspace:SetAttribute("hex_client", true)

	self:RenderUI()
	RunService.RenderStepped:Connect(function()
		self:RenderUI()
	end)

	return true
end

function Client:RenderUI()
	local sceneName = self.CurrentScene
	local menuName = self.CurrentMenu

	local scene = self.Scenes[sceneName]
	local sceneParts = scene and scene.SceneParts or {}
	for _, scenePart in self.SceneParts do
		local shouldEnable = if table.find(sceneParts, scenePart) then sceneName ~= nil else false
		if scenePart.Instance:IsA("ScreenGui") then
			scenePart.Instance.Enabled = shouldEnable
		elseif
			scenePart.Instance:IsA("Frame")
			or scenePart.Instance:IsA("TextButton")
			or scenePart.Instance:IsA("ImageButton")
		then
			scenePart.Instance.Visible = shouldEnable
		end
		if shouldEnable and scenePart.Update then
			task.spawn(scenePart.Update, scenePart)
		end
	end

	for name, v in self.Scenes do
		if name == sceneName then
			v.Instance.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		else
			v.Instance.Parent = nil
		end
	end

	for name, menu in self.Menus do
		local shouldEnable = menuName == name
		if menu.Instance:IsA("ScreenGui") then
			menu.Instance.Enabled = shouldEnable
		elseif menu.Instance:IsA("Frame") or menu.Instance:IsA("TextButton") or menu.Instance:IsA("ImageButton") then
			menu.Instance.Visible = shouldEnable
		end
		menu.Instance.Parent = shouldEnable and Players.LocalPlayer:WaitForChild("PlayerGui") or nil

		if shouldEnable and menu.Update then
			task.spawn(menu.Update, menu)
		end
	end
end

function Client:SetMenu(menuName: string)
	if self.CurrentMenu == menuName then
		return
	end
	if menuName and not self.Menus[menuName] then
		warn("Attempted to set invalid menu: " .. menuName)
		return
	end
	self.CurrentMenu = menuName
	self:RenderUI()
end

function Client:CloseMenu()
	self.CurrentMenu = nil
	self:RenderUI()
end

function Client:CreateMenu(menuName: string, instance: ScreenGui | Frame | TextButton | ImageButton)
	local menu = {
		Name = menuName,
		Instance = instance,
	}
	menu.Instance.Name = menuName
	self.Menus[menuName] = menu
	return menu
end

function Client:SetScene(sceneName: string)
	if self.CurrentScene == sceneName then
		return
	end
	if sceneName and not self.Scenes[sceneName] then
		warn("Attempted to set invalid scene: " .. sceneName)
		return
	end
	self.CurrentScene = sceneName
	self:RenderUI()
end

function Client:CreateScene(sceneName: string)
	local scene = {
		Name = sceneName,
		Instance = Instance.new("ScreenGui"),
		SceneParts = {},
	}
	scene.Instance.Name = sceneName
	scene.Instance.ResetOnSpawn = false
	scene.Instance.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	scene.Instance.IgnoreGuiInset = true
	scene.Instance.Parent = nil
	self.Scenes[sceneName] = scene
	return scene
end

function Client:CreateScenePart(partName: string, instance)
	local scenePart = {
		Name = partName,
		Instance = instance,
		Enabled = false,
	}
	self.SceneParts[partName] = scenePart
	self:RenderUI()
	return scenePart
end

function Client:BindScenePartToScene(partName: string, sceneName: string)
	local scene = self.Scenes[sceneName]
	local scenePart = self.SceneParts[partName]
	if not scene then
		warn("Attempted to bind to invalid scene: " .. sceneName)
		return
	end
	if not scenePart then
		warn("Attempted to bind invalid scene part: " .. partName)
		return
	end

	table.insert(scene.SceneParts, scenePart)
end

return Client
