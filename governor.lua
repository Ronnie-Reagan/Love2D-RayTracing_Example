local mathutil = require("shared.mathutil")

local clamp = mathutil.clamp
local clampInt = mathutil.clampInt
local mibToBytes = mathutil.mibToBytes

local M = {}

local DEFAULT_STATE = {
    enabled = true,
    minimumFPS = 30,
    maxSecondsPerFrame = 1 / 24,
    dummyRenderOnMove = false,
    dummyRenderHoldSeconds = 0.18,
    limitRAM = false,
    ramLimitMB = 2048,
    limitVRAM = false,
    vramLimitMB = 1024,
    requestedRenderScale = nil,
    lastFrameSeconds = 0.0,
    lastMotionTime = -1e9,
    estimatedSceneVRAMBytes = 0,
    estimatedSceneRAMBytes = 0,
    estimatedRenderVRAMBytes = 0,
    estimatedTotalVRAMBytes = 0,
    importedTriangleBudget = nil,
    importedBudgetReason = "hard-cap",
}

local function copyDefaults()
    local out = {}
    for key, value in pairs(DEFAULT_STATE) do
        out[key] = value
    end
    return out
end

function M.new(initial)
    local state = copyDefaults()
    if initial then
        for key, value in pairs(initial) do
            state[key] = value
        end
    end
    return state
end

function M.getFrameBudgetSeconds(state)
    local fpsBudget = (state.minimumFPS or 0) > 0 and (1 / math.max(1, state.minimumFPS)) or nil
    local secondsBudget = tonumber(state.maxSecondsPerFrame) or 0
    if secondsBudget <= 0 then
        return fpsBudget
    end
    if not fpsBudget then
        return secondsBudget
    end
    return math.min(fpsBudget, secondsBudget)
end

function M.noteMotion(state, now)
    state.lastMotionTime = tonumber(now) or state.lastMotionTime
end

function M.shouldUseDummyRender(state, now)
    if not state.enabled or not state.dummyRenderOnMove then
        return false
    end

    now = tonumber(now) or 0.0
    return (now - (state.lastMotionTime or -1e9)) <= (state.dummyRenderHoldSeconds or 0.0)
end

function M.setRequestedRenderScale(state, scale, limits)
    state.requestedRenderScale = clamp(
        tonumber(scale) or 1.0,
        limits and limits.min or 0.05,
        limits and limits.max or 4.0
    )
end

function M.updateRenderVRAMEstimate(state, renderWidth, renderHeight)
    renderWidth = math.max(1, math.floor(renderWidth or 1))
    renderHeight = math.max(1, math.floor(renderHeight or 1))

    local rgba16fBytes = renderWidth * renderHeight * 8
    state.estimatedRenderVRAMBytes = rgba16fBytes * 4
    state.estimatedTotalVRAMBytes = state.estimatedRenderVRAMBytes + (state.estimatedSceneVRAMBytes or 0)
end

function M.updateSceneEstimates(state, scene)
    state.estimatedSceneVRAMBytes = tonumber(scene and scene.estimatedVRAMBytes) or 0
    state.estimatedSceneRAMBytes = tonumber(scene and scene.estimatedRAMBytes) or 0
    state.importedTriangleBudget = tonumber(scene and scene.budgetedTriangles) or state.importedTriangleBudget
    state.importedBudgetReason = tostring(scene and scene.budgetReason or state.importedBudgetReason)
    state.estimatedTotalVRAMBytes = (state.estimatedRenderVRAMBytes or 0) + (state.estimatedSceneVRAMBytes or 0)
end

function M.getImportBudget(state, hardCap, estimates)
    local budget = math.max(1, math.floor(hardCap or 1))
    local reason = "hard-cap"

    if state.limitVRAM then
        local vramLimitBytes = mibToBytes(state.vramLimitMB)
        local reservedRender = tonumber(estimates and estimates.renderVRAMBytes) or 0
        local fixedScene = tonumber(estimates and estimates.baseSceneVRAMBytes) or 0
        local perTriangleVRAM = math.max(1, math.floor(tonumber(estimates and estimates.perTriangleVRAMBytes) or 1))
        local available = vramLimitBytes - reservedRender - fixedScene
        local vramBudget = math.floor(available / perTriangleVRAM)
        budget = math.min(budget, math.max(0, vramBudget))
        reason = "vram"
    end

    if state.limitRAM then
        local ramLimitBytes = mibToBytes(state.ramLimitMB)
        local fixedRAM = tonumber(estimates and estimates.baseSceneRAMBytes) or 0
        local perTriangleRAM = math.max(1, math.floor(tonumber(estimates and estimates.perTriangleRAMBytes) or 1))
        local available = ramLimitBytes - fixedRAM
        local ramBudget = math.floor(available / perTriangleRAM)
        budget = math.min(budget, math.max(0, ramBudget))
        reason = (reason == "hard-cap") and "ram" or (reason .. "+ram")
    end

    return math.max(0, math.floor(budget)), reason
end

function M.stepTowardsFrameBudget(state, frameSeconds, currentScale, limits)
    state.lastFrameSeconds = tonumber(frameSeconds) or 0.0

    if not state.enabled then
        return currentScale, false
    end

    local budget = M.getFrameBudgetSeconds(state)
    if not budget or budget <= 0 then
        return currentScale, false
    end

    local preferred = tonumber(state.requestedRenderScale) or currentScale
    local minScale = limits and limits.min or 0.05
    local maxScale = math.min(limits and limits.max or preferred, preferred)
    local changed = false
    local nextScale = currentScale

    if frameSeconds > budget * 1.06 then
        nextScale = clamp(currentScale - 0.05, minScale, maxScale)
        changed = math.abs(nextScale - currentScale) > 0.0001
    elseif frameSeconds < budget * 0.78 and currentScale < maxScale then
        nextScale = clamp(currentScale + 0.05, minScale, maxScale)
        changed = math.abs(nextScale - currentScale) > 0.0001
    end

    return nextScale, changed
end

function M.adjustMinimumFPS(state, delta)
    state.minimumFPS = clampInt((state.minimumFPS or 30) + delta * 5, 1, 240)
end

function M.adjustMaxSecondsPerFrame(state, delta)
    local step = (math.abs(delta) >= 10) and 0.010 or 0.002
    state.maxSecondsPerFrame = clamp((state.maxSecondsPerFrame or (1 / 24)) + delta * step, 0.0, 5.0)
end

function M.adjustRamLimit(state, delta)
    local step = (math.abs(delta) >= 10) and 512 or 128
    state.ramLimitMB = clampInt((state.ramLimitMB or 2048) + delta * step, 128, 65536)
end

function M.adjustVRamLimit(state, delta)
    local step = (math.abs(delta) >= 10) and 256 or 64
    state.vramLimitMB = clampInt((state.vramLimitMB or 1024) + delta * step, 64, 32768)
end

return M
