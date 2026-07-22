local TableUtil = require(script.Parent.TableUtil)
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local AnalyticsService = game:GetService("AnalyticsService")
local Inventory = {}
Inventory.__index = Inventory
local inventories = {}

-- Valid AnalyticsEconomyTransactionType names, so an arbitrary `source` string
-- (e.g. "Fishing", "Trade") that isn't a transaction type is classified cleanly
-- instead of erroring when we log an economy event.
local VALID_TRANSACTION = {}
for _, item in ipairs(Enum.AnalyticsEconomyTransactionType:GetEnumItems()) do
	VALID_TRANSACTION[item.Name] = true
end

-- Resolve the transaction type for an economy event: prefer the call's `source`
-- when it names a real transaction type, else the item's registered default, else
-- Gameplay.
local function transactionTypeFor(source, config)
	if type(source) == "string" and VALID_TRANSACTION[source] then
		return source
	end
	if config.default and VALID_TRANSACTION[config.default] then
		return config.default
	end
	return Enum.AnalyticsEconomyTransactionType.Gameplay.Name
end

-- Notify the inventory's owner that items changed, and -- for items whitelisted
-- via Server:TrackEconomy -- log a Roblox economy analytics event. Fired at the
-- public-operation level (GiveItem/SpendItem/...) rather than per internal Set, so
-- a grant that fills several stacks still produces a single, correctly-aggregated
-- toast and a single economy event. Owner-only: ownerless (chest/shared)
-- inventories stay silent. kind is "Added" | "Removed". `source` (optional) tags
-- what caused the change (e.g. "Trade"): it rides along in the toast payload so a
-- client-side ItemNotifications Filter can suppress toasts from a particular
-- source, and it doubles as the analytics transaction type when it names one.
-- `skipEconomy` is set by net-zero transfers (TransferItemTo — stash moves, trades) so a
-- relocation of items is never logged as an economy faucet/sink.
local function notify(inventory, kind, itemName, amount, source, skipEconomy)
	if not RunService:IsServer() then
		return
	end
	local state = inventory.State
	local player = state and state.Player
	if not player or not amount or amount <= 0 then
		return
	end
	-- One-time migrations grant a whole legacy balance at once; callers set this
	-- flag around the grant so the port doesn't spam the owner with toasts -- or
	-- pollute economy analytics with a migration that isn't a real gain.
	if state._suppressNotify then
		return
	end
	local Server = require(script.Parent.Server)
	Server:FireClient(player, "_ItemNotification", {
		Kind = kind,
		ItemName = itemName,
		Amount = amount,
		Source = source,
	})

	-- Economy analytics for whitelisted items (currencies, premium resources, ...).
	-- LogEconomyEvent is server + published-game only and can throw, so it must
	-- never be allowed to break the actual inventory change.
	local config = Server.EconomyItems and Server.EconomyItems[itemName]
	if config and not skipEconomy then
		local flowType = if kind == "Added"
			then Enum.AnalyticsEconomyFlowType.Source
			else Enum.AnalyticsEconomyFlowType.Sink
		-- Ending balance is the player's TOTAL holdings of the item. By default that's just
		-- this inventory, but an item can live in more than one (e.g. Caps also sits in the
		-- "_Cache" stash) — TrackEconomy's balancePrefixes lists those extra state prefixes
		-- so the reported balance sums them all rather than under-reporting the stash.
		local balance = inventory:CountItem(itemName)
		if config.balancePrefixes then
			for _, prefix in config.balancePrefixes do
				if prefix ~= inventory.Prefix then
					balance += Inventory.get(state, prefix):CountItem(itemName)
				end
			end
		end
		local transactionType = transactionTypeFor(source, config)
		pcall(function()
			AnalyticsService:LogEconomyEvent(player, flowType, itemName, amount, balance, transactionType)
		end)
	end
end

function Inventory.get(state, prefix)
	inventories[state] = inventories[state] or {}
	if inventories[state][prefix] then
		return inventories[state][prefix]
	end

	local self = setmetatable({
		State = state,
		Prefix = prefix,
	}, Inventory)

	inventories[state][prefix] = self
	return self
end

-- Apply an item's icon styling (image, tint, scale type) to an ImageLabel or
-- ImageButton. Item info lives on the server as Server.Items and is replicated to
-- the client as Client.ItemTable, so we read whichever side we're on — this makes
-- it usable from the client UI templates as well as any server-side rendering.
-- Unknown items leave the label untouched (no icon set).
function Inventory.renderItemImage(imageLabel, itemOrName: {} | string)
	local itemName = type(itemOrName) == "table" and itemOrName.ItemName or itemOrName
	local source
	if RunService:IsServer() then
		source = require(script.Parent.Server).Items
	else
		source = require(script.Parent.Client).ItemTable
	end
	local itemInfo = source and source[itemName]
	if not itemInfo then
		return
	end
	local render = itemInfo.Render
	-- No icon — no Render table, or an empty Image (the default an ImageLabel/omitted field
	-- falls back to). Blank the label and stop, rather than crashing on a nil `render` or
	-- applying an empty image: an iconless item (e.g. a gun awaiting art) reads as an empty
	-- slot instead of erroring.
	if not render or (render.Image or "") == "" then
		imageLabel.Image = ""
		return
	end
	render.ScaleType = render.ScaleType or Enum.ScaleType.Fit
	render.ImageColor3 = render.ImageColor3 or Color3.new(1, 1, 1)
	for key, value in render do
		imageLabel[key] = value
	end
end

-- Drop every cached Inventory bound to `state` so they don't outlive it (called
-- from Server.playerLeft alongside State:Destroy).
function Inventory.release(state)
	inventories[state] = nil
end

local function createItem(inventory, itemName, amount, template)
	if RunService:IsClient() then
		error("Inventory called a server function")
	end
	amount = math.floor(amount or 1)
	if amount <= 0 then
		warn("Attempted to create item with non-positive amount: " .. tostring(amount))
		return
	end
	local info = require(script.Parent.Server).Items[itemName]
	if not info then
		warn("Attempted to give invalid item: " .. itemName)
		return
	end

	local id = HttpService:GenerateGUID(false)
	local item = {
		ID = id,
		ItemName = itemName,
		Amount = amount,
	}
	if template then
		item = TableUtil.deepCopy(template)
		id = item.ID
	end

	item.LocalID = inventory.State:Increment(inventory.Prefix .. "/LastLocalID")
	inventory.State:Set(inventory.Prefix .. "/Items/" .. id, item)
	inventory.State:Increment(inventory.Prefix .. "/Weight", info.Weight * item.Amount)
	inventory.State:Increment(inventory.Prefix .. "/Value", info.Value * item.Amount)
	inventory.State:Increment(inventory.Prefix .. "/ItemCount", item.Amount)
	inventory.State:Increment(inventory.Prefix .. "/StackCount")
	local index = inventory.State:Get(inventory.Prefix .. "/Index/" .. itemName) or {}
	table.insert(index, id)
	inventory.State:Set(inventory.Prefix .. "/Index/" .. itemName, index)
	return id, item
end

-- `source` (optional) tags the "Removed" toast (e.g. "BulletSpend") so a client
-- ItemNotifications Filter can suppress it without muting ordinary drops.
function Inventory:SpendItem(itemName, amount, source)
	if RunService:IsClient() then
		error("Inventory called a server function")
	end

	amount = amount or 1
	amount = math.floor(amount)
	if amount <= 0 then
		return false
	end

	local info = require(script.Parent.Server).Items[itemName]
	if not info then
		warn("Attempted to spend invalid item: " .. itemName)
		return false
	end

	-- Check if we have enough items before modifying anything, this allows the function to act as an attempt to spend without actually spending if the player doesn't have enough
	if self:CountItem(itemName) < amount then
		return false
	end
	local currentIndex = table.clone(self.State:Get(self.Prefix .. "/Index/" .. itemName) or {})

	local remaining = amount
	local removed = 0
	local indexChanged = false
	for i = #currentIndex, 1, -1 do
		if remaining <= 0 then
			break
		end
		local id = currentIndex[i]
		local item = self.State:Get(self.Prefix .. "/Items/" .. id)
		if not item then
			table.remove(currentIndex, i)
			self.State:Increment(self.Prefix .. "/StackCount", -1)
			indexChanged = true
			continue
		end
		local itemAmount = item.Amount
		local toRemove = math.min(itemAmount, remaining)
		item.Amount -= toRemove

		remaining -= toRemove
		removed += toRemove
		if item.Amount <= 0 then
			table.remove(currentIndex, i)
			self.State:Set(self.Prefix .. "/Items/" .. id, nil)
			self.State:Increment(self.Prefix .. "/StackCount", -1)
			indexChanged = true
		else
			self.State:Set(self.Prefix .. "/Items/" .. id, item)
		end
	end

	if indexChanged then
		self.State:Set(self.Prefix .. "/Index/" .. itemName, currentIndex)
	end

	if removed ~= amount then
		warn("SpendItem removed " .. removed .. " items but expected " .. amount .. ".")
		return false
	end

	self.State:Increment(self.Prefix .. "/Weight", -info.Weight * removed)
	self.State:Increment(self.Prefix .. "/Value", -info.Value * removed)
	self.State:Increment(self.Prefix .. "/ItemCount", -removed)

	-- Only toast on a fully-successful spend; a partial removal returns false
	-- above, so we never show a "-N" that contradicts the failed result.
	notify(self, "Removed", itemName, removed, source)
	return true
end

-- Pure read of replicated state, so it is safe on both client and server (the
-- client uses it for shop affordability checks). It does not consult the item
-- info table, which only exists server-side.
function Inventory:CountItem(itemName)
	local index = self.State:Get(self.Prefix .. "/Index/" .. itemName) or {}
	local count = 0
	for _, id in index do
		local item = self.State:Get(self.Prefix .. "/Items/" .. id)
		if item then
			local itemAmount = item.Amount
			if type(itemAmount) ~= "number" then
				warn("Invalid item amount for " .. tostring(itemName) .. " [" .. tostring(id) .. "]")
				continue
			end
			count += itemAmount
		end
	end
	return count
end

-- Pure read of every item instance, keyed by item ID. Safe on both client and
-- server (reads replicated state). Use for non-stackable items whose per-instance
-- data matters -- e.g. finding an Escape Note by its Sector -- which CountItem
-- (a quantity sum) can't express. The result is the live state table; treat it as
-- read-only and copy before mutating.
function Inventory:GetItems()
	return self.State:Get(self.Prefix .. "/Items") or {}
end

-- `source` (optional) tags the "Added" toast so a client ItemNotifications Filter
-- can suppress it (see SpendItem). `skipEconomy` (optional) suppresses the economy-analytics
-- Source event — set by net-zero transfers so a relocation isn't logged as a faucet.
function Inventory:GiveItem(itemName: string, amount: number?, source: string?, skipEconomy: boolean?)
	if RunService:IsClient() then
		error("Inventory called a server function")
	end

	local info = require(script.Parent.Server).Items[itemName]
	if not info then
		warn("Attempted to give invalid item: " .. itemName)
		return
	end

	if info.Stackable then
		local stackSize = info.StackSize or math.huge
		local remaining = amount or 1
		local currentIndex = table.clone(self.State:Get(self.Prefix .. "/Index/" .. itemName) or {})
		local indexChanged = false

		-- First try to fill existing stacks
		for i = #currentIndex, 1, -1 do
			if remaining <= 0 then
				break
			end
			local id = currentIndex[i]
			local item = self.State:Get(self.Prefix .. "/Items/" .. id)
			if not item then
				table.remove(currentIndex, i)
				indexChanged = true
				continue
			end
			local itemAmount = item.Amount
			if type(itemAmount) ~= "number" then
				warn("Invalid item amount for " .. tostring(itemName) .. " [" .. tostring(id) .. "]")
				table.remove(currentIndex, i)
				indexChanged = true
				continue
			end
			local space = stackSize - itemAmount
			if space <= 0 then
				continue
			end
			local toAdd = math.min(space, remaining)
			item.Amount = itemAmount + toAdd
			self.State:Set(self.Prefix .. "/Items/" .. id, item)
			self.State:Increment(self.Prefix .. "/Weight", info.Weight * toAdd)
			self.State:Increment(self.Prefix .. "/Value", info.Value * toAdd)
			self.State:Increment(self.Prefix .. "/ItemCount", toAdd)
			remaining -= toAdd
		end

		if indexChanged then
			self.State:Set(self.Prefix .. "/Index/" .. itemName, currentIndex)
		end

		-- Then create new stacks as needed
		while remaining > 0 do
			local toAdd = math.min(remaining, stackSize)
			createItem(self, itemName, toAdd)
			remaining -= toAdd
		end
	else
		for _ = 1, amount or 1 do
			createItem(self, itemName, 1)
		end
	end

	-- GiveItem always adds the full requested amount (new stacks absorb any
	-- remainder), so one toast for the whole grant.
	notify(self, "Added", itemName, amount or 1, source, skipEconomy)
end

function Inventory:GiveItems(items, source)
	if RunService:IsClient() then
		error("Inventory called a server function")
	end
	for itemName, amount in items do
		self:GiveItem(itemName, amount, source)
	end
end

-- Add a SINGLE item instance (Amount 1) carrying arbitrary per-instance `data`
-- merged onto it -- e.g. an Escape Note's { Code, Sector }. Unlike GiveItem (which
-- stacks by quantity), every call makes a fresh ID, so non-stackable instances
-- with distinct data coexist. Structural keys (ID/ItemName/Amount/LocalID) are
-- protected from being clobbered by `data`. Returns id, item.
function Inventory:AddItem(itemName: string, data: {}?)
	if RunService:IsClient() then
		error("Inventory called a server function")
	end
	local info = require(script.Parent.Server).Items[itemName]
	if not info then
		warn("Attempted to add invalid item: " .. itemName)
		return
	end

	local id, item = createItem(self, itemName, 1)
	if not id then
		return
	end
	if data then
		for key, value in data do
			if key ~= "ID" and key ~= "ItemName" and key ~= "Amount" and key ~= "LocalID" then
				-- deepCopy only handles tables; pass primitives (a spear's Name,
				-- Ore, a note's Code/Sector, …) straight through.
				item[key] = if typeof(value) == "table" then TableUtil.deepCopy(value) else value
			end
		end
		self.State:Set(self.Prefix .. "/Items/" .. id, item)
	end

	notify(self, "Added", itemName, 1)
	return id, item
end

-- Remove one specific instance by its ID (the unique id AddItem/createItem
-- returned), updating every derived total and the name index. SpendItem removes
-- by NAME for a quantity; this is for non-stackable instances whose per-instance
-- data makes the caller care WHICH one goes (e.g. consuming the Note that matches
-- a particular exit Sector). Returns true if an instance was removed.
function Inventory:RemoveItem(id: string)
	if RunService:IsClient() then
		error("Inventory called a server function")
	end
	local item = self.State:Get(self.Prefix .. "/Items/" .. id)
	if not item then
		return false
	end
	local amount = item.Amount or 1
	local info = require(script.Parent.Server).Items[item.ItemName]

	self.State:Set(self.Prefix .. "/Items/" .. id, nil)
	self.State:Increment(self.Prefix .. "/StackCount", -1)
	self.State:Increment(self.Prefix .. "/ItemCount", -amount)
	if info then
		self.State:Increment(self.Prefix .. "/Weight", -info.Weight * amount)
		self.State:Increment(self.Prefix .. "/Value", -info.Value * amount)
	end

	local index = table.clone(self.State:Get(self.Prefix .. "/Index/" .. item.ItemName) or {})
	local pos = table.find(index, id)
	if pos then
		table.remove(index, pos)
		self.State:Set(self.Prefix .. "/Index/" .. item.ItemName, index)
	end

	notify(self, "Removed", item.ItemName, amount)
	return true
end

-- Read a single item instance by its unique ID (the uuid AddItem/createItem
-- returned), or nil. The result is the live state table; treat it as read-only.
-- Safe on client and server (reads replicated state).
function Inventory:GetItem(id: string)
	return self.State:Get(self.Prefix .. "/Items/" .. id)
end

-- Merge `patch`'s fields into the existing instance `id` and write it back, so the
-- change replicates and any UI re-renders. For mutating an instance's carried data
-- in place -- e.g. re-rolling a Note's Sector -- without the remove+re-add churn (a
-- new id and spurious Added/Removed toasts). Structural keys (ID/ItemName/Amount/
-- LocalID) are protected, matching AddItem; Amount is untouched, so derived totals
-- stay correct and no toast is raised. Returns the updated item, or nil if `id` is
-- unknown.
function Inventory:UpdateItem(id: string, patch: {})
	if RunService:IsClient() then
		error("Inventory called a server function")
	end
	local item = self.State:Get(self.Prefix .. "/Items/" .. id)
	if not item then
		return nil
	end
	local updated = TableUtil.deepCopy(item)
	for key, value in patch do
		if key ~= "ID" and key ~= "ItemName" and key ~= "Amount" and key ~= "LocalID" then
			updated[key] = if typeof(value) == "table" then TableUtil.deepCopy(value) else value
		end
	end
	self.State:Set(self.Prefix .. "/Items/" .. id, updated)
	return updated
end

-- Move `amount` of the instance `id` from this inventory into `target`, preserving
-- the instance's per-instance data (a note's Sector, a weapon's rolled stats, …).
-- This is the primitive behind trading, where an offer references specific uuids:
-- unlike SpendItem/GiveItem (which work by item NAME and would re-roll a fresh,
-- data-less instance) the exact carried data crosses intact. `amount` defaults to
-- the whole stack and is clamped to it; a partial move splits the stack, leaving
-- the remainder (with its data) in place and creating a fresh instance in `target`.
-- Both owners get the usual Added/Removed toasts, tagged with `source` (optional,
-- e.g. "Trade") so a client can filter them. Returns true on success.
function Inventory:TransferItemTo(id: string, amount: number?, target, source: string?)
	if RunService:IsClient() then
		error("Inventory called a server function")
	end
	if not target then
		return false
	end
	local item = self.State:Get(self.Prefix .. "/Items/" .. id)
	if not item then
		return false
	end
	local have = item.Amount or 0
	amount = math.floor(amount or have)
	if amount <= 0 or amount > have then
		return false
	end
	local info = require(script.Parent.Server).Items[item.ItemName]

	-- Remove from the source: delete the instance outright when the whole stack
	-- moves, otherwise just decrement it.
	if amount >= have then
		self.State:Set(self.Prefix .. "/Items/" .. id, nil)
		self.State:Increment(self.Prefix .. "/StackCount", -1)
		local index = table.clone(self.State:Get(self.Prefix .. "/Index/" .. item.ItemName) or {})
		local pos = table.find(index, id)
		if pos then
			table.remove(index, pos)
			self.State:Set(self.Prefix .. "/Index/" .. item.ItemName, index)
		end
	else
		item.Amount = have - amount
		self.State:Set(self.Prefix .. "/Items/" .. id, item)
	end
	if info then
		self.State:Increment(self.Prefix .. "/Weight", -info.Weight * amount)
		self.State:Increment(self.Prefix .. "/Value", -info.Value * amount)
	end
	self.State:Increment(self.Prefix .. "/ItemCount", -amount)

	-- A transfer is net-zero for the economy — items relocate, nothing is created or
	-- destroyed — so every notify below passes skipEconomy=true: the move still toasts, but
	-- is never logged as an analytics faucet/sink (stash moves and trades both land here).
	if info and info.Stackable then
		-- Stackable: merge into the target's existing stacks first (then new stacks as
		-- needed, respecting StackSize), matching GiveItem. Per-instance data isn't
		-- meaningful for a stackable item, so it isn't carried here; GiveItem fires the
		-- target's Added toast (tagged with `source`).
		target:GiveItem(item.ItemName, amount, source, true)
	else
		-- Non-stackable: move the exact instance so its custom data crosses intact. A
		-- fresh uuid avoids duplicating an ID across inventories on a partial move;
		-- createItem re-stamps LocalID and updates the target's totals.
		local moved = TableUtil.deepCopy(item)
		moved.ID = HttpService:GenerateGUID(false)
		moved.Amount = amount
		createItem(target, moved.ItemName, amount, moved)
		notify(target, "Added", item.ItemName, amount, source, true)
	end

	notify(self, "Removed", item.ItemName, amount, source, true)
	return true
end

function Inventory:Recalculate()
	if RunService:IsClient() then
		error("Inventory called a server function")
	end
	local itemTable = require(script.Parent.Server).Items
	local weight = 0
	local value = 0
	local itemCount = 0
	local stackCount = 0
	local index = {}
	local items = self.State:Get(self.Prefix .. "/Items") or {}

	for _, item in items do
		local info = itemTable[item.ItemName]
		if not info then
			warn("Invalid item: " .. tostring(item.ItemName))
			continue
		end
		local amount = item.Amount
		weight += info.Weight * amount
		value += info.Value * amount
		index[item.ItemName] = index[item.ItemName] or {}
		table.insert(index[item.ItemName], item.ID)
		itemCount += amount
		stackCount += 1
	end

	for _, list in index do
		table.sort(list, function(a, b)
			local aItem = items[a]
			local bItem = items[b]
			return (aItem and aItem.LocalID or 0) < (bItem and bItem.LocalID or 0)
		end)
	end

	self.State:Set(self.Prefix .. "/Weight", weight)
	self.State:Set(self.Prefix .. "/Value", value)
	self.State:Set(self.Prefix .. "/Index", index)
	self.State:Set(self.Prefix .. "/ItemCount", itemCount)
	self.State:Set(self.Prefix .. "/StackCount", stackCount)
end

return Inventory
