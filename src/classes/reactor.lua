-- Reactor class (Extreme Reactors 2 "BigReactors-Reactor" peripheral, MC 1.20.1 Modernized API).
--
-- One instance wraps one reactor multiblock. Two operating modes, auto-detected each tick
-- via isActivelyCooled():
--
--   * PASSIVE  (air-cooled)  -> produces RF directly. updateRods() steers the control rods so
--     the aggregate grid energy buffer stays inside the configured band while the generation
--     rate load-follows the measured grid drain.
--
--   * ACTIVE   (fluid-cooled)-> produces steam ("hot fluid") for turbines. updateRods() steers
--     the rods so steam PRODUCTION matches the turbines' measured steam CONSUMPTION (fed in by
--     the controller via overallStats) - i.e. no excess steam is ever created.
--
-- Both modes use the same weighted PID (see updateRods) - only the measured/target quantities
-- differ (RF + energy buffer vs. steam rate + steam tank).

-- Average of the values of any table (used on the control-rod level map, keys are rod indices).
local function calculateAverage(array)
    local sum = 0
    local count = 0
    for _, value in pairs(array) do
        sum = sum + value
        count = count + 1
    end
    return sum / count
end

-- Apply a FRACTIONAL rod level to a whole reactor.
-- Rod insertion is an integer 0..100 per rod, but with N rods we can fake fractional overall
-- insertion: e.g. level=42.5 on 4 rods -> two rods at 42 and two at 43 (average 42.5).
-- This gives the PID much finer authority on multi-rod reactors than snapping to integers.
local function setRods(reactor, level)
    level = math.max(level, 0)
    level = math.min(level, 100)
    local count = reactor.getNumberOfControlRods()

    -- How many rods get floor(level)+1 so the average lands on the fractional target.
    local numberToAddOneLevelTo = math.floor((level - math.floor(level)) * count + 0.5)

    local levelsMap = {}
    for idx0, _ in pairs(reactor.getControlRodsLevels()) do
        local rodLevel = math.floor(level)
        if numberToAddOneLevelTo > 0 then
            rodLevel = rodLevel + 1
            numberToAddOneLevelTo = numberToAddOneLevelTo - 1
        end
        levelsMap[idx0] = rodLevel
    end
    -- setControlRodsLevels requires a complete map (every rod index present).
    reactor.setControlRodsLevels(levelsMap)
end

-- Linear interpolation with clamped t (0..1).
local function lerp(start, finish, t)
    t = math.max(0, math.min(1, t))
    return (1 - t) * start + t * finish
end

-- One PID step -> rod level 0..100.
-- Gains are NEGATIVE because rod insertion is inversely related to output:
-- positive error (want MORE output) must push the rod level DOWN.
-- The integral is clamped to +/-100 (anti-windup) and the final output to 0..100.
local function iteratePID(pid, error)
    local P = pid.Kp * error

    pid.integral = pid.integral + pid.Ki * error
    pid.integral = math.max(math.min(100, pid.integral), -100)

    local derivative = pid.Kd * (error - pid.lastError)

    local rodLevel = math.max(math.min(P + pid.integral + derivative, 100), 0)

    pid.lastError = error
    return rodLevel
end

---@class Reactor
---@field id string
---@field active boolean
---@field activelyCooled boolean
---@field lastUpdatedTick number
---@field lastRFT number
---@field rodLevel number
---@field fuelUsage number
---@field waste number
---@field fuelTemp number
---@field caseTemp number
---@field fuelEfficiency number
---@field steamProductionRate number
---@field storedSteam number
---@field steamCapacity number
---@field lastRFTValues Deque
---@field rodLevelValues Deque
---@field fuelUsageValues Deque
---@field wasteValues Deque
---@field fuelTempValues Deque
---@field caseTempValues Deque
---@field steamProductionRateValues Deque
---@field storedSteamValues Deque
---@field averageLastRFT number
---@field averageRodLevel number
---@field averageFuelUsage number
---@field averageWaste number
---@field averageFuelTemp number
---@field averageSteamProductionRate number
---@field averageStoredSteam number
---@field averageFuelEfficiency number
---@field getLastRFT function
---@field getRodLevel function
---@field getFuelUsage function
---@field getWaste function
---@field getFuelTemp function
---@field getCaseTemp function
---@field getSteamProductionRate function
---@field getStoredSteam function
---@field getSteamCapacity function
---@field isActivelyCooled function
---@field getActive function
---@field setActive function
---@field setRodLevels function
local Reactor = {

    lastUpdatedTick = 0,

    -- Push this tick's raw readings into the rolling windows and refresh the averages.
    -- Window length = 20 * SECONDS_TO_AVERAGE ticks; all deques stay in lockstep.
    -- The PID acts on these averages so single-tick noise doesn't jerk the rods around.
    updateAverages = function (self)
        self.fuelUsageValues:pushleft(self.fuelUsage)
        self.lastRFTValues:pushleft(self.lastRFT)
        self.fuelTempValues:pushleft(self.fuelTemp)
        self.caseTempValues:pushleft(self.caseTemp)
        self.rodLevelValues:pushleft(self.rodLevel)
        self.wasteValues:pushleft(self.waste)
        self.steamProductionRateValues:pushleft(self.steamProductionRate)
        self.storedSteamValues:pushleft(self.storedSteam)

        local ticksToAverage = 20 * _G.SECONDS_TO_AVERAGE
        while self.lastRFTValues.size > ticksToAverage do
            self.fuelUsageValues:popright()
            self.lastRFTValues:popright()
            self.fuelTempValues:popright()
            self.caseTempValues:popright()
            self.rodLevelValues:popright()
            self.wasteValues:popright()
            self.steamProductionRateValues:popright()
            self.storedSteamValues:popright()
        end

        self.averageFuelUsage = self.fuelUsageValues:average()
        self.averageLastRFT = self.lastRFTValues:average()
        self.averageFuelTemp = self.fuelTempValues:average()
        self.averageCaseTemp = self.caseTempValues:average()
        self.averageRodLevel = self.rodLevelValues:average()
        self.averageWaste = self.wasteValues:average()
        self.averageSteamProductionRate = self.steamProductionRateValues:average()
        self.averageStoredSteam = self.storedSteamValues:average()

        self.averageFuelEfficiency = self.averageLastRFT / self.averageFuelUsage
    end,

    -- Read every stat from the peripheral once per game tick (idempotent per tick number).
    ---@param self Reactor
    ---@param currentTickNumber number
    update = function(self, currentTickNumber)
        if self.lastUpdatedTick >= currentTickNumber then
            return
        elseif self.lastUpdatedTick < currentTickNumber - 1 then
            -- We missed the last tick - Don't do anything different for now...
            print("missed last tick!")
        end

        self.activelyCooled = self.isActivelyCooled()
        self.active = self.getActive()
        self.lastRFT = self.getLastRFT()
        self.rodLevel = self.getRodLevel()
        self.fuelUsage = self.getFuelUsage()
        self.waste = self.getWaste()
        self.fuelTemp = self.getFuelTemp()
        self.caseTemp = self.getCaseTemp()
        self.steamProductionRate = self.getSteamProductionRate()
        self.storedSteam = self.getStoredSteam()
        self.steamCapacity = self.getSteamCapacity()
        self.fuelEfficiency = self.lastRFT / self.fuelUsage

        self:updateAverages()
        self.lastUpdatedTick = currentTickNumber
    end,

    -- The rod control law, run once per tick in auto mode.
    --
    -- Two error signals are blended:
    --   errorRFT : generation-rate error (produce what is being consumed - load following)
    --   errorRF  : buffer-fill error (keep the buffer at the middle of the [minb,maxb] band),
    --              normalized to "per-mille of capacity" so its magnitude is comparable
    --              across wildly different buffer sizes.
    --
    -- The weight W_RFT ramps from 1 (buffer at band center: pure load-following, smooth)
    -- down to 0 as the buffer strays a quarter-band away (pure buffer correction, decisive).
    -- The blended error then feeds one PID step whose output is the rod level.
    ---@param self Reactor
    updateRods = function (self)
        if not self.active then
            return
        end

        -- Passive (RF) reactor: track the aggregate energy buffer & grid drain.
        -- Actively cooled (steam) reactor: track the aggregate steam buffer & the turbines'
        -- actual steam consumption -> production matches demand, no excess steam is created.
        local currentGenerationRate = self.averageLastRFT
        local currentStoredAmount = _G.overallStats.storedThisTick
        local capacity = _G.overallStats.capacity
        -- Per-reactor share of the demand, so N same-mode reactors don't each chase the full load.
        local targetGenerationRate = _G.overallStats.rfLostPerReactor or _G.overallStats.rfLost

        if self.activelyCooled then
            currentGenerationRate = self.averageSteamProductionRate
            currentStoredAmount = _G.overallStats.storedSteam
            capacity = _G.overallStats.steamCapacity
            targetGenerationRate = _G.overallStats.steamConsumedPerReactor or _G.overallStats.steamConsumedLastTick
        end

        -- Nothing to regulate against yet (buffer not reported) -> hold rods, avoid divide-by-zero.
        if not capacity or capacity <= 0 then
            return
        end

        local diffb = _G.maxb - _G.minb          -- band width, percent
        local minRF = _G.minb / 100 * capacity   -- band floor, absolute
        local diffRF = diffb / 100 * capacity    -- band width, absolute
        local diffr = diffb / 100                -- band width, fraction of capacity
        -- Seek the middle of the target band; the weighting below blends toward pure
        -- rate-matching (load-following) as the buffer nears this target.
        local targetStoredAmount = diffRF / 2 + minRF

        self.pid.setpointRFT = targetGenerationRate
        self.pid.setpointRF = targetStoredAmount / capacity * 1000

        local errorRFT = self.pid.setpointRFT - currentGenerationRate
        local errorRF = self.pid.setpointRF - currentStoredAmount / capacity * 1000

        -- Distance from band center, measured in quarter-bands: 0 -> W_RFT=1, >=1 -> W_RFT=0.
        local bandQuarter = diffr / 4
        local W_RFT = 0
        if bandQuarter > 0 then
            W_RFT = lerp(1, 0, (math.abs(targetStoredAmount - currentStoredAmount) / capacity / bandQuarter))
        end
        W_RFT = math.max(math.min(W_RFT, 1), 0)

        local W_RF = (1 - W_RFT)

        local combinedError = W_RFT * errorRFT + W_RF * errorRF
        local rftRodLevel = iteratePID(self.pid, combinedError)

        self.setRodLevels(rftRodLevel)
    end,
}

-- Wrap the peripheral with the given network id and return a ready Reactor instance.
-- All peripheral access is funneled through the small getter closures below, so the rest of
-- the class never touches the raw peripheral (and the test harness can fake it wholesale).
---@param id string
---@return Reactor
local function newExtremeReactor(id)
    local extremeReactor = peripheral.wrap(id)

    -- Rod PID state. Negative gains: more insertion = less output (see iteratePID).
    -- Stock gains are inherited from the upstream project and behave sanely on both large
    -- and small reactors thanks to the band weighting in updateRods.
    local pid = {
        setpointRFT = 0,   -- target generation rate (RF/t or steam mB/t)
        setpointRF = 0,    -- target buffer fill (per-mille of capacity)
        Kp = -.008,
        Ki = -.00015,
        Kd = -.01,
        integral = 0,
        lastError = 0,
    }
    local reactorInstance = {
        id = id,
        pid = pid,
        fuelUsageValues = Deque.new(),
        lastRFTValues = Deque.new(),
        fuelTempValues = Deque.new(),
        caseTempValues = Deque.new(),
        rodLevelValues = Deque.new(),
        wasteValues = Deque.new(),
        steamProductionRateValues = Deque.new(),
        storedSteamValues = Deque.new(),

        -- Peripheral bindings (Modernized Object API).
        getFuelUsage = function () return extremeReactor.getFuelStats().fuelConsumedLastTick / 1000 end, -- mB -> B
        getLastRFT = function () return extremeReactor.getEnergyStats().energyProducedLastTick end,
        getFuelTemp = extremeReactor.getFuelTemperature,
        getCaseTemp = extremeReactor.getCasingTemperature,
        getRodLevel = function () return calculateAverage(extremeReactor.getControlRodsLevels()) end,
        getWaste = extremeReactor.getWasteAmount,
        getSteamProductionRate = extremeReactor.getHotFluidProducedLastTick, -- 0 on passive reactors
        getSteamCapacity = extremeReactor.getHotFluidAmountMax,
        getStoredSteam = extremeReactor.getHotFluidAmount,
        getActive = extremeReactor.getActive,
        isActivelyCooled = extremeReactor.isActivelyCooled,
        setActive = extremeReactor.setActive,
        setRodLevels = function (level) setRods(extremeReactor, level) end,
    }
	setmetatable(reactorInstance, {__index = Reactor})
    -- Prime all stats/averages immediately so consumers never see nil fields.
    local currentTickNumber = math.floor(os.clock() * 20)
    reactorInstance:update(currentTickNumber)
    return reactorInstance
end

_G.Reactor = {
    newExtremeReactor = newExtremeReactor,
}
