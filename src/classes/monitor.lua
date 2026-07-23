-- Monitor: a flowing grid of cards, one per reactor and one per turbine, plus an aggregate
-- header with global controls. Keeps the original bar-graph aesthetic; scales to any device
-- count by paging when the grid overflows the screen.

local HEADER_H = 6          -- rows reserved for the aggregate header + button row
local CARD_W = 25           -- outer card width (incl. border)
local CARD_H = 13           -- outer card height (incl. border)
local GAP = 1               -- gap between cards

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function round(num, dig)
    local m = 10 ^ (dig or 0)
    return math.floor(m * num + 0.5) / m
end

-- Human-readable RF-style number, fixed width.
local function fmt(num)
    num = num or 0
    if num >= 1000000000 then
        return string.format("%6.2fG", num / 1000000000)
    elseif num >= 1000000 then
        return string.format("%6.2fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%6.2fK", num / 1000)
    else
        return string.format("%6.1f ", num)
    end
end

local function truncate(text, width)
    if #text > width then
        return string.sub(text, 1, width)
    end
    return text
end

-- Short label from a peripheral id (drops the mod prefix, keeps the trailing number/name).
local function shortId(id)
    local tail = id:match("[_%-]([%w]+)$")
    return tail or id
end

--region primitives

local function drawText(mon, text, x, y, bg, fg)
    DrawUtil.drawText(mon, text, Vector2.new(x, y), bg, fg)
end

-- Horizontal fill bar.
local function drawHBar(mon, x, y, width, pct, fillColor, emptyColor)
    pct = clamp(pct, 0, 100)
    local fill = math.floor(width * pct / 100 + 0.5)
    DrawUtil.drawFilledBox(mon, emptyColor or colors.gray, Vector2.new(x, y), Vector2.new(width, 1))
    if fill > 0 then
        DrawUtil.drawFilledBox(mon, fillColor, Vector2.new(x, y), Vector2.new(fill, 1))
    end
end

-- RPM gauge: zone-colored fill 0..ceiling, white target line at idleRPM, red cell at the ceiling.
local function drawRPMGauge(mon, x, y, width, rpm, target, safe, ceiling)
    local frac = clamp(rpm / ceiling, 0, 1)
    local fill = math.floor(width * frac + 0.5)

    local color = colors.green
    if rpm >= ceiling then
        color = colors.red
    elseif rpm >= safe then
        color = colors.orange
    elseif rpm >= target * 0.98 and rpm <= target * 1.02 then
        color = colors.lime
    end

    DrawUtil.drawFilledBox(mon, colors.gray, Vector2.new(x, y), Vector2.new(width, 1))
    if fill > 0 then
        DrawUtil.drawFilledBox(mon, color, Vector2.new(x, y), Vector2.new(fill, 1))
    end

    -- target line
    local tx = clamp(math.floor(width * (target / ceiling) + 0.5), 1, width)
    DrawUtil.drawFilledBox(mon, colors.white, Vector2.new(x + tx - 1, y), Vector2.new(1, 1))
    -- ceiling redline
    DrawUtil.drawFilledBox(mon, colors.red, Vector2.new(x + width - 1, y), Vector2.new(1, 1))
end

--endregion
--region cards

local function drawCardFrame(mon, ox, oy, borderColor, title, titleColor)
    DrawUtil.drawBox(mon, borderColor, Vector2.new(ox, oy), Vector2.new(CARD_W, CARD_H))
    drawText(mon, truncate(" " .. title .. " ", CARD_W - 2), ox + 1, oy, colors.black, titleColor or borderColor)
end

---@param reactor Reactor
local function drawReactorCard(mon, ox, oy, reactor)
    local steam = reactor.activelyCooled
    local border = steam and colors.cyan or colors.green
    local badge = steam and "STEAM" or "POWER"

    drawCardFrame(mon, ox, oy, border, "R " .. shortId(reactor.id) .. "  [" .. badge .. "]")

    local ix, iy, iw = ox + 1, oy + 1, CARD_W - 2
    local dot = reactor.active and colors.lime or colors.red
    DrawUtil.drawFilledBox(mon, dot, Vector2.new(ox + CARD_W - 2, oy), Vector2.new(1, 1))

    -- Buffer bar (energy for passive, steam for active).
    local bufPct, bufLabel
    if steam then
        local cap = reactor.steamCapacity
        bufPct = cap > 0 and (reactor.averageStoredSteam / cap * 100) or 0
        bufLabel = "Steam"
    else
        bufPct = _G.overallStats.storedThisTick / _G.overallStats.capacity * 100
        bufLabel = "Buffer"
    end
    drawText(mon, string.format("%s %5.1f%%", bufLabel, bufPct), ix, iy, colors.black, colors.white)
    drawHBar(mon, ix, iy + 1, iw, bufPct, steam and colors.cyan or colors.green)

    -- Control rods.
    local rod = reactor.averageRodLevel or 0
    drawText(mon, string.format("Rods  %5.1f%%", rod), ix, iy + 3, colors.black, colors.white)
    drawHBar(mon, ix, iy + 4, iw, rod, colors.yellow)

    -- Temperatures.
    drawText(mon, string.format("Case %4dC  Fuel %4dC",
        math.floor((reactor.averageCaseTemp or 0) + 0.5),
        math.floor((reactor.averageFuelTemp or 0) + 0.5)), ix, iy + 6, colors.black, colors.lightBlue)

    -- Primary output.
    if steam then
        drawText(mon, "Steam " .. string.format("%5d", math.floor(reactor.averageSteamProductionRate + 0.5)) .. " mB/t",
            ix, iy + 8, colors.black, colors.cyan)
    else
        drawText(mon, "Gen   " .. fmt(reactor.averageLastRFT) .. " RF/t", ix, iy + 8, colors.black, colors.green)
    end

    drawText(mon, "Fuel  " .. string.format("%6.3f", reactor.averageFuelUsage or 0) .. " B/t",
        ix, iy + 9, colors.black, colors.orange)
    drawText(mon, "Waste " .. string.format("%6d", math.floor(reactor.waste or 0)) .. " mB",
        ix, iy + 10, colors.black, colors.orange)
end

---@param turbine Turbine
local function drawTurbineCard(mon, ox, oy, turbine)
    local cfg = CONTROL_CONFIG
    local rpm = turbine.rpm or 0

    local border = colors.green
    if rpm >= cfg.ceilingRPM then
        border = colors.red
    elseif rpm >= cfg.safeRPM then
        border = colors.orange
    end

    drawCardFrame(mon, ox, oy, border, "T " .. shortId(turbine.id))

    local ix, iy, iw = ox + 1, oy + 1, CARD_W - 2
    local dot = turbine.active and colors.lime or colors.red
    DrawUtil.drawFilledBox(mon, dot, Vector2.new(ox + CARD_W - 2, oy), Vector2.new(1, 1))

    drawText(mon, string.format("%5d RPM", math.floor(rpm + 0.5)), ox + CARD_W - 11, oy, colors.black, border)

    -- RPM gauge (the marquee visual).
    drawRPMGauge(mon, ix, iy + 1, iw, rpm, cfg.idleRPM, cfg.safeRPM, cfg.ceilingRPM)
    drawText(mon, "target " .. cfg.idleRPM .. "  max " .. cfg.ceilingRPM, ix, iy + 2, colors.black, colors.lightGray)

    -- Power out.
    drawText(mon, "Power " .. fmt(turbine.averageEnergyProduced) .. " RF/t", ix, iy + 4, colors.black, colors.green)

    -- Steam in (actual flow vs cap).
    drawText(mon, string.format("Steam %5d/%5d mB/t",
        math.floor(turbine.averageSteamFlow + 0.5), turbine.steamCap or 0), ix, iy + 5, colors.black, colors.cyan)

    -- Coils state.
    if turbine.coilsEngaged then
        drawText(mon, "Coils: GENERATING", ix, iy + 7, colors.black, colors.lime)
    else
        drawText(mon, "Coils: idle @1800", ix, iy + 7, colors.black, colors.lightGray)
    end

    -- Own internal buffer = the demand signal.
    local bufPct = turbine.energyCapacity > 0 and (turbine.energyStored / turbine.energyCapacity * 100) or 0
    drawText(mon, string.format("Buffer %5.1f%%", bufPct), ix, iy + 9, colors.black, colors.white)
    drawHBar(mon, ix, iy + 10, iw, bufPct, colors.magenta)
end

--endregion
--region header

local function drawHeader(mon, width, page, pages)
    DrawUtil.drawFilledBox(mon, colors.gray, Vector2.new(1, 1), Vector2.new(width, HEADER_H - 1))

    local s = _G.overallStats
    local gridPct = s.storedThisTick / s.capacity * 100

    drawText(mon, truncate("MULTI REACTOR / TURBINE CONTROL", width - 12), 2, 1, colors.gray, colors.white)
    drawText(mon, string.format("R:%d  T:%d", s.passiveReactorCount + s.activeReactorCount, s.turbineCount),
        width - 11, 1, colors.gray, colors.yellow)

    drawText(mon, string.format("Grid %5.1f%%   Gen %s RF/t   Drain %s RF/t",
        gridPct, fmt(s.totalRFT), fmt(s.rfLost)), 2, 2, colors.gray, colors.white)

    drawText(mon, string.format("Steam %d/%d mB/t   Fuel %6.3f B/t   Waste %d mB",
        math.floor(s.steamProductionRate + 0.5), math.floor(s.steamConsumedLastTick + 0.5),
        s.fuelUsage, math.floor(s.waste)), 2, 3, colors.gray, colors.cyan)

    if pages > 1 then
        drawText(mon, string.format("Page %d/%d", page, pages), width - 11, 3, colors.gray, colors.yellow)
    end
end

--endregion

---@class Monitor
local Monitor = {

    clear = function(self)
        self.mon.setBackgroundColor(colors.black)
        self.mon.clear()
        self.mon.setCursorPos(1, 1)
    end,

    -- Ordered entity list: reactors first, then turbines, stable by id.
    collectEntities = function(self)
        local list = {}
        local rkeys = {}
        for id in pairs(_G.reactors) do rkeys[#rkeys + 1] = id end
        table.sort(rkeys)
        for _, id in ipairs(rkeys) do list[#list + 1] = { kind = "reactor", obj = _G.reactors[id] } end

        local tkeys = {}
        for id in pairs(_G.turbines) do tkeys[#tkeys + 1] = id end
        table.sort(tkeys)
        for _, id in ipairs(tkeys) do list[#list + 1] = { kind = "turbine", obj = _G.turbines[id] } end
        return list
    end,

    tryAddButton = function(self, name, func, x1, y1, x2, y2, inactive, active)
        local ok = pcall(function()
            self.touch:add(name, func, x1, y1, x2, y2, inactive, active)
        end)
        if ok then
            self.buttons[name] = true
        end
    end,

    handleResize = function(self)
        self.monPeripheral.setTextScale(0.5)
        self.size = Vector2.new(self.monPeripheral.getSize())
        self.mon = window.create(self.monPeripheral, 1, 1, self.size.x, self.size.y, false)
        self.touch = _G.Touchpoint.new(self.id, self.mon)
        self.buttons = {}
        self.page = self.page or 1

        local w, h = self.size.x, self.size.y
        self.cols = math.max(0, math.floor((w - 1) / (CARD_W + GAP)))
        local availH = h - HEADER_H
        self.rows = math.max(0, math.floor((availH + GAP) / (CARD_H + GAP)))
        self.cardsPerPage = math.max(1, self.cols * self.rows)
        self.tooSmall = (self.cols < 1 or self.rows < 1)

        -- Global control buttons on the header button row (row 5). Gracefully skipped if no room.
        local by = 5
        self:tryAddButton("Auto", function() toggleAutoMode() end, 2, by, 10, by, colors.red, colors.lime)
        self:tryAddButton("Rctrs", function() setReactors(not _G.btnOn) end, 12, by, 20, by, colors.red, colors.lime)
        self:tryAddButton("Turbs", function()
            _G.turbinesOn = not _G.turbinesOn
            setTurbines(_G.turbinesOn)
        end, 22, by, 30, by, colors.red, colors.lime)

        if w >= 54 then
            self:tryAddButton("Prev", function() self.page = math.max(1, self.page - 1) end,
                w - 20, by, w - 12, by, colors.gray, colors.blue)
            self:tryAddButton("Next", function() self.page = self.page + 1 end,
                w - 10, by, w - 2, by, colors.gray, colors.blue)
        end
    end,

    updateButtonStates = function(self)
        if self.buttons["Auto"] then self.touch:setButton("Auto", CONTROL_CONFIG.autoMode) end
        if self.buttons["Rctrs"] then self.touch:setButton("Rctrs", _G.btnOn) end
        if self.buttons["Turbs"] then self.touch:setButton("Turbs", _G.turbinesOn ~= false) end
    end,

    draw = function(self)
        self.mon.setVisible(false)
        self:clear()

        local entities = self:collectEntities()
        local pages = math.max(1, math.ceil(#entities / self.cardsPerPage))
        if self.page > pages then self.page = pages end

        drawHeader(self.mon, self.size.x, self.page, pages)

        if self.tooSmall then
            drawText(self.mon, "Monitor too small for cards -", 2, HEADER_H + 1, colors.black, colors.red)
            drawText(self.mon, "make it wider/taller.", 2, HEADER_H + 2, colors.black, colors.red)
        else
            local startIdx = (self.page - 1) * self.cardsPerPage + 1
            local endIdx = math.min(#entities, startIdx + self.cardsPerPage - 1)
            for i = startIdx, endIdx do
                local slot = i - startIdx
                local col = slot % self.cols
                local row = math.floor(slot / self.cols)
                local ox = 1 + col * (CARD_W + GAP)
                local oy = HEADER_H + 1 + row * (CARD_H + GAP)
                local e = entities[i]
                if e.kind == "reactor" then
                    drawReactorCard(self.mon, ox, oy, e.obj)
                else
                    drawTurbineCard(self.mon, ox, oy, e.obj)
                end
            end

            if #entities == 0 then
                drawText(self.mon, "Waiting for reactors / turbines...", 2, HEADER_H + 1, colors.black, colors.yellow)
            end
        end

        self:updateButtonStates()
        self.touch:drawAllButtons()
        self.mon.setVisible(true)
    end,

    handleClick = function(self, buttonName)
        local btn = self.touch.buttonList[buttonName]
        if btn then btn.func() end
    end,

    handleEvents = function(self, event)
        if event[2] ~= self.id then
            return
        end
        local touchpointEvent = { self.touch:handleEvents(unpack(event)) }
        if touchpointEvent[1] == "button_click" then
            self:handleClick(touchpointEvent[3])
        end
        if event[1] == "monitor_resize" then
            if self.monPeripheral.getTextScale() ~= 0.5 then
                self.mon.setVisible(false)
                self.monPeripheral.setTextScale(0.5)
            end
            self:handleResize()
        end
        self:draw()
    end,
}

---@param id string
---@return Monitor
local function new(id)
    local monPeripheral = peripheral.wrap(id)
    local instance = {
        id = id,
        monPeripheral = monPeripheral,
        page = 1,
        buttons = {},
    }
    setmetatable(instance, { __index = Monitor })
    instance:handleResize()
    return instance
end

_G.Monitor = {
    new = new,
}
