--------------------------------------------------------------------------
-- metrics.lua
-- 对外统一入口：供 nginx.conf 的 /metrics 端点调用
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local monitor = require("gateway.monitor")

function _M.expose()
    monitor.expose()
end

return _M
