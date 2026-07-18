local Players = game:GetService("Players")
local PlayerUtil = {}

function PlayerUtil.observePlayers(callback, leavingCallback)
    local handler = function (player)
        callback(player)
        if not leavingCallback then return end
        repeat task.wait() until not player.Parent
        leavingCallback(player)
    end

    Players.PlayerAdded:Connect(handler)
    for _, player in Players:GetPlayers() do
        task.spawn(handler, player)
    end
end

return PlayerUtil