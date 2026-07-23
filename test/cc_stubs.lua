-- Minimal ComputerCraft environment stubs so the controller can run headless under
-- plain Lua (5.3/5.4) for smoke testing. Run from the project root: lua test/sim.lua

unpack = unpack or table.unpack

function sleep(_) end

--region colors
colors = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8,
    yellow = 16, lime = 32, pink = 64, gray = 128,
    lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
    brown = 4096, green = 8192, red = 16384, black = 32768,
}
local blitDigits = "0123456789abcdef"
function colors.toBlit(color)
    local n = math.floor(math.log(color) / math.log(2) + 0.5)
    return blitDigits:sub(n + 1, n + 1)
end
--endregion

--region vector (2D subset of CC's vector API)
local vmeta
vmeta = {
    __add = function(a, b) return vector.new(a.x + b.x, a.y + b.y) end,
    __sub = function(a, b) return vector.new(a.x - b.x, a.y - b.y) end,
    __mul = function(a, b)
        if type(b) == "number" then return vector.new(a.x * b, a.y * b) end
        return vector.new(a.x * b.x, a.y * b.y)
    end,
    __unm = function(a) return vector.new(-a.x, -a.y) end,
    __eq = function(a, b) return a.x == b.x and a.y == b.y end,
}
vector = {
    new = function(x, y)
        return setmetatable({ x = x, y = y }, vmeta)
    end,
}
--endregion

--region terminal / window
-- A fake terminal is a character grid; writes outside the grid are clipped like CC does.
local function makeTerm(w, h)
    local t = {
        _w = w, _h = h,
        _x = 1, _y = 1,
        _bg = colors.black, _fg = colors.white,
        _grid = {},
        _scale = 1,
        _visible = true,
    }
    for row = 1, h do t._grid[row] = {} end

    function t.getSize() return t._w, t._h end
    function t.setCursorPos(x, y) t._x, t._y = math.floor(x), math.floor(y) end
    function t.getCursorPos() return t._x, t._y end
    function t.setBackgroundColor(c) t._bg = c end
    function t.getBackgroundColor() return t._bg end
    function t.setTextColor(c) t._fg = c end
    function t.getTextColor() return t._fg end
    function t.setCursorBlink(_) end
    function t.isColor() return true end

    local function put(x, y, ch, fg, bg)
        if x >= 1 and x <= t._w and y >= 1 and y <= t._h then
            t._grid[y][x] = { ch = ch, fg = fg, bg = bg }
        end
    end

    function t.write(text)
        text = tostring(text)
        for i = 1, #text do
            put(t._x + i - 1, t._y, text:sub(i, i), t._fg, t._bg)
        end
        t._x = t._x + #text
    end

    function t.blit(text, fg, bg)
        assert(#text == #fg and #text == #bg, "blit: mismatched argument lengths")
        for i = 1, #text do
            put(t._x + i - 1, t._y, text:sub(i, i), fg:sub(i, i), bg:sub(i, i))
        end
        t._x = t._x + #text
    end

    function t.clear()
        for row = 1, t._h do t._grid[row] = {} end
    end
    function t.clearLine()
        t._grid[t._y] = {}
    end

    function t.setVisible(v) t._visible = v end
    function t.setTextScale(s) t._scale = s end
    function t.getTextScale() return t._scale end

    return t
end

local nativeTerm = makeTerm(51, 19)
local currentTerm = nativeTerm

term = setmetatable({
    redirect = function(target)
        local old = currentTerm
        currentTerm = target
        return old
    end,
    current = function() return currentTerm end,
    native = function() return nativeTerm end,
}, {
    -- Pass any other term.* call through to the current target.
    __index = function(_, key)
        return function(...)
            local f = currentTerm[key]
            if f then return f(...) end
        end
    end,
})

window = {
    create = function(_, _, _, w, h, visible)
        local win = makeTerm(w, h)
        win.setVisible(visible ~= false)
        return win
    end,
}

paintutils = {
    drawFilledBox = function(x1, y1, x2, y2, color)
        local tgt = currentTerm
        tgt.setBackgroundColor(color)
        local width = x2 - x1 + 1
        if width < 1 then return end
        for y = y1, y2 do
            tgt.setCursorPos(x1, y)
            tgt.write(string.rep(" ", width))
        end
    end,
    drawBox = function(x1, y1, x2, y2, color)
        local tgt = currentTerm
        tgt.setBackgroundColor(color)
        local width = x2 - x1 + 1
        if width < 1 then return end
        tgt.setCursorPos(x1, y1)
        tgt.write(string.rep(" ", width))
        tgt.setCursorPos(x1, y2)
        tgt.write(string.rep(" ", width))
        for y = y1, y2 do
            tgt.setCursorPos(x1, y)
            tgt.write(" ")
            tgt.setCursorPos(x2, y)
            tgt.write(" ")
        end
    end,
}

_G.makeTerm = makeTerm
--endregion

--region peripheral
peripheral = {
    _registry = {},   -- name -> { type = string, methods = table }
    register = function(name, ptype, methods)
        peripheral._registry[name] = { type = ptype, methods = methods }
    end,
    getNames = function()
        local names = {}
        for name in pairs(peripheral._registry) do names[#names + 1] = name end
        table.sort(names)
        return names
    end,
    getType = function(name)
        local entry = peripheral._registry[name]
        return entry and entry.type or nil
    end,
    wrap = function(name)
        local entry = peripheral._registry[name]
        return entry and entry.methods or nil
    end,
    getMethods = function(name)
        local entry = peripheral._registry[name]
        if not entry then return nil end
        local out = {}
        for k in pairs(entry.methods) do out[#out + 1] = k end
        table.sort(out)
        return out
    end,
}
--endregion

--region os / events
_G.__simClock = 0 -- seconds; the sim advances this
local eventQueue = {}

os.clock = function() return _G.__simClock end
os.epoch = function(_) return math.floor(_G.__simClock * 1000) end
os.queueEvent = function(...) eventQueue[#eventQueue + 1] = { ... } end
os.pullEvent = function(_)
    if #eventQueue > 0 then
        return unpack(table.remove(eventQueue, 1))
    end
    error("pullEvent with empty queue (not supported in sim)", 2)
end
os.startTimer = function(_) return 1 end
os.reboot = function() error("os.reboot called in sim") end
--endregion

--region fs (in-memory) + textutils + shell
local memfs = {}

fs = {
    combine = function(a, b)
        if a == "" then return b end
        return (a .. "/" .. b):gsub("//+", "/")
    end,
    getDir = function(path)
        return path:match("^(.*)/[^/]+$") or ""
    end,
    exists = function(path) return memfs[path] ~= nil end,
    makeDir = function(_) end,
    delete = function(path) memfs[path] = nil end,
    isDir = function(_) return false end,
    list = function(_) return {} end,
    open = function(path, mode)
        if mode == "r" then
            local content = memfs[path]
            if content == nil then return nil end
            return {
                readAll = function() return content end,
                close = function() end,
            }
        elseif mode == "w" then
            local buffer = {}
            return {
                write = function(text) buffer[#buffer + 1] = text end,
                close = function() memfs[path] = table.concat(buffer) end,
            }
        end
    end,
}

local function serializeValue(value, indent)
    local t = type(value)
    if t == "table" then
        local parts = { "{" }
        for k, v in pairs(value) do
            local key
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                key = k
            else
                key = "[" .. serializeValue(k) .. "]"
            end
            parts[#parts + 1] = key .. " = " .. serializeValue(v) .. ","
        end
        parts[#parts + 1] = "}"
        return table.concat(parts, " ")
    elseif t == "string" then
        return string.format("%q", value)
    else
        return tostring(value)
    end
end

textutils = {
    serialize = function(value) return serializeValue(value) end,
    unserialise = function(text)
        local fn = load("return " .. text)
        return fn and fn() or nil
    end,
}
textutils.serialise = textutils.serialize
textutils.unserialize = textutils.unserialise

shell = { run = function(path) dofile(path) end }
--endregion
