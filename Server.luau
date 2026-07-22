local Players = game:GetService("Players")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")
local PlayerUtil = require(script.Parent.PlayerUtil)
local TableUtil = require(script.Parent.TableUtil)
local Inventory = require(script.Parent.Inventory)
local RunService = game:GetService("RunService")

if RunService:IsClient() then
	warn("This module is not meant to be required on the client.")
	return {}
end

-- Cross-server event totals. Every Server:AddEvent is tallied into Server.EventBatch,
-- and every EVENT_FLUSH_INTERVAL this server folds its batch into one shared
-- MemoryStore entry, so all live servers' counts roll into a single running total.
local EVENT_MEMORYSTORE_KEY = "_hextotals"
local EVENT_FLUSH_INTERVAL = 300 -- seconds between flushes (5 minutes)
local EVENT_MEMORYSTORE_EXPIRY = 2592000 -- 30 days; every write refreshes it (45d max)

local Server = {
	Started = false,
	Running = false,
	Players = {},
	Items = {},
	Shops = {},

	-- Inventory items whose gains/spends emit Roblox economy analytics. Populated
	-- by Server:TrackEconomy; maps itemName -> { default = <transactionType name?> }.
	EconomyItems = {},

	-- This server's un-flushed event tallies (event name -> amount), folded into the
	-- shared MemoryStore total every EVENT_FLUSH_INTERVAL (see Server:FlushEventBatch).
	EventBatch = {},

	-- Cached cross-server event totals (event name -> running total): seeded from
	-- MemoryStore at startup and refreshed on every successful flush. Read it with
	-- Server:GetEventTotals.
	EventTotals = {},

	-- Player settings declared with Server:CreateSettings. `Settings` keeps menu order
	-- (the client renders it in this order); `SettingsByName` is the lookup.
	Settings = {},
	SettingsByName = {},

	-- Quest templates registered with Server:CreateQuests (name -> template).
	Quests = {},

	-- Developer products registered with Server:AddProducts (productId -> reward list).
	-- When non-empty, Start claims MarketplaceService.ProcessReceipt to grant them.
	Products = {},
	RemoteEvent = Instance.new("RemoteEvent"),
	RemoteFunction = Instance.new("RemoteFunction"),

	-- Player-to-player trading is OFF unless a game opts in with Server:EnableTrading.
	-- The Trade module ships with the package, but its remotes are only registered
	-- when this is true (see Server:Start), so a game that doesn't want players moving
	-- items between each other never exposes the trade backend.
	TradingEnabled = false,

	EventResponses = {},
	EventConnections = {},
}
Server.RemoteEvent.Parent = script
Server.RemoteFunction.Parent = script

-- Whitelist an inventory item (typically a currency like "Coins") for economy
-- analytics: every GiveItem/SpendItem of it then logs an AnalyticsService economy
-- event -- Source on a grant, Sink on a spend -- with the item's post-change
-- balance as the ending balance. Net-zero transfers (stash moves, trades) are NOT
-- logged. The `source` passed to GiveItem/SpendItem becomes the transaction type when
-- it names a valid Enum.AnalyticsEconomyTransactionType (e.g. "Shop", "IAP"); otherwise
-- `defaultTransactionType` (a name or EnumItem, if given) is used, falling back to
-- "Gameplay".
--
-- `balancePrefixes` (optional) is a list of EXTRA state prefixes the item also lives in,
-- summed into the reported ending balance so it reflects total holdings rather than one
-- inventory. E.g. Caps sits in both "_Inventory" and the "_Cache" stash, so pass
-- { "_Cache" } to have the stash balance included.
--
-- Idempotent. Analytics only records in published games, so this is a no-op in Studio.
-- Chaining: returns Server.
function Server:TrackEconomy(itemName, defaultTransactionType, balancePrefixes)
	assert(type(itemName) == "string", "Server:TrackEconomy expects an item name string")
	local default = defaultTransactionType
	if typeof(default) == "EnumItem" then
		default = default.Name
	end
	Server.EconomyItems[itemName] = { default = default, balancePrefixes = balancePrefixes }
	return Server
end

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
		-- Player settings overrides. Only settings the player has actually changed live
		-- here; anything absent falls back to the definition's Default (see GetSetting),
		-- so raising a default later moves every untouched player with it.
		_Settings = {},
		-- Active quests, keyed by a uuid minted when the quest is given (see GiveQuest).
		-- A quest is removed from here the moment its last stage completes.
		_Quests = {},
		-- Set of finished non-repeatable quests (templateName -> true). A quest here is
		-- never handed out again (guards GiveQuest against re-rewarding a done tutorial).
		_QuestsDone = {},
		-- UTC day index of the player's last login, guarding the _DaysPlayed counter
		-- (see below) so a second login the same day doesn't double-count.
		_LastDay = 0,
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

	-- _DaysPlayed: lifetime count of distinct UTC days the player has logged in — a
	-- built-in companion to _TimePlayed. +1 the first time they're seen on a new day (not
	-- a streak; a missed day doesn't reset it). os.time is epoch seconds, so the boundary
	-- is UTC midnight, consistent across servers/regions. Registered after the player entry
	-- above so AddEvent (which reads GetState) resolves.
	local today = math.floor(os.time() / 86400)
	if state:Get("_LastDay") ~= today then
		state:Set("_LastDay", today)
		Server:AddEvent(player, "_DaysPlayed")
	end

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
	-- Also tally into this server's batch, for the cross-server MemoryStore total.
	self.EventBatch[event] = (self.EventBatch[event] or 0) + value
	-- ...and into any active quest task watching this event (see CreateQuests).
	self:_advanceQuestsForEvent(player, event, value)
end

-- Fold this server's accumulated event batch into the shared cross-server total and
-- clear the batch. The MemoryStore entry is a single table of event -> running total:
-- a nil (never written / expired) value starts as an empty table, then every batched
-- key is incremented onto it.
--
-- Nothing is written when the batch is empty, so this costs nothing until events are
-- actually recorded. The batch is swapped out before the (yielding) UpdateAsync so
-- events raised mid-flush land in the next batch rather than being double-counted or
-- lost; if the write fails the counts are merged back so they retry on the next flush.
function Server:FlushEventBatch()
	if next(self.EventBatch) == nil then
		return true
	end

	local batch = self.EventBatch
	self.EventBatch = {}

	local updated
	local ok, err = pcall(function()
		local map = MemoryStoreService:GetHashMap(EVENT_MEMORYSTORE_KEY)
		map:UpdateAsync(EVENT_MEMORYSTORE_KEY, function(totals)
			totals = totals or {}
			for event, amount in batch do
				totals[event] = (totals[event] or 0) + amount
			end
			updated = totals
			return totals
		end, EVENT_MEMORYSTORE_EXPIRY)
	end)

	if not ok then
		for event, amount in batch do
			self.EventBatch[event] = (self.EventBatch[event] or 0) + amount
		end
		warn("[rbx] FlushEventBatch failed (counts kept for the next flush): " .. tostring(err))
		return false
	end

	-- Cache the freshly-merged totals so readers get the latest without another fetch.
	if updated then
		self.EventTotals = updated
	end
	return true
end

-- Seed the cached cross-server totals from MemoryStore. A nil entry (never written, or
-- expired) reads as an empty table. Yields; called once at startup by Server:Start. A
-- failed fetch leaves the existing cache alone rather than clobbering it.
function Server:LoadEventTotals()
	local ok, totals = pcall(function()
		return MemoryStoreService:GetHashMap(EVENT_MEMORYSTORE_KEY):GetAsync(EVENT_MEMORYSTORE_KEY)
	end)
	if not ok then
		warn("[rbx] LoadEventTotals failed: " .. tostring(totals))
		return false
	end
	self.EventTotals = totals or {}
	return true
end

-- The cross-server event totals (event name -> running total): the cached shared totals
-- from the startup fetch / last successful flush, PLUS this server's un-flushed
-- EventBatch, so the numbers already include events raised since the last flush.
-- Returns a fresh table, so a caller can't mutate the cache. Mirrored to the client
-- over the "_GetEventTotals" remote — see Client:GetEventTotals.
function Server:GetEventTotals()
	local totals = TableUtil.deepCopy(self.EventTotals)
	for event, amount in self.EventBatch do
		totals[event] = (totals[event] or 0) + amount
	end
	return totals
end

-- ── Player settings ──────────────────────────────────────────────────────────
-- Declared once at startup with Server:CreateSettings, stored per player under
-- "_Settings/<Name>", and rendered by the SettingsMenu client template.
--
-- A setting the player has never touched is simply ABSENT from their data and resolves
-- to the definition's Default — so raising a default later moves every untouched player
-- with it. Writing nil clears the override and returns them to that behaviour
-- (Server:ResetSettings does the lot).
local SETTING_TYPES = {
	String = true, -- free text; optional MaxLength
	Number = true, -- constrained to Min..Max, optionally snapped to Step
	Choice = true, -- one of Options (each a string, number or boolean)
	Toggle = true, -- a boolean on/off
}

-- Normalise a value for `setting`, or nil when it isn't acceptable. nil in means nil out
-- (an explicit reset), which callers tell apart from a rejection by checking the input.
local function coerceSetting(setting, value)
	if value == nil then
		return nil
	end

	if setting.Type == "Toggle" then
		if type(value) == "boolean" then
			return value
		end
	elseif setting.Type == "Number" then
		local number = tonumber(value)
		if not number then
			return nil
		end
		if setting.Step and setting.Step > 0 then
			number = setting.Min + math.round((number - setting.Min) / setting.Step) * setting.Step
		end
		return math.clamp(number, setting.Min, setting.Max)
	elseif setting.Type == "String" then
		if type(value) ~= "string" then
			return nil
		end
		if setting.MaxLength and #value > setting.MaxLength then
			return value:sub(1, setting.MaxLength)
		end
		return value
	elseif setting.Type == "Choice" then
		for _, option in setting.Options do
			if option == value then
				return value
			end
		end
	end
	return nil
end

-- defs: an array of setting definitions. Each is positional —
--   { <name>, <display name>, <type>, <default>, <extras?> }
-- where the optional 5th element is a table of type-specific extras:
--   Number — Min, Max, and an optional Step to snap to
--   Choice — Options (array of string / number / boolean)
--   String — MaxLength (optional)
--
--   Server:CreateSettings({
--       { "Music", "Music Volume", "Number", 0.5, { Min = 0, Max = 1, Step = 0.05 } },
--       { "Quality", "Graphics", "Choice", "High", { Options = { "Low", "Medium", "High" } } },
--       { "Hints", "Show Hints", "Toggle", true },
--       { "Tag", "Name Tag", "String", "", { MaxLength = 16 } },
--   })
--
-- Call before Server:Start. Redeclaring a name replaces it in place. Chaining: returns
-- Server.
function Server:CreateSettings(defs)
	for _, def in defs do
		local name = def.Name or def[1]
		local display = def.Display or def[2] or name
		local settingType = def.Type or def[3]
		local default = if def.Default ~= nil then def.Default else def[4]

		if type(name) ~= "string" or not SETTING_TYPES[settingType] then
			warn(
				"[rbx] CreateSettings: skipping '" .. tostring(name) .. "' (bad type '" .. tostring(settingType) .. "')"
			)
			continue
		end

		-- Type-specific extras come either as a 5th positional table (which keeps the
		-- definition a pure array) or as named fields on the definition itself.
		local extra = if type(def[5]) == "table" then def[5] else def

		local setting = {
			Name = name,
			Display = display,
			Type = settingType,
			Default = default,
			Min = extra.Min,
			Max = extra.Max,
			Step = extra.Step,
			Options = extra.Options,
			MaxLength = extra.MaxLength,
		}

		if settingType == "Number" then
			setting.Min = tonumber(setting.Min) or 0
			setting.Max = tonumber(setting.Max) or 100
			if setting.Max < setting.Min then
				setting.Min, setting.Max = setting.Max, setting.Min
			end
		elseif settingType == "Choice" then
			if type(setting.Options) ~= "table" or #setting.Options == 0 then
				warn("[rbx] CreateSettings: '" .. name .. "' is a Choice with no Options; skipping")
				continue
			end
		end

		-- A default the type wouldn't accept is unreachable from the menu, so pin it to
		-- something valid rather than leaving the setting stuck.
		local cleanDefault = coerceSetting(setting, setting.Default)
		if cleanDefault == nil then
			if settingType == "Choice" then
				cleanDefault = setting.Options[1]
			elseif settingType == "Number" then
				cleanDefault = setting.Min
			elseif settingType == "Toggle" then
				cleanDefault = false
			else
				cleanDefault = ""
			end
			warn("[rbx] CreateSettings: '" .. name .. "' had an invalid default; using " .. tostring(cleanDefault))
		end
		setting.Default = cleanDefault

		if self.SettingsByName[name] then
			for index, existing in self.Settings do
				if existing.Name == name then
					self.Settings[index] = setting
					break
				end
			end
		else
			table.insert(self.Settings, setting)
		end
		self.SettingsByName[name] = setting
	end
	return self
end

-- The player's value for `name`, falling back to the default when they've never set it.
function Server:GetSetting(player, name)
	local setting = self.SettingsByName[name]
	if not setting then
		return nil
	end
	local stored = self:Get(player, "_Settings/" .. name)
	if stored == nil then
		return setting.Default
	end
	return stored
end

-- Every setting resolved for `player` (name -> value).
function Server:GetSettings(player)
	local values = {}
	for _, setting in self.Settings do
		values[setting.Name] = self:GetSetting(player, setting.Name)
	end
	return values
end

-- Set a setting, validated against its definition. Passing nil CLEARS the override so
-- the player follows the default again. Returns true when applied, false when rejected.
function Server:SetSetting(player, name, value)
	local setting = self.SettingsByName[name]
	if not setting then
		return false
	end
	local clean = coerceSetting(setting, value)
	if value ~= nil and clean == nil then
		return false -- wrong type / not an option / unparseable
	end
	self:Set(player, "_Settings/" .. name, clean)
	return true
end

-- Clear every override, returning the player to the defaults.
function Server:ResetSettings(player)
	for _, setting in self.Settings do
		self:Set(player, "_Settings/" .. setting.Name, nil)
	end
	return true
end

-- ── Quests ───────────────────────────────────────────────────────────────────
-- Quests are declared once as templates (Server:CreateQuests) and handed out per player
-- (Server:GiveQuest), which mints a uuid and stores the live copy at "_Quests/<uuid>".
--
-- A template is a list of STAGES; each stage is a list of TASKS. A task names an event id
-- and how many points of it are needed — progress comes straight from Server:AddEvent, so
-- any event a game already records can drive a quest with no extra plumbing.
--
-- Completion is a small state machine:
--   * a task with no Rewards completes itself the moment it hits its points
--   * a task WITH Rewards waits to be claimed (ClaimQuestTask)
--   * once every task is claimed, a stage with a Reward waits for ClaimQuestStage,
--     otherwise it advances immediately
--   * advancing past the last stage deletes the quest, then chains to NextQuest if set
local QUEST_PATH = "_Quests/"

-- Blank progress/claim arrays sized to a stage's task list, so the shape is explicit in
-- the data rather than relying on nil-as-zero.
local function freshStage(stage)
	local progress, claimed = {}, {}
	for index in stage.Tasks do
		progress[index] = 0
		claimed[index] = false
	end
	return progress, claimed
end

-- templates: a map of name -> template.
--
--   Server:CreateQuests({
--       Initiation = {
--           Display = "Wasteland Initiation",
--           NextQuest = "Prospector",          -- optional: handed out on completion
--           Stages = {
--               {
--                   -- { <display>, <event id>, <points>, <rewards?> }
--                   Tasks = {
--                       { "Mine 10 ore", "OreMined", 10, { { "Caps", 50 } } },
--                       { "Get a kill", "Kills", 1 },   -- no rewards: auto-completes
--                   },
--                   Reward = { { "Caps", 100 } },        -- optional: else auto-advances
--               },
--           },
--       },
--   })
--
-- Tasks also accept named fields (Display / Event / Points / Rewards). Chaining: returns
-- Server.
function Server:CreateQuests(templates)
	for name, raw in templates do
		if type(raw) ~= "table" or type(raw.Stages) ~= "table" or #raw.Stages == 0 then
			warn("[rbx] CreateQuests: '" .. tostring(name) .. "' has no Stages; skipping")
			continue
		end

		local stages = {}
		local valid = true
		for stageIndex, rawStage in raw.Stages do
			local tasks = {}
			for _, rawTask in rawStage.Tasks or {} do
				local task = {
					Display = rawTask.Display or rawTask[1] or "",
					Event = rawTask.Event or rawTask[2],
					Points = tonumber(rawTask.Points or rawTask[3]) or 1,
					Rewards = rawTask.Rewards or rawTask[4],
				}
				if type(task.Event) ~= "string" then
					warn("[rbx] CreateQuests: '" .. name .. "' stage " .. stageIndex .. " has a task with no event id")
					valid = false
					break
				end
				table.insert(tasks, task)
			end
			if not valid then
				break
			end
			if #tasks == 0 then
				warn("[rbx] CreateQuests: '" .. name .. "' stage " .. stageIndex .. " has no Tasks")
				valid = false
				break
			end
			table.insert(stages, { Tasks = tasks, Reward = rawStage.Reward })
		end
		if not valid then
			continue
		end

		self.Quests[name] = {
			Name = name,
			Display = raw.Display or name,
			Stages = stages,
			NextQuest = raw.NextQuest,
			-- Non-repeatable by default: once finished, a quest is recorded in _QuestsDone
			-- and never handed out (or re-rewarded) again. Set Repeatable = true for quests
			-- meant to be re-run (e.g. dailies).
			Repeatable = raw.Repeatable == true,
		}
	end
	return self
end

-- Register a callback fired on quest lifecycle milestones, for analytics/notifications
-- (e.g. an onboarding funnel). Called as handler(player, questName, kind, stage):
--   kind "Given"         — quest handed out (stage begins at 1)
--   kind "StageComplete" — `stage` just finished (fires for every stage, incl. the last)
--   kind "Complete"      — the final stage finished; the quest is now removed
-- Errors in the handler are caught so they can't break quest flow.
function Server:SetQuestHandler(callback)
	self.QuestHandler = callback
	return self
end

function Server:_fireQuestHandler(player, questName, kind, stage)
	if not self.QuestHandler then
		return
	end
	local ok, err = pcall(self.QuestHandler, player, questName, kind, stage)
	if not ok then
		warn("[rbx] QuestHandler errored: " .. tostring(err))
	end
end

-- Hand `templateName` to `player`, returning the quest's uuid. A player only ever holds
-- one live copy of a template: if they already have it, that existing id comes back
-- instead of a duplicate.
function Server:GiveQuest(player, templateName)
	local template = self.Quests[templateName]
	if not template then
		warn("[rbx] GiveQuest: unknown quest '" .. tostring(templateName) .. "'")
		return nil
	end
	for questId, quest in self:GetQuests(player) do
		if quest.Template == templateName then
			return questId
		end
	end
	-- Already finished (and not repeatable)? Don't hand it out — or re-reward it — again.
	if not template.Repeatable and self:Get(player, "_QuestsDone/" .. templateName) then
		return nil
	end

	local questId = HttpService:GenerateGUID(false)
	local progress, claimed = freshStage(template.Stages[1])
	self:Set(player, QUEST_PATH .. questId, {
		Template = templateName,
		Stage = 1,
		Progress = progress,
		Claimed = claimed,
		StageClaimed = false,
	})
	self:_fireQuestHandler(player, templateName, "Given", 1)
	-- A stage that needs no work (rewardless zero-point tasks) shouldn't sit there.
	self:_refreshQuest(player, questId)
	return questId
end

-- Every live quest for `player`, keyed by uuid.
function Server:GetQuests(player)
	local quests = self:Get(player, "_Quests")
	return if type(quests) == "table" then quests else {}
end

-- Hand out a reward list ({{item, amount}, ...}). Tagged "Quest" so the client's
-- ItemNotifications can style or filter it.
function Server:_grantRewards(player, rewards)
	if type(rewards) ~= "table" then
		return
	end
	local inventory = self:GetInventory(player)
	if not inventory then
		return
	end
	for _, entry in rewards do
		local itemName, amount = entry[1], entry[2] or 1
		if self.Items[itemName] then
			inventory:GiveItem(itemName, amount, "Quest")
		else
			warn("[rbx] quest reward references unknown item '" .. tostring(itemName) .. "'")
		end
	end
end

-- Feed an event into every active task watching it. Called from AddEvent, so quests ride
-- the event pipeline a game already has. Progress is capped at the task's requirement so
-- the numbers stay tidy for display (7/10, never 12/10).
function Server:_advanceQuestsForEvent(player, event, value)
	for questId, quest in self:GetQuests(player) do
		local template = self.Quests[quest.Template]
		local stage = template and template.Stages[quest.Stage]
		if stage then
			local progress = table.clone(quest.Progress or {})
			local touched = false
			for index, taskInfo in stage.Tasks do
				if taskInfo.Event == event and not (quest.Claimed or {})[index] then
					local current = progress[index] or 0
					if current < taskInfo.Points then
						progress[index] = math.min(current + value, taskInfo.Points)
						touched = true
					end
				end
			end
			if touched then
				-- The WHOLE array, not "Progress/<index>": State splits a path on "/" and
				-- uses the segments as string keys, so an indexed write would land on
				-- Progress["1"] and leave the real Progress[1] untouched.
				self:Set(player, QUEST_PATH .. questId .. "/Progress", progress)
				self:_refreshQuest(player, questId)
			end
		end
	end
end

-- Settle a quest after progress or a claim: auto-complete finished tasks that carry no
-- reward, then advance once everything is claimed (pausing on a stage reward if there is
-- one). Advancing re-runs this, so stages needing no player action fall through.
function Server:_refreshQuest(player, questId)
	local path = QUEST_PATH .. questId
	local quest = self:Get(player, path)
	if type(quest) ~= "table" then
		return
	end
	local template = self.Quests[quest.Template]
	local stage = template and template.Stages[quest.Stage]
	if not stage then
		return
	end

	local claimed = table.clone(quest.Claimed or {})
	local changed = false
	for index, taskInfo in stage.Tasks do
		local points = (quest.Progress or {})[index] or 0
		if not claimed[index] and points >= taskInfo.Points then
			if type(taskInfo.Rewards) ~= "table" or #taskInfo.Rewards == 0 then
				claimed[index] = true
				changed = true
			end
		end
	end
	if changed then
		self:Set(player, path .. "/Claimed", claimed)
	end

	for index in stage.Tasks do
		if not claimed[index] then
			return -- work (or a claim) still outstanding
		end
	end

	-- Everything claimed. A stage reward waits for the player; otherwise move on.
	if type(stage.Reward) == "table" and #stage.Reward > 0 and not quest.StageClaimed then
		return
	end
	self:_advanceQuest(player, questId)
end

-- Move to the next stage, or finish the quest if that was the last one.
function Server:_advanceQuest(player, questId)
	local path = QUEST_PATH .. questId
	local quest = self:Get(player, path)
	if type(quest) ~= "table" then
		return
	end
	local template = self.Quests[quest.Template]
	if not template then
		return
	end

	local completedStage = quest.Stage
	self:_fireQuestHandler(player, quest.Template, "StageComplete", completedStage)

	local nextStage = quest.Stage + 1
	if nextStage > #template.Stages then
		self:Set(player, path, nil)
		-- Record the completion so a non-repeatable quest is never handed out again.
		if not template.Repeatable then
			self:Set(player, "_QuestsDone/" .. quest.Template, true)
		end
		self:_fireQuestHandler(player, quest.Template, "Complete", completedStage)
		if template.NextQuest then
			self:GiveQuest(player, template.NextQuest)
		end
		return
	end

	local progress, claimed = freshStage(template.Stages[nextStage])
	self:Set(player, path, {
		Template = quest.Template,
		Stage = nextStage,
		Progress = progress,
		Claimed = claimed,
		StageClaimed = false,
	})
	self:_refreshQuest(player, questId)
end

-- Claim a finished task's reward. Returns true when it was paid out.
function Server:ClaimQuestTask(player, questId, taskIndex)
	local path = QUEST_PATH .. tostring(questId)
	local quest = self:Get(player, path)
	if type(quest) ~= "table" then
		return false
	end
	local template = self.Quests[quest.Template]
	local stage = template and template.Stages[quest.Stage]
	local task = stage and stage.Tasks[taskIndex]
	if not task or (quest.Claimed or {})[taskIndex] then
		return false
	end
	if ((quest.Progress or {})[taskIndex] or 0) < task.Points then
		return false
	end

	self:_grantRewards(player, task.Rewards)
	local claimed = table.clone(quest.Claimed or {})
	claimed[taskIndex] = true
	self:Set(player, path .. "/Claimed", claimed)
	self:_refreshQuest(player, questId)
	return true
end

-- Claim a completed stage's reward, which also advances the quest.
function Server:ClaimQuestStage(player, questId)
	local path = QUEST_PATH .. tostring(questId)
	local quest = self:Get(player, path)
	if type(quest) ~= "table" or quest.StageClaimed then
		return false
	end
	local template = self.Quests[quest.Template]
	local stage = template and template.Stages[quest.Stage]
	if not stage or type(stage.Reward) ~= "table" or #stage.Reward == 0 then
		return false
	end
	for index in stage.Tasks do
		if not (quest.Claimed or {})[index] then
			return false -- a task is still outstanding
		end
	end

	self:_grantRewards(player, stage.Reward)
	self:Set(player, path .. "/StageClaimed", true)
	self:_advanceQuest(player, questId)
	return true
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

-- Build a shop whose prices come straight from each item's Value, instead of hand-writing
-- every trade. A "Buy" vendor sells items to the player at Value × BuyMultiplier (default
-- 1.5); a "Sell" vendor pays Value × SellMultiplier (default 0.5) for them. Prices then
-- stay consistent with net worth and (for guns) repair cost, and retune automatically when
-- a Value changes.
--
-- config:
--   Name            display name (default = shopId)
--   Type            "Buy" (default) or "Sell"
--   Items           array of item names, or { name, packSize } pairs — packSize lets a
--                   stackable trade in bulk (e.g. { "Bullet", 30 } = 30 at a time)
--   BuyMultiplier   default 1.5
--   SellMultiplier  default 0.5
--   TradeAll        default true for a Sell vendor (dump a whole stack), false for Buy
--
-- Call AFTER Server:AddItemInfo (it reads Values) and before Start. Chaining: returns
-- Server. Currency (Caps) is always the counter-item.
function Server:AddVendor(shopId, config)
	config = config or {}
	local selling = config.Type == "Sell"
	local buyMul = config.BuyMultiplier or 1.5
	local sellMul = config.SellMultiplier or 0.5

	local trades = {}
	for _, entry in config.Items or {} do
		local itemName, pack = entry, 1
		if type(entry) == "table" then
			itemName, pack = entry[1], entry[2] or 1
		end

		local info = self.Items[itemName]
		if not info then
			warn("[rbx] AddVendor: '" .. shopId .. "' references unknown item '" .. tostring(itemName) .. "'")
			continue
		end

		local value = info.Value or 0
		if selling then
			-- Player hands over the item(s) for caps; floor so the house keeps the change.
			local price = math.max(0, math.floor(value * pack * sellMul))
			table.insert(trades, { Give = { { "Caps", price } }, Cost = { { itemName, pack } } })
		else
			-- Player pays caps for the item(s); ceil so buying is never under Value.
			local price = math.max(1, math.ceil(value * pack * buyMul))
			table.insert(trades, { Give = { { itemName, pack } }, Cost = { { "Caps", price } } })
		end
	end

	self:AddShopInfo({
		[shopId] = {
			Name = config.Name or shopId,
			Trades = trades,
			TradeAll = if config.TradeAll ~= nil then config.TradeAll else selling,
		},
	})
	return self
end

-- Register Roblox developer products and what each one grants. `map` is keyed by product
-- id, each value a reward list of { itemName, amount } pairs (same shape as a shop trade's
-- Give or a daily-reward tier):
--
--   Server:AddProducts({
--       [123456789] = { { "Caps", 1000 } },
--       [987654321] = { { "Caps", 5000 } },
--   })
--
-- Registering any product makes Start install the single global ProcessReceipt handler,
-- which grants the rewards on purchase, idempotently (see processReceipt). The R$ price
-- lives on the product itself in Roblox — only the id -> reward mapping belongs here. Call
-- after AddItemInfo (reward items must exist) and before Start. Chaining: returns Server.
function Server:AddProducts(map)
	for productId, rewards in map do
		local id = tonumber(productId)
		if not id then
			warn("[rbx] AddProducts: product id must be a number, got " .. tostring(productId))
			continue
		end
		self.Products[id] = TableUtil.deepCopy(rewards)
	end
	return self
end

-- Register a server-side guard that can veto individual shop trades. `callback` is
-- called as callback(player, shopId, trade, inventory) right before a trade (or each
-- sub-trade of a mass trade) executes; return false to reject it, true to allow. This
-- is the authoritative counterpart to the client ItemShop's TradeFilter — use it to
-- enforce a hide rule that must not be bypassable (e.g. "can't buy a pickaxe you
-- already own"). A single guard covers every shop; branch on shopId/trade inside it.
function Server:SetShopTradeGuard(callback)
	self.ShopTradeGuard = callback
end

-- Opt into player-to-player trading (see Trade.luau). Trading is OFF by default, so
-- the trade remotes aren't registered and no items can move between players unless a
-- game calls this. Call before Server:Start (Start reads the flag when deciding
-- whether to start the Trade module).
function Server:EnableTrading()
	self.TradingEnabled = true
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
			-- "TimedReward" categorises the economy analytics as a daily/timed payout.
			inventory:GiveItem(itemName, amount, "TimedReward")
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
-- A ToolFilter (see WireTools) can further narrow the wired set — e.g. wiring only
-- the single best pickaxe a player owns — and, because this runs on every inventory
-- change, the wired tools stay in sync as items are gained or spent.
function Server:_reconcileTools(player)
	local folder = self.ToolsFolder
	local entry = self.Players[player]
	if not folder or not entry then
		return
	end

	local items = entry.State:Get("_Inventory/Items") or {}
	local desired = {} -- itemID -> ItemName
	for id, item in items do
		if type(item) == "table" and item.ItemName and folder:FindFirstChild(item.ItemName) then
			-- The optional filter gets the candidate item and the whole inventory, so
			-- it can decide relative to the other items owned (e.g. "is this the best
			-- pickaxe?"). No filter means every matching item is wired, as before.
			if not self.ToolFilter or self.ToolFilter(player, item, items) then
				desired[id] = item.ItemName
			end
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
				-- Give the tool its backpack/hotbar icon from the item's Render.Image,
				-- so a tool template authored without a TextureId still shows the same
				-- icon the item uses everywhere else. Falls back to "" (no icon).
				local info = self.Items[itemName]
				tool.TextureId = (info and info.Render and info.Render.Image) or ""
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
--
-- filter (optional): filter(player, item, items) -> boolean, called for every
-- inventory item whose ItemName matches a template in `folder`. Return true to wire
-- a Tool for that item, false to skip it. `item` is the candidate item table and
-- `items` is the player's whole `_Inventory/Items` map, so the decision can be made
-- relative to the rest of the inventory (e.g. wire only the highest-Power pickaxe).
-- It runs during reconciliation, which fires on every item gain/spend and on
-- respawn, so the wired set follows the filter automatically.
function Server:WireTools(folder, filter)
	self.ToolsFolder = folder
	self.ToolFilter = filter
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

	-- A game-supplied guard can veto specific trades server-side (see
	-- Server:SetShopTradeGuard) — the authoritative counterpart to the client
	-- ItemShop's TradeFilter, so a hide rule can't be bypassed by a crafted request.
	if Server.ShopTradeGuard and not Server.ShopTradeGuard(player, shopId, trade, inventory) then
		return { Success = false, Reason = "Blocked" }
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

	-- Counts were checked above, so each spend is expected to succeed. "Shop" tags the
	-- economy analytics so shop spends/payouts are categorised as shop transactions.
	for name, amount in required do
		inventory:SpendItem(name, amount * count, "Shop")
	end
	for _, entry in gives do
		inventory:GiveItem(entry[1], (entry[2] or 1) * count, "Shop")
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
		-- Honour the same server-side guard as single trades: a vetoed trade is simply
		-- skipped in the mass pass (mass trade does what it's allowed to).
		if Server.ShopTradeGuard and not Server.ShopTradeGuard(player, shopId, trade, inventory) then
			continue
		end
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

	-- Apply the whole pass at once: every spend, then every give. "Shop" categorises the
	-- economy analytics as shop transactions (matches processShopTrade).
	for name, amount in costs do
		inventory:SpendItem(name, amount, "Shop")
	end
	for name, amount in rewards do
		inventory:GiveItem(name, amount, "Shop")
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

-- MarketplaceService.ProcessReceipt handler for developer products registered with
-- Server:AddProducts. Roblox may invoke this more than once for a single purchase, and
-- re-invokes any receipt it hasn't been told was granted on the player's next join, so it
-- must be idempotent: every granted PurchaseId is recorded in the player's saved data and a
-- repeat is acknowledged without paying out again. Anything not safe to grant yet (unknown
-- product, player/data not loaded) returns NotProcessedYet so Roblox retries later rather
-- than consuming the receipt.
local function processReceipt(receiptInfo)
	local product = Server.Products[receiptInfo.ProductId]
	if not product then
		-- Not one of ours (or not registered on this server) — don't consume it.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local state = Server:GetState(player)
	local inventory = Server:GetInventory(player)
	if not state or not inventory then
		-- Profile not loaded yet; let Roblox retry once it is.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Already granted this exact purchase? Acknowledge, don't re-pay. The receipt list and
	-- the grant persist together in the one player State, so they can never partially save
	-- (a crash loses both, and Roblox then re-fires the receipt — self-healing).
	local granted = state:Get("_Receipts") or {}
	if table.find(granted, receiptInfo.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	state:ArrayInsert("_Receipts", receiptInfo.PurchaseId)
	for _, entry in product do
		local itemName, amount = entry[1], entry[2] or 1
		if Server.Items[itemName] then
			-- "IAP" tags the economy event as a real-money source for tracked items.
			inventory:GiveItem(itemName, amount, "IAP")
		else
			warn(
				"[rbx] product "
					.. tostring(receiptInfo.ProductId)
					.. " grants unknown item '"
					.. tostring(itemName)
					.. "'"
			)
		end
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function Server:Start()
	if self.Started then
		return false
	end
	self.Started = true
	self:SetRemoteResponse("_GetGameInfo", function()
		return {
			Items = self.Items,
			Shops = self.Shops,
			DailyRewards = self.DailyPlayTimeRewards,
			Settings = self.Settings,
			Quests = self.Quests,
			Products = self.Products,
		}
	end)

	-- Developer-product purchases (Server:AddProducts): claim the single global receipt
	-- handler only when the game registered products, so a game that handles its own
	-- receipts keeps control of ProcessReceipt.
	if next(self.Products) then
		MarketplaceService.ProcessReceipt = processReceipt
	end
	self:SetRemoteResponse("_ShopTrade", function(player, shopId, tradeIndex, quantity)
		return processShopTrade(player, shopId, tradeIndex, quantity)
	end)
	self:SetRemoteResponse("_ShopMassTrade", function(player, shopId)
		return processMassTrade(player, shopId)
	end)
	self:SetRemoteResponse("_ClaimDailyReward", function(player, tierKey)
		return self:ClaimDailyReward(player, tierKey)
	end)
	-- Settings: the client sends nil to clear an override and fall back to the default.
	self:SetRemoteResponse("_SetSetting", function(player, name, value)
		return { Success = self:SetSetting(player, name, value) }
	end)
	self:SetRemoteResponse("_ResetSettings", function(player)
		return { Success = self:ResetSettings(player) }
	end)

	-- Quest claims. Both are validated server-side against the live quest data.
	self:SetRemoteResponse("_ClaimQuestTask", function(player, questId, taskIndex)
		return { Success = self:ClaimQuestTask(player, questId, tonumber(taskIndex)) }
	end)
	self:SetRemoteResponse("_ClaimQuestStage", function(player, questId)
		return { Success = self:ClaimQuestStage(player, questId) }
	end)

	-- Lets the client read the cross-server event totals on demand (Client:GetEventTotals).
	self:SetRemoteResponse("_GetEventTotals", function()
		return self:GetEventTotals()
	end)

	-- P2P trading (see Trade.luau) registers its own remotes and player-leaving
	-- cleanup here. Off by default: only started when the module is present alongside
	-- Server AND the game opted in via Server:EnableTrading, so the trade backend is
	-- never exposed unless explicitly wanted.
	local tradeModule = script.Parent:FindFirstChild("Trade")
	if tradeModule and self.TradingEnabled then
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

	-- Seed the cached cross-server totals at startup so game code (and the client) can
	-- read them right away. Spawned so a slow MemoryStore fetch never delays Start.
	task.spawn(function()
		self:LoadEventTotals()
	end)

	-- Roll this server's event tallies into the shared cross-server total every
	-- EVENT_FLUSH_INTERVAL, and once more on shutdown so the final partial batch
	-- (up to 5 minutes of events) isn't lost when the server closes. Each successful
	-- flush also refreshes the cached totals.
	task.spawn(function()
		while task.wait(EVENT_FLUSH_INTERVAL) do
			self:FlushEventBatch()
		end
	end)
	game:BindToClose(function()
		self:FlushEventBatch()
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
