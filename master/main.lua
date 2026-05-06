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

-- Floor spacing: minimum vertical distance between distinct levels. Computers
-- whose Y values are within (levelSpacing - 1) blocks of each other are
-- bucketed onto the same level — this is what lets a display computer two
-- blocks above the floor's anchor still count as part of that floor.
-- Default 1 = strict (every Y is its own level, original behavior).
if config.levelSpacing == nil then config.levelSpacing = 1 end

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serializeJSON(config))
    f.close()
end

rednetSetup.open()

-- ---------- State ----------
local state = {
    -- registry[computerId] = { computerId, locY, locX, locZ, lastSeen, floorName, floorDescription }
    registry = {},
    -- topology[locY] = { floorNumber, locY, name, description, anchorComputerId, anchorSide }
    topology = nil,        -- nil until calibrated
    -- ignoredY[locY] = true means: don't accept registrations at this Y, skip it during calibration
    ignoredY = {},
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
if loadedTopo and loadedTopo.ignoredY then
    for _, y in ipairs(loadedTopo.ignoredY) do
        state.ignoredY[y] = true
    end
    log("Loaded " .. #loadedTopo.ignoredY .. " ignored Y level(s).")
end

-- ---------- Bucketing ----------
-- Cluster registry entries' locY values into canonical "level" Ys based on
-- config.levelSpacing. Sets entry.canonicalY on every registry entry.
local function rebucket()
    local spacing = config.levelSpacing or 1
    local entries = {}
    for _, e in pairs(state.registry) do table.insert(entries, e) end
    table.sort(entries, function(a, b) return a.locY < b.locY end)

    local currentCanonical, lastY
    for _, e in ipairs(entries) do
        if not currentCanonical or e.locY - lastY >= spacing then
            currentCanonical = e.locY
        end
        e.canonicalY = currentCanonical
        lastY = e.locY
    end
end

-- Lookup canonical Y for a given (senderId, fallbackLocY) pair.
local function canonicalYForSender(senderId, fallbackLocY)
    local e = state.registry[senderId]
    if e and e.canonicalY then return e.canonicalY end
    return fallbackLocY
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
    -- Persist topology AND ignoredY together so settings survive reboots.
    -- We persist even when topology is empty so that ignoredY changes stick
    -- even before calibration runs.
    local list = state.topology and topologyAsList() or {}
    local ignoredList = {}
    for y, _ in pairs(state.ignoredY or {}) do table.insert(ignoredList, y) end
    table.sort(ignoredList)
    writeJson(TOPOLOGY_FILE, {
        elevatorName = config.elevatorName,
        calibratedAt = os.epoch("utc"),
        levels = list,
        ignoredY = ignoredList,
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
    if state.ignoredY[tbl.locY] then
        -- This Y has been forgotten — don't pollute the registry. Floor will
        -- keep retrying but we'll keep dropping it.
        return
    end
    local existing = state.registry[senderId]
    local isNew = not existing
    state.registry[senderId] = {
        computerId = senderId,
        locY = tbl.locY,
        locX = tbl.locX,
        locZ = tbl.locZ,
        lastSeen = os.epoch("utc"),
    }
    rebucket()
    local canonical = state.registry[senderId].canonicalY
    -- If we have topology, find the floor number for this canonical Y so we can ack.
    local lvl = state.topology and state.topology[canonical]
    protocol.send(senderId, {
        type = protocol.TYPES.FLOOR_REGISTERED,
        elevatorName = config.elevatorName,
        floorNumber = lvl and lvl.floorNumber or nil,
        locY = tbl.locY,
        canonicalY = canonical,
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
    local canonical = entry.canonicalY or entry.locY
    local lvl = state.topology and state.topology[canonical]
    protocol.send(senderId, {
        type = protocol.TYPES.HEARTBEAT_ACK,
        floorNumber = lvl and lvl.floorNumber or nil,
        locY = entry.locY,
        canonicalY = canonical,
    })
end

local function handleElevatorArrived(senderId, tbl)
    if tbl.elevatorName ~= config.elevatorName then return end
    if state.setupMode then return end  -- calibration handles its own arrivals

    local canonicalY = canonicalYForSender(senderId, tbl.locY)
    local lvl = state.topology and state.topology[canonicalY]
    if not lvl then
        log("Arrival at unknown Y=" .. tostring(canonicalY) .. " - ignoring")
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

    local canonicalY = canonicalYForSender(senderId, tbl.locY)
    local lvl = state.topology and state.topology[canonicalY]
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

local function handleSetAnchorRequest(senderId, tbl)
    if tbl.elevatorName ~= config.elevatorName then return end
    if not state.topology then
        log("Anchor claim from " .. senderId .. " ignored - no topology yet")
        return
    end
    local canonicalY = canonicalYForSender(senderId, tbl.locY)
    local lvl = state.topology[canonicalY]
    if not lvl then
        log("Anchor claim from " .. senderId .. " for unknown level Y=" .. tostring(canonicalY))
        return
    end
    log("Anchor claim: floor " .. lvl.floorNumber .. " (Y=" .. lvl.locY ..
        ") -> comp=" .. tbl.computerId .. " side=" .. tbl.side ..
        " (was comp=" .. tostring(lvl.anchorComputerId) ..
        " side=" .. tostring(lvl.anchorSide) .. ")")
    lvl.anchorComputerId = tbl.computerId
    lvl.anchorSide = tbl.side
    persistTopology()
    broadcastStatus()
end

local function handleFloorRename(senderId, tbl)
    if tbl.elevatorName ~= config.elevatorName then return end
    if not state.topology then
        log("Rename ignored - no topology yet")
        return
    end
    local canonicalY = canonicalYForSender(senderId, tbl.locY)
    local lvl = state.topology[canonicalY]
    if not lvl then
        log("Rename for unknown level Y=" .. tostring(canonicalY))
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
            elseif t == "set_anchor_request"              then handleSetAnchorRequest(senderId, tbl)
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
    rebucket()
    -- Group by canonical Y (level bucket).
    local byLevel = {}
    for _, e in pairs(state.registry) do
        local cy = e.canonicalY or e.locY
        if not byLevel[cy] then byLevel[cy] = {} end
        table.insert(byLevel[cy], e)
    end
    local cys = {}
    for cy, _ in pairs(byLevel) do table.insert(cys, cy) end
    table.sort(cys)
    print(string.format("%d level(s) (spacing=%d):", #cys, config.levelSpacing or 1))
    for _, cy in ipairs(cys) do
        local entries = byLevel[cy]
        local marker = ""
        if state.ignoredY and state.ignoredY[cy] then marker = "  [IGNORED]" end
        print(string.format("  Level Y=%d  (%d computer%s)%s",
            cy, #entries, #entries == 1 and "" or "s", marker))
        for _, e in ipairs(entries) do
            local note = (e.locY ~= cy) and ("  (locY=" .. e.locY .. ")") or ""
            print(string.format("    comp=%d  X=%s  Z=%s%s",
                e.computerId, tostring(e.locX), tostring(e.locZ), note))
        end
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
    -- Build registry input for calibrate module, skipping ignored Y values.
    local registry = {}
    local skipped = 0
    for id, e in pairs(state.registry) do
        if state.ignoredY[e.locY] then
            skipped = skipped + 1
        else
            registry[id] = e
        end
    end
    if skipped > 0 then
        print("(skipping " .. skipped .. " floor computer(s) at ignored Y values)")
    end
    if next(registry) == nil then
        print("All registered floors are at ignored Y values. Use `unforget <Y>` first.")
        return
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

local function cmdFloorSpacing(args)
    if not args[1] then
        print("Current levelSpacing: " .. (config.levelSpacing or 1))
        print("Usage: floorspacing <N>")
        print("  N=1  : strict (every Y is its own level)")
        print("  N=3  : Y values within 2 blocks of each other are bucketed together")
        print("  N=5  : Y values within 4 blocks of each other are bucketed together")
        return
    end
    local n = tonumber(args[1])
    if not n or n < 1 then print("N must be >= 1"); return end
    config.levelSpacing = n
    saveConfig()
    rebucket()
    print("levelSpacing = " .. n .. ". Run `floors` to see updated grouping.")
    print("Run `calibrate` to rebuild topology with the new spacing.")
end

local function cmdForget(args)
    local y = tonumber(args[1])
    if not y then print("Usage: forget <Y>  (drop all floor computers at this exact locY)"); return end
    state.ignoredY[y] = true
    -- Drop registered computers at this exact locY (not canonical — exact)
    local removed = 0
    for id, e in pairs(state.registry) do
        if e.locY == y then state.registry[id] = nil; removed = removed + 1 end
    end
    rebucket()
    -- After rebucket, any topology entry whose canonical Y no longer has any
    -- registered members should be dropped.
    if state.topology then
        local stillRepresented = {}
        for _, e in pairs(state.registry) do stillRepresented[e.canonicalY] = true end
        for cy, _ in pairs(state.topology) do
            if not stillRepresented[cy] then state.topology[cy] = nil end
        end
        local list = topologyAsList()
        for i, lvl in ipairs(list) do lvl.floorNumber = i end
    end
    persistTopology()
    broadcastStatus()
    print(string.format("locY=%d ignored. Dropped %d registration(s).", y, removed))
end

local function cmdUnforget(args)
    local y = tonumber(args[1])
    if not y then print("Usage: unforget <Y>"); return end
    if not state.ignoredY[y] then
        print("Y=" .. y .. " was not ignored.")
        return
    end
    state.ignoredY[y] = nil
    persistTopology()
    print("Y=" .. y .. " no longer ignored. Floors there can re-register on their next heartbeat.")
end

local function cmdSetAnchor(args)
    local floorNum = tonumber(args[1])
    local computerId = tonumber(args[2])
    local side = args[3]
    if not floorNum or not computerId or not side then
        print("Usage: setanchor <floorNumber> <computerId> <side>")
        print("       e.g. setanchor 2 31 back")
        return
    end
    local valid = false
    for _, s in ipairs(protocol.SIDES) do if s == side then valid = true end end
    if not valid then
        print("Side must be one of: " .. table.concat(protocol.SIDES, ", "))
        return
    end
    local lvl = getLevelByNumber(floorNum)
    if not lvl then print("Unknown floor " .. floorNum); return end
    local oldId, oldSide = lvl.anchorComputerId, lvl.anchorSide
    lvl.anchorComputerId = computerId
    lvl.anchorSide = side
    persistTopology()
    broadcastStatus()
    print(string.format("Floor %d anchor: comp=%s side=%s -> comp=%d side=%s",
        floorNum, tostring(oldId), tostring(oldSide), computerId, side))
    print("(Topology broadcast — affected floor stations will pick up the change.)")
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
    print("  setanchor <N> <id> <side> - manually set the anchor for floor N")
    print("  floorspacing <N>       - bucket Y values within N-1 blocks as one level")
    print("  forget <Y>             - ignore all floor computers at this Y")
    print("  unforget <Y>           - stop ignoring a Y (allow re-registration)")
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
    setanchor = cmdSetAnchor,
    floorspacing = cmdFloorSpacing,
    forget = cmdForget,
    unforget = cmdUnforget,
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
