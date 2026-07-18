local TableUtil = {}

function TableUtil.deepCopy(original)
    local copy = {}

    for key, value in original do
        copy[key] = if typeof(value) == "table" then TableUtil.deepCopy(value) else value
    end

    return copy
end

-- Deep-fill `target` with any keys present in `template` but missing from it,
-- recursing into nested tables. Existing values in `target` are never changed or
-- removed, so saved data keeps its values while gaining fields added to the
-- template since it was written. Mutates and returns `target`.
function TableUtil.reconcile(target, template)
    for key, value in template do
        if target[key] == nil then
            target[key] = if typeof(value) == "table" then TableUtil.deepCopy(value) else value
        elseif typeof(value) == "table" and typeof(target[key]) == "table" then
            TableUtil.reconcile(target[key], value)
        end
    end

    return target
end

return TableUtil