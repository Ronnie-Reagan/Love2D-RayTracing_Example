-- simple .obj loader
local M = {}

function M.load(path)
    local vertices = {}
    local faces = {}

    for line in love.filesystem.lines(path) do
        if line:sub(1, 2) == "v " then
            local x, y, z = line:match("v%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)%s+([%-%d%.eE]+)")
            table.insert(vertices, {tonumber(x), tonumber(y), tonumber(z)})
        elseif line:sub(1, 2) == "f " then
            -- Match only vertex indices (handles `f v/vt/vn` or `f v//vn`)
            local a, b, c = line:match("f%s+(%d+)[^ ]*%s+(%d+)[^ ]*%s+(%d+)[^ ]*")
            if not a or not b or not c then
                print("Invalid triangle:", tri[1], tri[2], tri[3])
            end

            if a and b and c then
                table.insert(faces, {tonumber(a), tonumber(b), tonumber(c)})
            end
        end
    end

    return vertices, faces
end

return M
