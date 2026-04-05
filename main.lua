local objloader = require("objloader")

-- ╓───────────────────────────────────╖
-- ║ Various Initial Tables and Values ║
-- ╙───────────────────────────────────╜

--#region Variables

love.window.setMode(1900, 1060, { vsync = false })
local width, height = love.graphics.getDimensions()

local qualityPresets = {
    [5] = { name = "Ultra", scale = 1.00, fps = 0 },
    [4] = { name = "High", scale = 0.85, fps = 144 },
    [3] = { name = "Medium", scale = 0.70, fps = 90 },
    [2] = { name = "Low", scale = 0.55, fps = 60 },
    [1] = { name = "Potato", scale = 0.40, fps = 30 },
}

local renderModes = {
    { name = "Ultra-Fast", bounces = 1,  steps = 32,  shadows = false, reflections = false, scene = 0 },
    { name = "Fast",       bounces = 10, steps = 48,  shadows = false, reflections = false, scene = 0 },
    { name = "Balanced",   bounces = 20, steps = 72,  shadows = true,  reflections = true,  scene = 0 },
    { name = "Fancy",      bounces = 30, steps = 128, shadows = true,  reflections = true,  scene = 1 },
}

local fpsOptions = { 0, 10, 30, 60, 90, 120, 144, 240, 420 }

local sceneNames = {
    [0] = "Studio",
    [1] = "Showcase",
    [2] = "House of Mirrors",
    [3] = "Imported Objects",
}

local limits = {
    renderScale = { min = 0.05, max = 4.00, step = 0.05, fastStep = 0.25 },
    bounces     = { min = 1, max = 1000000, step = 1, fastStep = 1000 },
    steps       = { min = 8, max = 1000000, step = 8, fastStep = 256 },
    scene       = { min = 0, max = 3, step = 1, fastStep = 1 },
}

local defaults = {
    qualityIndex = 3,
    modeIndex = 2,
    camera = {
        pos   = { 3, 1.5, 3 },
        yaw   = 3.9465926535898,
        pitch = -0.155,
        fov   = math.pi / 3,
    }
}

local importedScene = {
    path = "",
    maxTriangles = 768,
    loaded = false,
    triCount = 0,
    meshVertsImage = nil,
    meshTexSize = { 3, 1 },
}

local modelBrowser = {
    folder = "objects",
    files = {},
    selectedIndex = 1,
}

local qualityIndex = defaults.qualityIndex
local renderScale = qualityPresets[qualityIndex].scale
local fpsTarget = qualityPresets[qualityIndex].fps

local tracerSettings = {
    modeIndex = defaults.modeIndex,
    maxBounces = renderModes[defaults.modeIndex].bounces,
    maxSteps = renderModes[defaults.modeIndex].steps,
    shadows = renderModes[defaults.modeIndex].shadows,
    reflections = renderModes[defaults.modeIndex].reflections,
    sceneVariant = renderModes[defaults.modeIndex].scene,
}

local renderWidth = math.max(1, math.floor(width * renderScale))
local renderHeight = math.max(1, math.floor(height * renderScale))

local accumA, accumB, accumSrc, accumDst
local shader
local currentFrame = 0
local keysDown = {}

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

-- ╓───────────────────────────────────╖
-- ║ Globally Helpful Helper Functions ║
-- ╙───────────────────────────────────╜

--#region Helpers


local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function clampInt(v, lo, hi)
    return math.floor(clamp(v, lo, hi))
end

local function formatBool(v)
    return v and "On" or "Off"
end

local function boolToInt(v)
    return v and 1 or 0
end

--#endregion

-- ╓───────────────────────────────────╖
-- ║ Vector3 Math and Components       ║
-- ╙───────────────────────────────────╜

--#region Vec3

local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function mul(v, s) return { v[1] * s, v[2] * s, v[3] * s } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end

local function norm(v)
    local m = math.sqrt(dot(v, v))
    if m <= 0.000001 then
        return { 0, 0, 0 }
    end
    return { v[1] / m, v[2] / m, v[3] / m }
end

local function copyVec3(v)
    return { v[1], v[2], v[3] }
end

--#endregion

-- ╓───────────────────────────────────╖
-- ║ Render Accumulation Management    ║
-- ╙───────────────────────────────────╜

--#region Render Accumulation

local function swap()
    accumSrc, accumDst = accumDst, accumSrc
end

local function clearAll()
    if accumA then
        accumA:renderTo(function()
            love.graphics.clear(0, 0, 0, 1)
        end)
    end
    if accumB then
        accumB:renderTo(function()
            love.graphics.clear(0, 0, 0, 1)
        end)
    end
end

local function resetAccum()
    currentFrame = 0
    clearAll()
end

local function rebuildAccum()
    renderWidth = math.max(1, math.floor(width * renderScale))
    renderHeight = math.max(1, math.floor(height * renderScale))

    accumA = love.graphics.newCanvas(renderWidth, renderHeight, { format = "rgba16f" })
    accumA:setFilter("linear", "linear")

    accumB = love.graphics.newCanvas(renderWidth, renderHeight, { format = "rgba16f" })
    accumB:setFilter("linear", "linear")

    accumSrc = accumA
    accumDst = accumB

    clearAll()
    currentFrame = 0
end

local function applyPreset(index)
    qualityIndex = clampInt(index, 1, #qualityPresets)
    renderScale = qualityPresets[qualityIndex].scale
    fpsTarget = qualityPresets[qualityIndex].fps
    rebuildAccum()
end

local function applyRenderMode(index)
    tracerSettings.modeIndex = clampInt(index, 1, #renderModes)
    local mode = renderModes[tracerSettings.modeIndex]
    tracerSettings.maxBounces = mode.bounces
    tracerSettings.maxSteps = mode.steps
    tracerSettings.shadows = mode.shadows
    tracerSettings.reflections = mode.reflections
    tracerSettings.sceneVariant = mode.scene
    resetAccum()
end

local function restoreDefaults()
    qualityIndex = defaults.qualityIndex
    renderScale = qualityPresets[qualityIndex].scale
    fpsTarget = qualityPresets[qualityIndex].fps

    tracerSettings.modeIndex = defaults.modeIndex
    tracerSettings.maxBounces = renderModes[defaults.modeIndex].bounces
    tracerSettings.maxSteps = renderModes[defaults.modeIndex].steps
    tracerSettings.shadows = renderModes[defaults.modeIndex].shadows
    tracerSettings.reflections = renderModes[defaults.modeIndex].reflections
    tracerSettings.sceneVariant = renderModes[defaults.modeIndex].scene

    camera.pos = copyVec3(defaults.camera.pos)
    camera.yaw = defaults.camera.yaw
    camera.pitch = defaults.camera.pitch
    camera.fov = defaults.camera.fov

    rebuildAccum()
end

--#endregion

-- ╓───────────────────────────────────╖
-- ║ Path and File Helpers             ║
-- ╙───────────────────────────────────╜

--#region Path and File Helpers

local function ceilDiv(a, b)
    if not b or b == 0 then
        return 1
    end
    return math.floor((a + b - 1) / b)
end

local function normalizePath(path)
    path = tostring(path or "")
    path = path:gsub("\\", "/")
    path = path:gsub("/+", "/")
    return path
end

local function basename(path)
    path = normalizePath(path)
    return path:match("([^/]+)$") or path
end

--#endregion

-- ╓───────────────────────────────────╖
-- ║ Imported OBJ Scene Management     ║
-- ╙───────────────────────────────────╜

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

local function buildImportedScene(path, maxTriangles)
    maxTriangles = maxTriangles or 768

    local model, err = objloader.load(path)
    local result = {
        path = path,
        maxTriangles = maxTriangles,
        loaded = false,
        triCount = 0,
        meshVertsImage = nil,
        meshUVImage = nil,
        meshMatIdImage = nil,
        meshTexSize = { 3, 1 },
        materialIndexByName = {},
        materialList = {},
        materialTextures = {},
        materialColors = {},
    }

    if not model then
        print("Imported OBJ scene failed to load:", path, err or "")
        return result
    end

    if not model.positions or not model.triangles or #model.positions == 0 or #model.triangles == 0 then
        print("Imported OBJ scene empty:", path)
        return result
    end

    local minX, minY, minZ = model.positions[1][1], model.positions[1][2], model.positions[1][3]
    local maxX, maxY, maxZ = minX, minY, minZ

    for i = 1, #model.positions do
        local v = model.positions[i]
        minX = math.min(minX, v[1])
        minY = math.min(minY, v[2])
        minZ = math.min(minZ, v[3])
        maxX = math.max(maxX, v[1])
        maxY = math.max(maxY, v[2])
        maxZ = math.max(maxZ, v[3])
    end

    local cx = (minX + maxX) * 0.5
    local cy = (minY + maxY) * 0.5
    local cz = (minZ + maxZ) * 0.5

    local sx = maxX - minX
    local sy = maxY - minY
    local sz = maxZ - minZ
    local maxExtent = math.max(sx, math.max(sy, sz))
    local scale = maxExtent > 0 and (8.5 / maxExtent) or 1.0

    local stride = math.max(1, ceilDiv(#model.triangles, maxTriangles))
    local selected = {}

    for i = 1, #model.triangles, stride do
        selected[#selected + 1] = model.triangles[i]
        if #selected >= maxTriangles then
            break
        end
    end


    local function getOrCreateMaterialIndex(name)
        name = name or "default"

        if result.materialIndexByName[name] then
            return result.materialIndexByName[name]
        end

        local m = (model.materials and model.materials[name]) or (model.materials and model.materials.default) or {
            kd = { 1, 1, 1 },
            ks = { 0, 0, 0 },
            ke = { 0, 0, 0 },
            mapKd = nil,
        }

        local idx = #result.materialList + 1
        result.materialIndexByName[name] = idx
        result.materialList[idx] = name
        result.materialColors[idx] = {
            (m.kd and m.kd[1]) or 1,
            (m.kd and m.kd[2]) or 1,
            (m.kd and m.kd[3]) or 1,
        }

        if m.mapKd and objloader.loadTextureImage then
            local img, texErr = objloader.loadTextureImage(m.mapKd)
            if img then
                result.materialTextures[idx] = img
                print("Loaded material texture:", name, m.mapKd)
            else
                print("Failed to load material texture:", name, m.mapKd, texErr or "")
            end
        end

        return idx
    end


    local triCount = #selected
    local vertsImageData = love.image.newImageData(3, triCount, "rgba32f")
    local uvImageData = love.image.newImageData(3, triCount, "rgba32f")
    local matIdImageData = love.image.newImageData(1, triCount, "rgba32f")


    local function scaledPos(v)
        return (v[1] - cx) * scale,
            (v[2] - cy) * scale,
            (v[3] - cz) * scale - 4.0
    end

    local function getUV(vti)
        if vti and model.texcoords and model.texcoords[vti] then
            return model.texcoords[vti][1], model.texcoords[vti][2]
        end
        return 0.0, 0.0
    end

    for row = 1, triCount do
        local tri = selected[row]
        local matIndex = getOrCreateMaterialIndex(tri.material)

        for col = 1, 3 do
            local ref = tri.v[col]
            local p = model.positions[ref.vi]
            local px, py, pz = scaledPos(p)
            vertsImageData:setPixel(col - 1, row - 1, px, py, pz, 0.0)

            local u, v = getUV(ref.vti)
            uvImageData:setPixel(col - 1, row - 1, u, v, 0.0, 0.0)
        end

        matIdImageData:setPixel(0, row - 1, matIndex - 1, 0.0, 0.0, 0.0)
    end

    result.loaded = true
    result.triCount = triCount
    result.meshVertsImage = love.graphics.newImage(vertsImageData)
    result.meshUVImage = love.graphics.newImage(uvImageData)
    result.meshMatIdImage = love.graphics.newImage(matIdImageData)
    result.meshTexSize = { 3, triCount }

    result.meshVertsImage:setFilter("nearest", "nearest")
    result.meshUVImage:setFilter("nearest", "nearest")
    result.meshMatIdImage:setFilter("nearest", "nearest")

    print("Imported OBJ loaded:", path, "sampled tris =", triCount, "materials =", #result.materialList)
    return result
end

local function loadSelectedModel()
    local path = getSelectedModelPath()
    local maxTriangles = (importedScene and importedScene.maxTriangles) or 768

    if not path then
        importedScene = {
            path = "objects",
            maxTriangles = maxTriangles,
            loaded = false,
            triCount = 0,
            meshVertsImage = nil,
            meshUVImage = nil,
            meshMatIdImage = nil,
            meshTexSize = { 3, 1 },
            materialIndexByName = {},
            materialList = {},
            materialTextures = {},
            materialColors = {},
        }
        print("No OBJ files found in objects/")
        return
    end

    importedScene = buildImportedScene(path, maxTriangles)
    print("Selected runtime model:", path)
end

local function focusImportedScene()
    tracerSettings.sceneVariant = 3
    camera.pos = { 0.0, 1.8, 7.5 }
    camera.yaw = math.pi
    camera.pitch = -0.08
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

-- ╓───────────────────────────────────╖
-- ║ Input Capture and Pause State     ║
-- ╙───────────────────────────────────╜

--#region Input Capture and Pause State

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
    menuIndex = clampInt(menuIndex, 1, math.max(1, #menuRows > 0 and #menuRows or 1))
end

local function closePauseMenu()
    isPaused = false
    enableMouse = true
    hoveredMenuIndex = 0
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

--#endregion

-- ╓───────────────────────────────────╖
-- ║ Pause Menu Definitions            ║
-- ╙───────────────────────────────────╜

--#region Pause Menu Definitions

local menuDefinitions = {}

local menuOrder = {}

local function registerMenuItem(def)
    menuDefinitions[def.id] = def
    menuOrder[#menuOrder + 1] = def.id
end

local function getMenuDefByIndex(index)
    local id = menuOrder[index]
    return id and menuDefinitions[id] or nil
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
        return
    end
    def.adjust(delta)
end

local function activateMenuIndex(index)
    local def = getMenuDefByIndex(index)
    if not def or not def.activate or def.kind == "section" then
        return
    end
    def.activate()
end

local function isInteractiveMenuIndex(index)
    local def = getMenuDefByIndex(index)
    return def and def.kind ~= "section"
end

local function stepMenuSelection(delta)
    if #menuOrder == 0 then
        return
    end

    local start = menuIndex
    local i = start

    repeat
        i = i + delta
        if i < 1 then i = #menuOrder end
        if i > #menuOrder then i = 1 end
        if isInteractiveMenuIndex(i) then
            menuIndex = i
            return
        end
    until i == start
end

--#region Session Menu Items

registerMenuItem({
    id = "section_resume",
    kind = "section",
    title = "Session",
})

registerMenuItem({
    id = "input_capture",
    label = function()
        return "Input Capture"
    end,
    value = function()
        return captureInput and "Locked" or "Unlocked"
    end,
    adjust = function(delta)
        if delta ~= 0 then
            toggleInputCapture()
        end
    end,
    activate = function()
        toggleInputCapture()
    end,
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
    id = "reset",
    label = function()
        return "Reset Accumulation"
    end,
    value = function()
        return "Clear sampled history"
    end,
    activate = function()
        resetAccum()
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

--#endregion

--#region Render Menu Items

registerMenuItem({
    id = "section_render",
    kind = "section",
    title = "Render",
})

registerMenuItem({
    id = "quality",
    label = function()
        return "Preset Quality"
    end,
    value = function()
        return qualityPresets[qualityIndex].name
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
    adjust = function(delta)
        cycleFPS(delta)
    end,
})

registerMenuItem({
    id = "render_mode",
    label = function()
        return "Tracer Mode"
    end,
    value = function()
        return renderModes[tracerSettings.modeIndex].name
    end,
    adjust = function(delta)
        applyRenderMode(tracerSettings.modeIndex + delta)
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
    adjust = function(delta)
        local step = (math.abs(delta) >= 10) and limits.scene.fastStep or limits.scene.step
        tracerSettings.sceneVariant = clampInt(
            tracerSettings.sceneVariant + delta * step,
            limits.scene.min,
            limits.scene.max
        )

        if tracerSettings.sceneVariant == 3 then
            camera.pos = { 0.0, 1.8, 7.5 }
            camera.yaw = math.pi
            camera.pitch = -0.08
        end

        resetAccum()
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

--#endregion

--#region Application Menu Items

registerMenuItem({
    id = "section_app",
    kind = "section",
    title = "Application",
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

-- ╓───────────────────────────────────╖
-- ║ Pause Menu Layout and Hit Testing ║
-- ╙───────────────────────────────────╜

--#region Pause Menu Layout and Hit Testing

local function rebuildMenuInteractionTables(layout)
    menuRows = {}
    menuPositionsX = {}
    menuPositionsY = {}
    menuItemCallbacks = {}
    lastMenuLayout = layout

    local interactiveLeft = layout.panelX + 18
    local interactiveRight = layout.panelX + layout.panelW - 18
    menuPositionsX[1] = { min = interactiveLeft, max = interactiveRight }

    local rowIndex = 0
    local y = layout.firstRowY

    for i = 1, #menuOrder do
        local def = getMenuDefByIndex(i)

        if def and def.kind == "section" then
            rowIndex = rowIndex + 1
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
            rowIndex = rowIndex + 1
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

--#endregion

-- ╓───────────────────────────────────╖
-- ║ Shared UI Drawing Helpers         ║
-- ╙───────────────────────────────────╜

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

-- ╓───────────────────────────────────╖
-- ║ LÖVE Runtime and Input Callbacks  ║
-- ╙───────────────────────────────────╜

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

        if love.timer and fpsTarget > 0 then
            local elapsed = love.timer.getTime() - frameStart
            local target = 1 / fpsTarget
            if elapsed < target then
                love.timer.sleep(target - elapsed)
            end
        end
    end
end

function love.load()
    love.window.setTitle("Path Traced SDF")

    fontSmall = love.graphics.newFont(12)
    fontBody = love.graphics.newFont(16)
    fontTitle = love.graphics.newFont(26)

    love.graphics.setFont(fontBody)
    love.mouse.setRelativeMode(true)

    shader = love.graphics.newShader("shader.glsl")
    rebuildAccum()
    applyRenderMode(tracerSettings.modeIndex)

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
        resetAccum()
        return
    end

    if isPaused and love.window.hasMouseFocus() then
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
            local xIndex, yIndex, itemIndex = getMenuCellAt(x, y)
            if xIndex and yIndex and menuItemCallbacks[xIndex] and menuItemCallbacks[xIndex][yIndex] then
                menuItemCallbacks[xIndex][yIndex]()
            elseif itemIndex then
                menuIndex = itemIndex
            end
        end
        return
    end

    enableMouse = true
    love.mouse.setRelativeMode(true)
end

function love.wheelmoved(x, y)
    if isPaused then
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
        if isPaused then
            closePauseMenu()
        else
            openPauseMenu()
        end
        return
    end

    if isPaused then
        if key == "up" or key == "w" then
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
        print(tostring(key))
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
            resetAccum()
        end
    end
end

--#endregion

--#endregion

-- ╓───────────────────────────────────╖
-- ║ UI Panels and Overlay Rendering   ║
-- ╙───────────────────────────────────╜

--#region UI Panels and Overlay Rendering

local function getPauseMenuMetrics()
    local headerH = 88
    local footerH = 82
    local rowH = 38
    local rowGap = 44
    local sectionGap = 36
    local topPad = 18
    local bottomPad = 16

    local contentH = 0

    for i = 1, #menuOrder do
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
    love.graphics.setColor(1, 1, 1, 0.96)
    love.graphics.print("Paused", m.panelX + 24, m.panelY + 18)

    love.graphics.setFont(fontSmall)
    love.graphics.setColor(1, 1, 1, 0.58)
    love.graphics.print("Realtime Path Tracer Controls", m.panelX + 26, m.panelY + 54)

    local contentTop = m.firstRowY - 6
    local contentBottom = m.panelY + m.panelH - m.footerH - 12
    love.graphics.setScissor(m.panelX + 8, contentTop, m.panelW - 16, contentBottom - contentTop)

    for i = 1, #menuOrder do
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
        { "Scene",   sceneNames[tracerSettings.sceneVariant] or tostring(tracerSettings.sceneVariant) },
        { "Bounces", tostring(tracerSettings.maxBounces) },
        { "Steps",   tostring(tracerSettings.maxSteps) },
        { "Shadows", formatBool(tracerSettings.shadows) },
        { "Reflect", formatBool(tracerSettings.reflections) },
    }

    if tracerSettings.sceneVariant == 3 then
        local selected = getSelectedModelPath()
        lines[#lines + 1] = { "Model", selected and basename(selected) or "None" }
        lines[#lines + 1] = { "OBJ Tris", tostring(importedScene.triCount or 0) }
        lines[#lines + 1] = { "OBJ Files", tostring(#modelBrowser.files) }
    end

    if uiState.compactHud then
        local panelW = 240
        local panelH = 104

        drawRoundedPanel(x, y, panelW, panelH, 14, 0.68, 0.10)

        love.graphics.setFont(fontSmall)
        love.graphics.setColor(1, 1, 1, 0.55)
        love.graphics.print("PATH TRACER", x + 14, y + 10)

        love.graphics.setFont(fontBody)
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.print(renderModes[tracerSettings.modeIndex].name, x + 14, y + 28)

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
    love.graphics.print("PATH TRACER", x + 14, y + 10)

    love.graphics.setFont(fontBody)
    love.graphics.setColor(1, 1, 1, 0.95)
    love.graphics.print(renderModes[tracerSettings.modeIndex].name, x + 14, y + 26)

    local lineY = y + headerH
    love.graphics.setFont(fontSmall)

    for i = 1, #lines do
        love.graphics.setColor(1, 1, 1, 0.62)
        love.graphics.print(lines[i][1], x + 14, lineY)
        drawChip(lines[i][2], x + panelW - 14, lineY - 4, true, 120)
        lineY = lineY + rowH
    end
end

local function drawBottomHintBar()
    local barH = 42
    love.graphics.setColor(0, 0, 0, 0.34)
    love.graphics.rectangle("fill", 0, height - barH, width, barH)

    love.graphics.setFont(fontSmall)
    love.graphics.setColor(1, 1, 1, 0.78)

    local text =
    "Esc Pause   •   Q / E Cycle Models   •   F5 Refresh Objects   •   R Reset Accumulation   •   Tab Toggle HUD   •   Caps—Lk Toggle Input   •   W / A / S / D Movement   •   Space Ascend   •   L—Ctrl Descend   •   Mouse Axis Look Around   •   Shift Increase Camera Speed"
    love.graphics.printf(text, 14, height - 28, width - 28, "left")
end

--#endregion

-- ╓───────────────────────────────────╖
-- ║ Final Draw Call to LÖVE for GPU   ║
-- ╙───────────────────────────────────╜

--#region Final Draw Call to LÖVE for GPU

function love.draw()
    if not isPaused then
        shader:send("iFrame", currentFrame)
        shader:send("iResolution", { renderWidth, renderHeight })
        shader:send("camPos", camera.pos)
        shader:send("yaw", camera.yaw)
        shader:send("pitch", camera.pitch)
        shader:send("tex", accumSrc)

        shader:send("uMaxBounces", tracerSettings.maxBounces)
        shader:send("uMaxSteps", tracerSettings.maxSteps)
        shader:send("uEnableShadows", boolToInt(tracerSettings.shadows))
        shader:send("uEnableReflections", boolToInt(tracerSettings.reflections))
        shader:send("uSceneVariant", tracerSettings.sceneVariant)
        shader:send("uMeshTriCount", importedScene.triCount or 0)
        shader:send("uMeshTexSize", importedScene.meshTexSize or { 3, 1 })

        if importedScene.meshVertsImage then
            shader:send("meshVerts", importedScene.meshVertsImage)
        end

        accumDst:renderTo(function()
            love.graphics.clear(0, 0, 0, 1)
            love.graphics.setShader(shader)
            love.graphics.setBlendMode("alpha", "premultiplied")
            love.graphics.draw(accumSrc, 0, 0)
            love.graphics.setShader()
        end)

        love.graphics.setShader()
        love.graphics.setBlendMode("alpha", "alphamultiply")
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(accumDst, 0, 0, 0, width / renderWidth, height / renderHeight)

        swap()
        currentFrame = currentFrame + 1
    else
        love.graphics.setShader()
        love.graphics.setBlendMode("alpha", "alphamultiply")
        love.graphics.setColor(1, 1, 1, 1)

        local pausedCanvas = accumSrc or accumDst
        if pausedCanvas then
            love.graphics.draw(pausedCanvas, 0, 0, 0, width / renderWidth, height / renderHeight)
        end

        drawPauseMenu()
    end

    drawHud()
    drawBottomHintBar()
end

--#endregion
