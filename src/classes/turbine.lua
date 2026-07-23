-- Turbine class (Extreme Reactors 2 "BigReactors-Turbine" peripheral, MC 1.20.1 Modernized API).
--
-- Control model (see README):
--   * Steam throttle (setFluidFlowRateMax) is a PI controller whose ONLY job is to hold idleRPM.
--   * Coils (setInductorEngaged) are the power tap: engaged = generate + brake, disengaged = freewheel.
--     Driven by this turbine's OWN internal RF buffer % with hysteresis.
--   * A safety governor overrides both above safeRPM/ceilingRPM so RPM can never cross the ceiling.
--
-- Because the steam PI always targets idleRPM, flipping coils ON makes "hold 1800" require lots of
-- steam (=> lots of power); coils OFF makes it require almost none (=> idle, no waste). One law,
-- every regime (cold spin-up, idle standby, full generation) handled by the same three steps.

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

---@class Turbine
---@field id string
---@field active boolean
---@field rpm number
---@field averageRPM number
---@field energyProduced number       RF/t produced last tick
---@field averageEnergyProduced number
---@field energyStored number
---@field energyCapacity number
---@field steamFlow number            actual mB/t steam consumed last tick
---@field averageSteamFlow number
---@field steamCap number             current setFluidFlowRateMax setting
---@field flowMaxMax number           hard per-turbine cap ceiling
---@field coilsEngaged boolean
---@field desiredCoils boolean
---@field bladeEfficiency number
---@field lastUpdatedTick number
local Turbine = {

    lastUpdatedTick = 0,

    ---@param self Turbine
    bufferPct = function(self)
        if self.energyCapacity <= 0 then
            return 100
        end
        return self.energyStored / self.energyCapacity * 100
    end,

    ---@param self Turbine
    updateAverages = function(self)
        self.rpmValues:pushleft(self.rpm)
        self.energyProducedValues:pushleft(self.energyProduced)
        self.steamFlowValues:pushleft(self.steamFlow)

        local ticksToAverage = 20 * _G.SECONDS_TO_AVERAGE
        while self.rpmValues.size > ticksToAverage do
            self.rpmValues:popright()
            self.energyProducedValues:popright()
            self.steamFlowValues:popright()
        end

        self.averageRPM = self.rpmValues:average()
        self.averageEnergyProduced = self.energyProducedValues:average()
        self.averageSteamFlow = self.steamFlowValues:average()
    end,

    ---@param self Turbine
    ---@param currentTickNumber number
    update = function(self, currentTickNumber)
        if self.lastUpdatedTick >= currentTickNumber then
            return
        end

        self.active = self.getActive()
        self.rpm = self.getRotorSpeed()
        self.energyProduced = self.getEnergyProduced()
        self.energyStored = self.getEnergyStored()
        self.energyCapacity = self.getEnergyCapacity()
        self.steamFlow = self.getFluidFlowRate()
        self.coilsEngaged = self.getInductorEngaged()
        self.bladeEfficiency = self.getBladeEfficiency()

        self:updateAverages()
        self.lastUpdatedTick = currentTickNumber
    end,

    -- Peripheral-write helpers: only hit the peripheral when the value actually changes,
    -- to keep 20Hz control from spamming the server with method calls.

    ---@param self Turbine
    ---@param amount number desired steam-flow cap (mB/t)
    writeSteam = function(self, amount)
        amount = math.floor(clamp(amount, 0, self.flowMaxMax) + 0.5)
        local forceEdge = (amount == 0 or amount == self.flowMaxMax)
        if forceEdge or math.abs(amount - self.lastWrittenSteamCap) >= self.steamWriteThreshold then
            self.setFluidFlowRateMax(amount)
            self.lastWrittenSteamCap = amount
            self.steamCap = amount
        end
    end,

    ---@param self Turbine
    ---@param engaged boolean
    writeCoils = function(self, engaged)
        if engaged ~= self.lastWrittenCoils then
            self.setInductorEngaged(engaged)
            self.lastWrittenCoils = engaged
            self.coilsEngaged = engaged
        end
    end,

    ---@param self Turbine
    setActive = function(self, state)
        self.setActivePeripheral(state)
        self.active = state
    end,

    -- The three-step control law. Called once per tick in auto mode.
    ---@param self Turbine
    ---@param config table CONTROL_CONFIG
    updateControl = function(self, config)
        if not self.active then
            return
        end

        self.steamWriteThreshold = config.steamWriteThreshold or 5

        local rpm = self.rpm                 -- instantaneous for safety
        local avgRpm = self.averageRPM       -- smoothed for the PI

        -- 1) SAFETY GOVERNOR -- highest priority, ignores the PI.
        if rpm >= config.ceilingRPM then
            self:writeSteam(0)
            self:writeCoils(true)            -- engage coils to brake
            self.pid.integral = 0            -- so we don't slam back to full steam
            return
        elseif rpm >= config.safeRPM then
            self:writeCoils(true)
            local capped = math.min(self.steamCap, self.flowMaxMax * 0.25)
            self:writeSteam(capped)
            self.pid.integral = math.min(self.pid.integral, capped)
            return
        end

        -- 2) COIL DEMAND -- hysteresis on this turbine's own internal buffer.
        local bufPct = self:bufferPct()
        if bufPct <= config.coilsOnBelowPct then
            self.desiredCoils = true
        elseif bufPct >= config.coilsOffAbovePct then
            self.desiredCoils = false
        end
        self:writeCoils(self.desiredCoils)

        -- 3) STEAM PI -- hold idleRPM. Integral carries the (mode-dependent) steady-state steam,
        --    so when coils flip the integral migrates to the new flow that holds 1800.
        local err = config.idleRPM - avgRpm
        self.pid.integral = clamp(self.pid.integral + config.turbineKi * err, 0, self.flowMaxMax)
        local output = clamp(self.pid.integral + config.turbineKp * err, 0, self.flowMaxMax)
        self:writeSteam(output)
    end,
}

---@param id string
---@return Turbine
local function newExtremeTurbine(id)
    local p = peripheral.wrap(id)

    -- Feature-detect the two diagnostics the mod historically misspelled
    -- (getBladeEffiency / getBladeEfficiency). Load-bearing methods are stable-named.
    local bladeEff = p.getBladeEfficiency or p.getBladeEffiency or function() return 0 end

    local instance = {
        id = id,

        rpm = 0, averageRPM = 0,
        energyProduced = 0, averageEnergyProduced = 0,
        energyStored = 0, energyCapacity = 0,
        steamFlow = 0, averageSteamFlow = 0,
        steamCap = 0,
        coilsEngaged = false,
        desiredCoils = false,
        bladeEfficiency = 0,

        lastWrittenSteamCap = -1,
        lastWrittenCoils = nil,
        steamWriteThreshold = 5,

        rpmValues = Deque.new(),
        energyProducedValues = Deque.new(),
        steamFlowValues = Deque.new(),

        pid = { integral = 0 },

        -- peripheral bindings
        getActive = p.getActive,
        getRotorSpeed = p.getRotorSpeed,
        getEnergyProduced = p.getEnergyProducedLastTick,
        getEnergyStored = p.getEnergyStored,
        getEnergyCapacity = p.getEnergyCapacity,
        getFluidFlowRate = p.getFluidFlowRate,
        getInductorEngaged = p.getInductorEngaged,
        getBladeEfficiency = bladeEff,
        setFluidFlowRateMax = p.setFluidFlowRateMax,
        setInductorEngaged = p.setInductorEngaged,
        setActivePeripheral = p.setActive,
    }

    -- Hard per-turbine steam ceiling, read from the peripheral (do NOT assume 2000).
    instance.flowMaxMax = p.getFluidFlowRateMaxMax()
    if not instance.flowMaxMax or instance.flowMaxMax <= 0 then
        instance.flowMaxMax = 2000
    end

    setmetatable(instance, { __index = Turbine })

    -- Ensure the turbine is running so it can be governed; start with coils disengaged.
    instance.setActivePeripheral(true)
    instance.active = true
    instance:writeCoils(false)

    local currentTickNumber = math.floor(os.clock() * 20)
    instance:update(currentTickNumber)
    return instance
end

_G.Turbine = {
    newExtremeTurbine = newExtremeTurbine,
}
