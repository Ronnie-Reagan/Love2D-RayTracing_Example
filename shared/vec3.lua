local M = {}

function M.add(a, b)
    return { a[1] + b[1], a[2] + b[2], a[3] + b[3] }
end

function M.sub(a, b)
    return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

function M.mul(v, s)
    return { v[1] * s, v[2] * s, v[3] * s }
end

function M.dot(a, b)
    return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

function M.cross(a, b)
    return {
        a[2] * b[3] - a[3] * b[2],
        a[3] * b[1] - a[1] * b[3],
        a[1] * b[2] - a[2] * b[1],
    }
end

function M.length(v)
    return math.sqrt(M.dot(v, v))
end

function M.normalize(v)
    local len = M.length(v)
    if len <= 1e-12 then
        return { 0, 1, 0 }
    end
    return { v[1] / len, v[2] / len, v[3] / len }
end

function M.copy(v)
    return { v[1], v[2], v[3] }
end

function M.addInPlace(a, b)
    a[1] = a[1] + b[1]
    a[2] = a[2] + b[2]
    a[3] = a[3] + b[3]
end

return M
