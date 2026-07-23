-- One-shot installer for my-reactor-controller.
-- On a CC:Tweaked computer:
--   wget run https://raw.githubusercontent.com/stedmana/my-reactor-controller/main/install.lua
--
-- Fetches the current file list from the GitHub tree API (no manifest to maintain),
-- downloads src/ + startup.lua to the computer root, then offers to reboot.

local OWNER = "stedmana"
local REPO = "my-reactor-controller"
local BRANCH = "main"

local TREE_URL = ("https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1"):format(OWNER, REPO, BRANCH)
local RAW_BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)

-- Only these paths end up on the computer (test/, README etc. stay on GitHub).
local function shouldInstall(path)
    return path == "startup.lua" or path:sub(1, 4) == "src/"
end

local function httpGet(url)
    local response, err = http.get(url)
    if not response then
        return nil, err or "request failed"
    end
    local body = response.readAll()
    response.close()
    return body
end

local function fetchFileList()
    print("Fetching file list from GitHub...")
    local body, err = httpGet(TREE_URL)
    if not body then
        error("Could not reach the GitHub API: " .. tostring(err))
    end

    local tree = textutils.unserialiseJSON(body)
    if not tree or not tree.tree then
        error("Unexpected GitHub API response")
    end
    if tree.truncated then
        error("GitHub tree response truncated (repo too large?)")
    end

    local paths = {}
    for _, entry in ipairs(tree.tree) do
        if entry.type == "blob" and shouldInstall(entry.path) then
            paths[#paths + 1] = entry.path
        end
    end
    table.sort(paths)
    return paths
end

local function downloadFile(path)
    local body, err = httpGet(RAW_BASE .. path)
    if not body then
        return false, err
    end

    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local file = fs.open(path, "w")
    file.write(body)
    file.close()
    return true
end

local function install()
    local paths = fetchFileList()
    if #paths == 0 then
        error("No files found to install!")
    end
    print(("Installing %d files..."):format(#paths))

    for i, path in ipairs(paths) do
        local ok, err = downloadFile(path)
        if not ok then
            -- one retry, then give up loudly
            os.sleep(0.5)
            ok, err = downloadFile(path)
            if not ok then
                error(("Failed to download %s: %s"):format(path, tostring(err)))
            end
        end
        print(("[%d/%d] %s"):format(i, #paths, path))
    end

    print("")
    print("Install complete!")
    print("Reboot now to start the controller? (y/n)")
    local answer = read()
    if answer == "y" or answer == "Y" then
        os.reboot()
    else
        print("Run 'reboot' (or hold Ctrl+R) when ready.")
    end
end

install()
