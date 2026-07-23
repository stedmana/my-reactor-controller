-- Controller orchestration: peripheral registry, tick loop, aggregate stats, and the
-- per-tick control passes for reactors (rods) and turbines (steam PID + coils + safety).
--
-- Per game tick (20/s), runLoop():
--   1. update every EnergyBuffer, Reactor, Turbine (read peripherals, refresh averages)
--   2. updateOverallStats()  - aggregate grid energy, steam production/consumption, shares
--   3. if autoMode: reactor rod PIDs + turbine control laws
--   4. every TICKS_TO_REDRAW ticks: redraw all monitors
--
-- Concurrently, eventListener() reacts to monitor touches/resizes and peripheral
-- attach/detach, so devices can be (un)plugged live without restarting.

---@type table<string, Monitor>
_G.monitors = {}
---@type table<string, Reactor>
_G.reactors = {}
---@type table<string, Turbine>
_G.turbines = {}
---@type table<string, EnergyBuffer>
_G.energyBuffers = {}

-- Master on/off states (mapped to the monitor's control buttons).
_G.btnOn = true        -- reactors
_G.turbinesOn = true   -- turbines

-- Aggregate stats, recomputed every tick. Smoothed values are used where available.
---@class OverallStats
_G.overallStats = {
    storedLastTick = 0,
    storedThisTick = 0,
    capacity = 1,

    lastRFT = 0,          -- passive reactor RF generation (drives rfLost feedback)
    turbineRFT = 0,       -- turbine RF generation
    totalRFT = 0,         -- lastRFT + turbineRFT (display)
    rfLost = 0,           -- grid drain (display)
    rfLostPerReactor = 0, -- per passive-reactor control target

    fuelUsage = 0,
    waste = 0,

    steamProductionRate = 0,
    storedSteam = 0,
    steamCapacity = 0,
    steamConsumedLastTick = 0,     -- total turbine steam draw (display)
    steamConsumedPerReactor = 0,   -- per active-reactor control target

    passiveReactorCount = 0,
    activeReactorCount = 0,
    turbineCount = 0,

    steamGroups = {},        -- groupId -> per-group steam cascade stats (see updateSteamGroups)
    hasSteamGroups = false,  -- true when >1 group is configured (UI shows group badges)

    efficiency = function()
        if _G.overallStats.fuelUsage <= 0 then return 0 end
        return _G.overallStats.totalRFT / _G.overallStats.fuelUsage
    end,
}

_G.selectedReactor = nil

local function updateOverallStats()
    local s = _G.overallStats

    -- Aggregate energy buffer = every internal RF buffer on the net (passive reactors + turbines).
    s.storedLastTick = 0
    s.storedThisTick = 0
    s.capacity = 0
    for _, buffer in pairs(_G.energyBuffers) do
        s.storedLastTick = s.storedLastTick + buffer.averageEnergyStoredLastTick
        s.storedThisTick = s.storedThisTick + buffer.averageEnergyStoredThisTick
        s.capacity = s.capacity + buffer.capacity
    end
    if s.capacity <= 0 then s.capacity = 1 end

    s.fuelUsage = 0
    s.waste = 0
    s.lastRFT = 0
    s.steamProductionRate = 0
    s.storedSteam = 0
    s.steamCapacity = 0
    s.passiveReactorCount = 0
    s.activeReactorCount = 0

    for _, reactor in pairs(_G.reactors) do
        if reactor.activelyCooled then
            s.activeReactorCount = s.activeReactorCount + 1
            s.steamProductionRate = s.steamProductionRate + reactor.averageSteamProductionRate
            s.storedSteam = s.storedSteam + reactor.averageStoredSteam
            s.steamCapacity = s.steamCapacity + reactor.steamCapacity
        else
            s.passiveReactorCount = s.passiveReactorCount + 1
            s.lastRFT = s.lastRFT + reactor.averageLastRFT
        end
        s.fuelUsage = s.fuelUsage + reactor.averageFuelUsage
        s.waste = s.waste + reactor.waste
    end

    -- Turbines: RF generation (display) and actual steam consumption (cascade to steam reactors).
    s.turbineRFT = 0
    s.steamConsumedLastTick = 0
    s.turbineCount = 0
    for _, turbine in pairs(_G.turbines) do
        s.turbineCount = s.turbineCount + 1
        s.turbineRFT = s.turbineRFT + turbine.averageEnergyProduced
        s.steamConsumedLastTick = s.steamConsumedLastTick + turbine.averageSteamFlow
    end

    s.totalRFT = s.lastRFT + s.turbineRFT

    -- Grid drain: passive generation +/- the aggregate buffer delta (turbine RF shows up here
    -- through the buffer delta, so passive reactors idle down when turbines already cover the load).
    s.rfLost = math.floor(s.lastRFT + s.storedLastTick - s.storedThisTick + 0.5)

    s.rfLostPerReactor = s.rfLost / math.max(1, s.passiveReactorCount)
    s.steamConsumedPerReactor = s.steamConsumedLastTick / math.max(1, s.activeReactorCount)

    updateSteamGroups(s)
end

-- Resolve the configured steam groups into a membership lookup. Every reactor/turbine id not
-- named in any group maps to the shared "default" group, so an empty steamGroups list keeps
-- the original single-network behavior.
---@return table reactorGroup id->groupId, table turbineGroup id->groupId
local function resolveGroupMembership()
    local reactorGroup, turbineGroup = {}, {}
    local groups = CONTROL_CONFIG.steamGroups or {}
    for i, group in ipairs(groups) do
        for _, rid in ipairs(group.reactors or {}) do reactorGroup[rid] = i end
        for _, tid in ipairs(group.turbines or {}) do turbineGroup[tid] = i end
    end
    return reactorGroup, turbineGroup
end

-- Per-group steam cascade. For each group, active reactors chase ONLY that group's turbine
-- steam draw and band-seek on that group's own steam tanks. Results are stashed on
-- overallStats so reactor:updateRods can read its group's numbers; each reactor/turbine also
-- gets a .groupId for the UI. With no groups configured, everything lands in "default" and
-- this reproduces the aggregate cascade exactly.
---@param s OverallStats
function updateSteamGroups(s)
    local reactorGroup, turbineGroup = resolveGroupMembership()
    local groups = {}

    local function groupFor(id)
        if not groups[id] then
            groups[id] = { consumption = 0, storedSteam = 0, steamCapacity = 0, reactorCount = 0, turbineCount = 0 }
        end
        return groups[id]
    end

    for id, turbine in pairs(_G.turbines) do
        local gid = turbineGroup[id] or "default"
        turbine.groupId = gid
        local g = groupFor(gid)
        g.consumption = g.consumption + turbine.averageSteamFlow
        g.turbineCount = g.turbineCount + 1
    end

    for id, reactor in pairs(_G.reactors) do
        if reactor.activelyCooled then
            local gid = reactorGroup[id] or "default"
            reactor.groupId = gid
            local g = groupFor(gid)
            g.storedSteam = g.storedSteam + reactor.averageStoredSteam
            g.steamCapacity = g.steamCapacity + reactor.steamCapacity
            g.reactorCount = g.reactorCount + 1
        else
            reactor.groupId = nil
        end
    end

    for _, g in pairs(groups) do
        g.consumedPerReactor = g.consumption / math.max(1, g.reactorCount)
    end

    s.steamGroups = groups
    -- More than one non-empty group means the UI should surface group ids on the cards.
    local count = 0
    for _ in pairs(groups) do count = count + 1 end
    s.hasSteamGroups = (CONTROL_CONFIG.steamGroups ~= nil and #CONTROL_CONFIG.steamGroups > 0 and count > 1)
end

-- Keep the legacy globals the monitor/PID code reads in sync with the config band.
local function syncConfigGlobals()
    _G.SECONDS_TO_AVERAGE = CONTROL_CONFIG.secondsToAverage or 0.5
    _G.minb = CONTROL_CONFIG.bufferMin
    _G.maxb = CONTROL_CONFIG.bufferMax
end

-- Effective setting for one entity: per-entity override if present, else the global value.
-- See entityOverrides in projectConfigs.lua for which keys each entity kind honors.
---@param entityID string peripheral id
---@param key string CONTROL_CONFIG key
function _G.getEntitySetting(entityID, key)
    local overrides = CONTROL_CONFIG.entityOverrides
    local entity = overrides and overrides[entityID]
    if entity and entity[key] ~= nil then
        return entity[key]
    end
    return CONTROL_CONFIG[key]
end

-- idleRPM must stay well under safeRPM so normal steering never brushes the governor.
local IDLE_RPM_MARGIN = 100
local IDLE_RPM_FLOOR = 100
function _G.clampIdleRPM(rpm)
    return math.max(IDLE_RPM_FLOOR, math.min(rpm, CONTROL_CONFIG.safeRPM - IDLE_RPM_MARGIN))
end

function _G.toggleFlywheel()
    CONTROL_CONFIG.flywheelMode = not CONTROL_CONFIG.flywheelMode
    ConfigUtil.writeConfig("control")
end

-- UI adjusters (monitor settings row). Each validates, persists, and re-syncs globals.

function _G.adjustIdleRPM(delta)
    CONTROL_CONFIG.idleRPM = _G.clampIdleRPM(CONTROL_CONFIG.idleRPM + delta)
    ConfigUtil.writeConfig("control")
end

-- Widen (+delta) or narrow (-delta) a [min,max] band symmetrically, keeping it sane.
local function adjustBand(minKey, maxKey, delta)
    local newMin = math.max(0, math.min(CONTROL_CONFIG[minKey] - delta, 100))
    local newMax = math.max(0, math.min(CONTROL_CONFIG[maxKey] + delta, 100))
    if newMax - newMin < 10 then -- too tight -> control law flaps; refuse
        return
    end
    CONTROL_CONFIG[minKey] = newMin
    CONTROL_CONFIG[maxKey] = newMax
    syncConfigGlobals()
    ConfigUtil.writeConfig("control")
end

function _G.adjustBufferBand(delta) adjustBand("bufferMin", "bufferMax", delta) end
function _G.adjustCoilBand(delta) adjustBand("coilsOnBelowPct", "coilsOffAbovePct", delta) end

-- Steering interval (server-lag throttle), 1..20 ticks. Governor is unaffected.
function _G.adjustControlInterval(delta)
    local current = CONTROL_CONFIG.controlIntervalTicks or 1
    CONTROL_CONFIG.controlIntervalTicks = math.max(1, math.min(20, current + delta))
    ConfigUtil.writeConfig("control")
end

---@param monitorID string
local function connectMonitor(monitorID)
    print("Monitor " .. monitorID .. " connected!")
    _G.monitors[monitorID] = Monitor.new(monitorID)
end

---@param reactorID string
local function connectExtremeReactor(reactorID)
    print("Extreme Reactor " .. reactorID .. " connected!")
    _G.reactors[reactorID] = Reactor.newExtremeReactor(reactorID)
    _G.reactors[reactorID].setActive(_G.btnOn)
    _G.selectedReactor = _G.reactors[reactorID]
    -- The reactor's internal battery is part of the grid buffer.
    _G.energyBuffers[reactorID] = EnergyBuffer.newReactorEnergyBuffer(reactorID)
end

---@param turbineID string
local function connectExtremeTurbine(turbineID)
    print("Extreme Turbine " .. turbineID .. " connected!")
    _G.turbines[turbineID] = Turbine.newExtremeTurbine(turbineID)
    -- The turbine's internal battery is also part of the grid buffer.
    _G.energyBuffers[turbineID] = EnergyBuffer.newReactorEnergyBuffer(turbineID)
end

---@param energyBufferID string
local function connectForgeEnergyBuffer(energyBufferID)
    print("Energy Buffer " .. energyBufferID .. " connected!")
    _G.energyBuffers[energyBufferID] = EnergyBuffer.newForgeEnergyBuffer(energyBufferID)
end

local function firePeripheralAttachEventForAllPeripherals()
    for _, id in pairs(peripheral.getNames()) do
        os.queueEvent("peripheral", id)
    end
end

---@param currentTickNumber number
local function updateEnergyBuffers(currentTickNumber)
    for _, energyBuffer in pairs(_G.energyBuffers) do
        energyBuffer:update(currentTickNumber)
    end
end

---@param currentTickNumber number
local function updateReactors(currentTickNumber)
    for _, reactor in pairs(_G.reactors) do
        reactor:update(currentTickNumber)
    end
end

---@param currentTickNumber number
local function updateTurbines(currentTickNumber)
    for _, turbine in pairs(_G.turbines) do
        turbine:update(currentTickNumber)
    end
end

function _G.setReactors(active)
    _G.btnOn = active
    for _, reactor in pairs(_G.reactors) do
        reactor.setActive(active)
    end
end

function _G.setTurbines(active)
    _G.turbinesOn = active
    for _, turbine in pairs(_G.turbines) do
        turbine:setActive(active)
    end
end

function _G.toggleAutoMode()
    CONTROL_CONFIG.autoMode = not CONTROL_CONFIG.autoMode
    ConfigUtil.writeConfig("control")
end

local function updateReactorRods()
    for _, reactor in pairs(_G.reactors) do
        -- A reactor mid-calibration owns its own rods (stepCalibration); skip normal steering.
        if not reactor.calibration then
            reactor:updateRods()
        end
    end
end

-- Advance any in-progress efficiency calibrations. Runs every tick (independent of the steering
-- interval) so each rod step is held for a real, consistent number of ticks.
local function stepCalibrations()
    for _, reactor in pairs(_G.reactors) do
        if reactor.calibration then
            reactor:stepCalibration()
        end
    end
end

-- Toggle output vs. efficiency optimize mode (feature 6).
function _G.toggleOptimizeMode()
    CONTROL_CONFIG.optimizeMode = (CONTROL_CONFIG.optimizeMode == "efficiency") and "output" or "efficiency"
    ConfigUtil.writeConfig("control")
end

-- Start calibration on the first eligible reactor (one at a time, so the sweep never blacks out
-- the whole grid). Returns ok, reason.
function _G.startCalibration()
    for _, reactor in pairs(_G.reactors) do
        if reactor.calibration then
            return false, "a reactor is already calibrating"
        end
    end
    for _, reactor in pairs(_G.reactors) do
        local ok = reactor:startCalibration()
        if ok then return true end
    end
    return false, "no reactor eligible (grid busy?)"
end

-- True while any reactor is mid-sweep (for the UI button state).
function _G.isCalibrating()
    for _, reactor in pairs(_G.reactors) do
        if reactor.calibration then return true end
    end
    return false
end

---@param steer boolean false = safety-governor-only pass (between steering intervals)
local function controlTurbines(steer)
    for _, turbine in pairs(_G.turbines) do
        turbine:updateControl(CONTROL_CONFIG, steer)
    end
end

---@param peripheralID string
local function handlePeripheralDetach(peripheralID)
    if _G.monitors[peripheralID] ~= nil then
        print("Monitor " .. peripheralID .. " disconnected!")
        _G.monitors[peripheralID] = nil
    end
    if _G.energyBuffers[peripheralID] ~= nil then
        _G.energyBuffers[peripheralID] = nil
    end
    if _G.reactors[peripheralID] ~= nil then
        print("Reactor " .. peripheralID .. " disconnected!")
        _G.reactors[peripheralID] = nil
        if _G.selectedReactor and _G.selectedReactor.id == peripheralID then
            _G.selectedReactor = next(_G.reactors) and _G.reactors[next(_G.reactors)] or nil
        end
    end
    if _G.turbines[peripheralID] ~= nil then
        print("Turbine " .. peripheralID .. " disconnected!")
        _G.turbines[peripheralID] = nil
    end
end

-- Extreme Reactors 2 (MC 1.20.1) reports these CC peripheral types.
local REACTOR_TYPES = {
    ["BigReactors-Reactor"] = true,
    ["extremereactor-reactorComputerPort"] = true,
}
local TURBINE_TYPES = {
    ["BigReactors-Turbine"] = true,
    ["extremereactor-turbineComputerPort"] = true,
}

---@param peripheralID string
---@param peripheralType string
local function handlePeripheralAttach(peripheralID, peripheralType)
    if peripheralType == "monitor" then
        connectMonitor(peripheralID)
    elseif REACTOR_TYPES[peripheralType] then
        connectExtremeReactor(peripheralID)
    elseif TURBINE_TYPES[peripheralType] then
        connectExtremeTurbine(peripheralID)
    elseif peripheralType == "energy_storage" then
        connectForgeEnergyBuffer(peripheralID)
    else
        print("Ignoring peripheral", peripheralID, "of type", peripheralType)
    end
end

local function redrawMonitors()
    for _, monitor in pairs(_G.monitors) do
        monitor:draw()
    end
end

_G.TICKS_TO_REDRAW = 2
local function runLoop(currentTickNumber)
    updateEnergyBuffers(currentTickNumber)
    updateReactors(currentTickNumber)
    updateTurbines(currentTickNumber)
    updateOverallStats()

    if CONTROL_CONFIG.autoMode then
        -- Calibration sweeps step every tick (own timing), independent of the steering throttle.
        stepCalibrations()

        -- Responsiveness throttle: steering runs every controlIntervalTicks; the turbine
        -- safety governor still runs every tick (inside updateControl, before steering).
        local interval = math.max(1, math.floor(CONTROL_CONFIG.controlIntervalTicks or 1))
        local steer = (currentTickNumber % interval == 0)
        if steer then
            updateReactorRods()
        end
        controlTurbines(steer)
    end

    if currentTickNumber % _G.TICKS_TO_REDRAW == 0 then
        redrawMonitors()
    end
end

local function eventListener()
    while true do
        local event = { os.pullEvent() }

        if event[1] == "monitor_touch" or event[1] == "monitor_resize" then
            local monitor = _G.monitors[event[2]]
            if monitor ~= nil then
                monitor:handleEvents(event)
            end
        elseif event[1] == "peripheral" then
            handlePeripheralAttach(event[2], peripheral.getType(event[2]))
        elseif event[1] == "peripheral_detach" then
            handlePeripheralDetach(event[2])
        end
    end
end

-- Game-tick-synchronized driver (inherited from upstream, subtle but effective):
-- os.clock() advances in 0.05s steps, so floor(os.clock()*20) is the current game tick.
-- queueEvent+pullEvent of a dummy event is a zero-sleep yield - it spins the coroutine
-- without losing the rest of the current tick (os.sleep would always round up to a tick).
--   * same tick as last run  -> yield and re-check
--   * exactly one tick later -> busy-yield ~2ms into the fresh tick (so peripherals have
--     settled), then run the control pass
--   * more than one tick     -> we lagged; run immediately and note the miss
local function loop()
    local loopEventName = "yield"
    local curTime = math.floor(os.clock() * 20)
    local lastTime = curTime

    os.sleep(0)
    while true do
        curTime = math.floor(os.clock() * 20)

        local hasDevices = next(_G.reactors) ~= nil or next(_G.turbines) ~= nil
        if not hasDevices then
            print("No reactor or turbine detected! Waiting for a connection...")
            sleep(1)
        elseif curTime < lastTime + 1 then
            os.queueEvent(loopEventName)
            os.pullEvent(loopEventName)
        elseif curTime > lastTime + 1 then
            print("Missed last", curTime - lastTime - 1, "tick(s)!", curTime)
            runLoop(curTime)
        else
            local t = os.epoch("utc")
            while os.epoch("utc") - t < 2 do
                os.queueEvent(loopEventName)
                os.pullEvent(loopEventName)
            end
            runLoop(curTime)
            os.sleep(0)
        end
        lastTime = curTime
    end
end

-- Exposed for the headless simulator in test/ (harmless in-game).
_G.__test = {
    runLoop = runLoop,
    updateOverallStats = updateOverallStats,
    handlePeripheralAttach = handlePeripheralAttach,
    handlePeripheralDetach = handlePeripheralDetach,
    syncConfigGlobals = syncConfigGlobals,
}

--Entry point
function _G.main()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    syncConfigGlobals()

    _G.monitors = {}
    _G.reactors = {}
    _G.turbines = {}
    _G.energyBuffers = {}

    -- Manually fire "peripheral" for everything already connected so registries populate.
    firePeripheralAttachEventForAllPeripherals()

    parallel.waitForAll(loop, eventListener)
end
