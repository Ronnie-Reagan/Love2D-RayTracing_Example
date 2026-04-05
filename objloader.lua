-- objloader.lua
local M = {}

local function normalizePath(path)
    path = tostring(path or "")
    path = path:gsub("\\", "/")
    path = path:gsub("/+", "/")
    return path
end

local function joinPath(a, b)
    a = normalizePath(a)
    b = normalizePath(b)

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

local function basename(path)
    path = normalizePath(path)
    return path:match("([^/]+)$") or path
end

local function fileExistsOS(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function parseVertex(line)
    local x, y, z = line:match("^v%s+([%-%+%d%.eE]+)%s+([%-%+%d%.eE]+)%s+([%-%+%d%.eE]+)")
    if not x or not y or not z then
        return nil
    end
    return { tonumber(x), tonumber(y), tonumber(z) }
end

local function parseFaceToken(token)
    local v = token:match("^([%-%d]+)")
    if not v then
        return nil
    end
    return tonumber(v)
end

local function resolveIndex(index, count)
    if index > 0 then
        return index
    end
    return count + index + 1
end

local function parseOBJLines(lineIterator)
    local vertices = {}
    local faces = {}

    for line in lineIterator do
        if line:sub(1, 2) == "v " then
            local vertex = parseVertex(line)
            if vertex then
                vertices[#vertices + 1] = vertex
            end

        elseif line:sub(1, 2) == "f " then
            local tokens = {}
            for token in line:gmatch("%S+") do
                if token ~= "f" then
                    tokens[#tokens + 1] = token
                end
            end

            if #tokens >= 3 then
                local indices = {}
                local valid = true

                for i = 1, #tokens do
                    local idx = parseFaceToken(tokens[i])
                    if not idx then
                        valid = false
                        break
                    end

                    idx = resolveIndex(idx, #vertices)
                    if idx < 1 or idx > #vertices then
                        valid = false
                        break
                    end

                    indices[#indices + 1] = idx
                end

                if valid then
                    for i = 2, #indices - 1 do
                        faces[#faces + 1] = { indices[1], indices[i], indices[i + 1] }
                    end
                end
            end
        end
    end

    return vertices, faces
end

local function loadFromLoveFilesystem(path)
    if not love.filesystem.getInfo(path) then
        return nil, nil, "not found in love.filesystem"
    end

    local ok, vertices, faces = pcall(function()
        return parseOBJLines(love.filesystem.lines(path))
    end)

    if not ok then
        return nil, nil, vertices
    end

    return vertices, faces
end

local function loadFromOSFilesystem(path)
    local file, err = io.open(path, "r")
    if not file then
        return nil, nil, err
    end

    local ok, vertices, faces = pcall(function()
        return parseOBJLines(file:lines())
    end)

    file:close()

    if not ok then
        return nil, nil, vertices
    end

    return vertices, faces
end

function M.getSearchRoots()
    local roots = {}
    local seen = {}

    local function add(path)
        path = normalizePath(path)
        if path == "" then
            path = "."
        end
        if not seen[path] then
            seen[path] = true
            roots[#roots + 1] = path
        end
    end

    add(".")

    if love.filesystem.getSourceBaseDirectory then
        add(love.filesystem.getSourceBaseDirectory())
    end

    if love.filesystem.getSaveDirectory then
        add(love.filesystem.getSaveDirectory())
    end

    return roots
end

function M.getCandidatePaths(path)
    path = normalizePath(path)
    local nameOnly = basename(path)
    local candidates = {}

    local function add(kind, resolved)
        candidates[#candidates + 1] = { kind = kind, path = normalizePath(resolved) }
    end

    add("love", path)
    add("os", path)

    for _, root in ipairs(M.getSearchRoots()) do
        add("os", joinPath(root, path))
        if not path:find("/") then
            add("os", joinPath(root, joinPath("objects", path)))
        end
        if path:find("/") then
            add("os", joinPath(root, nameOnly))
        end
    end

    return candidates
end

function M.resolvePath(path)
    local candidates = M.getCandidatePaths(path)

    for _, candidate in ipairs(candidates) do
        if candidate.kind == "love" then
            if love.filesystem.getInfo(candidate.path) then
                return "love", candidate.path, candidates
            end
        else
            if fileExistsOS(candidate.path) then
                return "os", candidate.path, candidates
            end
        end
    end

    return nil, nil, candidates
end

function M.listModels(folder)
    folder = normalizePath(folder or "objects")
    local found = {}
    local seen = {}

    local function addPath(rel)
        rel = normalizePath(rel)
        if rel:lower():match("%.obj$") and not seen[rel:lower()] then
            seen[rel:lower()] = true
            found[#found + 1] = rel
        end
    end

    if love.filesystem.getInfo(folder, "directory") then
        for _, name in ipairs(love.filesystem.getDirectoryItems(folder)) do
            addPath(joinPath(folder, name))
        end
    end

    for _, root in ipairs(M.getSearchRoots()) do
        local abs = joinPath(root, folder):gsub("/", "\\")
        local cmd = 'dir /b "' .. abs .. '" 2>nul'
        local p = io.popen(cmd)
        if p then
            for line in p:lines() do
                addPath(joinPath(folder, line))
            end
            p:close()
        end
    end

    table.sort(found, function(a, b) return a:lower() < b:lower() end)
    return found
end


local function parseTexcoord(line)
    local u, v, w = line:match("^vt%s+([%-%+%d%.eE]+)%s+([%-%+%d%.eE]+)%s*([%-%+%d%.eE]*)")
    if not u then
        return nil
    end
    return {
        tonumber(u) or 0.0,
        tonumber(v) or 0.0,
        tonumber(w) or 0.0
    }
end

local function parseNormal(line)
    local x, y, z = line:match("^vn%s+([%-%+%d%.eE]+)%s+([%-%+%d%.eE]+)%s+([%-%+%d%.eE]+)")
    if not x or not y or not z then
        return nil
    end
    return { tonumber(x), tonumber(y), tonumber(z) }
end

local function parseFaceVertexToken(token, vertexCount, texcoordCount, normalCount)
    local vi, vti, vni = token:match("^([%-%d]+)/([%-%d]*)/([%-%d]*)$")
    if not vi then
        vi, vti = token:match("^([%-%d]+)/([%-%d]*)$")
    end
    if not vi then
        vi, vni = token:match("^([%-%d]+)//([%-%d]*)$")
    end
    if not vi then
        vi = token:match("^([%-%d]+)$")
    end

    if not vi then
        return nil
    end

    vi = tonumber(vi)
    if not vi then
        return nil
    end
    vi = resolveIndex(vi, vertexCount)
    if vi < 1 or vi > vertexCount then
        return nil
    end

    if vti and vti ~= "" then
        vti = tonumber(vti)
        if not vti then
            return nil
        end
        vti = resolveIndex(vti, texcoordCount)
        if vti < 1 or vti > texcoordCount then
            vti = nil
        end
    else
        vti = nil
    end

    if vni and vni ~= "" then
        vni = tonumber(vni)
        if not vni then
            return nil
        end
        vni = resolveIndex(vni, normalCount)
        if vni < 1 or vni > normalCount then
            vni = nil
        end
    else
        vni = nil
    end

    return {
        vi = vi,
        vti = vti,
        vni = vni,
    }
end

local function parseOBJLines(lineIterator)
    local model = {
        positions = {},
        texcoords = {},
        normals = {},
        triangles = {},
        materials = {
            default = {
                kd = { 1, 1, 1 },
                ks = { 0, 0, 0 },
                ke = { 0, 0, 0 },
                mapKd = nil,
            }
        },
    }

    local currentMaterial = "default"

    for rawLine in lineIterator do
        local line = tostring(rawLine or ""):gsub("\r", "")
        line = line:match("^%s*(.-)%s*$") or ""

        if line ~= "" and line:sub(1, 1) ~= "#" then
            if line:sub(1, 2) == "v " then
                local vertex = parseVertex(line)
                if vertex then
                    model.positions[#model.positions + 1] = vertex
                end

            elseif line:sub(1, 3) == "vt " then
                local texcoord = parseTexcoord(line)
                if texcoord then
                    model.texcoords[#model.texcoords + 1] = texcoord
                end

            elseif line:sub(1, 3) == "vn " then
                local normal = parseNormal(line)
                if normal then
                    model.normals[#model.normals + 1] = normal
                end

            elseif line:sub(1, 2) == "f " then
                local refs = {}
                local valid = true

                for token in line:gmatch("%S+") do
                    if token ~= "f" then
                        local ref = parseFaceVertexToken(
                            token,
                            #model.positions,
                            #model.texcoords,
                            #model.normals
                        )
                        if not ref then
                            valid = false
                            break
                        end
                        refs[#refs + 1] = ref
                    end
                end

                if valid and #refs >= 3 then
                    for i = 2, #refs - 1 do
                        model.triangles[#model.triangles + 1] = {
                            material = currentMaterial,
                            v = {
                                { vi = refs[1].vi, vti = refs[1].vti, vni = refs[1].vni },
                                { vi = refs[i].vi, vti = refs[i].vti, vni = refs[i].vni },
                                { vi = refs[i + 1].vi, vti = refs[i + 1].vti, vni = refs[i + 1].vni },
                            }
                        }
                    end
                end

            elseif line:sub(1, 7) == "usemtl " then
                local name = line:match("^usemtl%s+(.+)$")
                if name and name ~= "" then
                    currentMaterial = name
                    if not model.materials[currentMaterial] then
                        model.materials[currentMaterial] = {
                            kd = { 1, 1, 1 },
                            ks = { 0, 0, 0 },
                            ke = { 0, 0, 0 },
                            mapKd = nil,
                        }
                    end
                end
            end
        end
    end

    return model
end

local function loadFromLoveFilesystem(path)
    if not love.filesystem.getInfo(path) then
        return nil, "not found in love.filesystem"
    end

    local ok, modelOrErr = pcall(function()
        return parseOBJLines(love.filesystem.lines(path))
    end)

    if not ok then
        return nil, modelOrErr
    end

    return modelOrErr
end

local function loadFromOSFilesystem(path)
    local file, err = io.open(path, "r")
    if not file then
        return nil, err
    end

    local ok, modelOrErr = pcall(function()
        return parseOBJLines(file:lines())
    end)

    file:close()

    if not ok then
        return nil, modelOrErr
    end

    return modelOrErr
end

function M.load(path)
    local backend, resolved, candidates = M.resolvePath(path)

    if not backend then
        print("OBJ loader: failed to resolve path: " .. tostring(path))
        print("OBJ loader: candidates tried:")
        for i = 1, #candidates do
            print("  [" .. i .. "] " .. candidates[i].kind .. " -> " .. candidates[i].path)
        end
        return nil, "failed to resolve path"
    end

    print("OBJ loader: resolved '" .. tostring(path) .. "' via " .. backend .. " -> " .. resolved)

    local model, err
    if backend == "love" then
        model, err = loadFromLoveFilesystem(resolved)
    else
        model, err = loadFromOSFilesystem(resolved)
    end

    if not model then
        print("OBJ loader: load failed: " .. tostring(resolved) .. " :: " .. tostring(err))
        return nil, err
    end

    print(
        "OBJ loader: loaded positions=" .. tostring(#model.positions) ..
        " texcoords=" .. tostring(#model.texcoords) ..
        " normals=" .. tostring(#model.normals) ..
        " triangles=" .. tostring(#model.triangles)
    )

    return model
end

return M
