local M = {}

function M.open()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            if not rednet.isOpen(name) then
                rednet.open(name)
            end
            return name
        end
    end
    error("No modem found. Attach a wireless or wired modem.", 0)
end

return M
