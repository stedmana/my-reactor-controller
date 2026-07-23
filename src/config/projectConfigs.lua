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

    -- Responsiveness / server-lag throttle. The safety governor ALWAYS runs at full tick
    -- rate; these only slow down the steering (rod PID, coil hysteresis, steam PI).
    controlIntervalTicks = 1, -- run the steering pass every N game ticks (1 = every tick)
    rpmDeadband = 0,          -- ignore steam-PI RPM errors smaller than this (RPM)
    rodWriteThreshold = 0,    -- min rod-level change (%-points) before pushing new levels

    -- Per-entity overrides of the global settings above, keyed by peripheral id, e.g.
    --   entityOverrides = { ["BigReactors-Turbine_2"] = { idleRPM = 900 } }
    -- Reactors honor: bufferMin, bufferMax.
    -- Turbines honor: coilsOnBelowPct, coilsOffAbovePct, idleRPM.
    entityOverrides = {},

    -- Steam network groups: which reactors feed which turbines. Each group runs its own
    -- steam-match cascade (active reactors chase ONLY their group's turbine steam draw).
    -- Any reactor/turbine not listed falls into the implicit "default" group, so an empty
    -- list = one big shared network (the original behavior). Example:
    --   steamGroups = {
    --     { reactors = { "BigReactors-Reactor_2" }, turbines = { "BigReactors-Turbine_1" } },
    --   }
    steamGroups = {},

    -- Flywheel mode (OFF by default). When armed, IDLE turbines (coils disengaged) run at FULL
    -- steam and climb as high as the turbine physically allows, banking rotational energy so a
    -- sudden power spike can be served instantly: the moment the coils engage, the normal 2000
    -- RPM ceiling snaps back and the governor brakes the overspeed off into the grid.
    --
    -- flywheelCeilingRPM is an OPTIONAL software cap while armed+idle: 0 (default) = uncapped
    -- (spin as high as possible); any positive value hard-cuts the rotor at that RPM instead.
    --
    --   !!! WARNING: running a turbine above 2000 RPM can make it EXPLODE in-game, and uncapped
    --   flywheel has NO upper RPM limit. This mode deliberately defeats the 2000 RPM safety
    --   guarantee; high-RPM behavior is NOT verified in-game - use at your own risk. !!!
    flywheelMode = false,
    flywheelCeilingRPM = 0,     -- 0 = uncapped; >0 = hard cut at this RPM while armed+idle

    -- Rolling-average window (seconds) for all smoothed stats.
    secondsToAverage = 0.5,
}
