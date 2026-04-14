local M = {}

function M.clamp(v, lo, hi)
    if v < lo then
        return lo
    end
    if v > hi then
        return hi
    end
    return v
end

function M.clampInt(v, lo, hi)
    return math.floor(M.clamp(v, lo, hi))
end

function M.ceilDiv(a, b)
    if not b or b == 0 then
        return 1
    end
    return math.floor((a + b - 1) / b)
end

function M.boolToInt(v)
    return v and 1 or 0
end

function M.formatBool(v)
    return v and "On" or "Off"
end

function M.bytesToMiB(bytes)
    return (tonumber(bytes) or 0) / (1024 * 1024)
end

function M.mibToBytes(mib)
    return math.max(0, tonumber(mib) or 0) * 1024 * 1024
end

return M
