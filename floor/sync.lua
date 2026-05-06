-- Floor station: handles master registration, heartbeats, redstone arrival
-- detection, and calibration responses. Persists learned anchor side to
-- floor_state.json so it doesn't relearn every reboot.

package.path = package.path .. ";/?.lua;/?/init.lua"

local protocol = require("shared.protocol")
local rednetSetup = require("shared.rednet_setup")
local logger = require("shared.log")

local log = logger.make("FLOOR")

local STATE_FILE = "floor_state.json"
local HEARTBEAT_INTERVAL = 10
local REGISTER_RETRY = 2

-- Load GPS — required to know our Y.
local locX, locY, locZ = gps.locate(2, false)
assert(locY, "GPS required. Place GPS hosts in range.")
log("Booting at Y=" .. locY .. " X=" .. tostring(locX) .. " Z=" .. tostring(locZ))

rednetSetup.open()

local function readJson(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r"); local raw = f.readAll(); f.close()
    return textutils.unserializeJSON(raw) or {}
end

local function writeJson(path, data)
    local f = fs.open(path, "w")
    f.write(textutils.serializeJSON(data))
    f.close()
end

local persisted = readJson(STATE_FILE) or {}
local config = readJson("elevator_config.json") or {}

-- elevator_config.json's elevatorName is authoritative if set (locked at
-- install). Otherwise we fall back to whatever we previously learned from
-- broadcasts and persisted to floor_state.json. If neither, auto-discover.
local lockedName = config.elevatorName

local state = {
    elevatorName = lockedName or persisted.elevatorName,  -- discovered from broadcasts if neither set
    syncComputerId = nil,
    floorNumber = nil,
    isAnchor = persisted.isAnchor or false,
    anchorSide = persisted.anchorSide,
    -- Per-side last redstone input states for edge detection
    lastInputs = {},
    isRegistered = false,
    -- Queue of pending output pulses: list of side names
    pulseQueue = {},
    -- Calibration mode: when set, fire all sides and wait for input
    calibrating = false,
}

for _, side in ipairs(protocol.SIDES) do state.lastInputs[side] = false end

local function persist()
    writeJson(STATE_FILE, {
        elevatorName = state.elevatorName,
        locY = locY,
        isAnchor = state.isAnchor,
        anchorSide = state.anchorSide,
    })
end

-- ---------- Senders ----------
local function sendRegister()
    if not state.elevatorName then return end  -- can't register without elevator name yet
    protocol.broadcast({
        type = protocol.TYPES.FLOOR_REGISTER,
        elevatorName = state.elevatorName,
        locY = locY, locX = locX, locZ = locZ,
        ts = os.epoch("utc"),
    })
end

local function sendHeartbeat()
    if not state.syncComputerId or not state.elevatorName then return end
    protocol.send(state.syncComputerId, {
        type = protocol.TYPES.FLOOR_HEARTBEAT,
        elevatorName = state.elevatorName,
        locY = locY, locX = locX, locZ = locZ,
        ts = os.epoch("utc"),
    })
end

local function sendArrived(sideReceived)
    if not state.syncComputerId then
        -- During calibration we may not have a syncComputerId yet — broadcast.
        protocol.broadcast({
            type = protocol.TYPES.ELEVATOR_ARRIVED,
            elevatorName = state.elevatorName,
            locY = locY, locX = locX, locZ = locZ,
            sideReceived = sideReceived,
            ts = os.epoch("utc"),
        })
        return
    end
    protocol.send(state.syncComputerId, {
        type = protocol.TYPES.ELEVATOR_ARRIVED,
        elevatorName = state.elevatorName,
        locY = locY, locX = locX, locZ = locZ,
        sideReceived = sideReceived,
        ts = os.epoch("utc"),
    })
end

local function sendDeparted()
    if not state.syncComputerId then return end
    protocol.send(state.syncComputerId, {
        type = protocol.TYPES.ELEVATOR_DEPARTED,
        elevatorName = state.elevatorName,
        locY = locY, locX = locX, locZ = locZ,
        ts = os.epoch("utc"),
    })
end

-- ---------- Handlers ----------
local function handleRegistered(senderId, tbl)
    if tbl.locY ~= locY then return end
    state.syncComputerId = senderId
    state.isRegistered = true
    if tbl.elevatorName and not state.elevatorName then
        state.elevatorName = tbl.elevatorName
        persist()
    end
    if tbl.floorNumber and tbl.floorNumber ~= state.floorNumber then
        state.floorNumber = tbl.floorNumber
        log("Assigned floor number " .. tbl.floorNumber)
    end
end

local function handleHeartbeatAck(senderId, tbl)
    if senderId ~= state.syncComputerId then return end
    if tbl.floorNumber and tbl.floorNumber ~= state.floorNumber then
        state.floorNumber = tbl.floorNumber
    end
end

local function handleStatus(senderId, tbl)
    -- Auto-discover elevator name only if we don't have one yet AND it
    -- wasn't locked at install. Once locked, foreign broadcasts are ignored.
    if tbl.elevatorName and not state.elevatorName and not lockedName then
        state.elevatorName = tbl.elevatorName
        persist()
        log("Auto-discovered elevator: " .. tbl.elevatorName)
    end
    if tbl.elevatorName and tbl.elevatorName ~= state.elevatorName then return end
    if tbl.syncComputerId then
        if state.syncComputerId ~= tbl.syncComputerId then
            state.syncComputerId = tbl.syncComputerId
            log("Discovered master: " .. tbl.syncComputerId)
        end
    end
    -- If broadcast tells us we're an anchor (post-calibration), persist.
    if tbl.floors then
        for _, f in ipairs(tbl.floors) do
            if f.floorY == locY then
                state.floorNumber = f.floorNumber
                if f.anchorComputerId == os.getComputerID() then
                    if not state.isAnchor or state.anchorSide ~= f.anchorSide then
                        state.isAnchor = true
                        state.anchorSide = f.anchorSide
                        persist()
                        log("I am the anchor for Floor " .. f.floorNumber .. " (side=" .. tostring(f.anchorSide) .. ")")
                    end
                elseif state.isAnchor then
                    -- Topology says we're not the anchor anymore.
                    state.isAnchor = false
                    state.anchorSide = nil
                    persist()
                end
                break
            end
        end
    end
end

local FIRE_DURATION = 0.5   -- seconds to assert output on all sides (short pulse)
local SETTLE_DURATION = 1.5 -- seconds to wait for redstone feedback to dissipate

local function snapshotInputs()
    local snap, active = {}, {}
    for _, side in ipairs(protocol.SIDES) do
        local ok, val = pcall(redstone.getInput, side)
        snap[side] = ok and val or false
        if ok and val then table.insert(active, side) end
    end
    return snap, active
end

local function formatSnapshot(snap)
    local parts = {}
    for _, side in ipairs(protocol.SIDES) do
        table.insert(parts, side .. "=" .. tostring(snap[side]))
    end
    return table.concat(parts, " ")
end

local function handleCalibrateCall(senderId, tbl)
    if tbl.targetY ~= locY then return end
    state.calibrating = true
    -- Suppress edge detection while we're firing AND while redstone settles.
    state.suppressInputUntil = os.clock() + FIRE_DURATION + SETTLE_DURATION

    local before, beforeActive = snapshotInputs()
    log("CALIBRATE: pre-fire inputs: " .. formatSnapshot(before))

    for _, side in ipairs(protocol.SIDES) do
        pcall(redstone.setOutput, side, true)
    end
    sleep(FIRE_DURATION)
    for _, side in ipairs(protocol.SIDES) do
        pcall(redstone.setOutput, side, false)
    end
    sleep(SETTLE_DURATION)

    local after, afterActive = snapshotInputs()
    log("CALIBRATE: post-settle inputs: " .. formatSnapshot(after))

    -- Sync lastInputs to post-settle values so subsequent rising edges are real.
    for _, side in ipairs(protocol.SIDES) do
        state.lastInputs[side] = after[side]
    end
    state.suppressInputUntil = nil

    -- Prefer a side that ROSE between before and after (means our call action
    -- caused the wire to go HIGH and stay — likely the elevator's response).
    local risenSide
    for _, side in ipairs(protocol.SIDES) do
        if after[side] and not before[side] then
            risenSide = side
            break
        end
    end
    -- Fall back to any active side post-settle (cart was already here).
    local activeSide = risenSide or afterActive[1]

    if activeSide then
        log("CALIBRATE: claiming anchor on side " .. activeSide ..
            (risenSide and " (rose during fire)" or " (already active)"))
        state.calibrating = false
        sendArrived(activeSide)
    else
        log("CALIBRATE: call sent, no immediate input. Watching for rising edge...")
        -- state.calibrating stays true; redstoneMonitorTask handles real arrival.
    end
end

local function handleReboot(senderId, tbl)
    if tbl.elevatorName and state.elevatorName and tbl.elevatorName ~= state.elevatorName then return end
    log("Reboot command received from master " .. senderId .. ". Rebooting in 1s...")
    sleep(1)
    os.reboot()
end

local function handleCallRequest(senderId, tbl)
    if tbl.elevatorName and tbl.elevatorName ~= state.elevatorName then return end
    -- Only the anchor for this floor pulses, on its known side.
    if tbl.anchorComputerId ~= os.getComputerID() then return end
    if not tbl.anchorSide then return end
    log("Pulsing " .. tbl.anchorSide .. " for call to floor " .. tostring(tbl.floorNumber))
    table.insert(state.pulseQueue, tbl.anchorSide)
end

-- ---------- Tasks ----------
local function messageListenerTask()
    while true do
        local senderId, tbl = protocol.receive()
        if tbl then
            local t = tbl.type
            if     t == protocol.TYPES.FLOOR_REGISTERED      then handleRegistered(senderId, tbl)
            elseif t == protocol.TYPES.HEARTBEAT_ACK         then handleHeartbeatAck(senderId, tbl)
            elseif t == protocol.TYPES.ELEVATOR_STATUS       then handleStatus(senderId, tbl)
            elseif t == protocol.TYPES.CALIBRATE_CALL        then handleCalibrateCall(senderId, tbl)
            elseif t == protocol.TYPES.ELEVATOR_CALL_REQUEST then handleCallRequest(senderId, tbl)
            elseif t == protocol.TYPES.REBOOT                then handleReboot(senderId, tbl)
            end
        end
    end
end

local function redstoneMonitorTask()
    while true do
        local suppressed = state.suppressInputUntil and os.clock() < state.suppressInputUntil
        for _, side in ipairs(protocol.SIDES) do
            local ok, val = pcall(redstone.getInput, side)
            if ok then
                if suppressed then
                    -- Don't emit events. Don't update lastInputs either —
                    -- handleCalibrateCall will reset them after the settle
                    -- period, ensuring a clean baseline for edge detection.
                else
                    if val and not state.lastInputs[side] then
                        -- Rising edge
                        if state.calibrating then
                            log("Calibration arrival via side: " .. side)
                            state.calibrating = false
                            sendArrived(side)
                        elseif state.isAnchor and side == state.anchorSide then
                            sendArrived(side)
                        end
                    elseif (not val) and state.lastInputs[side] then
                        -- Falling edge
                        if state.isAnchor and side == state.anchorSide then
                            sendDeparted()
                        end
                    end
                    state.lastInputs[side] = val
                end
            end
        end
        sleep(0.05)
    end
end

local function registrationTask()
    while true do
        if not state.isRegistered then
            sendRegister()
            sleep(REGISTER_RETRY)
        else
            sendHeartbeat()
            sleep(HEARTBEAT_INTERVAL)
        end
    end
end

local function pulseTask()
    while true do
        if #state.pulseQueue > 0 then
            local side = table.remove(state.pulseQueue, 1)
            pcall(redstone.setOutput, side, true)
            sleep(1)
            pcall(redstone.setOutput, side, false)
        else
            sleep(0.1)
        end
    end
end

-- ---------- REPL (for rename) ----------
local function replTask()
    print("Floor station ready. Y=" .. locY .. ". Type 'help' for commands.")
    while true do
        write("> ")
        local line = read()
        if line and line ~= "" then
            local args = {}
            for w in line:gmatch("%S+") do table.insert(args, w) end
            local cmd = table.remove(args, 1):lower()
            if cmd == "help" or cmd == "?" then
                print("Commands:")
                print("  rename <name...>      - rename this floor")
                print("  describe <text...>    - set this floor's description")
                print("  status                - show current state")
                print("  redstone              - show current redstone input on all sides")
                print("  claim <side>          - claim this computer as the anchor for this floor")
            elseif cmd == "rename" then
                local newName = table.concat(args, " ")
                if newName == "" then print("Usage: rename <name>") else
                    if not state.syncComputerId then
                        print("Not connected to master yet.")
                    else
                        protocol.send(state.syncComputerId, {
                            type = protocol.TYPES.FLOOR_RENAME,
                            elevatorName = state.elevatorName,
                            locY = locY,
                            newName = newName,
                        })
                        print("Sent rename request: '" .. newName .. "'")
                    end
                end
            elseif cmd == "describe" then
                local desc = table.concat(args, " ")
                if not state.syncComputerId then
                    print("Not connected to master yet.")
                else
                    protocol.send(state.syncComputerId, {
                        type = protocol.TYPES.FLOOR_RENAME,
                        elevatorName = state.elevatorName,
                        locY = locY,
                        newDescription = desc,
                    })
                    print("Sent description update.")
                end
            elseif cmd == "redstone" then
                print("Redstone inputs (computer ID " .. os.getComputerID() .. "):")
                for _, side in ipairs(protocol.SIDES) do
                    local ok, val = pcall(redstone.getInput, side)
                    print("  " .. side .. ": " .. (ok and tostring(val) or "n/a"))
                end
            elseif cmd == "claim" then
                local side = args[1]
                if not side then print("Usage: claim <side>");
                else
                    local valid = false
                    for _, s in ipairs(protocol.SIDES) do if s == side then valid = true end end
                    if not valid then
                        print("Side must be one of: " .. table.concat(protocol.SIDES, ", "))
                    elseif not state.syncComputerId then
                        print("Not connected to master yet.")
                    elseif not state.floorNumber then
                        print("Floor number not assigned yet (master must finish at least initial calibration).")
                    else
                        protocol.send(state.syncComputerId, {
                            type = "set_anchor_request",
                            elevatorName = state.elevatorName,
                            floorNumber = state.floorNumber,
                            locY = locY,
                            computerId = os.getComputerID(),
                            side = side,
                        })
                        print("Claim sent: I am the anchor for floor " .. state.floorNumber ..
                              " on side " .. side)
                    end
                end
            elseif cmd == "status" then
                print("  elevatorName: " .. tostring(state.elevatorName))
                print("  syncComputerId: " .. tostring(state.syncComputerId))
                print("  floorNumber: " .. tostring(state.floorNumber))
                print("  isAnchor: " .. tostring(state.isAnchor))
                print("  anchorSide: " .. tostring(state.anchorSide))
                print("  registered: " .. tostring(state.isRegistered))
            else
                print("Unknown. Type 'help'. (Use Ctrl+T to terminate.)")
            end
        end
    end
end

-- ---------- Main ----------
if state.elevatorName then
    local source = lockedName and "locked" or "remembered"
    log("Elevator: " .. state.elevatorName .. " (" .. source .. ")")
else
    log("Elevator: auto-discover (waiting for broadcast)")
end
log("Floor sync started. Anchor=" .. tostring(state.isAnchor) ..
    " side=" .. tostring(state.anchorSide))

parallel.waitForAny(
    messageListenerTask,
    redstoneMonitorTask,
    registrationTask,
    pulseTask,
    replTask
)
