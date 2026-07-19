local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Global (cross-server) leaderboards backed by OrderedDataStores. A game declares
-- one or more boards, each with a getter that reads a player's current value; this
-- module periodically writes every present player's value to that board's ordered
-- store and caches the top-N (with resolved names) for clients to read. The client
-- can't touch an OrderedDataStore directly, so the cached top list is served over
-- the _GetLeaderboard remote (see the Leaderboard ClientTemplate for the view).
--
-- Declare boards before Start:
--   local Leaderboard = require(...).Leaderboard
--   Leaderboard.AddBoard({
--       Id = "NetWorth",
--       Title = "Net Worth",
--       Store = "GlobalNetWorth",        -- OrderedDataStore name
--       Get = function(player) return server:Get(player, "_Inventory/Value") or 0 end,
--       Format = "short",                -- client display hint: short | long | duration
--   })
--   Leaderboard.Start()
--
-- Values must be non-negative integers (what OrderedDataStores store); the getter's
-- result is floored and clamped. A value of 0 is skipped so brand-new players don't
-- pad the board with zeroes.
local Leaderboard = {
	Boards = {}, -- array of board defs, in declared (display) order
	UpdateInterval = 60, -- seconds between write+refresh passes
	Started = false,
}

if RunService:IsClient() then
	warn("Leaderboard is a server module and is not meant to be required on the client.")
	return Leaderboard
end

local DataStoreService = game:GetService("DataStoreService")

-- userId -> username, so we don't re-hit GetNameFromUserIdAsync every refresh.
local nameCache = {}

local function getServer()
	return require(script.Parent.Server)
end

-- Resolve a display-ish name for a UserId: prefer a player currently in this
-- server (gives their DisplayName), else the cached/looked-up account name.
local function resolveName(userId)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.DisplayName
	end
	if nameCache[userId] then
		return nameCache[userId]
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and name then
		nameCache[userId] = name
		return name
	end
	return "Player " .. userId
end

-- Register a board. Safe to call repeatedly before Start; re-registering an Id
-- replaces the earlier def.
function Leaderboard.AddBoard(def)
	assert(type(def) == "table", "Leaderboard.AddBoard expects a table")
	assert(type(def.Id) == "string", "board needs a string Id")
	assert(type(def.Store) == "string", "board needs a Store (OrderedDataStore name)")
	assert(type(def.Get) == "function", "board needs a Get(player) function")

	local board = {
		Id = def.Id,
		Title = def.Title or def.Id,
		Store = def.Store,
		Get = def.Get,
		Format = def.Format or "long",
		Limit = def.Limit or 25,
		Cache = {},
		_ds = nil,
	}

	for index, existing in Leaderboard.Boards do
		if existing.Id == board.Id then
			Leaderboard.Boards[index] = board
			return
		end
	end
	table.insert(Leaderboard.Boards, board)
end

local function boardStore(board)
	if not board._ds then
		local ok, ds = pcall(function()
			return DataStoreService:GetOrderedDataStore(board.Store)
		end)
		board._ds = ok and ds or false
	end
	return board._ds or nil
end

-- Push one player's current value for one board into its ordered store.
local function writePlayer(board, player)
	local ds = boardStore(board)
	if not ds then
		return
	end
	local raw = board.Get(player)
	local value = math.floor(tonumber(raw) or 0)
	if value <= 0 then
		return
	end
	local ok, err = pcall(function()
		ds:SetAsync(tostring(player.UserId), value)
	end)
	if not ok then
		warn("[rbx] Leaderboard write failed for", board.Id, player.Name, ":", err)
	end
end

-- Pull the top-N for one board and rebuild its cache with resolved names.
local function refreshBoard(board)
	local ds = boardStore(board)
	if not ds then
		return
	end
	local ok, pages = pcall(function()
		return ds:GetSortedAsync(false, board.Limit)
	end)
	if not ok then
		warn("[rbx] Leaderboard refresh failed for", board.Id, ":", pages)
		return
	end
	local ok2, page = pcall(function()
		return pages:GetCurrentPage()
	end)
	if not ok2 then
		return
	end

	local entries = {}
	for _, item in page do
		local userId = tonumber(item.key)
		if userId then
			table.insert(entries, {
				UserId = userId,
				Name = resolveName(userId),
				Value = item.value,
			})
		end
	end
	board.Cache = entries
end

local function writeAll()
	local players = Players:GetPlayers()
	for _, board in Leaderboard.Boards do
		for _, player in players do
			writePlayer(board, player)
		end
	end
end

local function refreshAll()
	for _, board in Leaderboard.Boards do
		refreshBoard(board)
	end
end

-- The snapshot handed to clients: boards in display order with their cached rows.
local function snapshot()
	local boards = {}
	for _, board in Leaderboard.Boards do
		table.insert(boards, {
			Id = board.Id,
			Title = board.Title,
			Format = board.Format,
			Entries = board.Cache,
		})
	end
	return { Boards = boards }
end

function Leaderboard.Start()
	if Leaderboard.Started then
		return
	end
	Leaderboard.Started = true

	getServer():SetRemoteResponse("_GetLeaderboard", function()
		return snapshot()
	end)

	-- Capture a leaving player's latest value before they're gone.
	Players.PlayerRemoving:Connect(function(player)
		for _, board in Leaderboard.Boards do
			task.spawn(writePlayer, board, player)
		end
	end)

	task.spawn(function()
		-- Seed the cache once so the first viewer sees data, then write+refresh on
		-- the interval.
		refreshAll()
		while task.wait(Leaderboard.UpdateInterval) do
			writeAll()
			refreshAll()
		end
	end)
end

return Leaderboard
