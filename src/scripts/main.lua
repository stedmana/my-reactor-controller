-- my-reactor-controller entry point.
-- Loads every module in src/ (each file registers a _G.X global), then starts the controller.
-- No auto-updater: this is a local install.

local function insertAllFilepathsInDirectoryToTable(path, outputFilenames)
    for _, file in pairs(fs.list(path)) do
        local filepath = fs.combine(path, file)
        if fs.isDir(filepath) then
            insertAllFilepathsInDirectoryToTable(filepath, outputFilenames)
        else
            table.insert(outputFilenames, filepath)
        end
    end
end

-- Load-order matters: base globals must exist before modules that reference them at load time.
local LOAD_FIRST = {
    "src/config/projectConfigs.lua",
    "src/constants/projectConstants.lua",
    "src/classes/vector2.lua",
    "src/classes/deque.lua",
    "src/util/draw.lua",
}

local function runFile(filepath, loadedSet)
    if loadedSet[filepath] then
        return
    end
    loadedSet[filepath] = true
    shell.run(filepath)
end

local function executeAllModules()
    local loaded = {}

    for _, filepath in ipairs(LOAD_FIRST) do
        if fs.exists(filepath) then
            runFile(filepath, loaded)
        end
    end

    local filepaths = {}
    insertAllFilepathsInDirectoryToTable("src", filepaths)
    table.sort(filepaths)
    for _, filepath in pairs(filepaths) do
        if filepath ~= "src/scripts/main.lua" then
            runFile(filepath, loaded)
        end
    end
end

local function start()
    executeAllModules()

    -- Let reactors/turbines run for a second on world load so first-tick stats populate.
    sleep(1)

    term.clear()
    term.setCursorPos(1, 1)

    ConfigUtil.writeAllConfigsAsDefaults()
    ConfigUtil.readAllConfigs()

    -- main() is defined in controller.lua
    main()
end

start()
