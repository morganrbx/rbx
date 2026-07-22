local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local PolicyService = game:GetService("PolicyService")

-- Player-to-player trading with a dual-confirm ("both ready") escrow flow. The
-- server is the sole authority: it holds every live session in memory (never
-- persisted), validates ownership at each step, and swaps items atomically only
-- once BOTH players have marked ready against an unchanged pair of offers. Any
-- edit to either offer un-readies both sides, so nobody can slip an item away
-- after their partner has committed. All state is server-side; the client
-- (ClientTemplates.TradeMenu) is a thin view driven by the remotes registered in
-- Start. Started automatically by Server:Start when this module sits beside it.
--
-- Offers are keyed by item UUID: an offer is a map { [itemId] = amount } naming
-- the exact instances to hand over (amount defaults to the whole stack; a smaller
-- amount splits it). The swap moves those instances via Inventory:TransferItemTo,
-- so per-instance data (a note's Sector, a weapon's rolled stats) crosses the
-- trade intact rather than being re-rolled.
local Trade = {
	Sessions = {}, -- sessionId -> session
	PlayerSession = {}, -- player -> sessionId
	Requests = {}, -- targetPlayer -> { [fromPlayer] = { Expiry } } (a target may hold several)

	-- Max distance (studs) allowed between two players' characters for a trade
	-- request to open. nil/0 means unlimited (the default, so existing games are
	-- unaffected); set it with Trade.SetMaxRequestDistance to require proximity.
	MaxRequestDistance = nil,

	-- player -> whether PolicyService allows them to trade paid items. Populated on join
	-- (see fetchPolicy). A player who isn't `true` here — restricted, or not yet resolved
	-- — can't open or accept a trade, so an unreadable policy fails safe. See
	-- Trade.IsTradingAllowed.
	TradingAllowed = {},

	-- Optional filter(itemName) -> boolean deciding which items may be offered. Items it
	-- rejects are silently dropped from any offer. nil = everything is tradeable. Set with
	-- Trade.SetItemFilter (a project's trade UI should hide the same items).
	ItemFilter = nil,
}

if RunService:IsClient() then
	warn("Trade is a server module and is not meant to be required on the client.")
	return Trade
end

-- How long a pending trade invite stays open before it lapses.
local REQUEST_TTL = 30

local function getServer()
	return require(script.Parent.Server)
end

-- Resolve and cache a player's PolicyService trading permission. Roblox requires respecting
-- IsPaidItemTradingAllowed: some accounts (by age / region) may not trade items, and this
-- gates the whole flow for them. Retried a few times because GetPolicyInfoForPlayerAsync
-- yields and can transiently fail; if it still can't be read the player is left un-set, and
-- IsTradingAllowed treats that as "not allowed" so an unreadable policy fails safe (the
-- compliant default) rather than opening trading to someone who might be restricted.
local function fetchPolicy(player)
	for _ = 1, 3 do
		local ok, info = pcall(function()
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)
		if ok and type(info) == "table" then
			Trade.TradingAllowed[player] = info.IsPaidItemTradingAllowed ~= false
			return
		end
		if not player.Parent then
			return
		end
		task.wait(3)
	end
end

-- Whether `player` is currently permitted to trade. False until the policy resolves and
-- false for a restricted player, so callers can gate a trade OR hide a trade button.
function Trade.IsTradingAllowed(player)
	return Trade.TradingAllowed[player] == true
end

-- Set the proximity requirement for opening a trade request (studs between the two
-- players' characters). Pass nil or 0 to lift the limit. Read live per request, so
-- it can be changed at any time.
function Trade.SetMaxRequestDistance(studs)
	Trade.MaxRequestDistance = (type(studs) == "number" and studs > 0) and studs or nil
	-- Replicate the current range to clients (0 = unlimited) so the trade player
	-- list can filter to who's actually invitable and word its empty state.
	workspace:SetAttribute("hex_trade_range", Trade.MaxRequestDistance or 0)
end

-- Restrict which items may be offered in a trade. `callback(itemName)` returns whether that
-- item type is tradeable; items it rejects are silently dropped from any offer (see
-- sanitizeOffer). Pass nil to allow everything. Server-authoritative — a project's trade UI
-- should hide the same items, but this is what actually enforces it.
function Trade.SetItemFilter(callback)
	Trade.ItemFilter = callback
end

-- Whether `a` and `b` are close enough to trade under the current limit. With no
-- limit set, always true. With a limit, BOTH must have a live character (a player
-- who isn't in the world can't be "near" anyone), and their root parts must be
-- within MaxRequestDistance of each other.
local function withinRequestRange(a, b)
	local maxDist = Trade.MaxRequestDistance
	if not maxDist then
		return true
	end
	local rootA = a.Character and a.Character:FindFirstChild("HumanoidRootPart")
	local rootB = b.Character and b.Character:FindFirstChild("HumanoidRootPart")
	if not rootA or not rootB then
		return false
	end
	return (rootA.Position - rootB.Position).Magnitude <= maxDist
end

local function otherPlayer(session, player)
	return if session.A == player then session.B else session.A
end

-- Validate a raw offer (a map { [itemId] = amount }) against what `player` owns,
-- returning a clean map { [itemId] = amount } or nil + reason. Rejects the whole
-- offer if any uuid isn't in the player's inventory or the amount exceeds that
-- instance's stack, so an offer never promises items the player can't back.
local function sanitizeOffer(player, raw)
	local Server = getServer()
	local inventory = Server:GetInventory(player)
	if not inventory then
		return nil, "NoInventory"
	end
	local map = {}
	if type(raw) ~= "table" then
		return map, nil
	end

	for uuid, rawAmount in raw do
		if type(uuid) ~= "string" then
			continue
		end
		local amount = math.floor(tonumber(rawAmount) or 0)
		if amount <= 0 then
			continue
		end
		local item = inventory:GetItem(uuid)
		if not item then
			return nil, "InvalidItem"
		end
		if amount > (item.Amount or 0) then
			return nil, "Insufficient"
		end
		-- Untradeable item types (Trade.SetItemFilter) are dropped from the offer rather
		-- than blocking the whole trade, so one non-tradeable item can't jam an offer.
		if Trade.ItemFilter and not Trade.ItemFilter(item.ItemName) then
			continue
		end
		map[uuid] = amount
	end
	return map, nil
end

-- Resolve an offer map { [itemId] = amount } into wire entries
-- { {ID, ItemName, Amount}, ... }, looking each instance's name up in the
-- offerer's inventory so the partner's client can render it (a client can't read
-- the other player's inventory directly).
local function offerEntries(player, offerMap)
	local inventory = getServer():GetInventory(player)
	local entries = {}
	for uuid, amount in offerMap or {} do
		local item = inventory and inventory:GetItem(uuid)
		if item then
			table.insert(entries, { ID = uuid, ItemName = item.ItemName, Amount = amount })
		end
	end
	return entries
end

-- Per-player view of a session (each side sees its own offer as "Yours").
local function snapshotFor(session, player)
	local other = otherPlayer(session, player)
	return {
		SessionId = session.ID,
		Partner = other,
		PartnerName = other.DisplayName,
		YourOffer = offerEntries(player, session.Offer[player]),
		TheirOffer = offerEntries(other, session.Offer[other]),
		YourReady = session.Ready[player] == true,
		TheirReady = session.Ready[other] == true,
	}
end

local function broadcast(session, event)
	local Server = getServer()
	Server:FireClient(session.A, event, snapshotFor(session, session.A))
	Server:FireClient(session.B, event, snapshotFor(session, session.B))
end

-- Tear a session down and tell both sides why. Safe to call once per session.
local function endSession(session, reason, success)
	if not Trade.Sessions[session.ID] then
		return
	end
	Trade.Sessions[session.ID] = nil
	if Trade.PlayerSession[session.A] == session.ID then
		Trade.PlayerSession[session.A] = nil
	end
	if Trade.PlayerSession[session.B] == session.ID then
		Trade.PlayerSession[session.B] = nil
	end
	local Server = getServer()
	local payload = { Reason = reason, Success = success == true }
	Server:FireClient(session.A, "_TradeEnd", payload)
	Server:FireClient(session.B, "_TradeEnd", payload)
end

-- Any offer edit clears both readies, so a ready always reflects the exact pair of
-- offers on screen — nobody can commit and then alter their side.
local function resetReady(session)
	session.Ready[session.A] = false
	session.Ready[session.B] = false
end

-- Swap items once both sides are ready. Re-validates ownership under the live
-- inventory first (items may have moved since ready), and on any shortfall aborts
-- the swap, un-readies both, and reports it rather than paying out partially.
-- Spends both sides before granting either, so a swap never grants without first
-- taking the matching cost.
local function tryExecute(session)
	if not (session.Ready[session.A] and session.Ready[session.B]) then
		return
	end
	local Server = getServer()
	local invA = Server:GetInventory(session.A)
	local invB = Server:GetInventory(session.B)
	if not invA or not invB then
		endSession(session, "PlayerLeft", false)
		return
	end

	for player, inventory in { [session.A] = invA, [session.B] = invB } do
		for uuid, amount in session.Offer[player] do
			local item = inventory:GetItem(uuid)
			if not item or (item.Amount or 0) < amount then
				resetReady(session)
				broadcast(session, "_TradeUpdate")
				Server:FireClient(player, "_TradeError", { Reason = "Insufficient" })
				return
			end
		end
	end

	-- Cross the offers by moving the exact instances (data preserved): A's uuids to
	-- B, B's uuids to A. Each transfer mutates only inventory state, not the offer
	-- maps we iterate, so this is safe.
	for uuid, amount in session.Offer[session.A] do
		invA:TransferItemTo(uuid, amount, invB, "Trade")
	end
	for uuid, amount in session.Offer[session.B] do
		invB:TransferItemTo(uuid, amount, invA, "Trade")
	end

	endSession(session, "Completed", true)
end

-- player requests to trade with `target` (a Player instance). Opens a pending
-- invite the target answers via _TradeRespond; expires after REQUEST_TTL. A target
-- can hold several pending invites at once (keyed by sender), so a queue of
-- invitations on the client is backed by distinct server-side entries.
function Trade.request(player, target)
	if typeof(target) ~= "Instance" or not target:IsA("Player") or target == player then
		return { Success = false, Reason = "InvalidTarget" }
	end
	if Trade.PlayerSession[player] or Trade.PlayerSession[target] then
		return { Success = false, Reason = "Busy" }
	end
	-- Either side restricted by PolicyService (IsPaidItemTradingAllowed) blocks the trade.
	if not Trade.IsTradingAllowed(player) or not Trade.IsTradingAllowed(target) then
		return { Success = false, Reason = "Restricted" }
	end
	if not withinRequestRange(player, target) then
		return { Success = false, Reason = "TooFar" }
	end

	local pending = Trade.Requests[target]
	if not pending then
		pending = {}
		Trade.Requests[target] = pending
	end
	pending[player] = { Expiry = os.time() + REQUEST_TTL }
	getServer():FireClient(target, "_TradeInvite", {
		From = player,
		FromName = player.DisplayName,
		-- So the client's countdown bar matches the server's actual TTL.
		Duration = REQUEST_TTL,
	})

	-- Lapse this specific invite if it's still unanswered after the TTL.
	task.delay(REQUEST_TTL, function()
		local reqs = Trade.Requests[target]
		local entry = reqs and reqs[player]
		if entry and os.time() >= entry.Expiry then
			reqs[player] = nil
			if next(reqs) == nil then
				Trade.Requests[target] = nil
			end
			getServer():FireClient(player, "_TradeDeclined", { By = target, Reason = "Expired" })
		end
	end)

	return { Success = true }
end

-- `player` answers a pending invite from `fromPlayer`. On accept, and while both
-- are still free and present, a session opens for both.
function Trade.respond(player, fromPlayer, accept)
	local reqs = Trade.Requests[player]
	local pending = reqs and reqs[fromPlayer]
	if not pending then
		return { Success = false, Reason = "NoRequest" }
	end
	reqs[fromPlayer] = nil
	if next(reqs) == nil then
		Trade.Requests[player] = nil
	end

	if not accept then
		getServer():FireClient(fromPlayer, "_TradeDeclined", { By = player, Reason = "Declined" })
		return { Success = true }
	end

	if typeof(fromPlayer) ~= "Instance" or not fromPlayer:IsA("Player") or not fromPlayer.Parent then
		return { Success = false, Reason = "PlayerLeft" }
	end
	if Trade.PlayerSession[player] or Trade.PlayerSession[fromPlayer] then
		return { Success = false, Reason = "Busy" }
	end
	-- Re-check the policy on accept (in case it resolved after the invite was sent).
	if not Trade.IsTradingAllowed(player) or not Trade.IsTradingAllowed(fromPlayer) then
		return { Success = false, Reason = "Restricted" }
	end

	local session = {
		ID = HttpService:GenerateGUID(false),
		A = fromPlayer,
		B = player,
		Offer = { [fromPlayer] = {}, [player] = {} },
		Ready = { [fromPlayer] = false, [player] = false },
	}
	Trade.Sessions[session.ID] = session
	Trade.PlayerSession[fromPlayer] = session.ID
	Trade.PlayerSession[player] = session.ID

	broadcast(session, "_TradeStart")
	return { Success = true }
end

local function sessionOf(player)
	local id = Trade.PlayerSession[player]
	return id and Trade.Sessions[id] or nil
end

-- Replace `player`'s offer with a validated version and un-ready both sides.
function Trade.setOffer(player, rawOffer)
	local session = sessionOf(player)
	if not session then
		return { Success = false, Reason = "NoSession" }
	end
	local offer, reason = sanitizeOffer(player, rawOffer)
	if not offer then
		return { Success = false, Reason = reason }
	end
	session.Offer[player] = offer
	resetReady(session)
	broadcast(session, "_TradeUpdate")
	return { Success = true }
end

-- Toggle `player`'s ready flag. Marking ready re-checks they still own their whole
-- offer; when both are ready the swap runs immediately.
function Trade.setReady(player, ready)
	local session = sessionOf(player)
	if not session then
		return { Success = false, Reason = "NoSession" }
	end
	ready = ready == true

	if ready then
		local Server = getServer()
		local inventory = Server:GetInventory(player)
		if not inventory then
			return { Success = false, Reason = "NoInventory" }
		end
		for uuid, amount in session.Offer[player] do
			local item = inventory:GetItem(uuid)
			if not item or (item.Amount or 0) < amount then
				return { Success = false, Reason = "Insufficient" }
			end
		end
	end

	session.Ready[player] = ready
	broadcast(session, "_TradeUpdate")
	tryExecute(session)
	return { Success = true }
end

-- Either party cancels; the session ends for both.
function Trade.cancel(player)
	local session = sessionOf(player)
	if not session then
		return { Success = false, Reason = "NoSession" }
	end
	endSession(session, "Cancelled", false)
	return { Success = true }
end

-- Clean up when a player leaves: end their live session and drop any invite they
-- sent or were sent.
function Trade.playerLeft(player)
	local session = sessionOf(player)
	if session then
		endSession(session, "PlayerLeft", false)
	end
	-- Drop invites sent TO this player, and invites this player sent to anyone.
	Trade.Requests[player] = nil
	for target, reqs in Trade.Requests do
		reqs[player] = nil
		if next(reqs) == nil then
			Trade.Requests[target] = nil
		end
	end
	Trade.TradingAllowed[player] = nil
end

function Trade.Start()
	if Trade.Started then
		return
	end
	Trade.Started = true
	local Server = getServer()

	Server:SetRemoteResponse("_TradeRequest", function(player, target)
		return Trade.request(player, target)
	end)
	Server:SetRemoteResponse("_TradeRespond", function(player, fromPlayer, accept)
		return Trade.respond(player, fromPlayer, accept)
	end)
	Server:SetRemoteResponse("_TradeSetOffer", function(player, offer)
		return Trade.setOffer(player, offer)
	end)
	Server:SetRemoteResponse("_TradeSetReady", function(player, ready)
		return Trade.setReady(player, ready)
	end)
	Server:SetRemoteResponse("_TradeCancel", function(player)
		return Trade.cancel(player)
	end)

	Players.PlayerRemoving:Connect(Trade.playerLeft)

	-- Resolve each player's trading policy on join (and any already present).
	Players.PlayerAdded:Connect(function(player)
		task.spawn(fetchPolicy, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(fetchPolicy, player)
	end
end

return Trade
