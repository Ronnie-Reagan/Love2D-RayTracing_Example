local M = {}

function M.normalize(path)
    path = tostring(path or "")
    path = path:gsub("\\", "/")
    path = path:gsub("/+", "/")
    return path
end

function M.join(a, b)
    a = M.normalize(a)
    b = M.normalize(b)

    if a == "" or a == "." then
        return b
    end
    if b == "" then
        return a
    end
    if a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "/" .. b
end

function M.dirname(path)
    path = M.normalize(path)
    local dir = path:match("^(.*)/[^/]*$")
    if not dir or dir == "" then
        return "."
    end
    return dir
end

function M.basename(path)
    path = M.normalize(path)
    return path:match("([^/]+)$") or path
end

return M
