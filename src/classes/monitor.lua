-- Monitor: a flowing grid of cards, one per reactor and one per turbine, plus an aggregate
-- header with global controls. Keeps the original bar-graph aesthetic; scales to any device
-- count by paging when the grid overflows the screen.

local TEXT_ROWS = 5         -- header text rows: title, grid stats, steam stats, settings values, warning
local BTN_H = 3             -- button height in rows (tall enough for a drawn border + centered label)
local BTN_GAP = 1           -- gap between buttons
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

-- Steam-group badge ("G1", "G2", ...) for a card, or "" when groups aren't in use or the
-- entity is in the implicit shared ("default") group.
local function groupLabel(groupId)
    if not _G.overallStats.hasSteamGroups then return "" end
    if type(groupId) == "number" then return "G" .. groupId end
    return ""
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
    if steam then
        local gl = groupLabel(reactor.groupId)
        if gl ~= "" then badge = badge .. " " .. gl end
    end

    local calProg = reactor.calibrationProgress and reactor:calibrationProgress()
    if calProg then badge = badge .. " CAL" end

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

    -- Control rods (with the calibrated best-efficiency rod level appended when known).
    local rod = reactor.averageRodLevel or 0
    local rodLine = string.format("Rods  %5.1f%%", rod)
    if reactor.bestEffLevel then
        rodLine = string.format("Rods %5.1f%% best %d%%", rod, reactor.bestEffLevel)
    end
    drawText(mon, rodLine, ix, iy + 3, colors.black, colors.white)
    drawHBar(mon, ix, iy + 4, iw, rod, colors.yellow)

    -- Temperatures.
    drawText(mon, string.format("Case %4dC  Fuel %4dC",
        math.floor((reactor.averageCaseTemp or 0) + 0.5),
        math.floor((reactor.averageFuelTemp or 0) + 0.5)), ix, iy + 6, colors.black, colors.lightBlue)

    -- Primary output (replaced by a calibration progress readout during a sweep).
    if calProg then
        drawText(mon, string.format("Calibrating %3d%%", math.floor(calProg * 100 + 0.5)),
            ix, iy + 8, colors.black, colors.magenta)
    elseif steam then
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

    -- Flywheel (feature 5): while armed AND idle the gauge rescales past 2000 and the white
    -- line marks the 2000 danger threshold. A capped run scales to flywheelCeilingRPM; an
    -- uncapped run (cap 0) scales dynamically to the current RPM so the bar never pins at full.
    -- Otherwise the normal 1800/2000 gauge (per-turbine idleRPM override honored).
    local armedIdle = (cfg.flywheelMode == true) and (turbine.desiredCoils == false)
    local gaugeCeiling, gaugeSafe, target
    if armedIdle then
        local cap = cfg.flywheelCeilingRPM or 0
        if cap > 0 then
            gaugeCeiling = cap
        else
            -- Uncapped: round the scale up past the current RPM so there's always headroom.
            gaugeCeiling = math.max(cfg.ceilingRPM * 2, math.ceil((rpm + 1) / 500) * 500)
        end
        gaugeSafe = cfg.ceilingRPM               -- fill turns red once past the 2000 redline
        target = cfg.ceilingRPM                  -- white line marks the 2000 danger threshold
    else
        gaugeCeiling = cfg.ceilingRPM
        gaugeSafe = cfg.safeRPM
        target = clampIdleRPM(getEntitySetting(turbine.id, "idleRPM"))
    end

    local border = colors.green
    if armedIdle then
        border = rpm >= cfg.ceilingRPM and colors.red or colors.magenta
    elseif rpm >= gaugeCeiling then
        border = colors.red
    elseif rpm >= gaugeSafe then
        border = colors.orange
    end

    local title = "T " .. shortId(turbine.id)
    local gl = groupLabel(turbine.groupId)
    if gl ~= "" then title = title .. " [" .. gl .. "]" end
    drawCardFrame(mon, ox, oy, border, title)

    local ix, iy, iw = ox + 1, oy + 1, CARD_W - 2
    local dot = turbine.active and colors.lime or colors.red
    DrawUtil.drawFilledBox(mon, dot, Vector2.new(ox + CARD_W - 2, oy), Vector2.new(1, 1))

    drawText(mon, string.format("%5d RPM", math.floor(rpm + 0.5)), ox + CARD_W - 11, oy, colors.black, border)

    -- RPM gauge (the marquee visual).
    drawRPMGauge(mon, ix, iy + 1, iw, rpm, target, gaugeSafe, gaugeCeiling)
    if armedIdle then
        local capText = (cfg.flywheelCeilingRPM or 0) > 0 and ("cap " .. cfg.flywheelCeilingRPM) or "no cap"
        drawText(mon, "Flywheel " .. capText, ix, iy + 2, colors.black, colors.magenta)
    else
        drawText(mon, "Target " .. target .. "  Max " .. gaugeCeiling, ix, iy + 2, colors.black, colors.lightGray)
    end

    -- Power out.
    drawText(mon, "Power " .. fmt(turbine.averageEnergyProduced) .. " RF/t", ix, iy + 4, colors.black, colors.green)

    -- Steam in (actual flow vs cap).
    drawText(mon, string.format("Steam %5d/%5d mB/t",
        math.floor(turbine.averageSteamFlow + 0.5), turbine.steamCap or 0), ix, iy + 5, colors.black, colors.cyan)

    -- Coils state.
    if turbine.coilsEngaged then
        drawText(mon, "Coils: generating power", ix, iy + 7, colors.black, colors.lime)
    elseif armedIdle then
        drawText(mon, string.format("Flywheel spin %d", math.floor(rpm + 0.5)), ix, iy + 7, colors.black, colors.magenta)
    else
        drawText(mon, "Coils idle, hold " .. target, ix, iy + 7, colors.black, colors.lightGray)
    end

    -- Own internal buffer = the demand signal.
    local bufPct = turbine.energyCapacity > 0 and (turbine.energyStored / turbine.energyCapacity * 100) or 0
    drawText(mon, string.format("Buffer %5.1f%%", bufPct), ix, iy + 9, colors.black, colors.white)
    drawHBar(mon, ix, iy + 10, iw, bufPct, colors.magenta)
end

--endregion
--region header

local function drawHeader(mon, width, page, pages)
    DrawUtil.drawFilledBox(mon, colors.gray, Vector2.new(1, 1), Vector2.new(width, TEXT_ROWS))

    local s = _G.overallStats
    local gridPct = s.storedThisTick / s.capacity * 100
    local cfg = CONTROL_CONFIG

    drawText(mon, truncate("MULTI REACTOR / TURBINE CONTROL", width - 12), 2, 1, colors.gray, colors.white)
    drawText(mon, string.format("Reactors:%d  Turbines:%d", s.passiveReactorCount + s.activeReactorCount, s.turbineCount),
        width - 21, 1, colors.gray, colors.yellow)

    drawText(mon, string.format("Grid %5.1f%%   Generating %s RF/t   Drain %s RF/t",
        gridPct, fmt(s.totalRFT), fmt(s.rfLost)), 2, 2, colors.gray, colors.white)

    drawText(mon, string.format("Steam %d/%d mB/t   Fuel %6.3f B/t   Waste %d mB",
        math.floor(s.steamProductionRate + 0.5), math.floor(s.steamConsumedLastTick + 0.5),
        s.fuelUsage, math.floor(s.waste)), 2, 3, colors.gray, colors.cyan)

    if pages > 1 then
        drawText(mon, string.format("Page %d of %d", page, pages), width - 13, 3, colors.gray, colors.yellow)
    end

    -- Verbose current-settings line (the bordered +/- buttons below change these).
    local settings = string.format(
        "Target RPM %d    Buffer band %d-%d%%    Coil band %d-%d%%    Interval %d tick    Optimize: %s",
        cfg.idleRPM, cfg.bufferMin, cfg.bufferMax, cfg.coilsOnBelowPct, cfg.coilsOffAbovePct,
        cfg.controlIntervalTicks or 1, cfg.optimizeMode == "efficiency" and "Efficiency" or "Output")
    drawText(mon, truncate(settings, width - 2), 2, 4, colors.gray, colors.white)

    if cfg.flywheelMode then
        drawText(mon, truncate("! FLYWHEEL ARMED - idle turbines exceed 2000 RPM and may EXPLODE !", width - 2),
            2, 5, colors.gray, colors.red)
    end
end

-- Build the row-strings Touchpoint draws for a bordered button: the verbose text centered on
-- the middle row, blank rows above/below. `.label` carries the SHORT key so the button is still
-- addressed by name (state updates, tests) while displaying the verbose text.
local function buttonLabel(name, text, width, height)
    local rows = { label = name }
    local mid = math.floor((height - 1) / 2) + 1
    for i = 1, height do
        if i == mid then
            local s = (#text > width) and text:sub(1, width) or text
            local pad = width - #s
            local left = math.floor(pad / 2)
            rows[i] = string.rep(" ", left) .. s .. string.rep(" ", pad - left)
        else
            rows[i] = string.rep(" ", width)
        end
    end
    return rows
end

-- Ordered list of every header button. A spec with break_=true forces the next button onto a
-- fresh row (used to split the mode toggles from the settings adjusters).
---@param self Monitor
local function buttonSpecs(self)
    return {
        { name = "Auto",  label = "Auto Control",     func = function() toggleAutoMode() end,                       off = colors.red,  on = colors.lime },
        { name = "Rctrs", label = "Reactors On/Off",  func = function() setReactors(not _G.btnOn) end,              off = colors.red,  on = colors.lime },
        { name = "Turbs", label = "Turbines On/Off",  func = function() _G.turbinesOn = not _G.turbinesOn; setTurbines(_G.turbinesOn) end, off = colors.red, on = colors.lime },
        { name = "Fly",   label = "Flywheel Mode",    func = function() toggleFlywheel() end,                       off = colors.gray, on = colors.magenta },
        { name = "Opt",   label = "Optimize Mode",    func = function() toggleOptimizeMode() end,                   off = colors.gray, on = colors.lime },
        { name = "Calib", label = "Calibrate Reactor Efficiency", func = function() startCalibration() end,        off = colors.gray, on = colors.orange },
        { name = "Prev",  label = "Previous Page",    func = function() self.page = math.max(1, self.page - 1) end, off = colors.gray, on = colors.blue },
        { name = "Next",  label = "Next Page",        func = function() self.page = self.page + 1 end,              off = colors.gray, on = colors.blue },
        { break_ = true },
        { name = "RPM-",  label = "Lower Target RPM",   func = function() adjustIdleRPM(-100) end,      off = colors.gray, on = colors.blue },
        { name = "RPM+",  label = "Raise Target RPM",   func = function() adjustIdleRPM(100) end,       off = colors.gray, on = colors.blue },
        { name = "Buf-",  label = "Narrow Buffer Band", func = function() adjustBufferBand(-5) end,     off = colors.gray, on = colors.blue },
        { name = "Buf+",  label = "Widen Buffer Band",  func = function() adjustBufferBand(5) end,      off = colors.gray, on = colors.blue },
        { name = "Coil-", label = "Narrow Coil Band",   func = function() adjustCoilBand(-5) end,       off = colors.gray, on = colors.blue },
        { name = "Coil+", label = "Widen Coil Band",    func = function() adjustCoilBand(5) end,        off = colors.gray, on = colors.blue },
        { name = "Tick-", label = "Faster Response",    func = function() adjustControlInterval(-1) end, off = colors.gray, on = colors.blue },
        { name = "Tick+", label = "Slower Response",    func = function() adjustControlInterval(1) end,  off = colors.gray, on = colors.blue },
    }
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

    -- Flow the bordered buttons across the width starting at row y0: each is sized to its label,
    -- wraps to a new row when it would overrun, and (break_) starts a fresh row between groups.
    -- Registers each with Touchpoint and records its rect for the border pass. Returns the last
    -- row used, so the caller knows where the header ends.
    layoutButtons = function(self, width, y0)
        local rects = {}
        local x, y = 1, y0
        for _, spec in ipairs(buttonSpecs(self)) do
            if spec.break_ then
                x = 1
                y = y + BTN_H + BTN_GAP
            else
                local w = #spec.label + 4      -- 1 border + 1 pad on each side of the label
                if x > 1 and (x + w - 1) > width then
                    x = 1
                    y = y + BTN_H + BTN_GAP
                end
                local x2, y2 = x + w - 1, y + BTN_H - 1
                if x2 <= width and y2 <= self.size.y then
                    local label = buttonLabel(spec.name, spec.label, w, BTN_H)
                    local ok = pcall(function()
                        self.touch:add(label, spec.func, x, y, x2, y2, spec.off, spec.on)
                    end)
                    if ok then
                        self.buttons[spec.name] = true
                        rects[#rects + 1] = { x = x, y = y, w = w, h = BTN_H }
                    end
                end
                x = x + w + BTN_GAP
            end
        end
        self.buttonRects = rects
        return y + BTN_H - 1
    end,

    handleResize = function(self)
        self.monPeripheral.setTextScale(0.5)
        self.size = Vector2.new(self.monPeripheral.getSize())
        self.mon = window.create(self.monPeripheral, 1, 1, self.size.x, self.size.y, false)
        self.touch = _G.Touchpoint.new(self.id, self.mon)
        self.buttons = {}
        self.buttonRects = {}
        self.page = self.page or 1

        local w, h = self.size.x, self.size.y

        -- Header = the fixed text rows plus however many rows the flowing buttons take, then a
        -- one-row gap before the card grid begins.
        local buttonsBottom = self:layoutButtons(w, TEXT_ROWS + 1)
        self.headerH = buttonsBottom + 1

        -- Grid layout: how many CARD_W x CARD_H cards (plus GAP) fit beside/below the header.
        -- Cards flow left-to-right then top-to-bottom; anything beyond cols*rows pages over.
        self.cols = math.max(0, math.floor((w - 1) / (CARD_W + GAP)))
        local availH = h - self.headerH
        self.rows = math.max(0, math.floor((availH + GAP) / (CARD_H + GAP)))
        self.cardsPerPage = math.max(1, self.cols * self.rows)
        self.tooSmall = (self.cols < 1 or self.rows < 1)
    end,

    updateButtonStates = function(self)
        if self.buttons["Auto"] then self.touch:setButton("Auto", CONTROL_CONFIG.autoMode) end
        if self.buttons["Rctrs"] then self.touch:setButton("Rctrs", _G.btnOn) end
        if self.buttons["Turbs"] then self.touch:setButton("Turbs", _G.turbinesOn ~= false) end
        if self.buttons["Fly"] then self.touch:setButton("Fly", CONTROL_CONFIG.flywheelMode == true) end
        if self.buttons["Opt"] then self.touch:setButton("Opt", CONTROL_CONFIG.optimizeMode == "efficiency") end
        if self.buttons["Calib"] then self.touch:setButton("Calib", isCalibrating()) end
    end,

    draw = function(self)
        self.mon.setVisible(false)
        self:clear()

        local entities = self:collectEntities()
        local pages = math.max(1, math.ceil(#entities / self.cardsPerPage))
        if self.page > pages then self.page = pages end

        drawHeader(self.mon, self.size.x, self.page, pages)

        if self.tooSmall then
            drawText(self.mon, "Monitor too small for cards -", 2, self.headerH + 1, colors.black, colors.red)
            drawText(self.mon, "make it wider/taller.", 2, self.headerH + 2, colors.black, colors.red)
        else
            local startIdx = (self.page - 1) * self.cardsPerPage + 1
            local endIdx = math.min(#entities, startIdx + self.cardsPerPage - 1)
            for i = startIdx, endIdx do
                local slot = i - startIdx
                local col = slot % self.cols
                local row = math.floor(slot / self.cols)
                local ox = 1 + col * (CARD_W + GAP)
                local oy = self.headerH + 1 + row * (CARD_H + GAP)
                local e = entities[i]
                if e.kind == "reactor" then
                    drawReactorCard(self.mon, ox, oy, e.obj)
                else
                    drawTurbineCard(self.mon, ox, oy, e.obj)
                end
            end

            if #entities == 0 then
                drawText(self.mon, "Waiting for reactors / turbines...", 2, self.headerH + 1, colors.black, colors.yellow)
            end
        end

        self:updateButtonStates()
        self.touch:drawAllButtons()
        -- Outline every button so it reads as a clickable control (drawn on top of the fill).
        for _, r in ipairs(self.buttonRects or {}) do
            DrawUtil.drawBox(self.mon, colors.white, Vector2.new(r.x, r.y), Vector2.new(r.w, r.h))
        end
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
