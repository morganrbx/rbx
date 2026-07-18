local FormatUtil = {
	ThousandSeparator = ",",
}

function FormatUtil.formatLongNumber(num)
	num = math.floor(num)
	if num < 0 then
		return "-" .. FormatUtil.formatLongNumber(-num)
	end
	local sep = FormatUtil.ThousandSeparator
	-- Escape any pattern-magic characters so a separator like "." or "-" is matched
	-- literally when stripping a leading separator.
	local sepPattern = sep:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
	return (tostring(num):reverse():gsub("%d%d%d", "%1" .. sep):reverse():gsub("^" .. sepPattern, ""))
end

function FormatUtil.formatShortNumber(num, prefix)
	num = math.floor(num)
	if num < 0 then
		return "-" .. FormatUtil.formatShortNumber(-num, prefix)
	end
	prefix = if prefix then prefix .. " " else ""
	local suffixes = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No" }

	-- Below 1000 there's no suffix and nothing to scale; this also avoids
	-- log10(0) = -inf for num == 0.
	if num < 1000 then
		return prefix .. tostring(num)
	end

	local magnitude = math.floor(math.log10(num) / 3)
	local scaled = num / (10 ^ (magnitude * 3))

	-- Truncate to 3 significant figures (no rounding). scaled is in [1, 1000), so
	-- the number of decimals that gives 3 sig figs is 2 minus its count of integer
	-- digits: 1.23 (2dp), 12.3 (1dp), 123 (0dp).
	local decimals = math.max(0, 2 - math.floor(math.log10(scaled)))
	local factor = 10 ^ decimals
	scaled = math.floor(scaled * factor) / factor

	-- Fixed-decimal format then trim trailing zeros (12.30 -> 12.3, 5.00 -> 5).
	local text = string.format("%." .. decimals .. "f", scaled)
	if decimals > 0 then
		text = text:gsub("%.?0+$", "")
	end
	return prefix .. text .. (suffixes[magnitude + 1] or "")
end

-- Format a duration in seconds as a compact "1h 2m", "3m 4s", or "45s" string.
-- Shows at most the two most-significant non-zero units, so a countdown reads
-- cleanly (e.g. a daily-reward timer, a claim's remaining time). Negative or
-- non-number inputs clamp to "0s".
function FormatUtil.formatDuration(seconds)
	if type(seconds) ~= "number" then
		return "0s"
	end
	seconds = math.max(0, math.floor(seconds))

	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60

	local parts = {}
	if days > 0 then
		table.insert(parts, days .. "d")
	end
	if hours > 0 then
		table.insert(parts, hours .. "h")
	end
	if minutes > 0 then
		table.insert(parts, minutes .. "m")
	end
	-- Always include seconds when nothing larger was shown, so "0s"/"45s" render.
	if secs > 0 or #parts == 0 then
		table.insert(parts, secs .. "s")
	end

	-- Two most-significant units is plenty of precision for a UI timer.
	return table.concat(parts, " ", 1, math.min(2, #parts))
end

return FormatUtil
