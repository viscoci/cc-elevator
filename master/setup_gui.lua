-- First-run terminal GUI shown when no elevator_topology.json exists.
-- Lists registered floors live and waits for the user to type `calibrate`.

local M = {}

local function readConfig()
    local f = fs.open("elevator_config.json", "r")
    local raw = f.readAll(); f.close()
    return textutils.unserializeJSON(raw)
end

local function drawBox(x, y, w, h)
    term.setCursorPos(x, y); term.write("+" .. string.rep("-", w - 2) .. "+")
    for i = 1, h - 2 do
        term.setCursorPos(x, y + i); term.write("|" .. string.rep(" ", w - 2) .. "|")
    end
    term.setCursorPos(x, y + h - 1); term.write("+" .. string.rep("-", w - 2) .. "+")
end

local function center(line, width)
    local pad = math.max(0, math.floor((width - #line) / 2))
    return string.rep(" ", pad) .. line
end

-- registry: { [computerId] = { computerId, locY, locX, locZ, lastSeen } }
-- Returns a sorted list of unique Y values registered.
local function summarizeRegistry(registry)
    local seen, ys = {}, {}
    for _, entry in pairs(registry) do
        if entry.locY and not seen[entry.locY] then
            seen[entry.locY] = true
            table.insert(ys, entry.locY)
        end
    end
    table.sort(ys)
    return ys
end

function M.render(state)
    local cfg = readConfig()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    drawBox(1, 1, w, h)

    term.setCursorPos(2, 2)
    term.setTextColor(colors.yellow)
    term.write(center("ELEVATOR SETUP - " .. (cfg.elevatorName or "?"), w - 2))
    term.setTextColor(colors.white)

    local ys = summarizeRegistry(state.registry or {})
    local stationCount = 0
    for _ in pairs(state.registry or {}) do stationCount = stationCount + 1 end

    term.setCursorPos(3, 4)
    term.write("Floor stations registered: " .. stationCount ..
               " (" .. #ys .. " unique level" .. (#ys == 1 and "" or "s") .. ")")
    if #ys > 0 then
        term.setCursorPos(3, 5)
        term.write("Lowest Y: " .. ys[1])
        term.setCursorPos(3, 6)
        term.write("Highest Y: " .. ys[#ys])
    end

    term.setCursorPos(3, 8)
    term.setTextColor(colors.lightGray)
    term.write("Steps:")
    term.setTextColor(colors.white)
    term.setCursorPos(3, 9);  term.write(" 1. On every floor's CC, run:")
    term.setCursorPos(3, 10)
    term.setTextColor(colors.cyan)
    term.write("    wget run https://raw.githubusercontent.com/")
    term.setCursorPos(3, 11)
    term.write("      " .. cfg.repoOwner .. "/" .. cfg.repoName .. "/" .. cfg.repoBranch .. "/install.lua")
    term.setTextColor(colors.white)
    term.setCursorPos(3, 12); term.write(" 2. Wait for them to appear in the list above.")
    term.setCursorPos(3, 13); term.write(" 3. Park the cart anywhere.")
    term.setCursorPos(3, 14); term.write(" 4. Type 'calibrate' (or 'c') and press Enter.")

    if state.lastMessage then
        term.setCursorPos(3, h - 3)
        term.setTextColor(colors.lime)
        term.write(state.lastMessage:sub(1, w - 4))
        term.setTextColor(colors.white)
    end

    term.setCursorPos(3, h - 1)
    term.write("> ")
end

return M
