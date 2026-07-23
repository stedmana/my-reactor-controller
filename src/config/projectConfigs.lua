-- Tunable controller settings. Persisted via ConfigUtil (defaults + user overrides).
-- Edit live from the monitor buttons, or drop an override file; see util/config.lua.
_G.CONTROL_CONFIG = {
    -- Master automatic control. When false, reactors/turbines hold last manual state.
    autoMode = true,

    -- Aggregate energy-buffer target band (percent) for standalone (passively cooled) reactors.
    -- Rods are modulated to keep the combined internal RF buffer inside [bufferMin, bufferMax].
    bufferMin = 30,
    bufferMax = 70,

    -- Turbine speed governor (RPM).
    idleRPM = 1800,     -- steam PID target; efficiency sweet spot, held in every mode
    safeRPM = 1950,     -- soft brake: clamp steam hard at/above this
    ceilingRPM = 2000,  -- hard cut: steam -> 0 and coils engaged (brake) at/above this

    -- Per-turbine demand hysteresis, read from each turbine's OWN internal RF buffer (%).
    -- Below coilsOnBelowPct -> engage coils (generate). Above coilsOffAbovePct -> disengage (idle).
    coilsOnBelowPct = 30,
    coilsOffAbovePct = 70,

    -- Turbine steam PI gains (output = integral + Kp*error, in mB/t; positive: more steam -> more RPM).
    turbineKp = 1.5,
    turbineKi = 0.35,

    -- Only push a new steam-flow cap to a turbine when it moves at least this many mB/t (cut peripheral spam).
    steamWriteThreshold = 5,

    -- Rolling-average window (seconds) for all smoothed stats.
    secondsToAverage = 0.5,
}
