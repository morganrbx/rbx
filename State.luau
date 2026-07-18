local TableUtil = require(script.Parent.TableUtil)
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local DataStoreService
if RunService:IsServer() then
    DataStoreService = game:GetService("DataStoreService")
end

-- Lock tuning. Expiry is stored in os.time() (real UTC seconds) so it is
-- comparable across servers. The acquire window MUST exceed the TTL so a
-- stranded/abandoned lock is reclaimable within a single acquire call, and the
-- renew interval MUST be shorter than the TTL so a live owner never lapses.
local LOCK_TTL = 30
local LOCK_RENEW = 10
local LOCK_ACQUIRE_TIMEOUT = 35

local states = {}

if RunService:IsServer() then
    local Server = require(script.Parent.Server)
    Server:SetRemoteResponse("_StateSubscribe", function(player, id)
        local state = states[id]
        if not state then return end
        if not table.find(state.Players, player) then
            table.insert(state.Players, player)
        end
    end)

    Server:SetRemoteResponse("_StateUnsubscribe", function(player, id)
        local state = states[id]
        if not state then return end
        local index = table.find(state.Players, player)
        if index then
            table.remove(state.Players, index)
        end
    end)

    Server:SetRemoteResponse("_StateGet", function(_player, id)
        local state = states[id]
        if not state then return end
        return state.Data
    end)

    -- Scrub leaving players from every state's subscriber list so we never
    -- stream to a gone player or leak them in state.Players.
    game:GetService("Players").PlayerRemoving:Connect(function(player)
        for _, state in pairs(states) do
            local index = table.find(state.Players, player)
            if index then
                table.remove(state.Players, index)
            end
        end
    end)
else
    local Client = require(script.Parent.Client)
    Client:SetRemoteResponse("_StateStream", function(id, path, value)
        local state = states[id]
        if not state then return end
        -- While a replicated state is still fetching its snapshot, buffer
        -- incoming updates so they aren't clobbered by the snapshot assignment.
        if state._loading then
            table.insert(state._streamBuffer, {path, value})
            return
        end
        state:Set(path, value)
    end)
end

local State = {}
State.__index = State

-- Valid observer scopes (see State:Observe).
State.ObserverType = {
    Direct = "Direct",
    Children = "Children",
    Descendants = "Descendants",
}

-- True if `ancestor` is `path` itself or an ancestor of it ("a/b" is an ancestor
-- of "a/b/c"). The trailing "/" sentinel stops "a/b" matching "a/bc".
local function isAncestorOrEqual(ancestor, path)
    return path == ancestor or string.sub(path .. "/", 1, #ancestor + 1) == ancestor .. "/"
end

-- True if `child` is an immediate child of `parent` ("a/b" is, "a/b/c" is not).
local function isDirectChild(parent, child)
    if child == parent or not isAncestorOrEqual(parent, child) then
        return false
    end
    return not string.find(string.sub(child, #parent + 2), "/")
end

function State:Publish()
    if self.Published then
        return
    end
    self.Published = true
end


-- Acquire a lock for this profile using an UpdateAsync lock key. Retries until
-- `timeoutSec` of real elapsed time has passed (tick() is monotonic on a single
-- machine, so it is safe for measuring local elapsed time here — only the stored
-- Expiry needs the cross-server os.time() clock). Because the default timeout
-- exceeds LOCK_TTL, a lock stranded by a crashed/killed session is reclaimed
-- automatically once it expires.
function State:_acquireLock(timeoutSec)
    if not RunService:IsServer() or not self.DSName or not self.DSKey then
        return false
    end
    local lockKey = (self.DSKey .. ":lock")
    local ds = DataStoreService:GetDataStore(self.DSName)
    local owner = HttpService:GenerateGUID(false)
    local deadline = tick() + (timeoutSec or LOCK_ACQUIRE_TIMEOUT)
    local attempt = 0
    repeat
        attempt += 1
        local ok, result = pcall(function()
            return ds:UpdateAsync(lockKey, function(old)
                -- Grant the lock if it is free, has expired, or is already ours.
                if old == nil then
                    return {Owner = owner, Expiry = os.time() + LOCK_TTL}
                end
                if type(old) == "table"
                    and (old.Owner == owner or (old.Expiry and old.Expiry < os.time())) then
                    return {Owner = owner, Expiry = os.time() + LOCK_TTL}
                end
                return old
            end)
        end)
        if not ok then
            warn("State:_acquireLock attempt", attempt, "UpdateAsync ERROR for", self.DSKey, ":", result)
        elseif type(result) == "table" and result.Owner == owner then
            self._LockKey = lockKey
            self._LockOwner = owner
            self._LockExpiry = result.Expiry
            return true
        end
        if tick() < deadline then
            task.wait(1.5)
        end
    until tick() >= deadline
    warn("State:_acquireLock FAILED after", attempt, "attempts for", self.DSKey)
    return false
end

-- Refresh our lock's expiry so a long-lived session never lapses. Returns false
-- if we have lost ownership (another server stole an expired lock), letting the
-- caller stop writing.
function State:_renewLock()
    if not RunService:IsServer() or not self._LockKey or not self._LockOwner then
        return false
    end
    local ds = DataStoreService:GetDataStore(self.DSName)
    local ok, result = pcall(function()
        return ds:UpdateAsync(self._LockKey, function(old)
            if type(old) == "table" and old.Owner == self._LockOwner then
                old.Expiry = os.time() + LOCK_TTL
                return old
            end
            return old
        end)
    end)
    if not ok then
        warn("State:_renewLock UpdateAsync ERROR for", self.DSKey, ":", result)
        -- Transient error: keep the lock only while our last-known expiry still
        -- holds. Once it has passed we can no longer assume ownership — another
        -- server may have reclaimed the expired lock — so report it lost and let
        -- the caller stop writing rather than clobber the new owner's data.
        if self._LockExpiry and os.time() >= self._LockExpiry then
            warn("State:_renewLock assumed lost (expiry elapsed) for", self.DSKey)
            self._LockKey = nil
            self._LockOwner = nil
            self._LockExpiry = nil
            return false
        end
        return true
    end
    if type(result) == "table" and result.Owner == self._LockOwner then
        self._LockExpiry = result.Expiry
        return true
    end
    -- We no longer own the lock.
    warn("State:_renewLock lost ownership of", self.DSKey)
    self._LockKey = nil
    self._LockOwner = nil
    self._LockExpiry = nil
    return false
end

function State:_releaseLock()
    if not RunService:IsServer() or not self._LockKey or not self._LockOwner then
        return
    end
    local ds = DataStoreService:GetDataStore(self.DSName)
    -- NOTE: returning nil from an UpdateAsync transform CANCELS the update (it does
    -- not delete the key). To release, write an already-expired marker so the next
    -- _acquireLock treats the lock as free and reclaims it immediately.
    local ok, res = pcall(function()
        return ds:UpdateAsync(self._LockKey, function(old)
            if type(old) == "table" and old.Owner == self._LockOwner then
                return {Owner = "", Expiry = 0}
            end
            return old
        end)
    end)
    if not ok then
        -- Keep the lock fields set so a later attempt (e.g. BindToClose) retries
        -- the release instead of stranding the key in the store.
        warn("State:_releaseLock UpdateAsync ERROR for", self.DSKey, ":", res)
        return
    end
    self._LockKey = nil
    self._LockOwner = nil
    self._LockExpiry = nil
end

function State:Load()
    if not RunService:IsServer() or not self.DSName or not self.DSKey then
        return false
    end
    local ds = DataStoreService:GetDataStore(self.DSName)
    local locked = self:_acquireLock(LOCK_ACQUIRE_TIMEOUT)
    if not locked then
        -- Couldn't take the lock; load read-only so the session can still run,
        -- but _dataLoaded only flips true if the read actually succeeds, which
        -- gates Save() from writing defaults over real data.
        warn("State: failed to acquire lock for", self.DSKey, "— falling back to read-only load")
        local ok2, data2 = pcall(function()
            return ds:GetAsync(self.DSKey)
        end)
        if ok2 then
            self._dataLoaded = true
            if data2 then
                self.Data = data2
            end
            self:_reconcile()
            return true
        end
        warn("State:Load read-only GetAsync ERROR for", self.DSKey, ":", data2)
        return false
    end
    local ok, data = pcall(function()
        return ds:GetAsync(self.DSKey)
    end)
    if ok then
        self._dataLoaded = true
        if data then
            self.Data = data
        end
        self:_reconcile()
    else
        warn("State:Load GetAsync ERROR for", self.DSKey, ":", data)
    end
    return true
end

-- Fill any fields added to the template since this profile was last saved.
function State:_reconcile()
    if self.Template and typeof(self.Data) == "table" then
        TableUtil.reconcile(self.Data, self.Template)
    end
end

function State:Save()
    if not RunService:IsServer() or not self.DSName or not self.DSKey then
        return false
    end
    -- Never write defaults over real data we failed to read.
    if not self._dataLoaded then
        warn("State:Save aborted — data never loaded for", self.DSKey)
        return false
    end
    local ds = DataStoreService:GetDataStore(self.DSName)
    if self._isSaving then
        -- a save is already in progress; request another save to run after
        self._pendingSave = true
        return true
    end
    self._isSaving = true
    -- A write must hold the lock. The lock and the data live under different keys,
    -- so a single UpdateAsync can't make the ownership check and the write atomic;
    -- instead we confirm ownership in the store immediately before writing. If we
    -- have no lock, acquire one; if we think we hold one, renew it to verify it
    -- wasn't stolen while expired. Either failure path aborts rather than clobber
    -- another live session's data.
    if not self._LockOwner then
        if not self:_acquireLock(LOCK_ACQUIRE_TIMEOUT) then
            warn("State:Save aborted — could not acquire lock for", self.DSKey)
            self._isSaving = false
            return false
        end
    elseif not self:_renewLock() then
        if not self:_acquireLock(LOCK_ACQUIRE_TIMEOUT) then
            warn("State:Save aborted — lost lock and could not reacquire for", self.DSKey)
            self._isSaving = false
            return false
        end
    end
    local lastOk, lastErr
    -- Bound the drain so a stream of Sets faster than SetAsync completes can't
    -- spin here forever holding _isSaving; any pass left pending is picked up by
    -- the next autosave tick.
    local passes = 0
    repeat
        -- Clear before the write so a Set arriving mid-save triggers another pass.
        self._pendingSave = false
        passes += 1
        lastOk, lastErr = pcall(function()
            ds:SetAsync(self.DSKey, self.Data)
        end)
        if not lastOk then
            warn("State Save failed for", self.DSKey, ":", lastErr)
        end
    until not self._pendingSave or passes >= 5
    self._isSaving = false
    return lastOk
end

function State:SaveWithRetries(timeoutSec)
    local deadline = tick() + (timeoutSec or 5)
    local lastOk = false
    local attempt = 0
    while tick() < deadline do
        attempt = attempt + 1
        local ok = false
        local status = pcall(function()
            ok = self:Save()
        end)
        if status and ok then
            lastOk = true
            break
        end
        task.wait(0.25)
    end
    if not lastOk then
        warn("State:SaveWithRetries FAILED after", attempt, "attempts DSKey=", self.DSKey)
        -- In Studio, force-release the lock so a save that fails during stop/play
        -- doesn't strand it for the next test session. In a live server keep
        -- holding it: releasing after a failed save would let another server
        -- overwrite with stale data, and a genuinely dead owner is reclaimable via
        -- the TTL anyway.
        if RunService:IsStudio() then
            pcall(function()
                self:_releaseLock()
            end)
        end
    end
    return lastOk
end

function State:_startAutosave(interval)
    if self._AutosaveTask then return end
    self._AutosaveInterval = interval or 60
    self._AutosaveTask = task.spawn(function()
        local sinceSave = 0
        -- Tick at the renew cadence so the lock is refreshed well before it can
        -- lapse (LOCK_RENEW < LOCK_TTL); only persist data on the save interval.
        while self._AutosaveInterval do
            task.wait(LOCK_RENEW)
            if not self._AutosaveInterval then break end
            sinceSave += LOCK_RENEW
            if self._LockOwner and not self:_renewLock() then
                -- Lost the lock; try to take it back before the next save.
                self:_acquireLock(LOCK_ACQUIRE_TIMEOUT)
            end
            if sinceSave >= self._AutosaveInterval then
                sinceSave = 0
                local ok, err = pcall(function()
                    self:Save()
                end)
                if not ok then
                    warn("State autosave Save error for", self.DSKey, ":", err)
                end
            end
        end
    end)
end

function State:_stopAutosave()
    self._AutosaveInterval = nil
    self._AutosaveTask = nil
end

-- Idempotent teardown: stop the heartbeat, flush a final save ONLY while we
-- still hold the lock (never re-acquire here — doing so during shutdown races
-- with BindToClose and strands a fresh lock), then release. The _teardownStarted
-- guard is set synchronously before any yield, so concurrent callers
-- (PlayerRemoving + BindToClose) collapse to a single run.
function State:_teardownSave()
    if self._teardownStarted then
        return
    end
    self._teardownStarted = true
    self:_stopAutosave()
    -- If a periodic Save is still mid-flight, let it finish (bounded) before we
    -- write and release — otherwise we issue a concurrent write and then pull the
    -- lock out from under it.
    local saveDeadline = tick() + 5
    while self._isSaving and tick() < saveDeadline do
        task.wait(0.1)
    end
    if self._LockOwner and self._dataLoaded and self.DSName and self.DSKey then
        local ds = DataStoreService:GetDataStore(self.DSName)
        local ok, err = pcall(function()
            ds:SetAsync(self.DSKey, self.Data)
        end)
        if not ok then
            warn("State:_teardownSave SetAsync ERROR for", self.DSKey, ":", err)
        end
    end
    -- Retry the release a couple of times so a transient error doesn't strand it.
    for _ = 1, 3 do
        self:_releaseLock()
        if not self._LockKey then break end
        task.wait(0.2)
    end
    self._released = true
end

function State:Destroy()
    if RunService:IsServer() then
        self:_teardownSave()
        if self._playerRemovingConn then
            self._playerRemovingConn:Disconnect()
            self._playerRemovingConn = nil
        end
    else
        -- Client: tell the server to stop streaming this state to us.
        local Client = require(script.Parent.Client)
        Client:FireServer("_StateUnsubscribe", self.ID)
    end
    states[self.ID] = nil
end

-- Ensure all states attempt to save and release locks when the server closes (Studio stop/play or server shutdown)
if RunService:IsServer() then
    pcall(function()
        game:BindToClose(function()
            -- Kick off teardown for every player-bound state. _teardownSave is
            -- idempotent, so states already being torn down by PlayerRemoving are
            -- left to finish on their own coroutine rather than double-run.
            for _, s in pairs(states) do
                if s and s.DSName and s.DSKey and s.Player then
                    task.spawn(function()
                        pcall(function()
                            s:_teardownSave()
                        end)
                    end)
                end
            end
            -- Hold the server open until every in-flight teardown has released its
            -- lock (bounded, so a hung DataStore call can't block shutdown forever).
            local deadline = tick() + 25
            while tick() < deadline do
                local pending = false
                for _, s in pairs(states) do
                    if s and s.DSKey and s._teardownStarted and not s._released then
                        pending = true
                        break
                    end
                end
                if not pending then break end
                task.wait(0.1)
            end
        end)
    end)
end

function State.new(template, datastoreKey, playerToBind, id)
    local self = setmetatable({
        Data = if template then TableUtil.deepCopy(template) else {},
        Template = template,
        ID = id or HttpService:GenerateGUID(false),
        Player = playerToBind,
        Players = {},
        Observers = {
            Direct = {},
            Children = {},
            Descendants = {},
        },
    }, State)

    if datastoreKey then
        self.DSName = "HexState"
        self.DSKey = datastoreKey
    end

    states[self.ID] = self

    if RunService:IsServer() and self.DSName and self.DSKey then
        -- attempt to load profile and start autosave
        local ok, err = pcall(function()
            self:Load()
            self:_startAutosave(60)
        end)
        if not ok then
            warn("State.new load/autosave error for", self.DSKey, ":", err)
        end

        if self.Player then
            local Players = game:GetService("Players")
            self._playerRemovingConn = Players.PlayerRemoving:Connect(function(player)
                if player == self.Player then
                    self:_teardownSave()
                end
            end)
        end
    end

    return self
end

function State:Set(path: string, value)
    if self.Published then
        local Server = require(script.Parent.Server)
        Server:FireClients(self.Players, "_StateStream", self.ID, path, value)
    end

    local indexes = string.split(path, "/")
    local data = self.Data
    while #indexes > 1 do
        local key = table.remove(indexes, 1)
        if typeof(data[key]) ~= "table" then
            data[key] = {}
        end
        data = data[key]
    end
    data[indexes[1]] = value

    self:_notifyObservers(path)
    -- autosave will handle periodic saves; avoid immediate scheduling here
    return value
end

-- Fire observers affected by a change at `changedPath`. Each scope widens the
-- previous: Direct fires when the observed value itself changes (exact path or an
-- ancestor replaced); Children also fires when a direct child changes; Descendants
-- also fires when any descendant at any depth changes. Each observer receives the
-- current value at ITS own path.
function State:_notifyObservers(changedPath)
    for observedPath, observers in self.Observers.Direct do
        if isAncestorOrEqual(changedPath, observedPath) then
            self:_fireObservers(observers, observedPath)
        end
    end
    for observedPath, observers in self.Observers.Children do
        if isAncestorOrEqual(changedPath, observedPath) or isDirectChild(observedPath, changedPath) then
            self:_fireObservers(observers, observedPath)
        end
    end
    for observedPath, observers in self.Observers.Descendants do
        if isAncestorOrEqual(changedPath, observedPath) or isAncestorOrEqual(observedPath, changedPath) then
            self:_fireObservers(observers, observedPath)
        end
    end
end

function State:_fireObservers(observers, observedPath)
    local value = self:Get(observedPath)
    for _, observer in observers do
        task.spawn(observer[1], value)
    end
end

-- Returns the value at `path`. NOTE: table results are the LIVE internal table,
-- not a copy — treat them as read-only. Mutating a returned table in place
-- bypasses Set, so the change is never replicated to clients nor delivered to
-- observers, and can diverge from what gets persisted. Always write through Set.
function State:Get(path: string)
    if path == nil or typeof(path) ~= "string" then
        return self.Data
    end
    local indexes = string.split(path, "/")

    local data = self.Data
    for _, key in indexes do
        if typeof(data) ~= "table" then
            return nil
        end
        data = data[key]
    end
    return data
end

-- Observe changes at `path`. `observerType` selects the scope (default "Direct"):
--   Direct      — the observed value itself changed (exact path or ancestor replaced)
--   Children    — Direct, plus any direct child key changing
--   Descendants — Direct, plus any descendant at any depth changing
-- The callback receives the current value at `path`. Pass `immediate = true` to
-- also fire once with the current value at subscribe time.
function State:Observe(path, callback, observerType, immediate)
    observerType = observerType or State.ObserverType.Direct
    local bucket = self.Observers[observerType]
    assert(bucket, "State:Observe invalid observerType: " .. tostring(observerType))

    bucket[path] = bucket[path] or {}
    local observer = {callback}
    table.insert(bucket[path], observer)

    local function destroy()
        local tree = bucket[path]
        if not tree then return end
        local index = table.find(tree, observer)
        if not index then return end
        table.remove(tree, index)
        if #tree == 0 then
            bucket[path] = nil
        end
    end

    if immediate then
        task.spawn(callback, self:Get(path))
    end

    return {
        Disconnect = destroy,
        Destroy = destroy
    }
end

function State:Increment(path: string, value)
    return self:Set(path, (self:Get(path) or 0) + (value or 1))
end

-- Functionally update the value at `path`: passes the current value to `fn` and
-- stores (and replicates) whatever it returns.
function State:Update(path: string, fn)
    return self:Set(path, fn(self:Get(path)))
end

-- Insert `value` into the array at `path` (appends, or at `index` if given),
-- creating the array if it does not exist yet. Replicates via Set.
function State:ArrayInsert(path: string, value, index: number?)
    local array = self:Get(path)
    if typeof(array) ~= "table" then
        array = {}
    end
    if index then
        table.insert(array, index, value)
    else
        table.insert(array, value)
    end
    self:Set(path, array)
    return value
end

-- Remove the element at `index` from the array at `path` and return it.
function State:ArrayRemove(path: string, index: number)
    local array = self:Get(path)
    if typeof(array) ~= "table" then
        return nil
    end
    local removed = table.remove(array, index)
    self:Set(path, array)
    return removed
end

-- Remove the first occurrence of `value` from the array at `path`.
function State:ArrayRemoveValue(path: string, value)
    local array = self:Get(path)
    if typeof(array) ~= "table" then
        return nil
    end
    local index = table.find(array, value)
    if not index then
        return nil
    end
    return self:ArrayRemove(path, index)
end

function State.newReplicated(id)
    -- A replicated state is keyed by id, and the client's _StateStream handler
    -- dispatches every update to the single states[id] entry. So all consumers of
    -- the same id (Client.Data, an InventoryBar, a shop) MUST share one instance:
    -- creating a second would overwrite states[id] and silently freeze the first
    -- at its snapshot while only the newest receives streams. Reuse the existing.
    if states[id] then
        return states[id]
    end

    local self = State.new(nil,nil,nil,id)
    -- Subscribe first so no update is missed, but buffer streams until the
    -- snapshot is applied so they aren't overwritten by the assignment below.
    self._loading = true
    self._streamBuffer = {}

    local Client = require(script.Parent.Client)
    Client:FireServer("_StateSubscribe", id)
    self.Data = Client:InvokeServer("_StateGet", id) or self.Data

    self._loading = false
    for _, entry in self._streamBuffer do
        self:Set(entry[1], entry[2])
    end
    self._streamBuffer = nil

    return self
end

return State