local M = {}

function M.make(prefix)
    return function(msg)
        print("[" .. prefix .. "] " .. tostring(msg))
    end
end

return M
