local Players = game:GetService("Players")
local PlayerUtil = require(script.Parent.PlayerUtil)
local TableUtil = require(script.Parent.TableUtil)
local Inventory = require(script.Parent.Inventory)
local RunService = game:GetService("RunService")

if RunService:IsClient() then
	warn("This module is not meant to be required on the client.")
	return {}
end

local Server = {
	Started = false,
	Running = false,
	Players = {},
	Items = {},
	Shops = {},
	RemoteEvent = Instance.new("RemoteEvent"),
	RemoteFunction = Instance.new("RemoteFunction"),

	EventResponses = {},
	EventConnections = {},
}
Server.RemoteEvent.Parent = script
Server.RemoteFunction.Parent = script

local function playerJoined(player)
	local State = require(script.Parent.State)
	local template = {
		_Inventory = {
			Items = {},
			Weight = 0,
			Value = 0,
			ItemCount = 0,
			StackCount = 0,
			LastLocalID = 0,
			Index = {},
		},
		_EventTotals = {},
	}

	-- Daily play-time reward bookkeeping, added only when a game opts in via
	-- AddDailyPlayTimeRewards. NextEnd is an os.time() (UTC) deadline so the daily
	-- window is consistent across servers; PlayTime accrues one per second while in
	-- game; Claimed lists the tier keys (each a "seconds required" value) already
	-- collected this window. When now passes NextEnd all three reset (see
	-- _refreshDailyReset).
	if Server.DailyPlayTimeRewards then
		template._DailyPlayTimeRewards = {
			NextEnd = 0,
			PlayTime = 0,
			Claimed = {},
		}
	end

	local state = State.new(template, "Player_" .. player.UserId, player)
	local inventory = Inventory.get(state, "_Inventory")
	inventory:Recalculate()
	state:Publish()

	-- Load handler: runs BEFORE the player's entry is registered below, so the
	-- player-keyed getters (GetState / GetInventory / Get / Set) still return nil
	-- while it runs — nothing, anywhere, can observe a half-built state. It is handed
	-- (player, state, inventory) directly to do its work, and runs before the client
	-- is released (the hex_stateid attribute). Migration work that needs the
	-- player-keyed APIs (e.g. server:GetInventory) should task.spawn so it runs once
	-- the entry is registered. It may yield; the join waits on the synchronous part.
	-- Errors are caught so a broken handler can't strand the player without a state.
	if Server.LoadHandler then
		local ok, err = pcall(Server.LoadHandler, player, state, inventory)
		if not ok then
			warn(("[rbx] LoadHandler errored for %s: %s"):format(player.Name, tostring(err)))
		end
	end

	Server.Players[player] = { State = state, Inventory = inventory }

	player:SetAttribute("hex_stateid", state.ID)

	if Server.ToolsFolder then
		Server:_setupTools(player)
	end
end

local function playerLeft(player)
	local entry = Server.Players[player]
	if entry then
		if entry.ToolConnections then
			for _, connection in entry.ToolConnections do
				connection:Disconnect()
			end
		end
		-- Tear the profile down so it doesn't leak in State's `states` table (and
		-- its PlayerRemoving connection) for the life of the server. Destroy runs
		-- the (idempotent) teardown save + lock release, then drops it from states.
		if entry.State then
			entry.State:Destroy()
			Inventory.release(entry.State)
		end
	end
	Server.Players[player] = nil
end

function Server:GetState(player)
	local entry = self.Players[player]
	if not entry then
		return nil
	end
	return entry.State
end

function Server:GetInventory(player)
	local entry = self.Players[player]
	if not entry then
		return nil
	end
	return entry.Inventory
end

-- Register a function run during each player's join, AFTER their State has loaded
-- and the inventory is ready (GetState/GetInventory work) but BEFORE the client is
-- released (the hex_stateid attribute). The hook for one-time migrations / state
-- transforms, so nothing ever observes pre-migration state. Called as
-- handler(player, state, inventory) and may yield — the join waits on it.
function Server:SetLoadHandler(handler)
	self.LoadHandler = handler
end

function Server:AddEvent(player, event, value)
	value = value or 1
	local data = self:GetState(player)
	if not data then
		return
	end
	data:Increment("_EventTotals/" .. event, value)
end

function Server:AddItemInfo(itemTable)
	for key, value in itemTable do
		value = TableUtil.deepCopy(value)
		value.Value = value.Value or 0
		value.Weight = value.Weight or 0
		value.Name = value.Name or key
		value.Description = value.Description or ""
		value.Render = value.Render or {}
		value.Render.Image = value.Render.Image or ""
		Server.Items[key] = value
	end
end

function Server:AddShopInfo(shopTable)
	for key, value in shopTable do
		local shop = TableUtil.deepCopy(value)
		if shop.TradeAll == nil then
			shop.TradeAll = false
		end
		if shop.MassTrade == nil then
			shop.MassTrade = false
		end
		self.Shops[key] = shop
	end
end

local DAY_SECONDS = 86400

-- Register the daily play-time reward tiers. `rewards` is a map keyed by the
-- number of seconds a player must accrue in a day, to an array of reward entries
-- granted on claim:
--   Server:AddDailyPlayTimeRewards({
--       [30] = { {"Caps", 25} },
--       [60] = { {"Caps", 50}, {"Bullet", 10} },  -- a tier may grant several items
--   })
-- Enabling this makes join stamp the _DailyPlayTimeRewards template and Start tick
-- each player's PlayTime once per second. Rewards are claimed (not auto-granted)
-- via the _ClaimDailyReward remote / Server:ClaimDailyReward, once per tier per
-- daily window. Call before Server:Start (with AddItemInfo, so reward items exist).
function Server:AddDailyPlayTimeRewards(rewards)
	local config = {}
	for seconds, entries in rewards do
		if type(seconds) ~= "number" then
			warn("[rbx] AddDailyPlayTimeRewards: tier key must be seconds (number), got " .. tostring(seconds))
			continue
		end
		config[seconds] = TableUtil.deepCopy(entries)
	end
	self.DailyPlayTimeRewards = config
end

-- Roll a player's daily window forward if the deadline has passed: reset PlayTime,
-- clear the Claimed tier list, and set the next deadline 24h out. A never-loaded /
-- freshly-reconciled profile has NextEnd = 0, so its first pass here starts the
-- clock. No-op if the game hasn't opted into daily rewards.
local function refreshDailyReset(state)
	local data = state and state:Get("_DailyPlayTimeRewards")
	if not data then
		return
	end
	if os.time() >= (data.NextEnd or 0) then
		state:Set("_DailyPlayTimeRewards/NextEnd", os.time() + DAY_SECONDS)
		state:Set("_DailyPlayTimeRewards/PlayTime", 0)
		state:Set("_DailyPlayTimeRewards/Claimed", {})
	end
end

-- Per-second accrual for one player: roll the window if due, then add a second of
-- play. Driven by Start's heartbeat loop only while daily rewards are enabled.
function Server:_tickDailyPlayTime(player)
	local state = self:GetState(player)
	if not state or not state:Get("_DailyPlayTimeRewards") then
		return
	end
	refreshDailyReset(state)
	state:Increment("_DailyPlayTimeRewards/PlayTime", 1)
end

-- Claim the reward tier `tierKey` (a "seconds required" key from the config) for
-- `player`. Grants every entry in that tier's reward array. Returns { Success,
-- Reason? }: fails if daily rewards are disabled, the tier is unknown, the player
-- hasn't accrued enough PlayTime this window, or the tier was already claimed.
-- Idempotent against double-claims — the tier key is recorded in Claimed and
-- re-checked here, so a duplicate remote call is rejected rather than double-paid.
function Server:ClaimDailyReward(player, tierKey)
	local config = self.DailyPlayTimeRewards
	if not config then
		return { Success = false, Reason = "Disabled" }
	end
	-- Config keys are numbers (seconds); coerce so a string tier key from the wire
	-- still matches, and the value recorded in Claimed stays a consistent number.
	tierKey = tonumber(tierKey)
	local rewards = tierKey and config[tierKey]
	if not rewards then
		return { Success = false, Reason = "InvalidTier" }
	end
	local state = self:GetState(player)
	local inventory = self:GetInventory(player)
	if not state or not inventory then
		return { Success = false, Reason = "NoState" }
	end

	-- Roll a stale window first, so a claim right after midnight can't pay out
	-- against yesterday's accrued time or bypass the cleared Claimed list.
	refreshDailyReset(state)

	if (state:Get("_DailyPlayTimeRewards/PlayTime") or 0) < tierKey then
		return { Success = false, Reason = "NotEnoughTime" }
	end

	local claimed = state:Get("_DailyPlayTimeRewards/Claimed") or {}
	if table.find(claimed, tierKey) then
		return { Success = false, Reason = "AlreadyClaimed" }
	end

	-- Record the claim BEFORE granting so a re-entrant call (two remotes racing)
	-- sees it already claimed and can't double-pay.
	state:ArrayInsert("_DailyPlayTimeRewards/Claimed", tierKey)
	for _, entry in rewards do
		local itemName, amount = entry[1], entry[2] or 1
		if self.Items[itemName] then
			inventory:GiveItem(itemName, amount)
		else
			warn("[rbx] ClaimDailyReward: unknown reward item '" .. tostring(itemName) .. "'")
		end
	end

	return { Success = true }
end

-- Attribute stamped on every Tool we clone, so reconciliation only ever touches
-- tools WireTools created and never a tool the game placed by other means.
local TOOL_ATTRIBUTE = "hex_wiretool"

-- Bring a player's Tools in line with the items they own. For every inventory item
-- whose ItemName matches a Tool in the wired folder, ensure a clone exists (named
-- after the item's unique ID and stamped with TOOL_ATTRIBUTE); destroy any stamped
-- tool whose item has left the inventory. Equipped tools live in the Character, not
-- the Backpack, so both are searched — a still-owned equipped tool is left in place.
function Server:_reconcileTools(player)
	local folder = self.ToolsFolder
	local entry = self.Players[player]
	if not folder or not entry then
		return
	end

	local desired = {} -- itemID -> ItemName
	for id, item in entry.State:Get("_Inventory/Items") or {} do
		if type(item) == "table" and item.ItemName and folder:FindFirstChild(item.ItemName) then
			desired[id] = item.ItemName
		end
	end

	-- Collect the tools we previously generated, wherever they currently sit.
	local existing = {} -- itemID -> Tool
	for _, container in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if container then
			for _, tool in container:GetChildren() do
				if tool:IsA("Tool") and tool:GetAttribute(TOOL_ATTRIBUTE) then
					existing[tool.Name] = tool
				end
			end
		end
	end

	-- Drop tools whose item is gone (works whether held or in the backpack).
	for id, tool in existing do
		if not desired[id] then
			tool:Destroy()
		end
	end

	-- Add tools for newly-owned items. Needs a Backpack to hold them; before the
	-- first spawn there isn't one, but CharacterAdded re-runs this once there is.
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for id, itemName in desired do
			if not existing[id] then
				local tool = folder[itemName]:Clone()
				tool.Name = id
				tool:SetAttribute(TOOL_ATTRIBUTE, true)
				tool.Parent = backpack
			end
		end
	end
end

-- Wire a player's owned tool-items to live Tool instances in their inventory.
function Server:_setupTools(player)
	local entry = self.Players[player]
	if not entry or entry._toolsWired then
		return
	end
	entry._toolsWired = true
	entry.ToolConnections = {}
	local State = require(script.Parent.State)

	-- Any item added/removed re-reconciles; immediate = true seeds the current set.
	table.insert(
		entry.ToolConnections,
		entry.State:Observe("_Inventory/Items", function()
			self:_reconcileTools(player)
		end, State.ObserverType.Children, true)
	)

	-- A respawn means a new Backpack and the loss of any equipped tool, so re-place
	-- everything. defer so the Backpack exists by the time we reconcile.
	table.insert(
		entry.ToolConnections,
		player.CharacterAdded:Connect(function()
			task.defer(function()
				self:_reconcileTools(player)
			end)
		end)
	)
end

-- folder: an Instance holding Tool templates keyed by ItemName (e.g. a Tools
-- folder in ReplicatedStorage). Applies to current and future players.
function Server:WireTools(folder)
	self.ToolsFolder = folder
	for player in self.Players do
		self:_setupTools(player)
	end
end

-- Run a shop trade for `player`. A trade is symmetric — {Give = {{item,
-- amount}, ...}, Cost = {{item, amount}, ...}} — the player hands over every Cost
-- and receives every Give ("buying" and "selling" are the same operation with the
-- operands swapped). `quantity` is how many times to run it: nil (once), a specific
-- number, or `true` ("as many as affordable"). Validation is done up front and
-- atomically: if any cost/give item is unknown or the player can't afford every
-- cost for the resolved count, nothing is spent or granted. Returns {Success,
-- Reason?, Count?}.
local function processShopTrade(player, shopId, tradeIndex, quantity)
	local inventory = Server:GetInventory(player)
	if not inventory then
		return { Success = false, Reason = "NoInventory" }
	end

	local shop = Server.Shops[shopId]
	if not shop then
		return { Success = false, Reason = "InvalidShop" }
	end

	local trade = shop.Trades and shop.Trades[tradeIndex]
	if not trade then
		return { Success = false, Reason = "InvalidTrade" }
	end

	local costs = trade.Cost or {}
	local gives = trade.Give or {}

	-- Every referenced item must exist, or we'd take a cost without being able to
	-- grant its reward (or vice versa). Reject the whole transaction instead.
	for _, entry in costs do
		if not Server.Items[entry[1]] then
			return { Success = false, Reason = "InvalidCostItem" }
		end
	end
	for _, entry in gives do
		if not Server.Items[entry[1]] then
			return { Success = false, Reason = "InvalidGiveItem" }
		end
	end

	-- Aggregate per item so duplicate cost rows (two {"Coins", 10}) require the
	-- sum (20), not just the larger single row.
	local required = {}
	for _, entry in costs do
		local name = entry[1]
		required[name] = (required[name] or 0) + (entry[2] or 1)
	end

	-- Resolve how many times to run the trade. `true` means "as many as affordable",
	-- bounded by the scarcest cost item; a trade with no costs has no such bound, so
	-- it runs once. A number runs that many times (rejected if it can't be afforded
	-- below). nil runs once.
	local count = 1

	if shop.TradeAll then
		if quantity == true then
			local maxTrades
			for name, amount in required do
				local affordable = math.floor(inventory:CountItem(name) / amount)
				maxTrades = if maxTrades == nil then affordable else math.min(maxTrades, affordable)
			end
			count = maxTrades or 1
			if count < 1 then
				return { Success = false, Reason = "Insufficient" }
			end
		elseif type(quantity) == "number" and quantity >= 1 then
			count = math.floor(quantity)
		end
	end

	if count < 1 then
		return { Success = false, Reason = "InvalidQuantity" }
	end

	for name, amount in required do
		if inventory:CountItem(name) < amount * count then
			return { Success = false, Reason = "Insufficient" }
		end
	end

	-- Counts were checked above, so each spend is expected to succeed.
	for name, amount in required do
		inventory:SpendItem(name, amount * count)
	end
	for _, entry in gives do
		inventory:GiveItem(entry[1], (entry[2] or 1) * count)
	end

	return { Success = true, Count = count }
end

-- Run every trade in a shop as a single "trade all" pass, for shops that opt in
-- with MassTrade = true. Nothing is mutated during the loop: we tally what every
-- trade would spend and grant into `costs`/`rewards` tables, then apply the whole
-- lot in one batch at the end. Each trade is executed as many times as the player
-- can afford against the *running* balance — its affordability counts against the
-- live inventory minus what earlier trades in this pass have already committed to
-- `costs`, so two trades sharing a cost item can't both claim the same items.
-- Validation runs up front across the whole shop, so one unknown item rejects the
-- pass before anything is spent. Returns {Success, Reason?, Count?} where Count is
-- the total number of individual trades executed across the shop.
local function processMassTrade(player, shopId)
	local inventory = Server:GetInventory(player)
	if not inventory then
		return { Success = false, Reason = "NoInventory" }
	end

	local shop = Server.Shops[shopId]
	if not shop then
		return { Success = false, Reason = "InvalidShop" }
	end

	if not shop.MassTrade then
		return { Success = false, Reason = "MassTradeDisabled" }
	end

	local trades = shop.Trades or {}

	-- Validate every referenced item across the whole shop first: a single unknown
	-- cost/give item rejects the pass before we spend or grant anything.
	for _, trade in trades do
		for _, entry in trade.Cost or {} do
			if not Server.Items[entry[1]] then
				return { Success = false, Reason = "InvalidCostItem" }
			end
		end
		for _, entry in trade.Give or {} do
			if not Server.Items[entry[1]] then
				return { Success = false, Reason = "InvalidGiveItem" }
			end
		end
	end

	-- Tally everything here; nothing is spent or granted until the batch at the end.
	local costs = {}
	local rewards = {}
	local totalCount = 0

	for _, trade in trades do
		local tradeCosts = trade.Cost or {}
		local gives = trade.Give or {}

		-- Aggregate duplicate cost rows, matching processShopTrade.
		local required = {}
		for _, entry in tradeCosts do
			local name = entry[1]
			required[name] = (required[name] or 0) + (entry[2] or 1)
		end

		-- How many times this trade can run, bounded by the scarcest cost item.
		-- Affordability is the live count minus what earlier trades already booked
		-- into `costs`, so the running balance depletes without touching inventory.
		-- A trade with no costs runs once (as in trade-all).
		local maxTrades
		for name, amount in required do
			local available = inventory:CountItem(name) - (costs[name] or 0)
			local affordable = math.floor(available / amount)
			maxTrades = if maxTrades == nil then affordable else math.min(maxTrades, affordable)
		end
		local count = maxTrades or 1

		-- Unaffordable trades are simply skipped — a mass trade does what it can.
		if count >= 1 then
			for name, amount in required do
				costs[name] = (costs[name] or 0) + amount * count
			end
			for _, entry in gives do
				rewards[entry[1]] = (rewards[entry[1]] or 0) + (entry[2] or 1) * count
			end
			totalCount += count
		end
	end

	if totalCount < 1 then
		return { Success = false, Reason = "Insufficient" }
	end

	-- Apply the whole pass at once: every spend, then every give.
	for name, amount in costs do
		inventory:SpendItem(name, amount)
	end
	for name, amount in rewards do
		inventory:GiveItem(name, amount)
	end

	return { Success = true, Count = totalCount }
end

function Server:FireClient(player, ...)
	self.RemoteEvent:FireClient(player, ...)
end
function Server:FireAllClients(...)
	self.RemoteEvent:FireAllClients(...)
end
function Server:FireClients(players, ...)
	for _, player in players do
		self.RemoteEvent:FireClient(player, ...)
	end
end
function Server:InvokeClient(player, ...)
	return self.RemoteFunction:InvokeClient(player, ...)
end
Server.RemoteEvent.OnServerEvent:Connect(function(player, func, ...)
	for _, callback in Server.EventConnections[func] or {} do
		task.spawn(callback, player, ...)
	end
	if Server.EventResponses[func] then
		task.spawn(Server.EventResponses[func], player, ...)
	end
end)
Server.RemoteFunction.OnServerInvoke = function(player, func, ...)
	for _, callback in Server.EventConnections[func] or {} do
		task.spawn(callback, player, ...)
	end
	if Server.EventResponses[func] then
		return Server.EventResponses[func](player, ...)
	end
end

function Server:ConnectRemote(func, callback)
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

function Server:SetRemoteResponse(func, callback)
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

function Server:Start()
	if self.Started then
		return false
	end
	self.Started = true
	self:SetRemoteResponse("_GetGameInfo", function()
		return { Items = self.Items, Shops = self.Shops, DailyRewards = self.DailyPlayTimeRewards }
	end)
	self:SetRemoteResponse("_ShopTrade", function(player, shopId, tradeIndex, quantity)
		return processShopTrade(player, shopId, tradeIndex, quantity)
	end)
	self:SetRemoteResponse("_ShopMassTrade", function(player, shopId)
		return processMassTrade(player, shopId)
	end)
	self:SetRemoteResponse("_ClaimDailyReward", function(player, tierKey)
		return self:ClaimDailyReward(player, tierKey)
	end)

	-- P2P trading (see Trade.luau) registers its own remotes and player-leaving
	-- cleanup here. Only started when the module is present alongside Server.
	local tradeModule = script.Parent:FindFirstChild("Trade")
	if tradeModule then
		require(tradeModule).Start()
	end

	PlayerUtil.observePlayers(playerJoined, playerLeft)

	self.Running = true
	workspace:SetAttribute("hex_server", true)

	task.spawn(function()
		while task.wait(1) do
			for _, player in Players:GetPlayers() do
				self:AddEvent(player, "_TimePlayed")
				if self.DailyPlayTimeRewards then
					self:_tickDailyPlayTime(player)
				end
			end
		end
	end)
	return true
end

-- data shortcuts
function Server:Get(player, path)
	local state = self:GetState(player)
	if not state then
		return nil
	end
	return state:Get(path)
end

function Server:Set(player, path, value)
	local state = self:GetState(player)
	if not state then
		return
	end
	return state:Set(path, value)
end

function Server:Increment(player, path, amount)
	local state = self:GetState(player)
	if not state then
		return
	end
	return state:Increment(path, amount)
end

function Server:ArrayInsert(player, path, value)
	local state = self:GetState(player)
	if not state then
		return
	end
	return state:ArrayInsert(path, value)
end

function Server:ArrayRemove(player, path, value)
	local state = self:GetState(player)
	if not state then
		return
	end
	return state:ArrayRemove(path, value)
end

return Server
