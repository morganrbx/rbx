local root = script

local t = {}

-- lazy load all children: require ModuleScripts, return other instances as-is
setmetatable(t, {
	__index = function(self, k)
		local child = root:FindFirstChild(k)
		if not child then
			return nil
		end

		local v
		if child:IsA("ModuleScript") then
			v = require(child)
		else
			v = child
		end

		self[k] = v
		return v
	end,
})

return t
