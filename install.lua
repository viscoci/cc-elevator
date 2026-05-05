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

-- Pick role via single keypress (M or F) — avoids any input quirks at the
-- very first prompt where they're most painful to debug.
local function pickRole()
    term.write("Role: press [M]aster or [F]loor: ")
    term.setCursorBlink(true)
    while true do
        local event, p1 = os.pullEvent()
        if event == "char" then
            local c = p1:lower()
            if c == "m" then term.setCursorBlink(false); print("master"); return "master" end
            if c == "f" then term.setCursorBlink(false); print("floor"); return "floor" end
        elseif event == "key" then
            if p1 == keys.m then term.setCursorBlink(false); print("master"); return "master" end
            if p1 == keys.f then term.setCursorBlink(false); print("floor"); return "floor" end
        elseif event == "terminate" then
            term.setCursorBlink(false); error("Cancelled", 0)
        end
    end
end

term.clear()
term.setCursorPos(1, 1)
print("=== cc-elevator installer ===")
print()

local role = pickRole()

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
