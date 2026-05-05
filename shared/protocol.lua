local M = {}

M.NAME = "elevator-floor-protocol"

M.SIDES = { "top", "bottom", "left", "right", "front", "back" }

M.TYPES = {
    FLOOR_REGISTER       = "floor_register",
    FLOOR_REGISTERED     = "floor_registered",
    FLOOR_HEARTBEAT      = "floor_heartbeat",
    HEARTBEAT_ACK        = "heartbeat_ack",
    CALIBRATE_CALL       = "calibrate_call",
    ELEVATOR_ARRIVED     = "elevator_arrived",
    ELEVATOR_DEPARTED    = "elevator_departed",
    ELEVATOR_CALL        = "elevator_call",
    ELEVATOR_CALL_REQUEST = "elevator_call_request",
    ELEVATOR_STATUS      = "elevator_status",
    FLOOR_RENAME         = "floor_rename",
}

function M.send(targetId, payload)
    rednet.send(targetId, textutils.serializeJSON(payload), M.NAME)
end

function M.broadcast(payload)
    rednet.broadcast(textutils.serializeJSON(payload), M.NAME)
end

function M.receive(timeout)
    local senderId, msg, protocol = rednet.receive(M.NAME, timeout)
    if not senderId then return nil end
    if protocol ~= M.NAME then return nil end
    local ok, tbl = pcall(textutils.unserializeJSON, msg)
    if not ok or type(tbl) ~= "table" or not tbl.type then return nil end
    return senderId, tbl
end

return M
