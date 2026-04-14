local objloader = require("objloader")
local importedscene = require("imported_scene")
local governor = require("governor")
local mathutil = require("shared.mathutil")
local pathutil = require("shared.pathutil")
local vec3 = require("shared.vec3")

--[[ ╓───────────────────────────────────╖
     ║ Various Initial Tables and Values ║
     ╙───────────────────────────────────╜
]]

--#region Variables

love.window.setMode(1900, 1060, { vsync = false, resizable = true})
local width, height = love.graphics.getDimensions()

local qualityPresets = {
    [5] = { name = "Ultra", scale = 1.00, fps = 0 },
    [4] = { name = "High", scale = 0.85, fps = 144 },
    [3] = { name = "Medium", scale = 0.70, fps = 90 },
    [2] = { name = "Low", scale = 0.55, fps = 60 },
    [1] = { name = "Potato", scale = 0.40, fps = 30 },
}

local tracingModes = {
    { name = "RGB Rasterization",  shaderMode = 0, defaultBounces = 1,  defaultSteps = 32,  defaultReflections = false },
    { name = "RGB Ray Tracing",    shaderMode = 1, defaultBounces = 2,  defaultSteps = 48,  defaultReflections = true  },
    { name = "Spectral Ray Tracing", shaderMode = 2, defaultBounces = 2,  defaultSteps = 64,  defaultReflections = true  },
    { name = "Spectral Path Tracing", shaderMode = 3, defaultBounces = 20, defaultSteps = 72,  defaultReflections = true  },
    { name = "Wave Optics Rendering", shaderMode = 4, defaultBounces = 24, defaultSteps = 96,  defaultReflections = true  },
}

local fpsOptions = { 10, 30, 60, 90, 120, 144, 240, 420, 0}

local sceneNames = {
    [0] = "Studio",
    [1] = "Showcase",
    [2] = "House of Mirrors",
    [3] = "Imported Objects",
}

local limits = {
    renderScale = { min = 0.05, max = 4.00, step = 0.05, fastStep = 0.25 },
    bounces     = { min = 1, max = 1000, step = 1, fastStep = 100 },
    steps       = { min = 8, max = 1000, step = 8, fastStep = 100 },
    scene       = { min = 0, max = 3, step = 1, fastStep = 1 },
}

local defaults = {
    qualityIndex = 3,
    tracingModeIndex = 4,
    camera = {
        pos   = { 3, 1.5, 3 },
        yaw   = 3.9465926535898,
        pitch = -0.155,
        fov   = math.pi / 3,
    }
}

local IMPORTED_TRIANGLE_HARD_CAP = 81920
local IMPORTED_OBJECT_HARD_CAP = 4096
local IMPORTED_MESH_HARD_CAP = 16384
local IMPORTED_SCENE_DEPTH_OFFSET = -4.0

local importedScene = {
    path = "",
    maxTriangles = IMPORTED_TRIANGLE_HARD_CAP,
    loaded = false,
    importMode = "none",
    budgetReason = "hard-cap",
    budgetedTriangles = IMPORTED_TRIANGLE_HARD_CAP,
    triCount = 0,
    sourceTriCount = 0,
    objectCount = 0,
    meshCount = 0,
    sourceScene = nil,
    bounds = nil,
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

    -- kept for compatibility with any UI/debug code still touching them
    meshUVImage = nil,
    meshMatIdImage = nil,

    meshTexSize = { 1, 1 },
    triangleTexSize = { 1, 1 },
    objectNodeTexSize = { 1, 1 },
    meshNodeTexSize = { 1, 1 },
    bvhNodeTexSize = { 1, 1 },
    bvhNodeCount = 0,
    bvhLeafTriangles = 8,
    materialIndexByName = {},
    materialList = {},
    materialTextures = {},
    materialColors = {},
}

local modelBrowser = {
    folder = "objects",
    files = {},
    selectedIndex = 1,
}

local qualityIndex = defaults.qualityIndex
local renderScale = qualityPresets[qualityIndex].scale
local fpsTarget = qualityPresets[qualityIndex].fps
local runtimeGovernor = governor.new({
    requestedRenderScale = renderScale,
})

local tracerSettings = {
    tracingModeIndex = defaults.tracingModeIndex,
    tracingMode = tracingModes[defaults.tracingModeIndex].shaderMode,
    maxBounces = tracingModes[defaults.tracingModeIndex].defaultBounces,
    maxSteps = tracingModes[defaults.tracingModeIndex].defaultSteps,
    shadows = true,
    reflections = tracingModes[defaults.tracingModeIndex].defaultReflections,
    sceneVariant = 0,
}

local renderWidth = math.max(1, math.floor(width * renderScale))
local renderHeight = math.max(1, math.floor(height * renderScale))

local accumA, accumB, accumSrc, accumDst
local shader
local currentFrame = 0
local keysDown = {}
local fallbackFloatImage

local enableMouse = true
local isPaused = false
local captureInput = true
local menuIndex = 1
local hoveredMenuIndex = 0
local menuRows = {}
local menuPositionsX = {}
local menuPositionsY = {}
local menuItemCallbacks = {}
local lastMenuLayout = nil
local loadSelectedModel
local pausePageIndex = 2
local pauseTabs = {}
local dropdownState = {
    open = false,
    menuIndex = 0,
    options = {},
    x = 0,
    y = 0,
    w = 0,
    rowH = 30,
    hoveredOption = 0,
    scrollIndex = 1,
    visibleCount = 0,
    maxVisible = 8,
}

local uiState = {
    showHud = true,
    compactHud = false,
}

local camera = {
    pos   = { defaults.camera.pos[1], defaults.camera.pos[2], defaults.camera.pos[3] },
    yaw   = defaults.camera.yaw,
    pitch = defaults.camera.pitch,
    fov   = defaults.camera.fov,
}

local fontSmall
local fontBody
local fontTitle

--#endregion

--[[╓───────────────────────────────────╖
--  ║ Globally Helpful Helper Functions ║
--  ╙───────────────────────────────────╜
]]

--#region Helpers


local clamp = mathutil.clamp
local clampInt = mathutil.clampInt
local formatBool = mathutil.formatBool
local boolToInt = mathutil.boolToInt

local function formatMiB(bytes)
    return string.format("%.1f MiB", mathutil.bytesToMiB(bytes))
end

--#endregion

--[[╓───────────────────────────────────╖
--  ║ Vector3 Math and Components       ║
--  ╙───────────────────────────────────╜
]]

--#region Vec3

local add = vec3.add
local sub = vec3.sub
local mul = vec3.mul
local dot = vec3.dot

local function norm(v)
    local out = vec3.normalize(v)
    if dot(v, v) <= 0.000001 then
        return { 0, 0, 0 }
    end
    return out
end

local copyVec3 = vec3.copy

local function atan2(y, x)
---@diagnostic disable: deprecated
    if math.atan2 then
        return math.atan2(y, x)
    end
---@diagnostic enable: deprecated
    return math.atan(y, x)
end

local function lookCameraAt(target)
    local dx = target[1] - camera.pos[1]
    local dy = target[2] - camera.pos[2]
    local dz = target[3] - camera.pos[3]
    local planar = math.max(0.0001, math.sqrt(dx * dx + dz * dz))

    camera.yaw = atan2(dx, dz)
    camera.pitch = atan2(dy, planar)
end

--#endregion

--[[╓───────────────────────────────────╖
--  ║ Render Accumulation Management    ║
--  ╙───────────────────────────────────╜
]]

--#region Render Accumulation

local function swapAccum()
    accumSrc, accumDst = accumDst, accumSrc
end

local function clearCanvas(canvas, r, g, b, a)
    if not canvas then
        return
    end

    canvas:renderTo(function()
        love.graphics.clear(r, g, b, a)
    end)
end

local function clearAccumHistory()
    clearCanvas(accumA, 0, 0, 0, 1)
    clearCanvas(accumB, 0, 0, 0, 1)
end

local function clearAll()
    clearAccumHistory()
end

local function configureCanvas(canvas, minFilter, magFilter)
    canvas:setFilter(minFilter, magFilter)
    canvas:setWrap("clamp", "clamp")
    return canvas
end

local function resetAccum()
    currentFrame = 0
    clearAccumHistory()
end

local function rebuildAccum()
    renderWidth = math.max(1, math.floor(width * renderScale))
    renderHeight = math.max(1, math.floor(height * renderScale))

    accumA = configureCanvas(love.graphics.newCanvas(renderWidth, renderHeight, { format = "rgba16f" }), "linear", "linear")

    accumB = configureCanvas(love.graphics.newCanvas(renderWidth, renderHeight, { format = "rgba16f" }), "linear", "linear")

    accumSrc = accumA
    accumDst = accumB

    clearAll()
    currentFrame = 0
    governor.updateRenderVRAMEstimate(runtimeGovernor, renderWidth, renderHeight)
end

local function applyPreset(index)
    qualityIndex = clampInt(index, 1, #qualityPresets)
    renderScale = qualityPresets[qualityIndex].scale
    fpsTarget = qualityPresets[qualityIndex].fps
    governor.setRequestedRenderScale(runtimeGovernor, renderScale, limits.renderScale)
    rebuildAccum()
end

local function applyTracingMode(index)
    tracerSettings.tracingModeIndex = clampInt(index, 1, #tracingModes)
    local mode = tracingModes[tracerSettings.tracingModeIndex]
    tracerSettings.tracingMode = mode.shaderMode
    tracerSettings.maxBounces = mode.defaultBounces
    tracerSettings.maxSteps = mode.defaultSteps
    tracerSettings.reflections = mode.defaultReflections
    resetAccum()
end

local function restoreDefaults()
    qualityIndex = defaults.qualityIndex
    renderScale = qualityPresets[qualityIndex].scale
    fpsTarget = qualityPresets[qualityIndex].fps
    runtimeGovernor = governor.new({
        requestedRenderScale = renderScale,
    })

    tracerSettings.tracingModeIndex = defaults.tracingModeIndex
    tracerSettings.tracingMode = tracingModes[defaults.tracingModeIndex].shaderMode
    tracerSettings.maxBounces = tracingModes[defaults.tracingModeIndex].defaultBounces
    tracerSettings.maxSteps = tracingModes[defaults.tracingModeIndex].defaultSteps
    tracerSettings.shadows = true
    tracerSettings.reflections = tracingModes[defaults.tracingModeIndex].defaultReflections
    tracerSettings.sceneVariant = 0

    camera.pos = copyVec3(defaults.camera.pos)
    camera.yaw = defaults.camera.yaw
    camera.pitch = defaults.camera.pitch
    camera.fov = defaults.camera.fov

    rebuildAccum()
    governor.updateSceneEstimates(runtimeGovernor, importedScene)
end

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ Path and File Helpers             ║
     ╙───────────────────────────────────╜
]]

--#region Path and File Helpers

local ceilDiv = mathutil.ceilDiv
local normalizePath = pathutil.normalize
local basename = pathutil.basename

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ Imported OBJ Scene Management     ║
     ╙───────────────────────────────────╜
]]

--#region Imported OBJ Scene Management

local function scanObjectsFolder()
    modelBrowser.files = objloader.listModels(modelBrowser.folder)
    if #modelBrowser.files == 0 then
        modelBrowser.selectedIndex = 1
    else
        modelBrowser.selectedIndex = clampInt(modelBrowser.selectedIndex, 1, #modelBrowser.files)
    end
end

local function getSelectedModelPath()
    if #modelBrowser.files == 0 then
        return nil
    end
    return modelBrowser.files[modelBrowser.selectedIndex]
end

local function newImportedSceneState(path, maxTriangles)
    return {
        path = path or "",
        maxTriangles = maxTriangles or IMPORTED_TRIANGLE_HARD_CAP,
        loaded = false,
        importMode = "none",
        budgetReason = "hard-cap",
        budgetedTriangles = maxTriangles or IMPORTED_TRIANGLE_HARD_CAP,
        triCount = 0,
        sourceTriCount = 0,
        objectCount = 0,
        meshCount = 0,
        sourceScene = nil,
        bounds = nil,
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
        bvhLeafTriangles = 8,
        materialIndexByName = {},
        materialList = {},
        materialTextures = {},
        materialColors = {},
    }
end

local function transformImportedBounds(bounds, cx, cy, cz, scale)
    if not bounds or not bounds.min or not bounds.max then
        return {
            min = { 0, 0, 0 },
            max = { 0, 0, 0 },
            size = { 0, 0, 0 },
            center = { 0, 0, 0 },
        }
    end

    local transformed = {
        min = { math.huge, math.huge, math.huge },
        max = { -math.huge, -math.huge, -math.huge },
    }

    local function addCorner(px, py, pz)
        px = -(px - cx) * scale
        py =  (py - cy) * scale
        pz = -(pz - cz) * scale + IMPORTED_SCENE_DEPTH_OFFSET

        transformed.min[1] = math.min(transformed.min[1], px)
        transformed.min[2] = math.min(transformed.min[2], py)
        transformed.min[3] = math.min(transformed.min[3], pz)
        transformed.max[1] = math.max(transformed.max[1], px)
        transformed.max[2] = math.max(transformed.max[2], py)
        transformed.max[3] = math.max(transformed.max[3], pz)
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

    return {
        min = transformed.min,
        max = transformed.max,
        size = {
            transformed.max[1] - transformed.min[1],
            transformed.max[2] - transformed.min[2],
            transformed.max[3] - transformed.min[3],
        },
        center = {
            (transformed.min[1] + transformed.max[1]) * 0.5,
            (transformed.min[2] + transformed.max[2]) * 0.5,
            (transformed.min[3] + transformed.max[3]) * 0.5,
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

local function getFallbackFloatImage()
    if fallbackFloatImage then
        return fallbackFloatImage
    end

    local imageData = love.image.newImageData(1, 1, "rgba32f")
    imageData:setPixel(0, 0, 0.0, 0.0, 0.0, 0.0)
    fallbackFloatImage = createNearestFloatImage(imageData)
    return fallbackFloatImage
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
            name = basename(path),
            meshIndices = meshIndices,
            bounds = scene.bounds,
            triangleCount = scene.totalTriangles or 0,
        }
    }
end

local function buildImportedScene(path, maxTriangles)
    maxTriangles = clampInt(maxTriangles or IMPORTED_TRIANGLE_HARD_CAP, 1, IMPORTED_TRIANGLE_HARD_CAP)

    return importedscene.build(path, {
        maxTriangles = maxTriangles,
        maxObjects = IMPORTED_OBJECT_HARD_CAP,
        maxMeshes = IMPORTED_MESH_HARD_CAP,
        depthOffset = IMPORTED_SCENE_DEPTH_OFFSET,
        governor = governor,
        governorState = runtimeGovernor,
        renderVRAMBytes = runtimeGovernor.estimatedRenderVRAMBytes or 0,
    })
end

local function sendImportedSceneUniforms()
    local fallback = getFallbackFloatImage()

    shader:send("uMeshTriCount", importedScene.triCount or 0)
    shader:send("uImportedObjectCount", importedScene.objectCount or 0)
    shader:send("uImportedMeshCount", importedScene.meshCount or 0)
    shader:send("uMeshTexSize", importedScene.triangleTexSize or importedScene.meshTexSize or { 1, 1 })
    shader:send("uObjectNodeTexSize", importedScene.objectNodeTexSize or { 1, 1 })
    shader:send("uMeshNodeTexSize", importedScene.meshNodeTexSize or { 1, 1 })
    shader:send("uImportedBvhNodeCount", importedScene.bvhNodeCount or 0)
    shader:send("uImportedBvhTexSize", importedScene.bvhNodeTexSize or { 1, 1 })

    shader:send("meshVerts", importedScene.triangleVertsImage or importedScene.meshVertsImage or fallback)
    shader:send("meshNormals", importedScene.triangleNormalsImage or importedScene.meshNormalsImage or fallback)
    shader:send("meshMatA", importedScene.triangleMatAImage or importedScene.meshMatAImage or fallback)
    shader:send("meshMatB", importedScene.triangleMatBImage or importedScene.meshMatBImage or fallback)
    shader:send("meshMatC", importedScene.triangleMatCImage or importedScene.meshMatCImage or fallback)
    shader:send("meshMatD", importedScene.triangleMatDImage or importedScene.meshMatDImage or fallback)
    shader:send("objectNodeA", importedScene.objectNodeAImage or fallback)
    shader:send("objectNodeB", importedScene.objectNodeBImage or fallback)
    shader:send("meshNodeA", importedScene.meshNodeAImage or fallback)
    shader:send("meshNodeB", importedScene.meshNodeBImage or fallback)
    shader:send("meshNodeC", importedScene.meshNodeCImage or fallback)
    shader:send("importedBvhNodeA", importedScene.bvhNodeAImage or fallback)
    shader:send("importedBvhNodeB", importedScene.bvhNodeBImage or fallback)
    shader:send("importedBvhNodeC", importedScene.bvhNodeCImage or fallback)
end

local function sendFrameUniforms(passType, historyTex, cacheTex, overrides)
    overrides = overrides or {}

    shader:send("uPassType", passType)
    shader:send("iFrame", overrides.frameIndex or currentFrame)
    shader:send("iResolution", { renderWidth, renderHeight })
    shader:send("camPos", camera.pos)
    shader:send("yaw", camera.yaw)
    shader:send("pitch", camera.pitch)
    shader:send("camFov", camera.fov)
    shader:send("tex", historyTex or getFallbackFloatImage())

    shader:send("uMaxBounces", overrides.maxBounces or tracerSettings.maxBounces)
    shader:send("uMaxSteps", overrides.maxSteps or tracerSettings.maxSteps)
    shader:send("uEnableShadows", boolToInt(tracerSettings.shadows))
    shader:send("uEnableReflections", boolToInt(overrides.enableReflections ~= nil and overrides.enableReflections or tracerSettings.reflections))
    shader:send("uSceneVariant", tracerSettings.sceneVariant)
    shader:send("uTracingMode", overrides.tracingMode or tracerSettings.tracingMode or 3)

    sendImportedSceneUniforms()
end

loadSelectedModel = function()
    local path = getSelectedModelPath()
    local maxTriangles = (importedScene and importedScene.maxTriangles) or IMPORTED_TRIANGLE_HARD_CAP

    if not path then
        importedScene = newImportedSceneState("objects", maxTriangles)
        governor.updateSceneEstimates(runtimeGovernor, importedScene)
        print("No OBJ files found in objects/")
        return
    end

    importedScene = buildImportedScene(path, maxTriangles)
    governor.updateSceneEstimates(runtimeGovernor, importedScene)
    print("Selected runtime model:", path)
end

local function focusImportedScene()
    tracerSettings.sceneVariant = 3
    local bounds = importedScene and importedScene.bounds or nil
    local center = bounds and bounds.center or { 0.0, 1.2, -4.0 }
    local size = bounds and bounds.size or { 7.0, 3.5, 1.0 }

    local radius = math.max(
        1.5,
        0.5 * math.sqrt(size[1] * size[1] + size[2] * size[2] + size[3] * size[3])
    )
    local halfFov = math.max(0.18, camera.fov * 0.5)
    local distance = radius / math.tan(halfFov)
    distance = distance + radius * 0.85

    camera.pos = {
        center[1],
        center[2] + size[2] * 0.08,
        center[3] + distance,
    }
    lookCameraAt(center)
end

local function cycleSelectedModel(delta)
    if #modelBrowser.files == 0 then
        scanObjectsFolder()
        if #modelBrowser.files == 0 then
            return
        end
    end

    modelBrowser.selectedIndex = modelBrowser.selectedIndex + delta
    if modelBrowser.selectedIndex < 1 then
        modelBrowser.selectedIndex = #modelBrowser.files
    elseif modelBrowser.selectedIndex > #modelBrowser.files then
        modelBrowser.selectedIndex = 1
    end

    loadSelectedModel()
    focusImportedScene()
    resetAccum()
end

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ Input Capture and Pause State     ║
     ╙───────────────────────────────────╜
]]

--#region Input Capture and Pause State

local closeDropdown
local setPausePage
local pausePages

local function setInputCapture(captured)
    captureInput = captured
    enableMouse = captured and not isPaused
    love.mouse.setRelativeMode(captured and not isPaused)
end

local function toggleInputCapture()
    setInputCapture(not captureInput)
end

local function openPauseMenu()
    isPaused = true
    enableMouse = false
    love.mouse.setRelativeMode(false)
    closeDropdown()
    setPausePage(clampInt(pausePageIndex, 1, #pausePages))
end

local function closePauseMenu()
    isPaused = false
    enableMouse = true
    hoveredMenuIndex = 0
    closeDropdown()
    love.mouse.setRelativeMode(true)
end

local function cycleFPS(delta)
    local currentIdx = 1
    for i = 1, #fpsOptions do
        if fpsOptions[i] == fpsTarget then
            currentIdx = i
            break
        end
    end
    currentIdx = clampInt(currentIdx + delta, 1, #fpsOptions)
    fpsTarget = fpsOptions[currentIdx]
end

local function reloadImportedSceneBudget()
    local hadPath = importedScene and importedScene.path and importedScene.path ~= ""
    if hadPath or #modelBrowser.files > 0 then
        loadSelectedModel()
        resetAccum()
    end
end

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ Pause Menu Definitions            ║
     ╙───────────────────────────────────╜
]]

--#region Pause Menu Definitions

local menuDefinitions = {}

local menuOrder = {}
local isInteractiveMenuIndex

pausePages = {
    { sectionId = "section_render", title = "Render" },
    { sectionId = "section_import", title = "Import" },
    { sectionId = "section_governor", title = "Governor" },
}

local function registerMenuItem(def)
    menuDefinitions[def.id] = def
    menuOrder[#menuOrder + 1] = def.id
end

local function getMenuDefByIndex(index)
    local id = menuOrder[index]
    return id and menuDefinitions[id] or nil
end

local function getPageStartIndex(pageIndex)
    local page = pausePages[pageIndex]
    if not page then
        return 1
    end

    for i = 1, #menuOrder do
        if menuOrder[i] == page.sectionId then
            return i
        end
    end

    return 1
end

local function getVisibleMenuIndices()
    local startIndex = getPageStartIndex(pausePageIndex)
    local endIndex = #menuOrder

    for nextPage = pausePageIndex + 1, #pausePages do
        local nextStart = getPageStartIndex(nextPage)
        if nextStart > startIndex then
            endIndex = nextStart - 1
            break
        end
    end

    local indices = {}
    for i = startIndex, endIndex do
        indices[#indices + 1] = i
    end
    return indices
end

closeDropdown = function()
    dropdownState.open = false
    dropdownState.menuIndex = 0
    dropdownState.options = {}
    dropdownState.hoveredOption = 0
    dropdownState.scrollIndex = 1
    dropdownState.visibleCount = 0
end

setPausePage = function(index)
    pausePageIndex = clampInt(index, 1, #pausePages)
    closeDropdown()

    local visible = getVisibleMenuIndices()
    for i = 1, #visible do
        if isInteractiveMenuIndex(visible[i]) then
            menuIndex = visible[i]
            return
        end
    end

    menuIndex = visible[1] or 1
end

local function buildMenuChoices(def)
    if not def or not def.choices then
        return {}
    end

    local options = def.choices()
    if not options then
        return {}
    end

    return options
end

local function clampDropdownState()
    local optionCount = #dropdownState.options
    if optionCount <= 0 then
        dropdownState.hoveredOption = 0
        dropdownState.scrollIndex = 1
        dropdownState.visibleCount = 0
        return
    end

    local maxVisible = math.max(1, dropdownState.maxVisible or 8)
    local visibleCount = math.min(optionCount, maxVisible)
    local maxScroll = math.max(1, optionCount - visibleCount + 1)

    dropdownState.hoveredOption = clampInt(dropdownState.hoveredOption, 1, optionCount)
    dropdownState.scrollIndex = clampInt(dropdownState.scrollIndex, 1, maxScroll)

    if dropdownState.hoveredOption < dropdownState.scrollIndex then
        dropdownState.scrollIndex = dropdownState.hoveredOption
    elseif dropdownState.hoveredOption >= (dropdownState.scrollIndex + visibleCount) then
        dropdownState.scrollIndex = dropdownState.hoveredOption - visibleCount + 1
    end

    dropdownState.visibleCount = visibleCount
end

local function openDropdownForIndex(index)
    local def = getMenuDefByIndex(index)
    if not def or not def.choices then
        return
    end

    local options = buildMenuChoices(def)
    if #options == 0 then
        return
    end

    dropdownState.open = true
    dropdownState.menuIndex = index
    dropdownState.options = options
    dropdownState.hoveredOption = def.getChoiceIndex and def.getChoiceIndex() or 1
    dropdownState.scrollIndex = math.max(1, dropdownState.hoveredOption - math.floor((dropdownState.maxVisible or 8) * 0.5))
    clampDropdownState()
end

local function chooseDropdownOption(optionIndex)
    local def = getMenuDefByIndex(dropdownState.menuIndex)
    if not def or not def.setChoiceIndex then
        closeDropdown()
        return
    end

    def.setChoiceIndex(optionIndex)
    closeDropdown()
end

local function stepDropdownHover(delta)
    if not dropdownState.open or delta == 0 or #dropdownState.options == 0 then
        return
    end

    dropdownState.hoveredOption = clampInt(
        dropdownState.hoveredOption + delta,
        1,
        #dropdownState.options
    )
    clampDropdownState()
end

local function getMenuLabelAndValue(index)
    local def = getMenuDefByIndex(index)
    if not def then
        return "", "", false
    end

    if def.kind == "section" then
        return def.title or "", "", true
    end

    local label = def.label and def.label() or (def.title or def.id or "")
    local value = def.value and def.value() or ""
    return label, value, false
end

local function adjustMenuIndex(index, delta)
    local def = getMenuDefByIndex(index)
    if not def or not def.adjust or delta == 0 or def.kind == "section" then
        if def and def.kind ~= "section" and def.choices and def.getChoiceIndex and def.setChoiceIndex and delta ~= 0 then
            local choiceCount = #buildMenuChoices(def)
            local nextIndex = clampInt(def.getChoiceIndex() + delta, 1, math.max(1, choiceCount))
            def.setChoiceIndex(nextIndex)
            closeDropdown()
        end
        return
    end
    def.adjust(delta)
    closeDropdown()
end

local function activateMenuIndex(index)
    local def = getMenuDefByIndex(index)
    if not def or not def.activate or def.kind == "section" then
        if def and def.kind ~= "section" and def.choices then
            if dropdownState.open and dropdownState.menuIndex == index then
                closeDropdown()
            else
                openDropdownForIndex(index)
            end
        end
        return
    end
    if def.choices then
        if dropdownState.open and dropdownState.menuIndex == index then
            closeDropdown()
        else
            openDropdownForIndex(index)
        end
        return
    end
    def.activate()
    closeDropdown()
end

isInteractiveMenuIndex = function(index)
    local def = getMenuDefByIndex(index)
    return def and def.kind ~= "section"
end

local function stepMenuSelection(delta)
    local visible = getVisibleMenuIndices()
    if #visible == 0 then
        return
    end

    local start = menuIndex
    local i = start

    repeat
        i = i + delta
        local minVisible = visible[1]
        local maxVisible = visible[#visible]
        if i < minVisible then i = maxVisible end
        if i > maxVisible then i = minVisible end
        if isInteractiveMenuIndex(i) then
            menuIndex = i
            closeDropdown()
            return
        end
    until i == start
end

--#region Render Menu Items

registerMenuItem({
    id = "section_render",
    kind = "section",
    title = "Render",
})

registerMenuItem({
    id = "resume",
    label = function()
        return "Resume"
    end,
    value = function()
        return "Return to scene"
    end,
    activate = function()
        closePauseMenu()
    end,
})

registerMenuItem({
    id = "reset_defaults",
    label = function()
        return "Reset Defaults"
    end,
    value = function()
        return "Restore camera and settings"
    end,
    activate = function()
        restoreDefaults()
    end,
})

registerMenuItem({
    id = "quality",
    label = function()
        return "Preset Quality"
    end,
    value = function()
        return qualityPresets[qualityIndex].name
    end,
    choices = function()
        local choices = {}
        for i = 1, #qualityPresets do
            choices[i] = qualityPresets[i].name
        end
        return choices
    end,
    getChoiceIndex = function()
        return qualityIndex
    end,
    setChoiceIndex = function(index)
        applyPreset(index)
    end,
    adjust = function(delta)
        applyPreset(qualityIndex + delta)
    end,
})

registerMenuItem({
    id = "scale",
    label = function()
        return "Render Scale"
    end,
    value = function()
        return string.format("%.2f", renderScale)
    end,
    adjust = function(delta)
        local step = (math.abs(delta) >= 10) and limits.renderScale.fastStep or limits.renderScale.step
        renderScale = clamp(renderScale + delta * step, limits.renderScale.min, limits.renderScale.max)
        governor.setRequestedRenderScale(runtimeGovernor, renderScale, limits.renderScale)
        rebuildAccum()
    end,
})

registerMenuItem({
    id = "fps",
    label = function()
        return "FPS Target"
    end,
    value = function()
        return fpsTarget == 0 and "Uncapped" or tostring(fpsTarget)
    end,
    choices = function()
        local choices = {}
        for i = 1, #fpsOptions do
            choices[i] = fpsOptions[i] == 0 and "Uncapped" or tostring(fpsOptions[i])
        end
        return choices
    end,
    getChoiceIndex = function()
        for i = 1, #fpsOptions do
            if fpsOptions[i] == fpsTarget then
                return i
            end
        end
        return 1
    end,
    setChoiceIndex = function(index)
        fpsTarget = fpsOptions[clampInt(index, 1, #fpsOptions)]
    end,
    adjust = function(delta)
        cycleFPS(delta)
    end,
})

registerMenuItem({
    id = "tracing_mode",
    label = function()
        return "Tracing Mode"
    end,
    value = function()
        return tracingModes[tracerSettings.tracingModeIndex].name
    end,
    choices = function()
        local choices = {}
        for i = 1, #tracingModes do
            choices[i] = tracingModes[i].name
        end
        return choices
    end,
    getChoiceIndex = function()
        return tracerSettings.tracingModeIndex
    end,
    setChoiceIndex = function(index)
        applyTracingMode(index)
    end,
    adjust = function(delta)
        applyTracingMode(tracerSettings.tracingModeIndex + delta)
    end,
})

registerMenuItem({
    id = "scene",
    label = function()
        return "Scene Variant"
    end,
    value = function()
        return sceneNames[tracerSettings.sceneVariant] or ("Scene " .. tostring(tracerSettings.sceneVariant))
    end,
    choices = function()
        local choices = {}
        for i = limits.scene.min, limits.scene.max do
            choices[#choices + 1] = sceneNames[i] or ("Scene " .. tostring(i))
        end
        return choices
    end,
    getChoiceIndex = function()
        return tracerSettings.sceneVariant - limits.scene.min + 1
    end,
    setChoiceIndex = function(index)
        tracerSettings.sceneVariant = clampInt(
            limits.scene.min + (index - 1),
            limits.scene.min,
            limits.scene.max
        )
        if tracerSettings.sceneVariant == 3 then
            focusImportedScene()
        end
        resetAccum()
    end,
    adjust = function(delta)
        local step = (math.abs(delta) >= 10) and limits.scene.fastStep or limits.scene.step
        tracerSettings.sceneVariant = clampInt(
            tracerSettings.sceneVariant + delta * step,
            limits.scene.min,
            limits.scene.max
        )

        if tracerSettings.sceneVariant == 3 then
            focusImportedScene()
        end

        resetAccum()
    end,
})

registerMenuItem({
    id = "bounces",
    label = function()
        return "Max Bounces"
    end,
    value = function()
        return tostring(tracerSettings.maxBounces)
    end,
    adjust = function(delta)
        local step = (math.abs(delta) >= 10) and limits.bounces.fastStep or limits.bounces.step
        tracerSettings.maxBounces = clampInt(
            tracerSettings.maxBounces + delta * step,
            limits.bounces.min,
            limits.bounces.max
        )
        resetAccum()
    end,
})

registerMenuItem({
    id = "steps",
    label = function()
        return "Max March Steps"
    end,
    value = function()
        return tostring(tracerSettings.maxSteps)
    end,
    adjust = function(delta)
        local step = (math.abs(delta) >= 10) and limits.steps.fastStep or limits.steps.step
        tracerSettings.maxSteps = clampInt(
            tracerSettings.maxSteps + delta * step,
            limits.steps.min,
            limits.steps.max
        )
        resetAccum()
    end,
})

registerMenuItem({
    id = "shadows",
    label = function()
        return "Shadows"
    end,
    value = function()
        return formatBool(tracerSettings.shadows)
    end,
    adjust = function(delta)
        if delta ~= 0 then
            tracerSettings.shadows = not tracerSettings.shadows
            resetAccum()
        end
    end,
    activate = function()
        tracerSettings.shadows = not tracerSettings.shadows
        resetAccum()
    end,
})

registerMenuItem({
    id = "reflections",
    label = function()
        return "Reflections"
    end,
    value = function()
        return formatBool(tracerSettings.reflections)
    end,
    adjust = function(delta)
        if delta ~= 0 then
            tracerSettings.reflections = not tracerSettings.reflections
            resetAccum()
        end
    end,
    activate = function()
        tracerSettings.reflections = not tracerSettings.reflections
        resetAccum()
    end,
})

registerMenuItem({
    id = "quit",
    label = function()
        return "Quit"
    end,
    value = function()
        return "Exit application"
    end,
    activate = function()
        love.event.quit()
    end,
})

registerMenuItem({
    id = "section_import",
    kind = "section",
    title = "Import",
})

registerMenuItem({
    id = "resume",
    label = function()
        return "Resume"
    end,
    value = function()
        return "Return to scene"
    end,
    activate = function()
        closePauseMenu()
    end,
})

registerMenuItem({
    id = "reset_defaults",
    label = function()
        return "Reset Defaults"
    end,
    value = function()
        return "Restore camera and settings"
    end,
    activate = function()
        restoreDefaults()
    end,
})

registerMenuItem({
    id = "runtime_model",
    label = function()
        return "Runtime Model"
    end,
    value = function()
        local selected = getSelectedModelPath()
        return selected and basename(selected) or "No OBJ files found"
    end,
    choices = function()
        local choices = {}
        for i = 1, #modelBrowser.files do
            choices[i] = basename(modelBrowser.files[i])
        end
        return choices
    end,
    getChoiceIndex = function()
        return clampInt(modelBrowser.selectedIndex, 1, math.max(1, #modelBrowser.files))
    end,
    setChoiceIndex = function(index)
        if #modelBrowser.files == 0 then
            return
        end
        modelBrowser.selectedIndex = clampInt(index, 1, #modelBrowser.files)
        loadSelectedModel()
        focusImportedScene()
        resetAccum()
    end,
    adjust = function(delta)
        if delta > 0 then
            cycleSelectedModel(1)
        elseif delta < 0 then
            cycleSelectedModel(-1)
        end
    end,
    activate = function()
        scanObjectsFolder()
        loadSelectedModel()
        focusImportedScene()
        resetAccum()
    end,
})

registerMenuItem({
    id = "refresh_models",
    label = function()
        return "Refresh Models"
    end,
    value = function()
        return tostring(#modelBrowser.files) .. " found"
    end,
    activate = function()
        scanObjectsFolder()
        loadSelectedModel()
        resetAccum()
    end,
})

registerMenuItem({
    id = "quit",
    label = function()
        return "Quit"
    end,
    value = function()
        return "Exit application"
    end,
    activate = function()
        love.event.quit()
    end,
})

--#endregion

--#region Governor Menu Items

registerMenuItem({
    id = "section_governor",
    kind = "section",
    title = "Governor",
})

registerMenuItem({
    id = "resume",
    label = function()
        return "Resume"
    end,
    value = function()
        return "Return to scene"
    end,
    activate = function()
        closePauseMenu()
    end,
})

registerMenuItem({
    id = "reset_defaults",
    label = function()
        return "Reset Defaults"
    end,
    value = function()
        return "Restore camera and settings"
    end,
    activate = function()
        restoreDefaults()
    end,
})

registerMenuItem({
    id = "governor_enabled",
    label = function()
        return "Adaptive Governor"
    end,
    value = function()
        return formatBool(runtimeGovernor.enabled)
    end,
    adjust = function(delta)
        if delta ~= 0 then
            runtimeGovernor.enabled = not runtimeGovernor.enabled
        end
    end,
    activate = function()
        runtimeGovernor.enabled = not runtimeGovernor.enabled
    end,
})

registerMenuItem({
    id = "governor_min_fps",
    label = function()
        return "Minimum FPS"
    end,
    value = function()
        return tostring(runtimeGovernor.minimumFPS)
    end,
    adjust = function(delta)
        governor.adjustMinimumFPS(runtimeGovernor, delta)
    end,
})

registerMenuItem({
    id = "governor_frame_budget",
    label = function()
        return "Max Seconds/Frame"
    end,
    value = function()
        return string.format("%.3f", runtimeGovernor.maxSecondsPerFrame or 0)
    end,
    adjust = function(delta)
        governor.adjustMaxSecondsPerFrame(runtimeGovernor, delta)
    end,
})

registerMenuItem({
    id = "governor_dummy_on_move",
    label = function()
        return "Dummy Render On Move"
    end,
    value = function()
        return formatBool(runtimeGovernor.dummyRenderOnMove)
    end,
    adjust = function(delta)
        if delta ~= 0 then
            runtimeGovernor.dummyRenderOnMove = not runtimeGovernor.dummyRenderOnMove
        end
    end,
    activate = function()
        runtimeGovernor.dummyRenderOnMove = not runtimeGovernor.dummyRenderOnMove
    end,
})

registerMenuItem({
    id = "governor_limit_ram",
    label = function()
        return "Limit RAM"
    end,
    value = function()
        return formatBool(runtimeGovernor.limitRAM)
    end,
    adjust = function(delta)
        if delta ~= 0 then
            runtimeGovernor.limitRAM = not runtimeGovernor.limitRAM
            reloadImportedSceneBudget()
        end
    end,
    activate = function()
        runtimeGovernor.limitRAM = not runtimeGovernor.limitRAM
        reloadImportedSceneBudget()
    end,
})

registerMenuItem({
    id = "governor_ram_limit",
    label = function()
        return "RAM Limit"
    end,
    value = function()
        return tostring(runtimeGovernor.ramLimitMB) .. " MiB"
    end,
    adjust = function(delta)
        governor.adjustRamLimit(runtimeGovernor, delta)
        reloadImportedSceneBudget()
    end,
})

registerMenuItem({
    id = "governor_limit_vram",
    label = function()
        return "Limit VRAM"
    end,
    value = function()
        return formatBool(runtimeGovernor.limitVRAM)
    end,
    adjust = function(delta)
        if delta ~= 0 then
            runtimeGovernor.limitVRAM = not runtimeGovernor.limitVRAM
            reloadImportedSceneBudget()
        end
    end,
    activate = function()
        runtimeGovernor.limitVRAM = not runtimeGovernor.limitVRAM
        reloadImportedSceneBudget()
    end,
})

registerMenuItem({
    id = "governor_vram_limit",
    label = function()
        return "VRAM Limit"
    end,
    value = function()
        return tostring(runtimeGovernor.vramLimitMB) .. " MiB"
    end,
    adjust = function(delta)
        governor.adjustVRamLimit(runtimeGovernor, delta)
        reloadImportedSceneBudget()
    end,
})

registerMenuItem({
    id = "quit",
    label = function()
        return "Quit"
    end,
    value = function()
        return "Exit application"
    end,
    activate = function()
        love.event.quit()
    end,
})

--#endregion

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ Pause Menu Layout and Hit Testing ║
     ╙───────────────────────────────────╜
]]

--#region Pause Menu Layout and Hit Testing

local function rebuildMenuInteractionTables(layout)
    menuRows = {}
    menuPositionsX = {}
    menuPositionsY = {}
    menuItemCallbacks = {}
    lastMenuLayout = layout
    pauseTabs = {}

    local interactiveLeft = layout.panelX + 18
    local interactiveRight = layout.panelX + layout.panelW - 18
    menuPositionsX[1] = { min = interactiveLeft, max = interactiveRight }

    local tabX = math.floor(layout.panelX + ((layout.panelW / #pausePages ) + 0.5))
    local tabY = layout.panelY + 24
    for i = 1, #pausePages do
        local title = pausePages[i].title
        local tabW = fontSmall:getWidth(title) + 28
        pauseTabs[i] = {
            x1 = tabX,
            x2 = tabX + tabW,
            y1 = tabY,
            y2 = tabY + 24,
            index = i,
        }
        tabX = tabX + tabW + 8
    end

    local y = layout.firstRowY
    local visible = getVisibleMenuIndices()

    for _, i in ipairs(visible) do
        local def = getMenuDefByIndex(i)

        if def and def.kind == "section" then
            local top = y - 2
            local bottom = top + 30
            menuRows[i] = {
                x1 = interactiveLeft,
                x2 = interactiveRight,
                y1 = top,
                y2 = bottom,
                index = i,
                section = true,
            }
            y = y + layout.sectionGap
        else
            local top = y - 4
            local bottom = top + layout.rowH

            menuRows[i] = {
                x1 = interactiveLeft,
                x2 = interactiveRight,
                y1 = top,
                y2 = bottom,
                index = i,
                section = false,
            }

            menuPositionsY[i] = {
                min = top,
                max = bottom,
                index = i,
            }

            menuItemCallbacks[1] = menuItemCallbacks[1] or {}
            menuItemCallbacks[1][i] = function()
                menuIndex = i
                activateMenuIndex(i)
            end

            y = y + layout.rowGap
        end
    end
end

local function getMenuCellAt(mx, my)
    for xIndex, xRange in pairs(menuPositionsX) do
        if mx >= xRange.min and mx <= xRange.max then
            for yIndex, yRange in pairs(menuPositionsY) do
                if my >= yRange.min and my <= yRange.max then
                    return xIndex, yIndex, yRange.index
                end
            end
        end
    end
    return nil
end

local function getPauseTabAt(mx, my)
    for i = 1, #pauseTabs do
        local tab = pauseTabs[i]
        if mx >= tab.x1 and mx <= tab.x2 and my >= tab.y1 and my <= tab.y2 then
            return tab.index
        end
    end
    return nil
end

local function getDropdownOptionAt(mx, my)
    if not dropdownState.open then
        return nil
    end

    local startIndex = dropdownState.scrollIndex or 1
    local visibleCount = dropdownState.visibleCount or math.min(#dropdownState.options, dropdownState.maxVisible or 8)
    local endIndex = math.min(#dropdownState.options, startIndex + visibleCount - 1)

    for i = startIndex, endIndex do
        local top = dropdownState.y + (i - startIndex) * dropdownState.rowH
        local bottom = top + dropdownState.rowH
        if mx >= dropdownState.x and mx <= (dropdownState.x + dropdownState.w) and my >= top and my <= bottom then
            return i
        end
    end

    return nil
end

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ Shared UI Drawing Helpers         ║
     ╙───────────────────────────────────╜
]]

--#region Shared UI Drawing Helpers

local function drawRoundedPanel(x, y, w, h, r, fillA, lineA)
    love.graphics.setColor(0.08, 0.08, 0.10, fillA or 0.90)
    love.graphics.rectangle("fill", x, y, w, h, r, r)
    love.graphics.setColor(1, 1, 1, lineA or 0.10)
    love.graphics.rectangle("line", x, y, w, h, r, r)
end

local function drawChip(text, x, y, alignRight, maxWidth)
    love.graphics.setFont(fontSmall)

    local content = tostring(text or "")
    local padX = 10
    local h = 22
    local limit = maxWidth or 220

    while fontSmall:getWidth(content) + padX * 2 > limit and #content > 3 do
        content = content:sub(1, #content - 2)
    end

    if content ~= tostring(text or "") then
        content = content .. "…"
    end

    local w = math.min(limit, fontSmall:getWidth(content) + padX * 2)

    if alignRight then
        x = x - w
    end

    love.graphics.setColor(1, 1, 1, 0.08)
    love.graphics.rectangle("fill", x, y, w, h, 8, 8)
    love.graphics.setColor(1, 1, 1, 0.10)
    love.graphics.rectangle("line", x, y, w, h, 8, 8)
    love.graphics.setColor(1, 1, 1, 0.92)
    love.graphics.print(content, x + padX, y + 3)

    return w
end

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ LÖVE Runtime and Input Callbacks  ║
     ╙───────────────────────────────────╜
]]

--#region LÖVE Runtime and Input Callbacks

--#region Core Lifecycle

function love.run()
    if love.load then
        ---@diagnostic disable-next-line: redundant-parameter
        love.load(love.arg.parseGameArguments(arg), arg)
    end
    if love.timer then
        love.timer.step()
    end

    local dt = 0

    return function()
        local frameStart = love.timer and love.timer.getTime() or 0

        if love.event then
            love.event.pump()
            for name, a, b, c, d, e, f in love.event.poll() do
                if name == "quit" then
                    if not love.quit or not love.quit() then
                        return a or 0
                    end
                end
                love.handlers[name](a, b, c, d, e, f)
            end
        end

        if love.timer then
            dt = love.timer.step()
        end

        if love.update then
            love.update(dt)
        end

        if love.graphics and love.graphics.isActive() then
            love.graphics.origin()
            love.graphics.clear(love.graphics.getBackgroundColor())

            if love.draw then
                love.draw()
            end

            love.graphics.present()
        end

        if not isPaused then
            local elapsed = (love.timer and love.timer.getTime() or 0) - frameStart
            local nextScale, changed = governor.stepTowardsFrameBudget(
                runtimeGovernor,
                elapsed,
                renderScale,
                limits.renderScale
            )
            if changed then
                renderScale = nextScale
                rebuildAccum()
            end
        end

        if love.timer and fpsTarget > 0 then
            local elapsed = love.timer.getTime() - frameStart
            local target = 1 / fpsTarget
            if elapsed < target then
                love.timer.sleep(target - (elapsed * 1.001)) -- Quick and dirty attempt to account for over-sleeping
            end
        end
    end
end

function love.load()
    love.window.setTitle("Love2D RayTracing Example")

    fontSmall = love.graphics.newFont(12)
    fontBody = love.graphics.newFont(16)
    fontTitle = love.graphics.newFont(20)

    love.graphics.setFont(fontBody)
    love.mouse.setRelativeMode(true)

    shader = love.graphics.newShader("shader.glsl")
    rebuildAccum()
    applyTracingMode(tracerSettings.tracingModeIndex)

    scanObjectsFolder()
    loadSelectedModel()
    print("Imported OBJ triangles:", importedScene.triCount)

    if not isInteractiveMenuIndex(menuIndex) then
        stepMenuSelection(1)
    end
end

function love.resize(w, h)
    width, height = w, h
    rebuildAccum()
end

--#endregion

--#region Mouse Callbacks

function love.mousemoved(x, y, dx, dy)
    if not isPaused and love.window.hasMouseFocus() and enableMouse then
        camera.yaw = (camera.yaw + dx * 0.005) % (2 * math.pi)
        camera.pitch = math.max(
            -math.pi / 2 + 0.001,
            math.min(math.pi / 2 - 0.001, camera.pitch - dy * 0.005)
        )
        governor.noteMotion(runtimeGovernor, love.timer and love.timer.getTime() or 0)
        resetAccum(true)
        return
    end

    if isPaused and love.window.hasMouseFocus() then
        local hoveredOption = getDropdownOptionAt(x, y)
        if hoveredOption then
            dropdownState.hoveredOption = hoveredOption
            hoveredMenuIndex = dropdownState.menuIndex
            return
        end

        local hoveredTab = getPauseTabAt(x, y)
        if hoveredTab then
            hoveredMenuIndex = 0
            return
        end

        local _, _, itemIndex = getMenuCellAt(x, y)
        hoveredMenuIndex = itemIndex or 0
        if itemIndex then
            menuIndex = itemIndex
        end
    end
end

function love.mousepressed(x, y, button)
    if isPaused then
        if button == 1 then
            local dropdownOption = getDropdownOptionAt(x, y)
            if dropdownOption then
                chooseDropdownOption(dropdownOption)
                return
            end

            local tabIndex = getPauseTabAt(x, y)
            if tabIndex then
                setPausePage(tabIndex)
                return
            end

            local xIndex, yIndex, itemIndex = getMenuCellAt(x, y)
            if xIndex and yIndex and menuItemCallbacks[xIndex] and menuItemCallbacks[xIndex][yIndex] then
                menuItemCallbacks[xIndex][yIndex]()
            elseif itemIndex then
                menuIndex = itemIndex
            else
                closeDropdown()
            end
        end
        return
    end

    enableMouse = true
    love.mouse.setRelativeMode(true)
end

function love.wheelmoved(x, y)
    if isPaused then
        if dropdownState.open then
            stepDropdownHover(y < 0 and 1 or (y > 0 and -1 or 0))
            return
        end

        menuIndex = clampInt(menuIndex, 1, #menuOrder)
        adjustMenuIndex(menuIndex, y > 0 and 1 or (y < 0 and -1 or 0))
        return
    end

    if y > 0 then
        applyPreset(qualityIndex + 1)
    elseif y < 0 then
        applyPreset(qualityIndex - 1)
    end
end

--#endregion

--#region Keyboard Callbacks

function love.keypressed(key)
    if key == "escape" then
        if isPaused and dropdownState.open then
            closeDropdown()
        elseif isPaused then
            closePauseMenu()
        else
            openPauseMenu()
        end
        return
    end

    if isPaused then
        if key == "q" then
            setPausePage(pausePageIndex - 1)
        elseif key == "e" then
            setPausePage(pausePageIndex + 1)
        elseif dropdownState.open and (key == "up" or key == "w") then
            stepDropdownHover(-1)
        elseif dropdownState.open and (key == "down" or key == "s") then
            stepDropdownHover(1)
        elseif dropdownState.open and (key == "return" or key == "kpenter" or key == "space") then
            chooseDropdownOption(dropdownState.hoveredOption)
        elseif key == "up" or key == "w" then
            stepMenuSelection(-1)
        elseif key == "down" or key == "s" then
            stepMenuSelection(1)
        elseif key == "left" or key == "a" then
            adjustMenuIndex(menuIndex, -1)
        elseif key == "right" or key == "d" then
            adjustMenuIndex(menuIndex, 1)
        elseif key == "pageup" then
            adjustMenuIndex(menuIndex, 10)
        elseif key == "pagedown" then
            adjustMenuIndex(menuIndex, -10)
        elseif key == "return" or key == "kpenter" or key == "space" then
            activateMenuIndex(menuIndex)
        elseif key == "r" then
            resetAccum()
        end
        return
    end

    if key == "capslock" then
        toggleInputCapture()
        return
    elseif key == "q" then
        cycleSelectedModel(-1)
        return
    elseif key == "e" then
        cycleSelectedModel(1)
        return
    elseif key == "f5" then
        scanObjectsFolder()
        loadSelectedModel()
        resetAccum()
        return
    end

    if key == "r" then
        resetAccum()
    elseif key == "tab" then
        uiState.showHud = not uiState.showHud
    elseif key == "f1" then
        uiState.compactHud = not uiState.compactHud
    else
        -- print(tostring(key))
        keysDown[key] = true
    end
end

function love.keyreleased(key)
    keysDown[key] = false
end

--#endregion

--#region Simulation Update

function love.update(dt)
    if isPaused then
        return
    end

    if enableMouse then
        local move = { 0, 0, 0 }
        local moveSpeed = keysDown["lshift"] and 7.5 or 2.5

        if keysDown["w"] then
            move = add(move, {
                math.cos(camera.pitch) * math.sin(camera.yaw),
                math.sin(camera.pitch),
                math.cos(camera.pitch) * math.cos(camera.yaw)
            })
        end

        if keysDown["s"] then
            move = sub(move, {
                math.cos(camera.pitch) * math.sin(camera.yaw),
                math.sin(camera.pitch),
                math.cos(camera.pitch) * math.cos(camera.yaw)
            })
        end

        if keysDown["a"] then
            move = sub(move, { math.cos(camera.yaw), 0, -math.sin(camera.yaw) })
        end

        if keysDown["d"] then
            move = add(move, { math.cos(camera.yaw), 0, -math.sin(camera.yaw) })
        end

        if keysDown["space"] then
            move = add(move, { 0, 1, 0 })
        end

        if keysDown["lctrl"] then
            move = sub(move, { 0, 1, 0 })
        end

        if dot(move, move) > 0 then
            move = norm(move)
            camera.pos = add(camera.pos, mul(move, moveSpeed * dt))
            governor.noteMotion(runtimeGovernor, love.timer and love.timer.getTime() or 0)
            resetAccum(true)
        end
    end
end

--#endregion

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ UI Panels and Overlay Rendering   ║
     ╙───────────────────────────────────╜
]]

--#region UI Panels and Overlay Rendering

local function getPauseMenuMetrics()
    local headerH = 54
    local footerH = 82
    local rowH = 38
    local rowGap = 44
    local sectionGap = 36
    local topPad = 18
    local bottomPad = 16

    local contentH = 0

    local visible = getVisibleMenuIndices()
    for _, i in ipairs(visible) do
        local def = getMenuDefByIndex(i)
        if def and def.kind == "section" then
            contentH = contentH + sectionGap
        else
            contentH = contentH + rowGap
        end
    end

    local panelH = headerH + topPad + contentH + bottomPad + footerH
    panelH = math.min(panelH, height - 40)

    local panelW = math.min(760, width - 40)
    local panelX = math.floor((width - panelW) * 0.5)
    local panelY = math.floor((height - panelH) * 0.5)

    return {
        panelW = panelW,
        panelH = panelH,
        panelX = panelX,
        panelY = panelY,
        headerH = headerH,
        footerH = footerH,
        rowH = rowH,
        rowGap = rowGap,
        sectionGap = sectionGap,
        firstRowY = panelY + headerH + topPad,
    }
end

local function drawPauseMenu()
    local m = getPauseMenuMetrics()

    rebuildMenuInteractionTables({
        panelX = m.panelX,
        panelY = m.panelY,
        panelW = m.panelW,
        panelH = m.panelH,
        firstRowY = m.firstRowY,
        rowH = m.rowH,
        rowGap = m.rowGap,
        sectionGap = m.sectionGap,
    })

    love.graphics.setColor(0, 0, 0, 0.72)
    love.graphics.rectangle("fill", 0, 0, width, height)

    drawRoundedPanel(m.panelX, m.panelY, m.panelW, m.panelH, 18, 0.94, 0.12)

    love.graphics.setFont(fontTitle)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("LOVE2D SDF RayTracer", m.panelX + 24, m.panelY + 14)

    love.graphics.setFont(fontSmall)
    for i = 1, #pauseTabs do
        local tab = pauseTabs[i]
        local active = (i == pausePageIndex)
        love.graphics.setColor(1, 1, 1, active and 0.14 or 0.06)
        love.graphics.rectangle("fill", tab.x1, tab.y1, tab.x2 - tab.x1, tab.y2 - tab.y1, 8, 8)
        love.graphics.setColor(1, 1, 1, active and 0.16 or 0.08)
        love.graphics.rectangle("line", tab.x1, tab.y1, tab.x2 - tab.x1, tab.y2 - tab.y1, 8, 8)
        love.graphics.setColor(1, 1, 1, active and 0.96 or 0.72)
        love.graphics.print(pausePages[i].title, tab.x1 + 12, tab.y1 + 4)
    end

    local contentTop = m.firstRowY - 6
    local contentBottom = m.panelY + m.panelH - m.footerH - 12
    love.graphics.setScissor(m.panelX + 8, contentTop, m.panelW - 16, contentBottom - contentTop)

    local visible = getVisibleMenuIndices()
    for _, i in ipairs(visible) do
        local def = getMenuDefByIndex(i)
        local row = menuRows[i]

        if def and def.kind == "section" then
            love.graphics.setFont(fontSmall)
            love.graphics.setColor(1, 1, 1, 0.45)
            love.graphics.print(def.title, m.panelX + 26, row.y1 + 2)
            love.graphics.setColor(1, 1, 1, 0.08)
            love.graphics.rectangle("fill", m.panelX + 130, row.y1 + 10, m.panelW - 160, 1)
        else
            local selected = (i == menuIndex)
            local hovered = (i == hoveredMenuIndex)
            local label, value = getMenuLabelAndValue(i)

            if selected then
                love.graphics.setColor(1, 1, 1, 0.12)
                love.graphics.rectangle("fill", row.x1, row.y1, row.x2 - row.x1, row.y2 - row.y1, 10, 10)
                love.graphics.setColor(1, 1, 1, 0.14)
                love.graphics.rectangle("line", row.x1, row.y1, row.x2 - row.x1, row.y2 - row.y1, 10, 10)
            elseif hovered then
                love.graphics.setColor(1, 1, 1, 0.07)
                love.graphics.rectangle("fill", row.x1, row.y1, row.x2 - row.x1, row.y2 - row.y1, 10, 10)
            end

            local labelX = m.panelX + 28
            local chipRightX = m.panelX + m.panelW - 28
            local chipMaxW = math.floor(m.panelW * 0.34)
            local reservedRight = chipMaxW + 26
            local labelMaxW = (m.panelW - 56) - reservedRight

            love.graphics.setFont(fontBody)
            love.graphics.setColor(1, 1, 1, selected and 0.98 or 0.86)

            local shownLabel = label
            while fontBody:getWidth(shownLabel) > labelMaxW and #shownLabel > 3 do
                shownLabel = shownLabel:sub(1, #shownLabel - 2)
            end
            if shownLabel ~= label then
                shownLabel = shownLabel .. "…"
            end

            love.graphics.print(shownLabel, labelX, row.y1 + 8)

            if value ~= "" then
                drawChip(value, chipRightX, row.y1 + 8, true, chipMaxW)
            end
        end
    end

    love.graphics.setScissor()

    if dropdownState.open and menuRows[dropdownState.menuIndex] then
        local row = menuRows[dropdownState.menuIndex]
        clampDropdownState()

        dropdownState.w = math.min(320, m.panelW - 56)
        dropdownState.rowH = 28

        local drawCount = dropdownState.visibleCount or math.min(#dropdownState.options, dropdownState.maxVisible or 8)
        local dropdownH = drawCount * dropdownState.rowH
        local preferredX = m.panelX + m.panelW - dropdownState.w - 28
        local minY = m.panelY + 84
        local maxY = height - dropdownH - 20

        dropdownState.x = clamp(preferredX, m.panelX + 28, width - dropdownState.w - 16)
        dropdownState.y = row.y2 + 6
        if dropdownState.y + dropdownH > (m.panelY + m.panelH - m.footerH - 6) then
            dropdownState.y = row.y1 - dropdownH - 6
        end
        dropdownState.y = clamp(dropdownState.y, minY, math.max(minY, maxY))

        love.graphics.setColor(0.06, 0.06, 0.09, 0.98)
        love.graphics.rectangle("fill", dropdownState.x, dropdownState.y, dropdownState.w, dropdownH, 10, 10)
        love.graphics.setColor(1, 1, 1, 0.12)
        love.graphics.rectangle("line", dropdownState.x, dropdownState.y, dropdownState.w, dropdownH, 10, 10)

        local startIndex = dropdownState.scrollIndex or 1
        local endIndex = math.min(#dropdownState.options, startIndex + drawCount - 1)

        for optionIndex = startIndex, endIndex do
            local optionY = dropdownState.y + (optionIndex - startIndex) * dropdownState.rowH
            local hovered = optionIndex == dropdownState.hoveredOption
            if hovered then
                love.graphics.setColor(1, 1, 1, 0.10)
                love.graphics.rectangle("fill", dropdownState.x + 4, optionY + 2, dropdownState.w - 8, dropdownState.rowH - 4, 8, 8)
            end

            love.graphics.setColor(1, 1, 1, hovered and 0.98 or 0.82)
            love.graphics.print(tostring(dropdownState.options[optionIndex]), dropdownState.x + 12, optionY + 5)
        end

        if startIndex > 1 then
            love.graphics.setColor(1, 1, 1, 0.45)
            love.graphics.print("...", dropdownState.x + dropdownState.w - 26, dropdownState.y + 2)
        end

        if endIndex < #dropdownState.options then
            love.graphics.setColor(1, 1, 1, 0.45)
            love.graphics.print("...", dropdownState.x + dropdownState.w - 26, dropdownState.y + dropdownH - 18)
        end
    end

    love.graphics.setColor(1, 1, 1, 0.08)
    love.graphics.rectangle("fill", m.panelX + 1, m.panelY + m.panelH - m.footerH, m.panelW - 2, m.footerH - 1)

    love.graphics.setFont(fontSmall)
    love.graphics.setColor(1, 1, 1, 0.70)
    love.graphics.print("Esc Close   •   Up/Down Select   •   Left/Right Adjust   •   Enter Activate", m.panelX + 24,
        m.panelY + m.panelH - 58)
    love.graphics.setColor(1, 1, 1, 0.50)
    love.graphics.print("Mouse hover/select works too. PgUp/PgDn applies larger numeric adjustments.", m.panelX + 24,
        m.panelY + m.panelH - 34)
end

local function drawHud()
    if not uiState.showHud then
        return
    end

    local x, y = 14, 14

    local lines = {
        { "FPS",     tostring(love.timer.getFPS()) },
        { "Frame",   tostring(currentFrame) },
        { "Preset",  qualityPresets[qualityIndex].name },
        { "Scale",   string.format("%.2f", renderScale) },
        { "Target",  fpsTarget == 0 and "Uncapped" or tostring(fpsTarget) },
        { "Tracing", tracingModes[tracerSettings.tracingModeIndex].name },
        { "Scene",   sceneNames[tracerSettings.sceneVariant] or tostring(tracerSettings.sceneVariant) },
        { "Bounces", tostring(tracerSettings.maxBounces) },
        { "Steps",   tostring(tracerSettings.maxSteps) },
        { "Shadows", formatBool(tracerSettings.shadows) },
        { "Reflect", formatBool(tracerSettings.reflections) },
        { "Gov FPS", tostring(runtimeGovernor.minimumFPS) },
        { "Gov Sec", string.format("%.3f", runtimeGovernor.maxSecondsPerFrame or 0) },
        { "Dummy", formatBool(governor.shouldUseDummyRender(runtimeGovernor, love.timer and love.timer.getTime() or 0)) },
    }

    if tracerSettings.sceneVariant == 3 then
        local selected = getSelectedModelPath()
        lines[#lines + 1] = { "Model", selected and basename(selected) or "None" }
        lines[#lines + 1] = { "OBJ Tris", tostring(importedScene.triCount or 0) }
        lines[#lines + 1] = { "Src Tris", tostring(importedScene.sourceTriCount or 0) }
        lines[#lines + 1] = { "Import", tostring(importedScene.importMode or "none") }
        lines[#lines + 1] = { "BVH", tostring(importedScene.bvhNodeCount or 0) }
        lines[#lines + 1] = { "Scene VRAM", formatMiB(importedScene.estimatedVRAMBytes or 0) }
        lines[#lines + 1] = { "OBJ Files", tostring(#modelBrowser.files) }
    end

    if uiState.compactHud then
        local panelW = 240
        local panelH = 104

        drawRoundedPanel(x, y, panelW, panelH, 14, 0.68, 0.10)

        love.graphics.setFont(fontSmall)
        love.graphics.setColor(1, 1, 1, 0.55)
        love.graphics.print("RENDERER", x + 14, y + 10)

        love.graphics.setFont(fontBody)
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.print(tracingModes[tracerSettings.tracingModeIndex].name, x + 14, y + 28)

        love.graphics.setFont(fontSmall)
        love.graphics.setColor(1, 1, 1, 0.80)
        love.graphics.print("FPS", x + 14, y + 60)
        drawChip(tostring(love.timer.getFPS()), x + panelW - 14, y + 56, true, 92)

        return
    end

    local headerH = 50
    local rowH = 24
    local bottomPad = 12
    local panelW = 300
    local panelH = headerH + (#lines * rowH) + bottomPad

    drawRoundedPanel(x, y, panelW, panelH, 14, 0.68, 0.10)

    love.graphics.setFont(fontSmall)
    love.graphics.setColor(1, 1, 1, 0.55)
    love.graphics.print("RENDERER", x + 14, y + 10)

    love.graphics.setFont(fontBody)
    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.print(tracingModes[tracerSettings.tracingModeIndex].name, x + 14, y + 26)

    local lineY = y + headerH
    love.graphics.setFont(fontSmall)

    for i = 1, #lines do
        love.graphics.setColor(1, 1, 1, 0.62)
        love.graphics.print(lines[i][1], x + 14, lineY)
        drawChip(lines[i][2], x + panelW - 14, lineY - 4, true, 120)
        lineY = lineY + rowH
    end
end

local function drawBottomHintBarLegacy()
    local barH = 42
    love.graphics.setColor(0, 0, 0, 0.34)
    love.graphics.rectangle("fill", 0, height - barH, width, barH)

    love.graphics.setFont(fontSmall)
    love.graphics.setColor(1, 1, 1, 0.78)

    local text =
    "Esc Pause   •   Q / E Cycle Models   •   F5 Refresh Objects   •   R Reset Accumulation   •   Tab Toggle HUD   •   Caps—Lk Toggle Input   •   W / A / S / D Movement   •   Space Ascend   •   L—Ctrl Descend   •   Mouse Axis Look Around   •   Shift Increase Camera Speed"
    love.graphics.printf(text, 14, height - 28, width - 28, "left")
end

local function drawBottomHintBarClean()
    local barH = 42
    love.graphics.setColor(0, 0, 0, 0.34)
    love.graphics.rectangle("fill", 0, height - barH, width, barH)

    love.graphics.setFont(fontSmall)
    love.graphics.setColor(1, 1, 1, 0.78)

    local text =
    "Esc Pause   |   Mouse Wheel Change Preset   |   Q / E Cycle Models   |   F5 Refresh Objects   |   R Reset Accumulation   |   Tab Toggle HUD   |   F1 Compact HUD   |   Caps Lock Toggle Input   |   W / A / S / D Move   |   Space Ascend   |   Left Ctrl Descend   |   Mouse Look   |   Left Shift Faster"
    love.graphics.printf(text, 14, height - 28, width - 28, "left")
end

local function renderFullscreenPass(targetCanvas, historyTex, cacheTex, overrides)
    sendFrameUniforms(1, historyTex, cacheTex, overrides)
    targetCanvas:renderTo(function()
        love.graphics.clear(0, 0, 0, 1)
        love.graphics.setShader(shader)
        love.graphics.setBlendMode("alpha", "premultiplied")
        love.graphics.draw(historyTex or getFallbackFloatImage(), 0, 0)
        love.graphics.setShader()
    end)
end

local function drawCanvasToScreen(canvas)
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha", "alphamultiply")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, 0, 0, 0, width / renderWidth, height / renderHeight)
end

local function renderDummyPreviewFrame()
    local fallback = getFallbackFloatImage()
    renderFullscreenPass(accumDst, fallback, fallback, {
        frameIndex = 0,
        tracingMode = tracingModes[1].shaderMode,
        maxBounces = tracingModes[1].defaultBounces,
        maxSteps = tracingModes[1].defaultSteps,
        enableReflections = false,
    })
    drawCanvasToScreen(accumDst)
end

--#endregion

--[[ ╓───────────────────────────────────╖
     ║ Final Draw Call to LÖVE for GPU   ║
     ╙───────────────────────────────────╜
]]

--#region Final Draw Call to LÖVE for GPU

function love.draw()
    local dummyRenderActive = (not isPaused) and governor.shouldUseDummyRender(
        runtimeGovernor,
        love.timer and love.timer.getTime() or 0
    )

    if not isPaused and dummyRenderActive then
        renderDummyPreviewFrame()
    elseif not isPaused then
        sendFrameUniforms(1, accumSrc, getFallbackFloatImage())
        accumDst:renderTo(function()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.setShader(shader)
            love.graphics.setBlendMode("alpha", "premultiplied")
            love.graphics.draw(accumSrc, 0, 0)
            love.graphics.setShader()
        end)

        drawCanvasToScreen(accumDst)

        swapAccum()
        currentFrame = currentFrame + 1
    else
        local pausedCanvas = accumSrc or accumDst
        if pausedCanvas then
            drawCanvasToScreen(pausedCanvas)
        end

        if isPaused then
            drawPauseMenu()
        end
    end

    drawHud()
    drawBottomHintBarClean()
end

--#endregion
