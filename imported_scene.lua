local objloader = require("objloader")
local mathutil = require("shared.mathutil")
local pathutil = require("shared.pathutil")
local vec3 = require("shared.vec3")

local clamp = mathutil.clamp
local clampInt = mathutil.clampInt
local ceilDiv = mathutil.ceilDiv

local M = {}

local BYTES_PER_RGBA32F_TEXEL = 16
local BYTES_PER_RGBA16F_TEXEL = 8
local DEFAULT_BVH_LEAF_TRIANGLES = 8

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

local function expandBoundsByBounds(bounds, other)
    if not other or not other.min or not other.max then
        return
    end

    expandBounds(bounds, other.min)
    expandBounds(bounds, other.max)
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

    return {
        min = { bounds.min[1], bounds.min[2], bounds.min[3] },
        max = { bounds.max[1], bounds.max[2], bounds.max[3] },
        size = {
            bounds.max[1] - bounds.min[1],
            bounds.max[2] - bounds.min[2],
            bounds.max[3] - bounds.min[3],
        },
        center = {
            (bounds.min[1] + bounds.max[1]) * 0.5,
            (bounds.min[2] + bounds.max[2]) * 0.5,
            (bounds.min[3] + bounds.max[3]) * 0.5,
        },
    }
end

local function createNearestFloatImage(imageData)
    local image = love.graphics.newImage(imageData)
    image:setFilter("nearest", "nearest")
    image:setWrap("clamp", "clamp")
    return image
end

local function getTextureSizeLimit()
    local limit = 8192

    if love.graphics and love.graphics.getSystemLimits then
        local systemLimits = love.graphics.getSystemLimits() or {}
        limit = tonumber(systemLimits.texturesize)
            or tonumber(systemLimits.maxtexturesize)
            or tonumber(systemLimits.maxTextureSize)
            or limit
    end

    return math.max(1, math.floor(limit))
end

local function getLinearAtlasLayout(itemCount, textureLimit)
    itemCount = math.max(1, math.floor(itemCount or 1))
    textureLimit = math.max(1, math.floor(textureLimit or getTextureSizeLimit()))

    local columns = math.min(itemCount, textureLimit)
    local rows = ceilDiv(itemCount, columns)
    if rows > textureLimit then
        return nil, string.format(
            "Need %d texels but the GPU texture limit is %d x %d.",
            itemCount,
            textureLimit,
            textureLimit
        )
    end

    return {
        columns = columns,
        rows = rows,
    }
end

local function getTriangleAtlasLayout(triangleCount, textureLimit)
    triangleCount = math.max(1, math.floor(triangleCount or 1))
    textureLimit = math.max(1, math.floor(textureLimit or getTextureSizeLimit()))

    local triangleColumns = math.max(1, math.floor(textureLimit / 3))
    if triangleColumns < 1 then
        return nil, string.format(
            "Texture width limit %d is too small for triangle vertex packing.",
            textureLimit
        )
    end

    triangleColumns = math.min(triangleCount, triangleColumns)
    local rows = ceilDiv(triangleCount, triangleColumns)
    if rows > textureLimit then
        return nil, string.format(
            "Need %d triangles but the GPU texture limit is %d x %d.",
            triangleCount,
            textureLimit,
            textureLimit
        )
    end

    return {
        triangleColumns = triangleColumns,
        rows = rows,
        vertexWidth = triangleColumns * 3,
        materialWidth = triangleColumns,
    }
end

local function getLinearAtlasCoord(indexZero, columns)
    columns = math.max(1, math.floor(columns or 1))
    local x = indexZero % columns
    local y = math.floor(indexZero / columns)
    return x, y
end

local function avg3(v)
    if not v then
        return 0.0
    end
    return ((v[1] or 0) + (v[2] or 0) + (v[3] or 0)) / 3.0
end

local function min3(v)
    if not v then
        return 0.0
    end
    return math.min(v[1] or 0, math.min(v[2] or 0, v[3] or 0))
end

local function max3(v)
    if not v then
        return 0.0
    end
    return math.max(v[1] or 0, math.max(v[2] or 0, v[3] or 0))
end

local function saturateColor3(v, fallback)
    fallback = fallback or 0.0
    return {
        clamp(tonumber(v and v[1]) or fallback, 0.0, 1.0),
        clamp(tonumber(v and v[2]) or fallback, 0.0, 1.0),
        clamp(tonumber(v and v[3]) or fallback, 0.0, 1.0),
    }
end

local function multiplyColor3(a, b)
    return {
        (a[1] or 0.0) * (b[1] or 0.0),
        (a[2] or 0.0) * (b[2] or 0.0),
        (a[3] or 0.0) * (b[3] or 0.0),
    }
end

local function nsToRoughness(ns)
    local t = clamp((tonumber(ns) or 0) / 1000.0, 0.0, 1.0)
    return clamp(1.0 - math.sqrt(t), 0.02, 1.0)
end

local function legacyKsToMetallic(specularColor, baseColor, transmission)
    if transmission > 0.001 then
        return 0.0
    end

    local ksAvg = clamp(avg3(specularColor), 0.0, 1.0)
    local ksChroma = clamp(max3(specularColor) - min3(specularColor), 0.0, 1.0)
    local baseAvg = clamp(avg3(baseColor), 0.0, 1.0)

    local coloredSpec = clamp((ksChroma * 2.4) + math.max(0.0, ksAvg - 0.16) * 0.8, 0.0, 1.0)
    local brightSpec = clamp((ksAvg - 0.45) / 0.55, 0.0, 1.0)

    return clamp(
        math.max(coloredSpec * clamp(baseAvg * 1.1, 0.0, 1.0), brightSpec * 0.65),
        0.0,
        1.0
    )
end

local function resolveTransmission(material, albedo, opacity)
    local transmission = clamp(1.0 - opacity, 0.0, 1.0)
    local illum = math.floor(tonumber(material.illum) or 2)

    if transmission <= 0.0001 then
        if material.hasTf and max3(material.tf) < 0.999 then
            transmission = 0.92
        elseif material.hasNi and illum >= 4 then
            transmission = 0.92
        end
    end

    local transmissionColor = material.hasTf and saturateColor3(material.tf, 1.0) or { 1.0, 1.0, 1.0 }
    if transmission > 0.0001 and not material.hasTf and avg3(albedo) < 0.985 then
        transmissionColor = { albedo[1], albedo[2], albedo[3] }
    end

    return clamp(transmission, 0.0, 1.0), transmissionColor
end

local function resolveMaterial(scene, name)
    return (scene.materials and scene.materials[name]) or
           (scene.materials and scene.materials.default) or
           {
               kd = { 1, 1, 1 },
               ks = { 0, 0, 0 },
               ke = { 0, 0, 0 },
               tf = { 1, 1, 1 },
               ns = 0,
               ni = 1.5,
               d = 1.0,
               illum = 2,
           }
end

local function newImportedSceneState(path, maxTriangles)
    return {
        path = path or "",
        maxTriangles = maxTriangles or 1,
        loaded = false,
        importMode = "none",
        budgetReason = "hard-cap",
        budgetedTriangles = maxTriangles or 1,
        triCount = 0,
        sourceTriCount = 0,
        sourceFaceCount = 0,
        sourceVertexCount = 0,
        objectCount = 0,
        meshCount = 0,
        bounds = nil,
        summary = nil,
        objects = {},
        meshes = {},
        loadError = nil,
        estimatedVRAMBytes = 0,
        estimatedRAMBytes = 0,

        triangleVertsImage = nil,
        triangleNormalsImage = nil,
        triangleMatAImage = nil,
        triangleMatBImage = nil,
        triangleMatCImage = nil,
        triangleMatDImage = nil,

        objectNodeAImage = nil,
        objectNodeBImage = nil,
        meshNodeAImage = nil,
        meshNodeBImage = nil,
        meshNodeCImage = nil,
        bvhNodeAImage = nil,
        bvhNodeBImage = nil,
        bvhNodeCImage = nil,

        meshVertsImage = nil,
        meshNormalsImage = nil,
        meshMatAImage = nil,
        meshMatBImage = nil,
        meshMatCImage = nil,
        meshMatDImage = nil,
        meshUVImage = nil,
        meshMatIdImage = nil,

        meshTexSize = { 1, 1 },
        triangleTexSize = { 1, 1 },
        objectNodeTexSize = { 1, 1 },
        meshNodeTexSize = { 1, 1 },
        bvhNodeTexSize = { 1, 1 },
        bvhNodeCount = 0,
        bvhLeafTriangles = DEFAULT_BVH_LEAF_TRIANGLES,
        materialIndexByName = {},
        materialList = {},
        materialTextures = {},
        materialColors = {},
    }
end

local function transformImportedBounds(bounds, cx, cy, cz, scale, depthOffset)
    if not bounds or not bounds.min or not bounds.max then
        return {
            min = { 0, 0, 0 },
            max = { 0, 0, 0 },
            size = { 0, 0, 0 },
            center = { 0, 0, 0 },
        }
    end

    local transformed = newBounds()

    local function addCorner(px, py, pz)
        px = -(px - cx) * scale
        py =  (py - cy) * scale
        pz = -(pz - cz) * scale + depthOffset
        expandBounds(transformed, { px, py, pz })
    end

    for xi = 0, 1 do
        local px = (xi == 0) and bounds.min[1] or bounds.max[1]
        for yi = 0, 1 do
            local py = (yi == 0) and bounds.min[2] or bounds.max[2]
            for zi = 0, 1 do
                local pz = (zi == 0) and bounds.min[3] or bounds.max[3]
                addCorner(px, py, pz)
            end
        end
    end

    return finalizeBounds(transformed)
end

local function getImportedSourceObjects(scene, path)
    if scene.objects and #scene.objects > 0 then
        return scene.objects
    end

    local meshIndices = {}
    for meshIndex = 1, #scene.meshes do
        meshIndices[#meshIndices + 1] = meshIndex
    end

    return {
        {
            name = pathutil.basename(path),
            meshIndices = meshIndices,
            bounds = scene.bounds,
            triangleCount = scene.totalTriangles or 0,
        }
    }
end

local function estimateSourceRAMBytes(summary)
    if not summary then
        return 0
    end

    local fileSize = tonumber(summary.fileSizeBytes) or 0
    local positions = tonumber(summary.vertexCount) or 0
    local texcoords = tonumber(summary.texcoordCount) or 0
    local normals = tonumber(summary.normalCount) or 0
    local triangles = tonumber(summary.triangleCount) or 0

    return
        fileSize * 2
        + positions * 96
        + texcoords * 32
        + normals * 48
        + triangles * 192
end

local function estimateImportBudget(summary, options)
    local hardCap = math.max(1, math.floor(options.maxTriangles or 1))
    local budget = hardCap
    local reason = "hard-cap"

    if options.governor and options.governor.getImportBudget then
        local estimates = {
            renderVRAMBytes = options.renderVRAMBytes or 0,
            baseSceneVRAMBytes = 8192,
            perTriangleVRAMBytes = 224,
            baseSceneRAMBytes = estimateSourceRAMBytes(summary),
            perTriangleRAMBytes = 192,
        }

        budget, reason = options.governor.getImportBudget(
            options.governorState,
            hardCap,
            estimates
        )
        budget = math.min(hardCap, budget)
    end

    if summary and summary.triangleCount and summary.triangleCount > 0 then
        budget = math.min(budget, summary.triangleCount)
    end

    return math.max(0, budget), reason
end

local function buildPackedMaterialResolver(scene, result)
    local function getOrCreateMaterialIndex(name)
        name = name or "default"

        if result.materialIndexByName[name] then
            return result.materialIndexByName[name]
        end

        local m = resolveMaterial(scene, name)

        local idx = #result.materialList + 1
        result.materialIndexByName[name] = idx
        result.materialList[idx] = name
        result.materialColors[idx] = saturateColor3(m.kd, 1.0)

        return idx
    end

    local function getPackedMaterial(name, verts)
        name = name or "default"
        local m = resolveMaterial(scene, name)

        getOrCreateMaterialIndex(name)

        local albedo = saturateColor3(m.kd, 1.0)
        if verts then
            local vertexColor = { 0.0, 0.0, 0.0 }
            local vertexColorCount = 0

            for i = 1, #verts do
                local color = verts[i] and verts[i].color or nil
                if color then
                    vertexColor[1] = vertexColor[1] + clamp(color[1] or 1.0, 0.0, 1.0)
                    vertexColor[2] = vertexColor[2] + clamp(color[2] or 1.0, 0.0, 1.0)
                    vertexColor[3] = vertexColor[3] + clamp(color[3] or 1.0, 0.0, 1.0)
                    vertexColorCount = vertexColorCount + 1
                end
            end

            if vertexColorCount > 0 then
                local tint = {
                    vertexColor[1] / vertexColorCount,
                    vertexColor[2] / vertexColorCount,
                    vertexColor[3] / vertexColorCount,
                }
                albedo = multiplyColor3(albedo, tint)
            end
        end

        local emission = {
            math.max((m.ke and m.ke[1]) or 0, 0),
            math.max((m.ke and m.ke[2]) or 0, 0),
            math.max((m.ke and m.ke[3]) or 0, 0),
        }

        local specularColor = saturateColor3(m.ks, 0.0)
        local opacity = clamp(tonumber(m.d) or 1.0, 0.0, 1.0)
        local roughness = (m.hasPr and m.pr ~= nil) and clamp(m.pr, 0.0, 1.0) or nsToRoughness(m.ns)
        local transmission, transmissionColor = resolveTransmission(m, albedo, opacity)
        local metallic = (m.hasPm and m.pm ~= nil)
            and clamp(m.pm, 0.0, 1.0)
            or legacyKsToMetallic(specularColor, albedo, transmission)
        local clearcoat = (m.hasPc and m.pc ~= nil)
            and clamp(m.pc, 0.0, 1.0)
            or clamp(math.max(avg3(specularColor) - 0.08, 0.0) * (1.0 - metallic) * 0.5, 0.0, 1.0)
        local clearcoatRoughness = (m.hasPcr and m.pcr ~= nil)
            and clamp(m.pcr, 0.02, 1.0)
            or clamp(roughness * 0.5 + 0.08, 0.02, 1.0)
        local ior = clamp((m.hasNi and m.ni) or ((transmission > 0.001) and 1.5 or 1.45), 1.0, 2.8)
        local specular = (m.hasPs and m.ps ~= nil)
            and clamp(m.ps, 0.0, 1.0)
            or clamp(0.5 + avg3(specularColor) * 0.5, 0.0, 1.0)

        if transmission > 0.001 then
            metallic = 0.0
        end

        return {
            albedo = albedo,
            emission = emission,
            metallic = metallic,
            roughness = roughness,
            transmissionColor = transmissionColor,
            transmission = transmission,
            ior = ior,
            clearcoat = clearcoat,
            clearcoatRoughness = clearcoatRoughness,
            specular = specular,
        }
    end

    return getOrCreateMaterialIndex, getPackedMaterial
end

local function chooseBounds(scene, path)
    local bounds = scene.bounds
    local minv = bounds and bounds.min or nil
    local maxv = bounds and bounds.max or nil

    if minv and maxv then
        return minv, maxv
    end

    local firstPos = nil
    for _, mesh in ipairs(scene.meshes or {}) do
        if mesh.vertices and #mesh.vertices > 0 then
            firstPos = mesh.vertices[1].position
            break
        end
    end

    if not firstPos then
        return nil, nil, "Imported OBJ scene has no vertices: " .. tostring(path)
    end

    minv = { firstPos[1], firstPos[2], firstPos[3] }
    maxv = { firstPos[1], firstPos[2], firstPos[3] }

    for _, mesh in ipairs(scene.meshes or {}) do
        for i = 1, #mesh.vertices do
            local p = mesh.vertices[i].position
            minv[1] = math.min(minv[1], p[1])
            minv[2] = math.min(minv[2], p[2])
            minv[3] = math.min(minv[3], p[3])
            maxv[1] = math.max(maxv[1], p[1])
            maxv[2] = math.max(maxv[2], p[2])
            maxv[3] = math.max(maxv[3], p[3])
        end
    end

    return minv, maxv, nil
end

local function buildTriangles(scene, path, result, depthOffset)
    local minv, maxv, boundsErr = chooseBounds(scene, path)
    if boundsErr then
        return nil, nil, boundsErr
    end

    local cx = (minv[1] + maxv[1]) * 0.5
    local cy = (minv[2] + maxv[2]) * 0.5
    local cz = (minv[3] + maxv[3]) * 0.5

    local sx = maxv[1] - minv[1]
    local sy = maxv[2] - minv[2]
    local sz = maxv[3] - minv[3]
    local maxExtent = math.max(sx, math.max(sy, sz))
    local scale = maxExtent > 0 and (8.5 / maxExtent) or 1.0

    local function scaledPos(v)
        return {
            -(v[1] - cx) * scale,
            (v[2] - cy) * scale,
            -(v[3] - cz) * scale + depthOffset,
        }
    end

    local function scaledNormal(v)
        local nx = -((v and v[1]) or 0.0)
        local ny = (v and v[2]) or 0.0
        local nz = -((v and v[3]) or 0.0)
        return vec3.normalize({ nx, ny, nz })
    end

    result.bounds = transformImportedBounds(scene.bounds, cx, cy, cz, scale, depthOffset)

    local packedObjects = {}
    local packedMeshes = {}
    local triangles = {}
    local sourceObjects = getImportedSourceObjects(scene, path)
    local getOrCreateMaterialIndex, getPackedMaterial = buildPackedMaterialResolver(scene, result)

    for _, sourceObject in ipairs(sourceObjects) do
        local meshIndices = sourceObject.meshIndices or {}
        local objectIndex = #packedObjects + 1
        local objectEntry = {
            name = sourceObject.name or ("Object " .. tostring(objectIndex)),
            sourceIndex = sourceObject.objectIndex or objectIndex,
            bounds = transformImportedBounds(sourceObject.bounds or scene.bounds, cx, cy, cz, scale, depthOffset),
            meshStart = #packedMeshes + 1,
            meshCount = 0,
            triangleCount = 0,
        }

        for _, meshIndex in ipairs(meshIndices) do
            local mesh = scene.meshes[meshIndex]
            local triCount = mesh and math.floor((mesh.indices and #mesh.indices or 0) / 3) or 0

            if mesh and triCount > 0 then
                local materialName = mesh.material or "default"
                local materialIndex = getOrCreateMaterialIndex(materialName)
                local meshEntry = {
                    name = mesh.name,
                    objectIndex = objectIndex,
                    objectName = objectEntry.name,
                    groupName = mesh.groupName,
                    materialName = materialName,
                    materialIndex = materialIndex,
                    smoothingGroup = mesh.smoothingGroup,
                    bounds = transformImportedBounds(mesh.bounds, cx, cy, cz, scale, depthOffset),
                    triangleCount = triCount,
                    sourceMeshIndex = meshIndex,
                }

                for tri = 1, triCount do
                    local base = (tri - 1) * 3 + 1
                    local verts = {
                        mesh.vertices[mesh.indices[base]],
                        mesh.vertices[mesh.indices[base + 1]],
                        mesh.vertices[mesh.indices[base + 2]],
                    }
                    local packed = getPackedMaterial(materialName, verts)
                    local p0 = scaledPos(verts[1].position or { 0, 0, 0 })
                    local p1 = scaledPos(verts[2].position or { 0, 0, 0 })
                    local p2 = scaledPos(verts[3].position or { 0, 0, 0 })
                    local n0 = scaledNormal(verts[1].normal or { 0, 1, 0 })
                    local n1 = scaledNormal(verts[2].normal or { 0, 1, 0 })
                    local n2 = scaledNormal(verts[3].normal or { 0, 1, 0 })
                    local triBounds = newBounds()

                    expandBounds(triBounds, p0)
                    expandBounds(triBounds, p1)
                    expandBounds(triBounds, p2)
                    triBounds = finalizeBounds(triBounds)

                    triangles[#triangles + 1] = {
                        v0 = p0,
                        v1 = p1,
                        v2 = p2,
                        n0 = n0,
                        n1 = n1,
                        n2 = n2,
                        bounds = triBounds,
                        centroid = {
                            (p0[1] + p1[1] + p2[1]) / 3.0,
                            (p0[2] + p1[2] + p2[2]) / 3.0,
                            (p0[3] + p1[3] + p2[3]) / 3.0,
                        },
                        material = packed,
                        materialIndex = materialIndex,
                        objectIndex = objectIndex,
                        sourceMeshIndex = meshIndex,
                    }
                end

                packedMeshes[#packedMeshes + 1] = meshEntry
                objectEntry.meshCount = objectEntry.meshCount + 1
                objectEntry.triangleCount = objectEntry.triangleCount + triCount
            end
        end

        if objectEntry.meshCount > 0 then
            packedObjects[#packedObjects + 1] = objectEntry
        end
    end

    return triangles, {
        objects = packedObjects,
        meshes = packedMeshes,
        transform = {
            center = { cx, cy, cz },
            scale = scale,
        },
    }, nil
end

local function computeRangeBounds(triangles, startIndex, endIndex)
    local nodeBounds = newBounds()
    local centroidBounds = newBounds()

    for i = startIndex, endIndex do
        local tri = triangles[i]
        expandBoundsByBounds(nodeBounds, tri.bounds)
        expandBounds(centroidBounds, tri.centroid)
    end

    return finalizeBounds(nodeBounds), finalizeBounds(centroidBounds)
end

local function reorderSliceByAxis(triangles, startIndex, endIndex, axis)
    local slice = {}
    for i = startIndex, endIndex do
        slice[#slice + 1] = triangles[i]
    end

    table.sort(slice, function(a, b)
        return (a.centroid[axis] or 0) < (b.centroid[axis] or 0)
    end)

    for i = 1, #slice do
        triangles[startIndex + i - 1] = slice[i]
    end
end

local function buildBvhRecursive(triangles, startIndex, endIndex, nodes, leafTriangles)
    local nodeIndex = #nodes + 1
    nodes[nodeIndex] = false

    local nodeBounds, centroidBounds = computeRangeBounds(triangles, startIndex, endIndex)
    local triCount = endIndex - startIndex + 1

    if triCount <= leafTriangles then
        nodes[nodeIndex] = {
            bounds = nodeBounds,
            leaf = true,
            triStart = startIndex,
            triCount = triCount,
        }
        return nodeIndex
    end

    local extent = centroidBounds.size or { 0, 0, 0 }
    local axis = 1
    if extent[2] > extent[axis] then axis = 2 end
    if extent[3] > extent[axis] then axis = 3 end

    reorderSliceByAxis(triangles, startIndex, endIndex, axis)
    local mid = startIndex + math.floor(triCount * 0.5) - 1
    local left = buildBvhRecursive(triangles, startIndex, mid, nodes, leafTriangles)
    local right = buildBvhRecursive(triangles, mid + 1, endIndex, nodes, leafTriangles)

    nodes[nodeIndex] = {
        bounds = nodeBounds,
        leaf = false,
        left = left,
        right = right,
    }

    return nodeIndex
end

local function buildBvh(triangles, leafTriangles)
    local nodes = {}
    if #triangles <= 0 then
        return nodes
    end

    buildBvhRecursive(triangles, 1, #triangles, nodes, leafTriangles)
    return nodes
end

local function estimateImportedSceneVRAMBytes(triangleLayout, objectLayout, meshLayout, bvhLayout)
    local bytes = 0

    bytes = bytes + (triangleLayout.vertexWidth * triangleLayout.rows * BYTES_PER_RGBA32F_TEXEL * 2)
    bytes = bytes + (triangleLayout.materialWidth * triangleLayout.rows * BYTES_PER_RGBA32F_TEXEL * 4)
    bytes = bytes + (objectLayout.columns * objectLayout.rows * BYTES_PER_RGBA32F_TEXEL * 2)
    bytes = bytes + (meshLayout.columns * meshLayout.rows * BYTES_PER_RGBA32F_TEXEL * 3)
    bytes = bytes + (bvhLayout.columns * bvhLayout.rows * BYTES_PER_RGBA32F_TEXEL * 3)

    return bytes
end

local function fillSceneTextures(result, triangles, packed, nodes)
    local triCount = #triangles
    local textureLimit = getTextureSizeLimit()

    local triangleLayout, triangleLayoutErr = getTriangleAtlasLayout(triCount, textureLimit)
    if not triangleLayout then
        return nil, triangleLayoutErr
    end

    local objectLayout, objectLayoutErr = getLinearAtlasLayout(math.max(1, #packed.objects), textureLimit)
    if not objectLayout then
        return nil, objectLayoutErr
    end

    local meshLayout, meshLayoutErr = getLinearAtlasLayout(math.max(1, #packed.meshes), textureLimit)
    if not meshLayout then
        return nil, meshLayoutErr
    end

    local bvhLayout, bvhLayoutErr = getLinearAtlasLayout(math.max(1, #nodes), textureLimit)
    if not bvhLayout then
        return nil, bvhLayoutErr
    end

    local vertsImageData = love.image.newImageData(triangleLayout.vertexWidth, triangleLayout.rows, "rgba32f")
    local normalsImageData = love.image.newImageData(triangleLayout.vertexWidth, triangleLayout.rows, "rgba32f")
    local matAImageData = love.image.newImageData(triangleLayout.materialWidth, triangleLayout.rows, "rgba32f")
    local matBImageData = love.image.newImageData(triangleLayout.materialWidth, triangleLayout.rows, "rgba32f")
    local matCImageData = love.image.newImageData(triangleLayout.materialWidth, triangleLayout.rows, "rgba32f")
    local matDImageData = love.image.newImageData(triangleLayout.materialWidth, triangleLayout.rows, "rgba32f")
    local objectNodeAImageData = love.image.newImageData(objectLayout.columns, objectLayout.rows, "rgba32f")
    local objectNodeBImageData = love.image.newImageData(objectLayout.columns, objectLayout.rows, "rgba32f")
    local meshNodeAImageData = love.image.newImageData(meshLayout.columns, meshLayout.rows, "rgba32f")
    local meshNodeBImageData = love.image.newImageData(meshLayout.columns, meshLayout.rows, "rgba32f")
    local meshNodeCImageData = love.image.newImageData(meshLayout.columns, meshLayout.rows, "rgba32f")
    local bvhNodeAImageData = love.image.newImageData(bvhLayout.columns, bvhLayout.rows, "rgba32f")
    local bvhNodeBImageData = love.image.newImageData(bvhLayout.columns, bvhLayout.rows, "rgba32f")
    local bvhNodeCImageData = love.image.newImageData(bvhLayout.columns, bvhLayout.rows, "rgba32f")

    for triangleIndex = 1, triCount do
        local tri = triangles[triangleIndex]
        local triX, triY = getLinearAtlasCoord(triangleIndex - 1, triangleLayout.triangleColumns)

        local positions = { tri.v0, tri.v1, tri.v2 }
        local normals = { tri.n0, tri.n1, tri.n2 }
        for col = 1, 3 do
            local p = positions[col]
            local n = normals[col]
            local vertexX = triX * 3 + (col - 1)
            vertsImageData:setPixel(vertexX, triY, p[1], p[2], p[3], 1.0)
            normalsImageData:setPixel(vertexX, triY, n[1], n[2], n[3], 1.0)
        end

        local packedMaterial = tri.material
        matAImageData:setPixel(
            triX, triY,
            packedMaterial.albedo[1],
            packedMaterial.albedo[2],
            packedMaterial.albedo[3],
            packedMaterial.roughness
        )
        matBImageData:setPixel(
            triX, triY,
            packedMaterial.emission[1],
            packedMaterial.emission[2],
            packedMaterial.emission[3],
            packedMaterial.metallic
        )
        matCImageData:setPixel(
            triX, triY,
            packedMaterial.transmissionColor[1],
            packedMaterial.transmissionColor[2],
            packedMaterial.transmissionColor[3],
            packedMaterial.transmission
        )
        matDImageData:setPixel(
            triX, triY,
            packedMaterial.ior,
            packedMaterial.clearcoat,
            packedMaterial.clearcoatRoughness,
            packedMaterial.specular
        )
    end

    for objectRow, objectEntry in ipairs(packed.objects) do
        local objectX, objectY = getLinearAtlasCoord(objectRow - 1, objectLayout.columns)
        objectNodeAImageData:setPixel(
            objectX, objectY,
            objectEntry.bounds.min[1],
            objectEntry.bounds.min[2],
            objectEntry.bounds.min[3],
            objectEntry.meshStart - 1
        )
        objectNodeBImageData:setPixel(
            objectX, objectY,
            objectEntry.bounds.max[1],
            objectEntry.bounds.max[2],
            objectEntry.bounds.max[3],
            objectEntry.meshCount
        )
    end

    for meshRow, meshEntry in ipairs(packed.meshes) do
        local meshX, meshY = getLinearAtlasCoord(meshRow - 1, meshLayout.columns)
        meshNodeAImageData:setPixel(
            meshX, meshY,
            meshEntry.bounds.min[1],
            meshEntry.bounds.min[2],
            meshEntry.bounds.min[3],
            0.0
        )
        meshNodeBImageData:setPixel(
            meshX, meshY,
            meshEntry.bounds.max[1],
            meshEntry.bounds.max[2],
            meshEntry.bounds.max[3],
            meshEntry.triangleCount
        )
        meshNodeCImageData:setPixel(
            meshX, meshY,
            meshEntry.objectIndex - 1,
            meshEntry.materialIndex - 1,
            meshEntry.sourceMeshIndex - 1,
            0.0
        )
    end

    for nodeRow, node in ipairs(nodes) do
        local nodeX, nodeY = getLinearAtlasCoord(nodeRow - 1, bvhLayout.columns)
        if node.leaf then
            bvhNodeAImageData:setPixel(
                nodeX, nodeY,
                node.bounds.min[1],
                node.bounds.min[2],
                node.bounds.min[3],
                node.triStart - 1
            )
            bvhNodeBImageData:setPixel(
                nodeX, nodeY,
                node.bounds.max[1],
                node.bounds.max[2],
                node.bounds.max[3],
                node.triCount
            )
            bvhNodeCImageData:setPixel(nodeX, nodeY, 1.0, 0.0, 0.0, 0.0)
        else
            bvhNodeAImageData:setPixel(
                nodeX, nodeY,
                node.bounds.min[1],
                node.bounds.min[2],
                node.bounds.min[3],
                node.left - 1
            )
            bvhNodeBImageData:setPixel(
                nodeX, nodeY,
                node.bounds.max[1],
                node.bounds.max[2],
                node.bounds.max[3],
                node.right - 1
            )
            bvhNodeCImageData:setPixel(nodeX, nodeY, 0.0, 0.0, 0.0, 0.0)
        end
    end

    result.triangleTexSize = { triangleLayout.triangleColumns, triangleLayout.rows }
    result.objectNodeTexSize = { objectLayout.columns, objectLayout.rows }
    result.meshNodeTexSize = { meshLayout.columns, meshLayout.rows }
    result.bvhNodeTexSize = { bvhLayout.columns, bvhLayout.rows }
    result.meshTexSize = result.triangleTexSize
    result.bvhNodeCount = #nodes

    result.triangleVertsImage = createNearestFloatImage(vertsImageData)
    result.triangleNormalsImage = createNearestFloatImage(normalsImageData)
    result.triangleMatAImage = createNearestFloatImage(matAImageData)
    result.triangleMatBImage = createNearestFloatImage(matBImageData)
    result.triangleMatCImage = createNearestFloatImage(matCImageData)
    result.triangleMatDImage = createNearestFloatImage(matDImageData)
    result.objectNodeAImage = createNearestFloatImage(objectNodeAImageData)
    result.objectNodeBImage = createNearestFloatImage(objectNodeBImageData)
    result.meshNodeAImage = createNearestFloatImage(meshNodeAImageData)
    result.meshNodeBImage = createNearestFloatImage(meshNodeBImageData)
    result.meshNodeCImage = createNearestFloatImage(meshNodeCImageData)
    result.bvhNodeAImage = createNearestFloatImage(bvhNodeAImageData)
    result.bvhNodeBImage = createNearestFloatImage(bvhNodeBImageData)
    result.bvhNodeCImage = createNearestFloatImage(bvhNodeCImageData)

    result.meshVertsImage = result.triangleVertsImage
    result.meshNormalsImage = result.triangleNormalsImage
    result.meshMatAImage = result.triangleMatAImage
    result.meshMatBImage = result.triangleMatBImage
    result.meshMatCImage = result.triangleMatCImage
    result.meshMatDImage = result.triangleMatDImage

    result.estimatedVRAMBytes = estimateImportedSceneVRAMBytes(triangleLayout, objectLayout, meshLayout, bvhLayout)

    return {
        triangleLayout = triangleLayout,
        objectLayout = objectLayout,
        meshLayout = meshLayout,
        bvhLayout = bvhLayout,
    }, nil
end

function M.build(path, options)
    options = options or {}

    local hardCap = math.max(1, math.floor(options.maxTriangles or 81920))
    local result = newImportedSceneState(path, hardCap)
    local summary = objloader.inspect(path)
    result.summary = summary
    result.sourceTriCount = summary and summary.triangleCount or 0
    result.sourceFaceCount = summary and summary.faceCount or 0
    result.sourceVertexCount = summary and summary.vertexCount or 0

    local budgetedTriangles, budgetReason = estimateImportBudget(summary, {
        maxTriangles = hardCap,
        governor = options.governor,
        governorState = options.governorState,
        renderVRAMBytes = options.renderVRAMBytes or 0,
    })

    if budgetedTriangles <= 0 then
        result.loadError = "Import blocked by active RAM/VRAM budget."
        result.budgetReason = budgetReason
        result.budgetedTriangles = budgetedTriangles
        result.estimatedRAMBytes = estimateSourceRAMBytes(summary)
        return result
    end

    result.budgetedTriangles = budgetedTriangles
    result.budgetReason = budgetReason
    result.estimatedRAMBytes = estimateSourceRAMBytes(summary)

    local scene, err = objloader.load(path, {
        keepRawArrays = false,
        triangleSampleTarget = budgetedTriangles,
        sourceTriangleCount = summary and summary.triangleCount or nil,
    })

    if not scene then
        result.loadError = err or "failed to load"
        return result
    end

    if not scene.meshes or #scene.meshes == 0 then
        result.loadError = "scene is empty"
        return result
    end

    local triangles, packed, triErr = buildTriangles(
        scene,
        path,
        result,
        tonumber(options.depthOffset) or -4.0
    )

    if not triangles then
        result.loadError = triErr or "triangle extraction failed"
        return result
    end

    if #triangles <= 0 then
        result.loadError = "scene has no triangles"
        return result
    end

    if #packed.objects > (options.maxObjects or 4096) then
        result.loadError = string.format(
            "Imported OBJ rejected: objects=%d budget=%d",
            #packed.objects,
            options.maxObjects or 4096
        )
        return result
    end

    if #packed.meshes > (options.maxMeshes or 16384) then
        result.loadError = string.format(
            "Imported OBJ rejected: meshes=%d budget=%d",
            #packed.meshes,
            options.maxMeshes or 16384
        )
        return result
    end

    local leafTriangles = clampInt(options.bvhLeafTriangles or DEFAULT_BVH_LEAF_TRIANGLES, 2, 16)
    local nodes = buildBvh(triangles, leafTriangles)
    local layouts, layoutErr = fillSceneTextures(result, triangles, packed, nodes)
    if not layouts then
        result.loadError = layoutErr or "failed to build textures"
        return result
    end

    result.loaded = true
    result.importMode = ((summary and summary.triangleCount or #triangles) > #triangles) and "sampled" or "exact"
    result.triCount = #triangles
    result.objectCount = #packed.objects
    result.meshCount = #packed.meshes
    result.objects = packed.objects
    result.meshes = packed.meshes
    result.bvhLeafTriangles = leafTriangles

    print(
        "Imported OBJ loaded:",
        path,
        "source tris =", summary and summary.triangleCount or #triangles,
        "uploaded tris =", #triangles,
        "mode =", result.importMode,
        "budget =", budgetedTriangles,
        "budget reason =", budgetReason,
        "objects =", #packed.objects,
        "meshes =", #packed.meshes,
        "bvh nodes =", #nodes,
        "tri atlas =", string.format("%dx%d tris", layouts.triangleLayout.triangleColumns, layouts.triangleLayout.rows),
        "tex limit =", getTextureSizeLimit()
    )

    return result
end

function M.estimateRenderVRAMBytes(renderWidth, renderHeight)
    renderWidth = math.max(1, math.floor(renderWidth or 1))
    renderHeight = math.max(1, math.floor(renderHeight or 1))
    return renderWidth * renderHeight * BYTES_PER_RGBA16F_TEXEL * 4
end

return M
