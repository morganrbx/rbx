local Event = {}
Event.__index = Event

function Event.new()
    return setmetatable({
        Connections = {}
    }, Event)
end

function Event:Connect(func)
    local connection = {
        Connected = true,
        Disconnect = function(this)
            this.Connected = false
            for i, v in ipairs(self.Connections) do
                if v[1] == this then
                    table.remove(self.Connections, i)
                    break
                end
            end
        end
    }
    table.insert(self.Connections, {connection, func})
    return connection
end

function Event:Fire(...)
    for _, connection in self.Connections do
        if connection[1].Connected then
            task.spawn(connection[2], ...)
        end
    end
    if self.OnInvoke then
        task.spawn(self.OnInvoke, ...)
    end
end

function Event:Invoke(...)
    for _, connection in self.Connections do
        if connection[1].Connected then
            task.spawn(connection[2], ...)
        end
    end
    if self.OnInvoke then
       return self.OnInvoke(...)
    end
end

function Event:Destroy()
    for _, connection in self.Connections do
        connection[1].Connected = false
    end
    self.Connections = {}
end

return Event