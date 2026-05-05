-- Floor display: renders attached monitors based on elevator_status broadcasts.
-- Auto-detects this display's floor by matching nearest Y coordinate.
-- Touching a monitor calls the elevator to this floor.
-- Logic ported from elevator_display_link_v2.lua (computer 38).

package.path = package.path .. ";/?.lua;/?/init.lua"

local protocol = require("shared.protocol")
local rednetSetup = require("shared.rednet_setup")
local logger = require("shared.log")

local log = logger.make("DISPLAY")

-- Detect monitors
local monitors = {}
local monitorCount = 0
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
        monitors[name] = peripheral.wrap(name)
        monitorCount = monitorCount + 1
        log("Found monitor: " .. name)
    end
end

if next(monitors) == nil then
    log("No monitor attached - display task idling.")
    -- Idle forever so parallel.waitForAll doesn't bail.
    while true do sleep(60) end
end

local displayLocX, displayLocY, displayLocZ = gps.locate(2, false)
assert(displayLocY, "GPS required for display.")
log("Display at Y=" .. displayLocY)

rednetSetup.open()

-- State
local syncComputerId = nil
local elevatorName = nil
local elevatorState = "unknown"
local currentFloor = nil
local destination = nil
local floors = {}
local myFloor = nil

local function calculateMyFloor()
    if not displayLocY or #floors == 0 then return nil end
    local nearest, dist = nil, math.huge
    for _, f in ipairs(floors) do
        local d = math.abs(f.floorY - displayLocY)
        if d < dist then dist = d; nearest = f end
    end
    return nearest
end

local function isComingHere()
    if not myFloor or not destination then return false end
    return destination.floorNumber == myFloor.floorNumber
end

local function wrapText(text, maxWidth)
    if #text <= maxWidth then return { text } end
    local lines, currentLine = {}, ""
    for word in text:gmatch("%S+") do
        if #currentLine == 0 then currentLine = word
        elseif #currentLine + 1 + #word <= maxWidth then currentLine = currentLine .. " " .. word
        else table.insert(lines, currentLine); currentLine = word end
    end
    if #currentLine > 0 then table.insert(lines, currentLine) end
    if #lines == 0 or (#lines == 1 and #lines[1] > maxWidth) then
        lines = {}
        for i = 1, #text, maxWidth do table.insert(lines, text:sub(i, i + maxWidth - 1)) end
    end
    return lines
end

local function getBackgroundColor()
    if not myFloor then return colors.black end
    if currentFloor and currentFloor.floorNumber == myFloor.floorNumber then return colors.green end
    if isComingHere() then return colors.cyan end
    if elevatorState == "moving_up" or elevatorState == "moving_down" then return colors.orange end
    if currentFloor and myFloor then
        local diff = math.abs(currentFloor.floorNumber - myFloor.floorNumber)
        if diff <= 2 then return colors.yellow else return colors.red end
    end
    return colors.black
end

local function renderWrappedText(monitor, text, width, startY, maxLines)
    local lines = wrapText(text, width)
    local n = math.min(#lines, maxLines or #lines)
    for i = 1, n do
        local line = lines[i]
        local x = math.floor((width - #line) / 2) + 1
        monitor.setCursorPos(x, startY + i - 1)
        monitor.write(line)
    end
end

local function renderSingleBlock(monitor)
    local bg = getBackgroundColor()
    monitor.setTextScale(0.5)
    local w, h = monitor.getSize()
    monitor.setBackgroundColor(bg)
    local fg = (bg == colors.yellow) and colors.purple or colors.white
    monitor.setTextColor(fg)
    monitor.clear()

    if myFloor then
        local numText = tostring(myFloor.floorNumber)
        local nameText = myFloor.floorName or "---"
        monitor.setCursorPos(math.floor((w - #numText) / 2) + 1, math.floor(h / 2) - 1)
        monitor.write(numText)
        local startY = math.floor(h / 2) + 1
        renderWrappedText(monitor, nameText, w, startY, h - startY + 1)
    else
        local txt = "---"
        monitor.setCursorPos(math.floor((w - #txt) / 2) + 1, math.floor(h / 2))
        monitor.write(txt)
    end
end

local function renderStacked(monitor)
    local bg = getBackgroundColor()
    monitor.setTextScale(0.5)
    local w, h = monitor.getSize()
    monitor.setBackgroundColor(bg)
    local fg = (bg == colors.yellow) and colors.purple or colors.white
    monitor.setTextColor(fg)
    monitor.clear()

    local elevatorHere = currentFloor and myFloor and (currentFloor.floorNumber == myFloor.floorNumber)

    if elevatorHere then
        local numText = tostring(myFloor.floorNumber)
        local nameText = myFloor.floorName or "---"
        monitor.setCursorPos(math.floor((w - #numText) / 2) + 1, math.floor(h / 2) - 1)
        monitor.write(numText)
        local startY = math.floor(h / 2) + 1
        renderWrappedText(monitor, nameText, w, startY, h - startY)
    elseif elevatorState == "moving_up" or elevatorState == "moving_down" then
        local arrow = elevatorState == "moving_up" and "^" or "v"
        monitor.setCursorPos(math.floor((w - 1) / 2) + 1, math.floor(h / 10) + 1)
        monitor.write(arrow)
        if isComingHere() then
            local s = "Arriving..."
            monitor.setCursorPos(math.floor((w - #s) / 2) + 1, math.floor(h / 5) + 1)
            monitor.write(s)
        else
            local s = "Going to"
            monitor.setCursorPos(math.floor((w - #s) / 2) + 1, math.floor(h / 7) + 1)
            monitor.write(s)
            if destination then
                local dn = tostring(destination.floorNumber)
                monitor.setCursorPos(math.floor((w - #dn) / 2) + 1, math.floor(h / 5) + 1)
                monitor.write(dn)
                local dnName = destination.floorName or "---"
                renderWrappedText(monitor, dnName, w, math.floor(h / 4) + 1,
                    math.max(1, math.floor(h / 2) - math.floor(h / 4) - 2))
            end
        end
        -- Call button strip
        local callY = math.floor(h / 2)
        monitor.setBackgroundColor(colors.gray)
        monitor.setTextColor(colors.white)
        monitor.setCursorPos(1, callY); monitor.write(string.rep(" ", w))
        local callText = "Call"
        monitor.setCursorPos(math.floor((w - #callText) / 2) + 1, callY); monitor.write(callText)
        monitor.setBackgroundColor(bg); monitor.setTextColor(fg)
        -- This floor section
        local label = "This Floor"
        monitor.setCursorPos(math.floor((w - #label) / 2) + 1, math.floor(h * 5 / 8))
        monitor.write(label)
        if myFloor then
            local mn = tostring(myFloor.floorNumber)
            monitor.setCursorPos(math.floor((w - #mn) / 2) + 1, math.floor(h * 11 / 16))
            monitor.write(mn)
            local mname = myFloor.floorName or "---"
            renderWrappedText(monitor, mname, w, math.floor(h * 3 / 4) + 1, h - math.floor(h * 3 / 4))
        end
    else
        -- Elevator at different floor (stationary)
        local lbl = "Current Floor"
        monitor.setCursorPos(math.floor((w - #lbl) / 2) + 1, math.floor(h / 10) + 1)
        monitor.write(lbl)
        local cn = currentFloor and tostring(currentFloor.floorNumber) or "---"
        monitor.setCursorPos(math.floor((w - #cn) / 2) + 1, math.floor(h / 5) + 1)
        monitor.write(cn)
        local cname = currentFloor and currentFloor.floorName or "---"
        renderWrappedText(monitor, cname, w, math.floor(h / 4) + 1,
            math.max(1, math.floor(h / 2) - math.floor(h / 4) - 2))
        -- Call button strip
        local callY = math.floor(h / 2)
        monitor.setBackgroundColor(colors.gray)
        monitor.setTextColor(colors.white)
        monitor.setCursorPos(1, callY); monitor.write(string.rep(" ", w))
        local callText = "Call"
        monitor.setCursorPos(math.floor((w - #callText) / 2) + 1, callY); monitor.write(callText)
        monitor.setBackgroundColor(bg); monitor.setTextColor(fg)
        -- This floor
        local lbl2 = "This Floor"
        monitor.setCursorPos(math.floor((w - #lbl2) / 2) + 1, math.floor(h * 5 / 8))
        monitor.write(lbl2)
        local mn = myFloor and tostring(myFloor.floorNumber) or "---"
        monitor.setCursorPos(math.floor((w - #mn) / 2) + 1, math.floor(h * 11 / 16))
        monitor.write(mn)
        local mname = myFloor and myFloor.floorName or "---"
        renderWrappedText(monitor, mname, w, math.floor(h * 3 / 4) + 1, h - math.floor(h * 3 / 4))
    end
end

local function renderAll()
    for _, monitor in pairs(monitors) do
        monitor.setTextScale(5)
        local ow, oh = monitor.getSize()
        if ow == 1 and oh == 1 then renderSingleBlock(monitor)
        else renderStacked(monitor) end
    end
end

local function sendCall()
    if not myFloor then log("Cannot call - no floor detected"); return end
    if not syncComputerId then log("Cannot call - master unknown"); return end
    protocol.send(syncComputerId, {
        type = protocol.TYPES.ELEVATOR_CALL,
        floorNumber = myFloor.floorNumber,
        floorName = myFloor.floorName,
        floorY = myFloor.floorY,
        locY = displayLocY, locX = displayLocX, locZ = displayLocZ,
    })
    log("Call sent: floor " .. myFloor.floorNumber)
end

local function listenerTask()
    while true do
        local senderId, tbl = protocol.receive()
        if tbl and tbl.type == protocol.TYPES.ELEVATOR_STATUS then
            local changed = false
            if tbl.syncComputerId and tbl.syncComputerId ~= syncComputerId then
                syncComputerId = tbl.syncComputerId
                log("Discovered master: " .. syncComputerId)
            end
            if tbl.elevatorName then elevatorName = tbl.elevatorName end
            if tbl.floors then
                floors = tbl.floors
                local nf = calculateMyFloor()
                if nf and (not myFloor or myFloor.floorNumber ~= nf.floorNumber or myFloor.floorName ~= nf.floorName) then
                    myFloor = nf
                    log("My floor: " .. myFloor.floorNumber .. " (" .. (myFloor.floorName or "?") .. ")")
                    changed = true
                elseif nf and myFloor and (myFloor.floorName ~= nf.floorName) then
                    myFloor = nf; changed = true
                end
            end
            if tbl.state ~= elevatorState then elevatorState = tbl.state; changed = true end
            local oldCF = currentFloor and currentFloor.floorNumber
            currentFloor = tbl.currentFloor
            if (currentFloor and currentFloor.floorNumber) ~= oldCF then changed = true end
            local oldD = destination and destination.floorNumber
            destination = tbl.destination
            if (destination and destination.floorNumber) ~= oldD then changed = true end
            if changed then renderAll() end
        end
    end
end

local function touchTask()
    while true do
        local _, side = os.pullEvent("monitor_touch")
        if monitors[side] then sendCall() end
    end
end

log("Display started, " .. monitorCount .. " monitor(s)")
renderAll()
parallel.waitForAny(listenerTask, touchTask)
