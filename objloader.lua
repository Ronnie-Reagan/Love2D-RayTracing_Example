-- objloader.lua
local mathutil = require("shared.mathutil")
local pathutil = require("shared.pathutil")
local vec3 = require("shared.vec3")

local M = {}

local DEFAULT_OPTIONS = {
    generateMissingNormals = true,
    keepRawArrays = false,
    splitByMaterial = true,
    splitByObject = true,
    splitByGroup = true,
    splitBySmoothingGroup = true,
}

local normalizePath = pathutil.normalize
local joinPath = pathutil.join
local dirname = pathutil.dirname
local basename = pathutil.basename
local clamp = mathutil.clamp
local vec3sub = vec3.sub
local vec3cross = vec3.cross
local vec3length = vec3.length
local vec3normalize = vec3.normalize
local vec3addInPlace = vec3.addInPlace

local function fileExistsOS(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function readTextOS(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, err
    end
    local text = f:read("*a")
    f:close()
    return text
end

local function readTextLove(path)
    if not love or not love.filesystem or not love.filesystem.getInfo(path) then
        return nil, "not found in love.filesystem"
    end
    return love.filesystem.read(path)
end

local function trim(s)
    return (tostring(s or ""):match("^%s*(.-)%s*$") or "")
end

local function parseFloat(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function parseVec3(words, startIndex, fallback)
    fallback = fallback or 0.0
    return {
        parseFloat(words[startIndex], fallback),
        parseFloat(words[startIndex + 1], fallback),
        parseFloat(words[startIndex + 2], fallback),
    }
end

local function newBounds()
    return {
        min = { math.huge, math.huge, math.huge },
        max = { -math.huge, -math.huge, -math.huge },
    }
end

local function expandBounds(bounds, p)
    if p[1] < bounds.min[1] then bounds.min[1] = p[1] end
    if p[2] < bounds.min[2] then bounds.min[2] = p[2] end
    if p[3] < bounds.min[3] then bounds.min[3] = p[3] end
    if p[1] > bounds.max[1] then bounds.max[1] = p[1] end
    if p[2] > bounds.max[2] then bounds.max[2] = p[2] end
    if p[3] > bounds.max[3] then bounds.max[3] = p[3] end
end

local function finalizeBounds(bounds)
    if bounds.min[1] == math.huge then
        return {
            min = { 0, 0, 0 },
            max = { 0, 0, 0 },
            size = { 0, 0, 0 },
            center = { 0, 0, 0 },
        }
    end

    local size = {
        bounds.max[1] - bounds.min[1],
        bounds.max[2] - bounds.min[2],
        bounds.max[3] - bounds.min[3],
    }

    return {
        min = { bounds.min[1], bounds.min[2], bounds.min[3] },
        max = { bounds.max[1], bounds.max[2], bounds.max[3] },
        size = size,
        center = {
            (bounds.min[1] + bounds.max[1]) * 0.5,
            (bounds.min[2] + bounds.max[2]) * 0.5,
            (bounds.min[3] + bounds.max[3]) * 0.5,
        },
    }
end

local function expandBoundsByBounds(bounds, other)
    if not other or not other.min or not other.max then
        return
    end

    expandBounds(bounds, other.min)
    expandBounds(bounds, other.max)
end

local function splitWords(line)
    local words = {}
    for word in line:gmatch("%S+") do
        words[#words + 1] = word
    end
    return words
end

local function iterateLogicalLines(text)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local physicalLines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        physicalLines[#physicalLines + 1] = line
    end

    local i = 0
    local logicalLine = nil

    return function()
        while true do
            i = i + 1
            if i > #physicalLines then
                if logicalLine ~= nil then
                    local out = logicalLine
                    logicalLine = nil
                    return out
                end
                return nil
            end

            local line = physicalLines[i]
            if line:sub(-1) == "\\" then
                logicalLine = (logicalLine or "") .. line:sub(1, -2)
            else
                if logicalLine ~= nil then
                    local out = logicalLine .. line
                    logicalLine = nil
                    return out
                end
                return line
            end
        end
    end
end

local function resolveIndex(index, count)
    if index > 0 then
        return index
    end
    return count + index + 1
end

local function parsePosition(words)
    if #words < 4 then
        return nil
    end

    local pos = {
        parseFloat(words[2], 0.0),
        parseFloat(words[3], 0.0),
        parseFloat(words[4], 0.0),
    }

    local color = nil
    if #words >= 7 then
        color = {
            clamp(parseFloat(words[5], 1.0), 0.0, 1.0),
            clamp(parseFloat(words[6], 1.0), 0.0, 1.0),
            clamp(parseFloat(words[7], 1.0), 0.0, 1.0),
            (#words >= 8) and clamp(parseFloat(words[8], 1.0), 0.0, 1.0) or 1.0,
        }
    end

    return pos, color
end

local function parseTexcoord(words)
    if #words < 2 then
        return nil
    end
    return {
        parseFloat(words[2], 0.0),
        parseFloat(words[3], 0.0),
        parseFloat(words[4], 0.0),
    }
end

local function parseNormal(words)
    if #words < 4 then
        return nil
    end
    return vec3normalize({
        parseFloat(words[2], 0.0),
        parseFloat(words[3], 0.0),
        parseFloat(words[4], 0.0),
    })
end

local function parseFaceRef(token, vertexCount, texcoordCount, normalCount)
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

    return { vi = vi, vti = vti, vni = vni }
end

local function decodeMapPath(line)
    local rest = trim(line:match("^%S+%s+(.+)$"))
    if rest == "" then
        return nil
    end

    local candidate = nil
    local tokens = splitWords(rest)
    local i = 1
    while i <= #tokens do
        local token = tokens[i]
        if token:sub(1, 1) == "-" then
            i = i + 2
        else
            candidate = table.concat(tokens, " ", i)
            break
        end
    end

    if not candidate or candidate == "" then
        candidate = rest
    end
    return trim(candidate)
end

local function newMaterial(name)
    return {
        name = name,
        ka = { 0, 0, 0 },
        kd = { 1, 1, 1 },
        ks = { 0, 0, 0 },
        ke = { 0, 0, 0 },
        tf = { 1, 1, 1 },
        ns = 0.0,
        ni = 1.5,
        d = 1.0,
        illum = 2,
        pr = nil,
        pm = nil,
        ps = nil,
        pc = nil,
        pcr = nil,
        aniso = nil,
        anisor = nil,
        hasTf = false,
        hasNi = false,
        hasD = false,
        hasKe = false,
        hasPr = false,
        hasPm = false,
        hasPs = false,
        hasPc = false,
        hasPcr = false,
        mapKa = nil,
        mapKd = nil,
        mapKs = nil,
        mapKe = nil,
        mapTf = nil,
        mapPr = nil,
        mapPm = nil,
        mapPs = nil,
        mapBump = nil,
        mapNormal = nil,
        mapD = nil,
    }
end

local function parseMTLText(text, objPath)
    local materials = {}
    local current = nil
    local objDir = dirname(objPath)

    local function resolveAssetPath(rel)
        rel = trim(rel)
        if rel == "" then
            return nil
        end
        return normalizePath(joinPath(objDir, rel))
    end

    for rawLine in iterateLogicalLines(text) do
        local line = trim(rawLine:gsub("#.*$", ""))
        if line ~= "" then
            local words = splitWords(line)
            local head = words[1]

            if head == "newmtl" then
                local name = trim(line:match("^newmtl%s+(.+)$"))
                if name == "" then
                    name = "unnamed_" .. tostring(#materials + 1)
                end
                current = newMaterial(name)
                materials[name] = current

            elseif current then
                if head == "Ka" then
                    current.ka = parseVec3(words, 2, 0.0)
                elseif head == "Kd" then
                    current.kd = parseVec3(words, 2, 0.0)
                elseif head == "Ks" then
                    current.ks = parseVec3(words, 2, 0.0)
                elseif head == "Ke" then
                    current.ke = parseVec3(words, 2, 0.0)
                    current.hasKe = true
                elseif head == "Tf" then
                    current.tf = parseVec3(words, 2, 1.0)
                    current.hasTf = true
                elseif head == "Ns" then
                    current.ns = parseFloat(words[2], 0.0)
                elseif head == "Ni" then
                    current.ni = math.max(1.0, parseFloat(words[2], 1.5))
                    current.hasNi = true
                elseif head == "d" then
                    current.d = clamp(parseFloat(words[2], 1.0), 0.0, 1.0)
                    current.hasD = true
                elseif head == "Tr" then
                    current.d = 1.0 - clamp(parseFloat(words[2], 0.0), 0.0, 1.0)
                    current.hasD = true
                elseif head == "illum" then
                    current.illum = math.floor(parseFloat(words[2], 2))
                elseif head == "Pr" then
                    current.pr = clamp(parseFloat(words[2], 1.0), 0.0, 1.0)
                    current.hasPr = true
                elseif head == "Pm" then
                    current.pm = clamp(parseFloat(words[2], 0.0), 0.0, 1.0)
                    current.hasPm = true
                elseif head == "Ps" then
                    current.ps = clamp(parseFloat(words[2], 1.0), 0.0, 1.0)
                    current.hasPs = true
                elseif head == "Pc" then
                    current.pc = clamp(parseFloat(words[2], 0.0), 0.0, 1.0)
                    current.hasPc = true
                elseif head == "Pcr" then
                    current.pcr = clamp(parseFloat(words[2], 0.03), 0.0, 1.0)
                    current.hasPcr = true
                elseif head == "aniso" then
                    current.aniso = clamp(parseFloat(words[2], 0.0), 0.0, 1.0)
                elseif head == "anisor" then
                    current.anisor = clamp(parseFloat(words[2], 0.0), 0.0, 1.0)
                elseif head == "map_Ka" then
                    current.mapKa = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_Kd" then
                    current.mapKd = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_Ks" then
                    current.mapKs = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_Ke" then
                    current.mapKe = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_Tf" then
                    current.mapTf = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_Pr" then
                    current.mapPr = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_Pm" then
                    current.mapPm = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_Ps" then
                    current.mapPs = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_d" then
                    current.mapD = resolveAssetPath(decodeMapPath(line))
                elseif head == "map_Bump" or head == "bump" then
                    current.mapBump = resolveAssetPath(decodeMapPath(line))
                elseif head == "norm" then
                    current.mapNormal = resolveAssetPath(decodeMapPath(line))
                end
            end
        end
    end

    return materials
end

local function readText(kind, path)
    if kind == "love" then
        return readTextLove(path)
    end
    return readTextOS(path)
end

local function getSearchRoots()
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

    if love and love.filesystem then
        if love.filesystem.getSourceBaseDirectory then
            add(love.filesystem.getSourceBaseDirectory())
        end
        if love.filesystem.getSaveDirectory then
            add(love.filesystem.getSaveDirectory())
        end
    end

    return roots
end

function M.getSearchRoots()
    return getSearchRoots()
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

    for _, root in ipairs(getSearchRoots()) do
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
            if love and love.filesystem and love.filesystem.getInfo(candidate.path) then
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

local function inspectOBJText(text)
    local info = {
        vertexCount = 0,
        texcoordCount = 0,
        normalCount = 0,
        faceCount = 0,
        triangleCount = 0,
        objectCount = 0,
        groupCount = 0,
        materialUseCount = 0,
        mtllibCount = 0,
    }

    for rawLine in iterateLogicalLines(text) do
        local line = trim(rawLine:gsub("#.*$", ""))
        if line ~= "" then
            local words = splitWords(line)
            local head = words[1]

            if head == "v" then
                info.vertexCount = info.vertexCount + 1
            elseif head == "vt" then
                info.texcoordCount = info.texcoordCount + 1
            elseif head == "vn" then
                info.normalCount = info.normalCount + 1
            elseif head == "f" then
                local triCount = math.max(0, (#words - 1) - 2)
                info.faceCount = info.faceCount + 1
                info.triangleCount = info.triangleCount + triCount
            elseif head == "o" then
                info.objectCount = info.objectCount + 1
            elseif head == "g" then
                info.groupCount = info.groupCount + 1
            elseif head == "usemtl" then
                info.materialUseCount = info.materialUseCount + 1
            elseif head == "mtllib" then
                info.mtllibCount = info.mtllibCount + 1
            end
        end
    end

    return info
end

local function resolveRelativeTextFile(objBackend, objPath, relPath)
    relPath = trim(relPath)
    if relPath == "" then
        return nil, nil
    end

    local baseDir = dirname(objPath)
    local attempts = {
        normalizePath(joinPath(baseDir, relPath)),
        normalizePath(joinPath(baseDir, basename(relPath))),
        normalizePath(relPath),
        normalizePath(basename(relPath)),
    }

    local seen = {}
    for _, candidate in ipairs(attempts) do
        if candidate ~= "" and not seen[candidate] then
            seen[candidate] = true
            local text = readText(objBackend, candidate)
            if text then
                return candidate, text
            end
        end
    end

    return nil, nil
end

function M.inspect(path)
    local backend, resolved = M.resolvePath(path)
    if not backend then
        return nil
    end

    local text = readText(backend, resolved)
    if not text then
        return nil
    end

    local info = inspectOBJText(text)
    info.backend = backend
    info.path = resolved

    local size
    if backend == "love" and love and love.filesystem and love.filesystem.getInfo then
        local fileInfo = love.filesystem.getInfo(resolved)
        size = fileInfo and fileInfo.size or nil
    else
        local f = io.open(resolved, "rb")
        if f then
            size = f:seek("end")
            f:close()
        end
    end
    info.fileSizeBytes = tonumber(size) or #text

    return info
end

local function meshKeyForState(objectName, groupName, materialName, smoothingGroup, options)
    local objectPart = options.splitByObject and objectName or "*"
    local groupPart = options.splitByGroup and groupName or "*"
    local materialPart = options.splitByMaterial and materialName or "*"
    local smoothPart = options.splitBySmoothingGroup and smoothingGroup or "*"
    return table.concat({ objectPart, groupPart, materialPart, smoothPart }, "\31")
end

local function newMesh(objectName, groupName, materialName, smoothingGroup)
    return {
        name = objectName ~= "" and objectName or groupName,
        objectName = objectName,
        groupName = groupName,
        material = materialName,
        smoothingGroup = smoothingGroup,
        vertices = {},
        indices = {},
        bounds = newBounds(),
        _vertexMap = {},
        _missingNormalVertexIndices = {},
        _faceCounter = 0,
    }
end

local function addMeshVertex(mesh, scene, ref, uniqueTag)
    local key = tostring(ref.vi) .. "/" .. tostring(ref.vti or 0) .. "/" .. tostring(ref.vni or 0)
    if uniqueTag then
        key = key .. "/" .. tostring(uniqueTag)
    end

    local existing = mesh._vertexMap[key]
    if existing then
        return existing
    end

    local p = scene.positions[ref.vi]
    local vertex = {
        position = { p[1], p[2], p[3] },
        texcoord = ref.vti and scene.texcoords[ref.vti] and {
            scene.texcoords[ref.vti][1],
            scene.texcoords[ref.vti][2],
            scene.texcoords[ref.vti][3],
        } or nil,
        normal = ref.vni and scene.normals[ref.vni] and {
            scene.normals[ref.vni][1],
            scene.normals[ref.vni][2],
            scene.normals[ref.vni][3],
        } or nil,
        color = scene.colors[ref.vi] and {
            scene.colors[ref.vi][1],
            scene.colors[ref.vi][2],
            scene.colors[ref.vi][3],
            scene.colors[ref.vi][4],
        } or nil,
        source = { vi = ref.vi, vti = ref.vti, vni = ref.vni },
    }

    local index = #mesh.vertices + 1
    mesh.vertices[index] = vertex
    mesh._vertexMap[key] = index
    expandBounds(mesh.bounds, vertex.position)

    if not vertex.normal then
        mesh._missingNormalVertexIndices[index] = true
    end

    return index
end

local function addTriangleToMesh(mesh, scene, a, b, c)
    mesh._faceCounter = mesh._faceCounter + 1
    local forceUnique = (mesh.smoothingGroup == "off")
    local faceTag = forceUnique and mesh._faceCounter or nil

    local ia = addMeshVertex(mesh, scene, a, faceTag and (faceTag .. ":1") or nil)
    local ib = addMeshVertex(mesh, scene, b, faceTag and (faceTag .. ":2") or nil)
    local ic = addMeshVertex(mesh, scene, c, faceTag and (faceTag .. ":3") or nil)

    mesh.indices[#mesh.indices + 1] = ia
    mesh.indices[#mesh.indices + 1] = ib
    mesh.indices[#mesh.indices + 1] = ic
end

local function ensureMaterial(scene, name)
    if not scene.materials[name] then
        scene.materials[name] = newMaterial(name)
    end
    return scene.materials[name]
end

local function generateMissingNormalsForMesh(mesh)
    if not next(mesh._missingNormalVertexIndices) then
        mesh.bounds = finalizeBounds(mesh.bounds)
        mesh.triangleCount = #mesh.indices / 3
        return
    end

    local accum = {}
    for index in pairs(mesh._missingNormalVertexIndices) do
        accum[index] = { 0, 0, 0 }
    end

    for i = 1, #mesh.indices, 3 do
        local ia = mesh.indices[i]
        local ib = mesh.indices[i + 1]
        local ic = mesh.indices[i + 2]

        local a = mesh.vertices[ia].position
        local b = mesh.vertices[ib].position
        local c = mesh.vertices[ic].position

        local ab = vec3sub(b, a)
        local ac = vec3sub(c, a)
        local n = vec3cross(ab, ac)

        if accum[ia] then vec3addInPlace(accum[ia], n) end
        if accum[ib] then vec3addInPlace(accum[ib], n) end
        if accum[ic] then vec3addInPlace(accum[ic], n) end
    end

    for index, sum in pairs(accum) do
        mesh.vertices[index].normal = vec3normalize(sum)
    end

    mesh.bounds = finalizeBounds(mesh.bounds)
    mesh.triangleCount = #mesh.indices / 3
end

local function getMeshTriangleCount(mesh)
    return mesh.triangleCount or math.floor((mesh.indices and #mesh.indices or 0) / 3)
end

local function buildSceneObjects(scene)
    local objects = {}
    local objectIndexByName = {}
    local totalTriangles = 0

    for meshIndex, mesh in ipairs(scene.meshes) do
        mesh.meshIndex = meshIndex
        mesh.triangleCount = getMeshTriangleCount(mesh)
        totalTriangles = totalTriangles + mesh.triangleCount

        local objectName = trim(mesh.objectName)
        if objectName == "" then
            objectName = trim(mesh.name)
        end
        if objectName == "" then
            objectName = "object_" .. tostring(#objects + 1)
        end

        local objectIndex = objectIndexByName[objectName]
        local object = objectIndex and objects[objectIndex] or nil

        if not object then
            objectIndex = #objects + 1
            object = {
                name = objectName,
                meshIndices = {},
                bounds = newBounds(),
                triangleCount = 0,
            }
            objects[objectIndex] = object
            objectIndexByName[objectName] = objectIndex
        end

        mesh.objectIndex = objectIndex
        object.meshIndices[#object.meshIndices + 1] = meshIndex
        object.triangleCount = object.triangleCount + mesh.triangleCount
        expandBoundsByBounds(object.bounds, mesh.bounds)
    end

    for objectIndex, object in ipairs(objects) do
        object.objectIndex = objectIndex
        object.meshCount = #object.meshIndices
        object.bounds = finalizeBounds(object.bounds)
    end

    scene.objects = objects
    scene.objectIndexByName = objectIndexByName
    scene.objectCount = #objects
    scene.meshCount = #scene.meshes
    scene.totalTriangles = totalTriangles
end

local function buildTriangleSampler(options)
    local target = math.floor(tonumber(options and options.triangleSampleTarget) or 0)
    local sourceTotal = math.floor(tonumber(options and options.sourceTriangleCount) or 0)

    if target <= 0 or sourceTotal <= 0 or target >= sourceTotal then
        return function()
            return true
        end
    end

    local seen = 0
    local kept = 0

    return function()
        seen = seen + 1
        if kept >= target then
            return false
        end

        local expectedKept = math.floor((seen * target) / sourceTotal)
        if expectedKept > kept then
            kept = kept + 1
            return true
        end

        return false
    end
end

local function parseOBJText(text, backend, path, options)
    options = options or DEFAULT_OPTIONS

    local scene = {
        source = { kind = backend, path = path },
        positions = {},
        texcoords = {},
        normals = {},
        colors = {},
        materials = {
            default = newMaterial("default"),
        },
        mtllibs = {},
        meshes = {},
        bounds = newBounds(),
    }

    local meshLookup = {}
    local currentObject = basename(path)
    local currentGroup = "default"
    local currentMaterial = "default"
    local currentSmoothingGroup = "on"
    local shouldStoreTriangle = buildTriangleSampler(options)

    local function getCurrentMesh()
        ensureMaterial(scene, currentMaterial)
        local key = meshKeyForState(currentObject, currentGroup, currentMaterial, currentSmoothingGroup, options)
        local mesh = meshLookup[key]
        if not mesh then
            mesh = newMesh(currentObject, currentGroup, currentMaterial, currentSmoothingGroup)
            scene.meshes[#scene.meshes + 1] = mesh
            meshLookup[key] = mesh
        end
        return mesh
    end

    for rawLine in iterateLogicalLines(text) do
        local line = trim(rawLine:gsub("#.*$", ""))
        if line ~= "" then
            local words = splitWords(line)
            local head = words[1]

            if head == "v" then
                local pos, color = parsePosition(words)
                if pos then
                    scene.positions[#scene.positions + 1] = pos
                    scene.colors[#scene.colors + 1] = color
                    expandBounds(scene.bounds, pos)
                end

            elseif head == "vt" then
                local tex = parseTexcoord(words)
                if tex then
                    scene.texcoords[#scene.texcoords + 1] = tex
                end

            elseif head == "vn" then
                local normal = parseNormal(words)
                if normal then
                    scene.normals[#scene.normals + 1] = normal
                end

            elseif head == "f" then
                local refs = {}
                local valid = true
                for i = 2, #words do
                    local ref = parseFaceRef(words[i], #scene.positions, #scene.texcoords, #scene.normals)
                    if not ref then
                        valid = false
                        break
                    end
                    refs[#refs + 1] = ref
                end

                if valid and #refs >= 3 then
                    local mesh = getCurrentMesh()
                    for i = 2, #refs - 1 do
                        if shouldStoreTriangle() then
                            addTriangleToMesh(mesh, scene, refs[1], refs[i], refs[i + 1])
                        end
                    end
                end

            elseif head == "o" then
                currentObject = trim(line:match("^o%s+(.+)$"))
                if currentObject == "" then
                    currentObject = "unnamed_object"
                end

            elseif head == "g" then
                currentGroup = trim(line:match("^g%s+(.+)$"))
                if currentGroup == "" then
                    currentGroup = "default"
                end

            elseif head == "usemtl" then
                currentMaterial = trim(line:match("^usemtl%s+(.+)$"))
                if currentMaterial == "" then
                    currentMaterial = "default"
                end
                ensureMaterial(scene, currentMaterial)

            elseif head == "s" then
                currentSmoothingGroup = trim(line:match("^s%s+(.+)$"))
                if currentSmoothingGroup == "" then
                    currentSmoothingGroup = "on"
                end
                if currentSmoothingGroup == "0" then
                    currentSmoothingGroup = "off"
                end

            elseif head == "mtllib" then
                local libName = trim(line:match("^mtllib%s+(.+)$"))
                if libName ~= "" then
                    scene.mtllibs[#scene.mtllibs + 1] = libName
                    local resolvedLibPath, libText = resolveRelativeTextFile(backend, path, libName)
                    if libText then
                        local parsed = parseMTLText(libText, resolvedLibPath)
                        for name, material in pairs(parsed) do
                            scene.materials[name] = material
                        end
                    end
                end
            end
        end
    end

    scene.bounds = finalizeBounds(scene.bounds)

    for _, mesh in ipairs(scene.meshes) do
        if options.generateMissingNormals then
            generateMissingNormalsForMesh(mesh)
        else
            mesh.bounds = finalizeBounds(mesh.bounds)
            mesh.triangleCount = #mesh.indices / 3
        end
        mesh._vertexMap = nil
        mesh._missingNormalVertexIndices = nil
        mesh._faceCounter = nil
    end

    if not options.keepRawArrays then
        scene.positions = nil
        scene.texcoords = nil
        scene.normals = nil
        scene.colors = nil
    end

    buildSceneObjects(scene)

    return scene
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

    local function scanLoveDir(dir)
        if not (love and love.filesystem and love.filesystem.getInfo(dir, "directory")) then
            return
        end

        for _, name in ipairs(love.filesystem.getDirectoryItems(dir)) do
            local relPath = joinPath(dir, name)
            local info = love.filesystem.getInfo(relPath)
            if info and info.type == "directory" then
                scanLoveDir(relPath)
            else
                addPath(relPath)
            end
        end
    end

    scanLoveDir(folder)

    local isWindows = package.config:sub(1, 1) == "\\"
    for _, root in ipairs(getSearchRoots()) do
        local abs = joinPath(root, folder)
        local cmd
        if isWindows then
            cmd = 'dir /b /s /a-d "' .. joinPath(abs, "*.obj"):gsub("/", "\\") .. '" 2>nul'
        else
            cmd = 'find "' .. abs:gsub('"', '\\"') .. '" -type f \\( -iname "*.obj" \\) 2>/dev/null'
        end

        local p = io.popen(cmd)
        if p then
            local absPrefix = normalizePath(abs):lower()
            for line in p:lines() do
                local resolved = normalizePath(line)
                local lowered = resolved:lower()

                if lowered:sub(1, #absPrefix) == absPrefix then
                    local suffix = resolved:sub(#absPrefix + 1):gsub("^/", "")
                    addPath(joinPath(folder, suffix))
                else
                    addPath(resolved)
                end
            end
            p:close()
        end
    end

    table.sort(found, function(a, b)
        return a:lower() < b:lower()
    end)
    return found
end

function M.load(path, options)
    options = setmetatable(options or {}, {
        __index = DEFAULT_OPTIONS,
    })

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

    local text, err = readText(backend, resolved)
    if not text then
        print("OBJ loader: load failed: " .. tostring(resolved) .. " :: " .. tostring(err))
        return nil, err
    end

    local ok, sceneOrErr = pcall(function()
        return parseOBJText(text, backend, resolved, options)
    end)

    if not ok then
        print("OBJ loader: parse failed: " .. tostring(resolved) .. " :: " .. tostring(sceneOrErr))
        return nil, sceneOrErr
    end

    local materialCount = 0
    for _ in pairs(sceneOrErr.materials) do
        materialCount = materialCount + 1
    end

    print(
        "OBJ loader: loaded meshes=" .. tostring(#sceneOrErr.meshes) ..
        " materials=" .. tostring(materialCount)
    )

    return sceneOrErr
end

return M
