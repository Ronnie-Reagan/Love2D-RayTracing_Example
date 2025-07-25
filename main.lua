-- Ping‑pong accumulation + SDF path tracer
love.window.setMode(1900, 1060, {vsync = false})
local width, height = love.graphics.getDimensions()

-- Ping‑pong canvases
local accumA, accumB, accumSrc, accumDst

local shader
local currentFrame = 0
local keysDown = {}
local enableMouse = true

local camera = {
    pos   = {3, 1.5, 3},
    yaw   = 3.9465926535898,
    pitch = -0.155,
    fov   = math.pi/3
}

-- Utility math
local function add(a,b) return {a[1]+b[1],a[2]+b[2],a[3]+b[3]} end
local function sub(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
local function mul(v,s) return {v[1]*s,v[2]*s,v[3]*s} end
local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function norm(v) local m=math.sqrt(dot(v,v)); return {v[1]/m,v[2]/m,v[3]/m} end

-- Swap src/dst
local function swap()
    accumSrc, accumDst = accumDst, accumSrc
end

-- Clear both buffers
local function clearAll()
    accumA:renderTo(function() love.graphics.clear(0,0,0,1) end)
    accumB:renderTo(function() love.graphics.clear(0,0,0,1) end)
end

function love.load()
    love.window.setTitle("Path Traced SDF")
    love.mouse.setRelativeMode(true)

    -- 16-bit float buffers
    accumA = love.graphics.newCanvas(width, height, {format="rgba16f"})
    accumA:setFilter("linear","linear")
    accumB = love.graphics.newCanvas(width, height, {format="rgba16f"})
    accumB:setFilter("linear","linear")

    accumSrc = accumA
    accumDst = accumB

    shader = love.graphics.newShader("shader.glsl")

    clearAll()
end

function love.mousemoved(x,y,dx,dy)
    if love.window.hasMouseFocus() and enableMouse then
        camera.yaw   = (camera.yaw + dx*0.005) % (2*math.pi)
        camera.pitch = math.max(-math.pi/2+0.001, math.min(math.pi/2-0.001, camera.pitch - dy*0.005))
        currentFrame = 0
        clearAll()
    end
end

function love.keypressed(key)
    if key=="escape" then
        love.mouse.setRelativeMode(false)
        enableMouse = false
    elseif key=="r" then
        currentFrame = 0
        clearAll()
    else
        keysDown[key] = true
    end
end
function love.keyreleased(key)
    keysDown[key] = false
end

function love.update(dt)
    -- WASD movement
    local move = {0,0,0}
    if keysDown["w"] then move = add(move, {math.cos(camera.pitch)*math.sin(camera.yaw), math.sin(camera.pitch), math.cos(camera.pitch)*math.cos(camera.yaw)}) end
    if keysDown["s"] then move = sub(move, {math.cos(camera.pitch)*math.sin(camera.yaw), math.sin(camera.pitch), math.cos(camera.pitch)*math.cos(camera.yaw)}) end
    if keysDown["a"] then move = sub(move, {math.cos(camera.yaw),0,-math.sin(camera.yaw)}) end
    if keysDown["d"] then move = add(move, {math.cos(camera.yaw),0,-math.sin(camera.yaw)}) end
    if keysDown["space"] then move = add(move, {0,1,0}) end
    if keysDown["lshift"] then move = sub(move, {0,1,0}) end

    if dot(move,move)>0 then
        move = norm(move)
        camera.pos = add(camera.pos, mul(move, 2.5*dt))
        currentFrame = 0
        clearAll()
    end
end

function love.draw()
    -- Pass uniforms + source buffer
    shader:send("iFrame", currentFrame)
    shader:send("iResolution", {width, height})
    shader:send("camPos", camera.pos)
    shader:send("yaw", camera.yaw)
    shader:send("pitch", camera.pitch)
    shader:send("tex", accumSrc)

    -- 1) Render tracer + blend into dst
    accumDst:renderTo(function()
        love.graphics.setShader(shader)
        love.graphics.setBlendMode("alpha","premultiplied")
        love.graphics.draw(accumSrc, 0, 0)
        love.graphics.setShader()
    end)

    -- 2) Present dst
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha","alphamultiply")
    love.graphics.draw(accumDst, 0, 0)

    -- 3) Swap, advance
    swap()
    currentFrame = currentFrame + 1

    love.graphics.setColor(1,1,1)
    love.graphics.print("Frame: "..currentFrame, 10, 10)
end
