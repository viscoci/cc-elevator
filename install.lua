-- One-shot installer: makes this computer part of the elevator system.
-- Usage on a fresh CC computer:
--   wget run https://raw.githubusercontent.com/<owner>/cc-elevator/main/install.lua

-- ===== EDIT THESE TO POINT AT YOUR REPO BEFORE PUSHING =====
local REPO_OWNER  = "viscoci"
local REPO_NAME   = "cc-elevator"
local REPO_BRANCH = "main"
-- ===========================================================

local function rawUrl(path)
    return "https://raw.githubusercontent.com/" .. REPO_OWNER ..
           "/" .. REPO_NAME .. "/" .. REPO_BRANCH .. "/" .. path
end

local function ensureDir(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function fetch(path)
    local resp = http.get(rawUrl(path))
    if not resp then error("Failed to fetch " .. path, 0) end
    local body = resp.readAll()
    resp.close()
    ensureDir(path)
    local f = fs.open(path, "w")
    f.write(body)
    f.close()
end

local function prompt(question, default)
    write(question)
    if default then write(" [" .. default .. "]") end
    write(": ")
    local answer = read()
    if answer == "" and default then return default end
    return answer
end

local function yesno(question, default)
    local d = default and "y" or "n"
    local a = prompt(question .. " (y/n)", d):lower()
    return a == "y" or a == "yes"
end

term.clear()
term.setCursorPos(1, 1)
print("=== cc-elevator installer ===")
print()

local role = prompt("Role (master/floor)", "floor"):lower()
if role ~= "master" and role ~= "floor" then
    error("Role must be 'master' or 'floor'", 0)
end

local config = {
    role = role,
    repoOwner = REPO_OWNER,
    repoName = REPO_NAME,
    repoBranch = REPO_BRANCH,
    autoUpdate = true,
}

if role == "master" then
    config.elevatorName = prompt("Elevator name (e.g. storage-silo)")
    if config.elevatorName == "" then error("Elevator name required", 0) end
else
    config.runSync    = yesno("Run floor sync on this computer?", true)
    config.runDisplay = yesno("Run floor display on this computer?", true)
    if not config.runSync and not config.runDisplay then
        error("At least one of sync/display must be enabled", 0)
    end
end

print()
print("Fetching manifest...")
fetch("manifest.lua")
local manifest = dofile("manifest.lua")

local files = {}
for _, p in ipairs(manifest.common or {}) do table.insert(files, p) end
for _, p in ipairs(manifest[role]   or {}) do table.insert(files, p) end

print("Downloading " .. #files .. " files...")
for _, path in ipairs(files) do
    if path ~= "manifest.lua" then
        write("  " .. path .. " ... ")
        fetch(path)
        print("ok")
    end
end

-- Persist config
local cfgFile = fs.open("elevator_config.json", "w")
cfgFile.write(textutils.serializeJSON(config))
cfgFile.close()

-- Wire up startup.lua to point at the role's startup
local startup = fs.open("startup.lua", "w")
startup.write('shell.run("' .. role .. '/startup.lua")\n')
startup.close()

print()
print("Install complete. Rebooting in 3...")
sleep(1) print("2...")
sleep(1) print("1...")
sleep(1)
os.reboot()
