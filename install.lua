-- One-shot installer: makes this computer part of the elevator system.
--
-- Interactive (no args):
--   wget run https://raw.githubusercontent.com/<owner>/cc-elevator/main/install.lua
--
-- Non-interactive (skip prompts):
--   wget run .../install.lua -M [elevatorName]                -- master
--   wget run .../install.lua -F   [elevatorName]              -- floor, sync+display
--   wget run .../install.lua -FS  [elevatorName]              -- floor, sync only
--   wget run .../install.lua -FD  [elevatorName]              -- floor, display only
--   wget run .../install.lua -FSD [elevatorName]              -- floor, sync+display
--
-- For floor installs, [elevatorName] is optional. If omitted, the floor will
-- auto-discover the elevator from the first matching broadcast it hears
-- (works fine for single-elevator worlds; specify a name if you have more
-- than one elevator and want to lock this floor to a specific one).
--
-- Order of letters after -F doesn't matter: -FDS is equivalent to -FSD.

local cliArgs = {...}

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

-- Drain any pending events. Used between prompts so leftover key/char/key_up
-- events from a previous keypress don't bleed into the next input.
local function drainEvents()
    os.queueEvent("__drain__")
    while os.pullEvent() ~= "__drain__" do end
end

-- Custom line reader: pulls char/key events directly. Avoids relying on
-- read(), which behaves inconsistently when scripts are launched via
-- `wget run` on some CC: Tweaked builds (no input echo, returns empty).
local function readLine()
    term.setCursorBlink(true)
    local s = ""
    while true do
        local event, p1 = os.pullEvent()
        if event == "char" then
            s = s .. p1
            term.write(p1)
        elseif event == "key" then
            if p1 == keys.enter then
                break
            elseif p1 == keys.backspace and #s > 0 then
                s = s:sub(1, -2)
                local x, y = term.getCursorPos()
                term.setCursorPos(x - 1, y)
                term.write(" ")
                term.setCursorPos(x - 1, y)
            end
        elseif event == "paste" then
            s = s .. p1
            term.write(p1)
        elseif event == "terminate" then
            term.setCursorBlink(false)
            error("Cancelled", 0)
        end
    end
    term.setCursorBlink(false)
    print()
    return s
end

local function prompt(question, default)
    term.write(question)
    if default then term.write(" [" .. default .. "]") end
    term.write(": ")
    local answer = readLine()
    if answer == "" and default then return default end
    return answer
end

local function yesno(question, default)
    local d = default and "y" or "n"
    local a = prompt(question .. " (y/n)", d):lower()
    return a == "y" or a == "yes"
end

-- Pick role via single keypress. Match only `char` events (not `key`); CC fires
-- both per keypress, but `char` arrives after `key`, and matching only `char`
-- ensures the trailing event for that keypress is consumed by us, not by the
-- next prompt.
local function pickRole()
    term.write("Role: press [M]aster or [F]loor: ")
    term.setCursorBlink(true)
    drainEvents()
    local result
    while not result do
        local event, p1 = os.pullEvent()
        if event == "char" then
            local c = p1:lower()
            if c == "m" then result = "master"
            elseif c == "f" then result = "floor"
            end
        elseif event == "terminate" then
            term.setCursorBlink(false); error("Cancelled", 0)
        end
    end
    term.setCursorBlink(false)
    print(result)
    drainEvents()
    return result
end

-- Parse CLI args. First arg may be a -M / -F[SD] flag.
local function parseCliFlag(flag)
    if not flag or flag:sub(1, 1) ~= "-" then return nil end
    local body = flag:sub(2):upper()
    if body == "M" then
        return { role = "master" }
    end
    if body:sub(1, 1) == "F" then
        local letters = body:sub(2)
        local hasS, hasD = letters:find("S"), letters:find("D")
        -- If no S/D letters given, default to both on (matches `-F` shorthand).
        if letters == "" then hasS, hasD = true, true end
        return {
            role = "floor",
            runSync = hasS ~= nil and hasS ~= false,
            runDisplay = hasD ~= nil and hasD ~= false,
        }
    end
    return nil
end

term.clear()
term.setCursorPos(1, 1)
print("=== cc-elevator installer ===")
print()

local cliFlag = parseCliFlag(cliArgs[1])
local role
if cliFlag then
    role = cliFlag.role
    print("Role: " .. role .. " (from CLI)")
else
    role = pickRole()
end

local config = {
    role = role,
    repoOwner = REPO_OWNER,
    repoName = REPO_NAME,
    repoBranch = REPO_BRANCH,
    autoUpdate = true,
}

if role == "master" then
    if cliArgs[2] and cliArgs[2] ~= "" then
        config.elevatorName = cliArgs[2]
        print("Elevator name: " .. config.elevatorName .. " (from CLI)")
    else
        config.elevatorName = prompt("Elevator name (e.g. storage-silo)")
        if config.elevatorName == "" then error("Elevator name required", 0) end
    end
else
    if cliFlag then
        config.runSync = cliFlag.runSync
        config.runDisplay = cliFlag.runDisplay
        print("Run sync: " .. tostring(config.runSync) .. " (from CLI)")
        print("Run display: " .. tostring(config.runDisplay) .. " (from CLI)")
    else
        config.runSync    = yesno("Run floor sync on this computer?", true)
        config.runDisplay = yesno("Run floor display on this computer?", true)
    end
    if not config.runSync and not config.runDisplay then
        error("At least one of sync/display must be enabled", 0)
    end

    -- Optional elevator name lock. Empty/omitted = auto-discover.
    if cliArgs[2] and cliArgs[2] ~= "" then
        config.elevatorName = cliArgs[2]
        print("Elevator name: " .. config.elevatorName .. " (from CLI)")
    else
        local name = prompt("Elevator name (blank = auto-discover)", "")
        if name ~= "" then config.elevatorName = name end
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
