-- Elevator master controller.
-- - Accepts floor_register / floor_heartbeat from floor stations.
-- - In setup mode (no topology cache), shows setup_gui and waits for `calibrate`.
-- - In normal mode, broadcasts elevator_status every 2s, tracks the cart's
--   position via elevator_arrived / elevator_departed events from anchors.
-- - REPL commands: floors, topology, calibrate, recalibrate <Y>, rename <N> <name>,
--                  describe <N> <text>, setup, help, exit.

package.path = package.path .. ";/?.lua;/?/init.lua"

local protocol = require("shared.protocol")
local rednetSetup = require("shared.rednet_setup")
local logger = require("shared.log")
local calibrate = require("master.calibrate")
local setupGui = require("master.setup_gui")

local log = logger.make("MASTER")

-- ---------- Config ----------
local CONFIG_FILE = "elevator_config.json"
local TOPOLOGY_FILE = "elevator_topology.json"
local BROADCAST_INTERVAL = 2
local HEARTBEAT_STALE_MS = 60 * 1000

local function readJson(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r"); local raw = f.readAll(); f.close()
    return textutils.unserializeJSON(raw)
end

local function writeJson(path, data)
    local f = fs.open(path, "w")
    f.write(textutils.serializeJSON(data))
    f.close()
end

local config = readJson(CONFIG_FILE)
assert(config and config.role == "master", "Run install.lua first (role must be master).")
assert(config.elevatorName, "elevatorName missing from config.")

rednetSetup.open()

-- ---------- State ----------
local state = {
    -- registry[computerId] = { computerId, locY, locX, locZ, lastSeen, floorName, floorDescription }
    registry = {},
    -- topology[locY] = { floorNumber, locY, name, description, anchorComputerId, anchorSide }
    topology = nil,        -- nil until calibrated
    currentFloor = nil,    -- last confirmed floor (table copy of topology entry)
    destination = nil,     -- pending target (table copy)
    elevatorState = "unknown",
    setupMode = true,
    lastMessage = nil,
}

-- Try to load existing topology.
local loadedTopo = readJson(TOPOLOGY_FILE)
if loadedTopo and loadedTopo.elevatorName == config.elevatorName and loadedTopo.levels then
    state.topology = {}
    for _, lvl in ipairs(loadedTopo.levels) do
        state.topology[lvl.locY] = lvl
    end
    state.setupMode = false
    log("Loaded topology with " .. #loadedTopo.levels .. " level(s).")
else
    log("No topology cache - entering setup mode.")
end

-- ---------- Helpers ----------
local function getLevelByNumber(n)
    if not state.topology then return nil end
    for _, lvl in pairs(state.topology) do
        if lvl.floorNumber == n then return lvl end
    end
    return nil
end

local function topologyAsList()
    if not state.topology then return {} end
    local list = {}
    for _, lvl in pairs(state.topology) do table.insert(list, lvl) end
    table.sort(list, function(a, b) return a.locY < b.locY end)
    return list
end

local function persistTopology()
    if not state.topology then return end
    local list = topologyAsList()
    writeJson(TOPOLOGY_FILE, {
        elevatorName = config.elevatorName,
        calibratedAt = os.epoch("utc"),
        levels = list,
    })
end

local function buildFloorsArray()
    local arr = {}
    for _, lvl in ipairs(topologyAsList()) do
        table.insert(arr, {
            floorNumber = lvl.floorNumber,
            floorName = lvl.name,
            floorDescription = lvl.description,
            floorY = lvl.locY,
            anchorComputerId = lvl.anchorComputerId,
            anchorSide = lvl.anchorSide,
        })
    end
    return arr
end

local function broadcastStatus()
    -- Always broadcast (even during setup) so fresh floor stations can learn
    -- our elevatorName and register. During setup mode, floors[] is empty and
    -- currentFloor/destination are nil, which is fine.
    local payload = {
        type = protocol.TYPES.ELEVATOR_STATUS,
        elevatorName = config.elevatorName,
        syncComputerId = os.getComputerID(),
        timestamp = os.epoch("utc"),
        state = state.elevatorState,
        currentFloor = state.currentFloor and {
            floorNumber = state.currentFloor.floorNumber,
            floorName = state.currentFloor.name,
            floorY = state.currentFloor.locY,
        } or nil,
        destination = state.destination and {
            floorNumber = state.destination.floorNumber,
            floorName = state.destination.name,
            floorY = state.destination.locY,
        } or nil,
        floors = buildFloorsArray(),
    }
    protocol.broadcast(payload)
end

-- ---------- Message handlers ----------
local function handleFloorRegister(senderId, tbl)
    if tbl.elevatorName ~= config.elevatorName then return end
    local existing = state.registry[senderId]
    local isNew = not existing
    state.registry[senderId] = {
        computerId = senderId,
        locY = tbl.locY,
        locX = tbl.locX,
        locZ = tbl.locZ,
        lastSeen = os.epoch("utc"),
    }
    -- If we have topology, find the floor number for this Y so we can ack.
    local lvl = state.topology and state.topology[tbl.locY]
    protocol.send(senderId, {
        type = protocol.TYPES.FLOOR_REGISTERED,
        elevatorName = config.elevatorName,
        floorNumber = lvl and lvl.floorNumber or nil,
        locY = tbl.locY,
    })
    if isNew then
        log("Registered floor station " .. senderId .. " at Y=" .. tbl.locY)
        state.lastMessage = "Floor station " .. senderId .. " (Y=" .. tbl.locY .. ") joined."
    end
end

local function handleHeartbeat(senderId, tbl)
    if tbl.elevatorName ~= config.elevatorName then return end
    local entry = state.registry[senderId]
    if entry then
        entry.lastSeen = os.epoch("utc")
    else
        -- Treat unknown heartbeat as registration.
        handleFloorRegister(senderId, tbl)
        return
    end
    local lvl = state.topology and state.topology[entry.locY]
    protocol.send(senderId, {
        type = protocol.TYPES.HEARTBEAT_ACK,
        floorNumber = lvl and lvl.floorNumber or nil,
        locY = entry.locY,
    })
end

local function handleElevatorArrived(senderId, tbl)
    if tbl.elevatorName ~= config.elevatorName then return end
    if state.setupMode then return end  -- calibration handles its own arrivals

    local lvl = state.topology and state.topology[tbl.locY]
    if not lvl then
        log("Arrival at unknown Y=" .. tostring(tbl.locY) .. " - ignoring")
        return
    end
    state.currentFloor = lvl
    state.elevatorState = "at_floor"
    if state.destination and state.destination.floorNumber == lvl.floorNumber then
        state.destination = nil
    end
    log("Cart arrived: Floor " .. lvl.floorNumber .. " (" .. lvl.name .. ")")
    broadcastStatus()
end

local function handleElevatorDeparted(senderId, tbl)
    if tbl.elevatorName ~= config.elevatorName then return end
    if state.setupMode then return end

    local lvl = state.topology and state.topology[tbl.locY]
    if not lvl then return end
    if state.currentFloor and state.currentFloor.locY == lvl.locY then
        state.currentFloor = nil
    end
    if state.destination then
        if state.destination.locY > lvl.locY then
            state.elevatorState = "moving_up"
        elseif state.destination.locY < lvl.locY then
            state.elevatorState = "moving_down"
        else
            state.elevatorState = "unknown"
        end
    else
        state.elevatorState = "unknown"
    end
    log("Cart departed Floor " .. lvl.floorNumber .. " (state=" .. state.elevatorState .. ")")
    broadcastStatus()
end

local function handleElevatorCall(senderId, tbl)
    if state.setupMode then return end
    local lvl = getLevelByNumber(tbl.floorNumber)
    if not lvl then
        log("Call for unknown floor " .. tostring(tbl.floorNumber))
        return
    end
    state.destination = lvl
    if state.currentFloor then
        if lvl.locY > state.currentFloor.locY then
            state.elevatorState = "moving_up"
        elseif lvl.locY < state.currentFloor.locY then
            state.elevatorState = "moving_down"
        end
    end
    log("Call request: Floor " .. lvl.floorNumber .. " (" .. lvl.name .. ")")
    -- Tell the anchor for that floor to pulse redstone.
    protocol.broadcast({
        type = protocol.TYPES.ELEVATOR_CALL_REQUEST,
        elevatorName = config.elevatorName,
        floorNumber = lvl.floorNumber,
        targetY = lvl.locY,
        anchorComputerId = lvl.anchorComputerId,
        anchorSide = lvl.anchorSide,
    })
    broadcastStatus()
end

local function handleFloorRename(senderId, tbl)
    if tbl.elevatorName ~= config.elevatorName then return end
    if not state.topology then
        log("Rename ignored - no topology yet")
        return
    end
    local lvl = state.topology[tbl.locY]
    if not lvl then
        log("Rename for unknown Y=" .. tostring(tbl.locY))
        return
    end
    if tbl.newName and tbl.newName ~= "" then
        log("Renaming Floor " .. lvl.floorNumber .. ": '" .. lvl.name .. "' -> '" .. tbl.newName .. "'")
        lvl.name = tbl.newName
    end
    if tbl.newDescription then
        lvl.description = tbl.newDescription
    end
    persistTopology()
    broadcastStatus()
end

-- ---------- Tasks ----------
local function messageListenerTask()
    while true do
        local senderId, tbl = protocol.receive()
        if tbl then
            local t = tbl.type
            if     t == protocol.TYPES.FLOOR_REGISTER     then handleFloorRegister(senderId, tbl)
            elseif t == protocol.TYPES.FLOOR_HEARTBEAT    then handleHeartbeat(senderId, tbl)
            elseif t == protocol.TYPES.ELEVATOR_ARRIVED   then handleElevatorArrived(senderId, tbl)
            elseif t == protocol.TYPES.ELEVATOR_DEPARTED  then handleElevatorDeparted(senderId, tbl)
            elseif t == protocol.TYPES.ELEVATOR_CALL      then handleElevatorCall(senderId, tbl)
            elseif t == protocol.TYPES.FLOOR_RENAME       then handleFloorRename(senderId, tbl)
            end
            -- Don't re-render setup GUI here; that would clobber any in-progress
            -- user input on the prompt line. The REPL refreshes the GUI between
            -- commands (and the user can press Enter on an empty line to refresh).
        end
    end
end

local function broadcastTask()
    while true do
        broadcastStatus()
        sleep(BROADCAST_INTERVAL)
    end
end

local function cleanupTask()
    while true do
        sleep(15)
        local now = os.epoch("utc")
        for id, entry in pairs(state.registry) do
            if now - entry.lastSeen > HEARTBEAT_STALE_MS then
                log("Floor station " .. id .. " (Y=" .. entry.locY .. ") went stale")
                state.registry[id] = nil
            end
        end
    end
end

-- ---------- REPL commands ----------
local function cmdFloors()
    if next(state.registry) == nil then
        print("(no floor stations registered)")
        return
    end
    local list = {}
    for _, e in pairs(state.registry) do table.insert(list, e) end
    table.sort(list, function(a, b) return a.locY < b.locY end)
    for _, e in ipairs(list) do
        print(string.format("  comp=%d  Y=%d  X=%s  Z=%s",
            e.computerId, e.locY, tostring(e.locX), tostring(e.locZ)))
    end
end

local function cmdTopology()
    if not state.topology then
        print("(not calibrated)")
        return
    end
    for _, lvl in ipairs(topologyAsList()) do
        print(string.format("  Floor %d  Y=%d  '%s'  anchor=%s side=%s",
            lvl.floorNumber, lvl.locY, lvl.name,
            tostring(lvl.anchorComputerId), tostring(lvl.anchorSide)))
    end
end

local function cmdCalibrate()
    if next(state.registry) == nil then
        print("No floor stations registered yet. Wait and try again.")
        return
    end
    print("Starting calibration sweep...")
    -- Build registry-by-floor input for calibrate module
    local registry = {}
    for id, e in pairs(state.registry) do
        registry[id] = e
    end
    local levels = calibrate.run(registry)
    if not levels then
        print("Calibration failed.")
        return
    end
    state.topology = {}
    for _, lvl in ipairs(levels) do state.topology[lvl.locY] = lvl end
    persistTopology()
    state.setupMode = false
    state.elevatorState = "unknown"
    print("Calibration complete. " .. #levels .. " levels saved.")
    broadcastStatus()
end

local function cmdRecalibrate(args)
    local y = tonumber(args[1])
    if not y then print("Usage: recalibrate <Y>"); return end
    local registry = {}
    for id, e in pairs(state.registry) do registry[id] = e end
    local result = calibrate.runOne(y, registry)
    if not result then print("No arrival detected."); return end
    state.topology = state.topology or {}
    local existing = state.topology[y] or { floorNumber = nil, locY = y, name = "Floor ?" }
    existing.anchorComputerId = result.computerId
    existing.anchorSide = result.sideIn
    state.topology[y] = existing
    -- Recompute floor numbers in case Y was new.
    local list = topologyAsList()
    for i, lvl in ipairs(list) do lvl.floorNumber = i end
    persistTopology()
    print("Y=" .. y .. " anchor recorded: comp=" .. result.computerId .. " side=" .. result.sideIn)
    broadcastStatus()
end

local function cmdRename(args)
    local n = tonumber(args[1])
    if not n then print("Usage: rename <floorNumber> <name...>"); return end
    table.remove(args, 1)
    local newName = table.concat(args, " ")
    if newName == "" then print("Need a new name"); return end
    local lvl = getLevelByNumber(n)
    if not lvl then print("Unknown floor " .. n); return end
    lvl.name = newName
    persistTopology()
    broadcastStatus()
    print("Floor " .. n .. " renamed to '" .. newName .. "'")
end

local function cmdDescribe(args)
    local n = tonumber(args[1])
    if not n then print("Usage: describe <floorNumber> <text...>"); return end
    table.remove(args, 1)
    local desc = table.concat(args, " ")
    local lvl = getLevelByNumber(n)
    if not lvl then print("Unknown floor " .. n); return end
    lvl.description = desc
    persistTopology()
    broadcastStatus()
    print("Floor " .. n .. " description updated.")
end

local function cmdSetup()
    state.setupMode = true
    setupGui.render(state)
end

local function cmdReboot(args)
    local target = args[1]
    if not target or target == "" then
        -- Broadcast to all floors of this elevator
        protocol.broadcast({
            type = protocol.TYPES.REBOOT,
            elevatorName = config.elevatorName,
            ts = os.epoch("utc"),
        })
        print("Reboot broadcast sent to all floors of '" .. config.elevatorName .. "'.")
    elseif target == "self" then
        print("Rebooting master in 1s...")
        sleep(1)
        os.reboot()
    elseif target == "all" then
        protocol.broadcast({
            type = protocol.TYPES.REBOOT,
            elevatorName = config.elevatorName,
            ts = os.epoch("utc"),
        })
        print("Reboot broadcast sent. Rebooting master in 3s...")
        sleep(3)
        os.reboot()
    else
        local id = tonumber(target)
        if not id then
            print("Usage: reboot [<computerId> | self | all]")
            return
        end
        protocol.send(id, {
            type = protocol.TYPES.REBOOT,
            elevatorName = config.elevatorName,
            ts = os.epoch("utc"),
        })
        print("Reboot sent to computer " .. id .. ".")
    end
end

local function cmdHelp()
    print("Commands:")
    print("  floors                 - list registered floor stations")
    print("  topology               - print calibrated floor list")
    print("  calibrate              - run full sweep (uses currently registered floors)")
    print("  recalibrate <Y>        - recalibrate a single level by Y coordinate")
    print("  rename <N> <name>      - rename floor N")
    print("  describe <N> <text>    - set description for floor N")
    print("  reboot                 - reboot all floor stations (auto-pulls latest code)")
    print("  reboot all             - reboot all floors AND master")
    print("  reboot self            - reboot just the master")
    print("  reboot <id>            - reboot one specific computer by ID")
    print("  setup                  - re-show the setup GUI")
    print("  help                   - this list")
    print("  exit                   - quit")
end

local commands = {
    floors = cmdFloors,
    topology = cmdTopology,
    calibrate = cmdCalibrate,
    c = cmdCalibrate,
    recalibrate = cmdRecalibrate,
    rename = cmdRename,
    describe = cmdDescribe,
    reboot = cmdReboot,
    setup = cmdSetup,
    help = cmdHelp,
    ["?"] = cmdHelp,
}

local function replTask()
    -- Initial render
    if state.setupMode then
        setupGui.render(state)
    else
        print("Master REPL ready. Type 'help' for commands.")
    end
    while true do
        if state.setupMode then
            -- Refresh the GUI so the registration count updates between commands.
            setupGui.render(state)
            local _, h = term.getSize()
            term.setCursorPos(3, h - 1); term.write("> ")
        else
            term.write("> ")
        end
        local line = read()
        if state.setupMode then
            -- After read() returns, scroll to a normal terminal flow for command output.
            term.clear(); term.setCursorPos(1, 1)
        end
        if line and line ~= "" then
            local args = {}
            for w in line:gmatch("%S+") do table.insert(args, w) end
            local cmd = table.remove(args, 1):lower()
            if cmd == "exit" or cmd == "quit" then return end
            local fn = commands[cmd]
            if fn then
                local ok, err = pcall(fn, args)
                if not ok then print("Error: " .. tostring(err)) end
            else
                print("Unknown command. Type 'help'.")
            end
        end
    end
end

-- ---------- Main ----------
log("Master started for elevator '" .. config.elevatorName .. "'")
parallel.waitForAny(messageListenerTask, broadcastTask, cleanupTask, replTask)
