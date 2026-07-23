-- Headless smoke test / simulator for the controller.
-- Run from the project root:  lua test/sim.lua
--
-- Builds fake reactor/turbine/monitor peripherals with rough-but-plausible physics,
-- drives the real control loop through three demand phases, and asserts:
--   * turbine RPM never crosses the 2000 ceiling (incl. an induced overspeed test)
--   * turbines settle near 1800 RPM in every phase
--   * coils disengage when the grid is full, re-engage under load
--   * the steam reactor throttles rods when turbines idle (production tracks consumption)
--   * the monitor renders and its buttons respond to touches

dofile("test/cc_stubs.lua")

-- Load the real modules in the same order main.lua would.
local MODULES = {
    "src/config/projectConfigs.lua",
    "src/constants/projectConstants.lua",
    "src/classes/vector2.lua",
    "src/classes/deque.lua",
    "src/util/draw.lua",
    "src/classes/touchpoint.lua",
    "src/classes/energybuffer.lua",
    "src/classes/reactor.lua",
    "src/classes/turbine.lua",
    "src/classes/monitor.lua",
    "src/util/config.lua",
    "src/scripts/controller.lua",
}
for _, path in ipairs(MODULES) do dofile(path) end

--region world + fake devices

local world = {
    steamTank = { amount = 0, capacity = 50000 },
    baseDraw = 0,
    passiveReactors = {},
    activeReactors = {},
    fakeTurbines = {},
    drawShortfall = 0,
}

local function rodAverage(rods)
    local sum, count = 0, 0
    for _, level in pairs(rods) do
        sum = sum + level
        count = count + 1
    end
    return sum / count
end

local function makeFakeReactor(name, opts)
    local self = {
        name = name,
        rods = {},
        active = true,
        battery = opts.activelyCooled and 0 or 5000000,
        batteryCap = opts.activelyCooled and 0 or 10000000,
        maxRF = opts.maxRF or 0,
        maxSteam = opts.maxSteam or 0,
        activelyCooled = opts.activelyCooled or false,
        genLast = 0,
        waste = 0,
    }
    for i = 0, (opts.rodCount or 4) - 1 do self.rods[i] = 80 end

    self.step = function()
        local avgRod = rodAverage(self.rods)
        local powerFraction = self.active and (100 - avgRod) / 100 or 0
        if self.activelyCooled then
            local produced = powerFraction * self.maxSteam
            local space = world.steamTank.capacity - world.steamTank.amount
            world.steamTank.amount = world.steamTank.amount + math.min(produced, space)
            self.genLast = produced
        else
            self.genLast = powerFraction * self.maxRF
            self.battery = math.min(self.batteryCap, self.battery + self.genLast)
        end
        self.waste = self.waste + self.genLast / 1000000
    end

    self.methods = {
        getActive = function() return self.active end,
        setActive = function(v) self.active = v end,
        isActivelyCooled = function() return self.activelyCooled end,
        getNumberOfControlRods = function()
            local n = 0
            for _ in pairs(self.rods) do n = n + 1 end
            return n
        end,
        getControlRodsLevels = function()
            local copy = {}
            for k, v in pairs(self.rods) do copy[k] = v end
            return copy
        end,
        setControlRodsLevels = function(levels)
            for k, v in pairs(levels) do self.rods[k] = v end
        end,
        getEnergyStats = function()
            return {
                energyStored = self.battery,
                energyCapacity = self.batteryCap,
                energyProducedLastTick = self.activelyCooled and 0 or self.genLast,
            }
        end,
        getFuelStats = function()
            return { fuelConsumedLastTick = self.genLast / 100 + 0.001 }
        end,
        getFuelTemperature = function() return 20 + (self.genLast / math.max(1, self.maxRF + self.maxSteam)) * 600 end,
        getCasingTemperature = function() return 20 + (self.genLast / math.max(1, self.maxRF + self.maxSteam)) * 300 end,
        getWasteAmount = function() return self.waste end,
        getHotFluidProducedLastTick = function() return self.activelyCooled and self.genLast or 0 end,
        getHotFluidAmount = function() return self.activelyCooled and world.steamTank.amount or 0 end,
        getHotFluidAmountMax = function() return self.activelyCooled and world.steamTank.capacity or 0 end,
    }
    return self
end

-- Rotor physics: rpm += (steamTorque - coilDrag - friction) * inertia
-- Constants chosen so ~2000 mB/t holds ~1800 RPM with coils engaged,
-- and freewheeling at full steam would badly overspeed (governor must prevent it).
local K_TORQUE, K_DRAG, K_FRICTION, INERTIA = 0.054, 0.05, 0.01, 0.2

local function makeFakeTurbine(name, misspellBladeMethod)
    local self = {
        name = name,
        rpm = 0,
        cap = 0,
        coils = false,
        active = true,
        buffer = 0,
        bufferCap = 1000000,
        flowLast = 0,
        genLast = 0,
        flowMaxMax = 2000,
        maxRpmSeen = 0,
    }

    self.step = function(grantedFlow)
        if not self.active then grantedFlow = 0 end
        self.flowLast = grantedFlow
        local torque = K_TORQUE * grantedFlow
        local drag = self.coils and K_DRAG * self.rpm or 0
        local friction = K_FRICTION * self.rpm
        self.rpm = math.max(0, self.rpm + (torque - drag - friction) * INERTIA)
        self.maxRpmSeen = math.max(self.maxRpmSeen, self.rpm)
        self.genLast = (self.coils and self.active) and self.rpm * 5 or 0
        self.buffer = math.min(self.bufferCap, self.buffer + self.genLast)
    end

    self.methods = {
        getActive = function() return self.active end,
        setActive = function(v) self.active = v end,
        getRotorSpeed = function() return self.rpm end,
        getEnergyProducedLastTick = function() return self.genLast end,
        getEnergyStored = function() return self.buffer end,
        getEnergyCapacity = function() return self.bufferCap end,
        getEnergyStats = function()
            return { energyStored = self.buffer, energyCapacity = self.bufferCap, energyProducedLastTick = self.genLast }
        end,
        getFluidFlowRate = function() return self.flowLast end,
        getFluidFlowRateMax = function() return self.cap end,
        getFluidFlowRateMaxMax = function() return self.flowMaxMax end,
        setFluidFlowRateMax = function(v) self.cap = v end,
        getInductorEngaged = function() return self.coils end,
        setInductorEngaged = function(v) self.coils = v end,
    }
    -- One turbine carries the mod's historical typo to exercise feature detection.
    if misspellBladeMethod then
        self.methods.getBladeEffiency = function() return 75 end
    else
        self.methods.getBladeEfficiency = function() return 75 end
    end
    return self
end

function world.step()
    -- 1) steam production
    for _, r in ipairs(world.activeReactors) do r.step() end

    -- 2) grant steam to turbines proportional to their requested caps
    local totalRequested = 0
    for _, t in ipairs(world.fakeTurbines) do
        totalRequested = totalRequested + (t.active and t.cap or 0)
    end
    local grantedTotal = math.min(totalRequested, world.steamTank.amount)
    for _, t in ipairs(world.fakeTurbines) do
        local request = t.active and t.cap or 0
        local grant = totalRequested > 0 and (request * grantedTotal / totalRequested) or 0
        t.step(grant)
    end
    world.steamTank.amount = world.steamTank.amount - grantedTotal

    -- 3) passive generation
    for _, r in ipairs(world.passiveReactors) do r.step() end

    -- 4) base draw, pulled proportionally from every RF buffer
    local pools = {}
    local totalStored = 0
    for _, r in ipairs(world.passiveReactors) do
        pools[#pools + 1] = r
        totalStored = totalStored + r.battery
    end
    for _, t in ipairs(world.fakeTurbines) do
        pools[#pools + 1] = t
        totalStored = totalStored + t.buffer
    end
    local draw = world.baseDraw
    if totalStored > 0 and draw > 0 then
        local pulled = 0
        for _, p in ipairs(pools) do
            local stored = p.battery or p.buffer
            local share = math.min(stored, draw * stored / totalStored)
            if p.battery then p.battery = p.battery - share else p.buffer = p.buffer - share end
            pulled = pulled + share
        end
        world.drawShortfall = world.drawShortfall + math.max(0, draw - pulled)
    end
end

--endregion
--region checks

local failures = {}
local function check(condition, label)
    if condition then
        print("PASS  " .. label)
    else
        print("FAIL  " .. label)
        failures[#failures + 1] = label
    end
end

--endregion
--region build world

local monitorPeripheral = makeTerm(164, 81)

local reactorBig = makeFakeReactor("reactor_big", { maxRF = 60000, rodCount = 9 })
local reactorMid = makeFakeReactor("reactor_mid", { maxRF = 30000, rodCount = 4 })
local reactorSteam = makeFakeReactor("reactor_steam", { maxSteam = 12000, rodCount = 4, activelyCooled = true })
world.passiveReactors = { reactorBig, reactorMid }
world.activeReactors = { reactorSteam }

for i = 1, 5 do
    world.fakeTurbines[i] = makeFakeTurbine("turbine_" .. i, i == 3)
end

peripheral.register("BigReactors-Reactor_0", "BigReactors-Reactor", reactorBig.methods)
peripheral.register("BigReactors-Reactor_1", "BigReactors-Reactor", reactorMid.methods)
peripheral.register("BigReactors-Reactor_2", "BigReactors-Reactor", reactorSteam.methods)
for i = 1, 5 do
    peripheral.register("BigReactors-Turbine_" .. i, "BigReactors-Turbine", world.fakeTurbines[i].methods)
end
peripheral.register("monitor_0", "monitor", monitorPeripheral)

ConfigUtil.writeAllConfigsAsDefaults()
ConfigUtil.readAllConfigs()
__test.syncConfigGlobals()

for _, name in ipairs(peripheral.getNames()) do
    __test.handlePeripheralAttach(name, peripheral.getType(name))
end

check(next(_G.reactors) ~= nil, "reactors registered")
check(next(_G.turbines) ~= nil, "turbines registered")
check(next(_G.monitors) ~= nil, "monitor registered")
local turbineCount, reactorCount = 0, 0
for _ in pairs(_G.turbines) do turbineCount = turbineCount + 1 end
for _ in pairs(_G.reactors) do reactorCount = reactorCount + 1 end
check(turbineCount == 5, "5 turbines wrapped")
check(reactorCount == 3, "3 reactors wrapped")

--endregion
--region run phases

local IDLE, SAFE, CEILING = CONTROL_CONFIG.idleRPM, CONTROL_CONFIG.safeRPM, CONTROL_CONFIG.ceilingRPM
local tick = 0
local ceilingViolations = 0

local function runTicks(n, sample)
    for _ = 1, n do
        tick = tick + 1
        _G.__simClock = tick / 20
        world.step()
        __test.runLoop(tick)
        for _, t in ipairs(world.fakeTurbines) do
            if t.rpm > CEILING + 1 then
                ceilingViolations = ceilingViolations + 1
            end
        end
        if sample then sample(tick) end
    end
end

-- Phase A: heavy base load -> turbines must generate.
world.baseDraw = 50000
local aGenerated = {}
local aRodSamples, aRodCount = 0, 0
runTicks(600, function()
    for i, t in ipairs(world.fakeTurbines) do
        if t.genLast > 0 then aGenerated[i] = true end
    end
    if tick > 400 then
        aRodSamples = aRodSamples + rodAverage(reactorSteam.rods)
        aRodCount = aRodCount + 1
    end
end)

local allGeneratedA = true
for i = 1, 5 do allGeneratedA = allGeneratedA and (aGenerated[i] == true) end
check(allGeneratedA, "phase A: every turbine generated under load")

local nearTarget = true
for _, t in ipairs(world.fakeTurbines) do
    nearTarget = nearTarget and math.abs(t.rpm - IDLE) < 250
end
check(nearTarget, "phase A: turbines near 1800 RPM under load")

-- Phase B: zero draw -> buffers fill, coils must disengage, steam production must throttle.
-- Long enough for the steam tank to finish band-seeking so the tail is pure load-following.
world.baseDraw = 0
local bCoilTicks = 0
local bProdSum, bConsSum, bSamples = 0, 0, 0
local bRodSamples, bRodCount = 0, 0
runTicks(1600, function()
    if tick > 2000 then
        for _, t in ipairs(world.fakeTurbines) do
            if t.coils then bCoilTicks = bCoilTicks + 1 end
        end
        bProdSum = bProdSum + reactorSteam.genLast
        local consumption = 0
        for _, t in ipairs(world.fakeTurbines) do consumption = consumption + t.flowLast end
        bConsSum = bConsSum + consumption
        bSamples = bSamples + 1
        bRodSamples = bRodSamples + rodAverage(reactorSteam.rods)
        bRodCount = bRodCount + 1
    end
end)

check(bCoilTicks == 0, "phase B: coils disengaged when grid full (idle @1800)")

local idleNearTarget = true
for _, t in ipairs(world.fakeTurbines) do
    idleNearTarget = idleNearTarget and math.abs(t.rpm - IDLE) < 250
end
check(idleNearTarget, "phase B: turbines hold ~1800 RPM while idle")

local avgProdB = bProdSum / math.max(1, bSamples)
local avgConsB = bConsSum / math.max(1, bSamples)
check(math.abs(avgProdB - avgConsB) <= math.max(200, avgConsB * 0.35),
    string.format("phase B: steam production tracks consumption (prod %.0f vs cons %.0f mB/t)", avgProdB, avgConsB))

local avgRodA = aRodSamples / math.max(1, aRodCount)
local avgRodB = bRodSamples / math.max(1, bRodCount)
check(avgRodB > avgRodA + 5,
    string.format("phase B: steam reactor rods throttled up when idle (A %.1f%% -> B %.1f%%)", avgRodA, avgRodB))

local tankPct = world.steamTank.amount / world.steamTank.capacity * 100
check(tankPct >= CONTROL_CONFIG.bufferMin - 10 and tankPct <= CONTROL_CONFIG.bufferMax + 10,
    string.format("phase B: steam tank settled near target band (%.1f%%)", tankPct))

-- Phase C: heavy load again -> coils re-engage.
world.baseDraw = 50000
local cGenerated = {}
runTicks(600, function()
    for i, t in ipairs(world.fakeTurbines) do
        if t.genLast > 0 then cGenerated[i] = true end
    end
end)
local allGeneratedC = true
for i = 1, 5 do allGeneratedC = allGeneratedC and (cGenerated[i] == true) end
check(allGeneratedC, "phase C: turbines resume generating when load returns")

check(ceilingViolations == 0, "no turbine ever crossed the 2000 RPM ceiling (all phases)")

local maxSeen = 0
for _, t in ipairs(world.fakeTurbines) do maxSeen = math.max(maxSeen, t.maxRpmSeen) end
print(string.format("      (max RPM observed anywhere: %.0f)", maxSeen))

--endregion
--region safety governor unit test

local victim = world.fakeTurbines[1]
victim.rpm = SAFE + 40 -- 1990
tick = tick + 1; _G.__simClock = tick / 20
world.step()
victim.rpm = SAFE + 40 -- keep it in the soft-brake band despite the step
__test.runLoop(tick)
check(victim.coils == true, "soft brake: coils forced on at 1990 RPM")
check(victim.cap <= victim.flowMaxMax * 0.25, "soft brake: steam clamped at 1990 RPM")

victim.rpm = CEILING + 5 -- 2005
tick = tick + 1; _G.__simClock = tick / 20
world.step()
victim.rpm = CEILING + 5
__test.runLoop(tick)
check(victim.cap == 0, "hard cut: steam zeroed above 2000 RPM")
check(victim.coils == true, "hard cut: coils engaged to brake above 2000 RPM")

--endregion
--region monitor render + touch test

local mon
for _, m in pairs(_G.monitors) do mon = m end
local okDraw = pcall(function() mon:draw() end)
check(okDraw, "monitor renders without error")

local autoBtn = mon.touch.buttonList["Auto"]
check(autoBtn ~= nil, "Auto button exists")
if autoBtn then
    local before = CONTROL_CONFIG.autoMode
    mon:handleEvents({ "monitor_touch", mon.id, autoBtn.xMin, autoBtn.yMin })
    check(CONTROL_CONFIG.autoMode == not before, "touching Auto toggles auto mode")
    mon:handleEvents({ "monitor_touch", mon.id, autoBtn.xMin, autoBtn.yMin })
    check(CONTROL_CONFIG.autoMode == before, "touching Auto again restores auto mode")
end

--region planned features: reserve bands, responsiveness throttle, configurable idleRPM

-- idleRPM validation: UI adjuster clamps to [floor, safeRPM - margin].
local savedIdle = CONTROL_CONFIG.idleRPM
adjustIdleRPM(100000)
check(CONTROL_CONFIG.idleRPM <= SAFE - 100, "idleRPM adjust clamps under safeRPM")
adjustIdleRPM(-100000)
check(CONTROL_CONFIG.idleRPM >= 100, "idleRPM adjust clamps at floor")
CONTROL_CONFIG.idleRPM = savedIdle
ConfigUtil.writeConfig("control")

-- Band adjusters: widen/narrow symmetrically, refuse to collapse below 10% width.
local bMin, bMax = CONTROL_CONFIG.bufferMin, CONTROL_CONFIG.bufferMax
adjustBufferBand(5)
check(CONTROL_CONFIG.bufferMin == bMin - 5 and CONTROL_CONFIG.bufferMax == bMax + 5
    and _G.minb == bMin - 5, "buffer band widens and re-syncs globals")
adjustBufferBand(-5)
check(CONTROL_CONFIG.bufferMin == bMin and CONTROL_CONFIG.bufferMax == bMax, "buffer band narrows back")
for _ = 1, 20 do adjustCoilBand(-5) end
check(CONTROL_CONFIG.coilsOffAbovePct - CONTROL_CONFIG.coilsOnBelowPct >= 10,
    "coil band refuses to collapse below 10% width")
CONTROL_CONFIG.coilsOnBelowPct, CONTROL_CONFIG.coilsOffAbovePct = 30, 70
ConfigUtil.writeConfig("control")

-- Per-turbine idleRPM override + responsiveness throttle, end to end:
-- turbine 2 targets 900 RPM while steering runs every 3rd tick with deadbands active.
CONTROL_CONFIG.entityOverrides["BigReactors-Turbine_2"] = { idleRPM = 900 }
CONTROL_CONFIG.controlIntervalTicks = 3
CONTROL_CONFIG.rpmDeadband = 15
CONTROL_CONFIG.rodWriteThreshold = 0.5

local rodWrites = 0
local origSetRods = reactorBig.methods.setControlRodsLevels
reactorBig.methods.setControlRodsLevels = function(levels)
    rodWrites = rodWrites + 1
    return origSetRods(levels)
end

world.baseDraw = 50000
local violationsBefore = ceilingViolations
runTicks(900)

local t2 = world.fakeTurbines[2]
check(math.abs(t2.rpm - 900) < 250,
    string.format("per-turbine idleRPM override honored (turbine 2 at %.0f RPM)", t2.rpm))
local othersNear = true
for i, t in ipairs(world.fakeTurbines) do
    if i ~= 2 then othersNear = othersNear and math.abs(t.rpm - IDLE) < 250 end
end
check(othersNear, "other turbines still ~1800 with interval+deadband active")
check(rodWrites <= 300,
    string.format("rod writes throttled by controlIntervalTicks (%d writes in 900 ticks)", rodWrites))
check(ceilingViolations == violationsBefore, "no ceiling violations under throttled steering")

-- Governor must still run on non-steering ticks (interval = 3).
local victim2 = world.fakeTurbines[4]
repeat tick = tick + 1 until tick % 3 ~= 0
_G.__simClock = tick / 20
world.step()
victim2.rpm = CEILING + 5
__test.runLoop(tick)
check(victim2.cap == 0 and victim2.coils == true,
    "safety governor runs full-rate between steering intervals")

-- Restore defaults for the remaining tests.
CONTROL_CONFIG.entityOverrides["BigReactors-Turbine_2"] = nil
CONTROL_CONFIG.controlIntervalTicks = 1
CONTROL_CONFIG.rpmDeadband = 0
CONTROL_CONFIG.rodWriteThreshold = 0
reactorBig.methods.setControlRodsLevels = origSetRods

-- Tick -/+ buttons adjust controlIntervalTicks, clamped to [1, 20].
local tickMinus = mon.touch.buttonList["Tick-"]
check(tickMinus ~= nil and mon.touch.buttonList["Tick+"] ~= nil, "Tick-/Tick+ buttons exist")
adjustControlInterval(-100)
check(CONTROL_CONFIG.controlIntervalTicks == 1, "control interval clamps at 1")
adjustControlInterval(100)
check(CONTROL_CONFIG.controlIntervalTicks == 20, "control interval clamps at 20")
CONTROL_CONFIG.controlIntervalTicks = 1
ConfigUtil.writeConfig("control")

-- Settings-row buttons on the monitor drive the adjusters (1800 +100 clamps to 1850).
local rpmPlus = mon.touch.buttonList["RPM+"]
check(rpmPlus ~= nil, "settings buttons exist (RPM+)")
if rpmPlus then
    local before = CONTROL_CONFIG.idleRPM
    mon:handleEvents({ "monitor_touch", mon.id, rpmPlus.xMin, rpmPlus.yMin })
    check(CONTROL_CONFIG.idleRPM == math.min(before + 100, SAFE - 100),
        "touching RPM+ raises idleRPM with safeRPM clamp")
    CONTROL_CONFIG.idleRPM = before
    ConfigUtil.writeConfig("control")
end

--endregion

--region feature 3: steam network groups

-- Put the steam reactor in a group fed only by turbines 1 & 2; the other three turbines
-- land in the implicit "default" group.
CONTROL_CONFIG.steamGroups = {
    { reactors = { "BigReactors-Reactor_2" }, turbines = { "BigReactors-Turbine_1", "BigReactors-Turbine_2" } },
}
world.baseDraw = 50000
runTicks(200)

local steamReactor = _G.reactors["BigReactors-Reactor_2"]
check(steamReactor.groupId == 1, "steam reactor resolved into its configured group")
check(_G.turbines["BigReactors-Turbine_1"].groupId == 1
    and _G.turbines["BigReactors-Turbine_3"].groupId == "default",
    "turbines split between group 1 and the default group")
check(_G.overallStats.hasSteamGroups == true, "hasSteamGroups set when >1 group present")
local g1 = _G.overallStats.steamGroups[1]
local gDef = _G.overallStats.steamGroups["default"]
check(g1 and g1.turbineCount == 2 and gDef and gDef.turbineCount == 3,
    "per-group turbine counts correct (2 in group 1, 3 in default)")
check(g1.consumption > 0 and reactorSteam.genLast > 0,
    "group cascade active: reactor produces against its group's steam draw")

CONTROL_CONFIG.steamGroups = {}
runTicks(50)
check(_G.overallStats.hasSteamGroups == false, "empty steamGroups falls back to one network")

--endregion

--region feature 5: flywheel mode

-- Step helper that does NOT feed the global ceiling-violation counter (flywheel deliberately
-- exceeds 2000 RPM, which is the whole point of the mode).
local function stepOnly(n)
    for _ = 1, n do
        tick = tick + 1
        _G.__simClock = tick / 20
        world.step()
        __test.runLoop(tick)
    end
end

-- Uncapped (default): idle turbines keep climbing well past 2000.
CONTROL_CONFIG.flywheelMode = true
CONTROL_CONFIG.flywheelCeilingRPM = 0
world.baseDraw = 0
stepOnly(400)
local midRpm = world.fakeTurbines[1].rpm
stepOnly(400)
local anyOver2000, keptClimbing = false, false
for _, t in ipairs(world.fakeTurbines) do
    if t.rpm > CEILING then anyOver2000 = true end
end
keptClimbing = world.fakeTurbines[1].rpm > midRpm + 50
check(anyOver2000, "flywheel uncapped: idle turbines spin well above 2000 RPM")
check(keptClimbing, "flywheel uncapped: RPM keeps climbing (no software ceiling)")

-- Optional cap: a positive flywheelCeilingRPM hard-limits the spin-up.
CONTROL_CONFIG.flywheelCeilingRPM = 2800
stepOnly(1200)
local underCap = true
for _, t in ipairs(world.fakeTurbines) do
    if t.rpm > CONTROL_CONFIG.flywheelCeilingRPM + 60 then underCap = false end
end
check(underCap, "flywheel capped: positive flywheelCeilingRPM limits the overspeed")
CONTROL_CONFIG.flywheelCeilingRPM = 0

-- Big spike: coils must engage and the overspeed must brake back under 2000.
world.baseDraw = 300000
stepOnly(600)
local generating = false
for _, t in ipairs(world.fakeTurbines) do
    if t.coils and t.genLast > 0 then generating = true end
end
check(generating, "flywheel: coils engage to serve a power spike")
local brakedBelowCeiling = true
for _, t in ipairs(world.fakeTurbines) do
    brakedBelowCeiling = brakedBelowCeiling and t.rpm < CEILING
end
check(brakedBelowCeiling, "flywheel: generating turbines brake back under 2000 RPM")

-- Disarm: everything must settle back under safeRPM (normal governor fully restored).
CONTROL_CONFIG.flywheelMode = false
world.baseDraw = 0
stepOnly(500)
local backNormal = true
for _, t in ipairs(world.fakeTurbines) do
    backNormal = backNormal and t.rpm < SAFE
end
check(backNormal, "flywheel: turbines return under safeRPM after disarm")

-- Fly button exists and toggles the mode.
local flyBtn = mon.touch.buttonList["Fly"]
check(flyBtn ~= nil, "Fly button exists")
if flyBtn then
    mon:handleEvents({ "monitor_touch", mon.id, flyBtn.xMin, flyBtn.yMin })
    check(CONTROL_CONFIG.flywheelMode == true, "touching Fly arms flywheel mode")
    mon:handleEvents({ "monitor_touch", mon.id, flyBtn.xMin, flyBtn.yMin })
    check(CONTROL_CONFIG.flywheelMode == false, "touching Fly again disarms flywheel mode")
end

world.baseDraw = 0

--endregion

--region feature 6: efficiency calibration + optimize mode

CONTROL_CONFIG.calibrationSettleTicks = 6
CONTROL_CONFIG.optimizeMode = "output"
world.baseDraw = 0
runTicks(300) -- let band control restore the buffer into its ~50% band

local bigReactor = _G.reactors["BigReactors-Reactor_0"]
local okCal = bigReactor:startCalibration()
check(okCal, "calibration starts when the grid is not busy")

local guard = 0
while bigReactor.calibration and guard < 500 do
    tick = tick + 1
    _G.__simClock = tick / 20
    world.step()
    __test.runLoop(tick)
    guard = guard + 1
end
check(bigReactor.calibration == nil, "calibration sweep runs to completion")

local pointCount = 0
for _ in pairs(bigReactor.curve or {}) do pointCount = pointCount + 1 end
check(pointCount == 21, "efficiency curve recorded all 21 rod steps")
check(type(bigReactor.bestEffLevel) == "number"
    and bigReactor.bestEffLevel >= 0 and bigReactor.bestEffLevel <= 100,
    "best-efficiency rod level picked from the curve")

local saved = ConfigUtil.readState("BigReactors-Reactor_0")
check(saved and saved.curve and saved.bestEffLevel ~= nil, "efficiency curve persisted to state file")

-- Refuse to start while the grid is busy (buffer drained below the band).
world.baseDraw = 500000
runTicks(200)
local okBusy, busyReason = bigReactor:startCalibration()
check(not okBusy, "calibration refuses while grid is busy (" .. tostring(busyReason) .. ")")

-- Optimize-efficiency mode never pulls rods out past the sweet spot, even under heavy load.
bigReactor.bestEffLevel = 60
world.baseDraw = 500000
CONTROL_CONFIG.optimizeMode = "efficiency"
runTicks(300)
check(rodAverage(reactorBig.rods) >= 55, "efficiency mode holds rods at/above the sweet spot under load")

CONTROL_CONFIG.optimizeMode = "output"
runTicks(300)
check(rodAverage(reactorBig.rods) < 55, "output mode pulls rods below the sweet spot to chase load")

-- Opt / Calib buttons.
local optBtn = mon.touch.buttonList["Opt"]
check(optBtn ~= nil, "Opt button exists")
if optBtn then
    mon:handleEvents({ "monitor_touch", mon.id, optBtn.xMin, optBtn.yMin })
    check(CONTROL_CONFIG.optimizeMode == "efficiency", "touching Opt switches to efficiency mode")
    mon:handleEvents({ "monitor_touch", mon.id, optBtn.xMin, optBtn.yMin })
    check(CONTROL_CONFIG.optimizeMode == "output", "touching Opt switches back to output mode")
end
check(mon.touch.buttonList["Calib"] ~= nil, "Calib button exists")

-- Restore defaults for the remaining tests.
CONTROL_CONFIG.optimizeMode = "output"
bigReactor.bestEffLevel = nil
world.baseDraw = 0
ConfigUtil.writeConfig("control")

--endregion

-- Detach/reattach shouldn't blow up.
__test.handlePeripheralDetach("BigReactors-Turbine_5")
tick = tick + 1; _G.__simClock = tick / 20
world.step()
__test.runLoop(tick)
__test.handlePeripheralAttach("BigReactors-Turbine_5", "BigReactors-Turbine")
tick = tick + 1; _G.__simClock = tick / 20
world.step()
__test.runLoop(tick)
check(true, "turbine detach/reattach survived")

--endregion
--region render preview (text-only dump of the fake monitor)

print("\n--- monitor render preview (text cells only, first 46 rows) ---")
local win = mon.mon
for y = 1, math.min(46, win._h) do
    local row = {}
    for x = 1, win._w do
        local cell = win._grid[y] and win._grid[y][x]
        row[x] = (cell and cell.ch ~= " " and cell.ch) or (cell and "#" or ".")
    end
    print(table.concat(row))
end

--endregion

print("")
if #failures > 0 then
    print(#failures .. " FAILURE(S):")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
else
    print("ALL CHECKS PASSED")
end
