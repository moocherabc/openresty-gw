--------------------------------------------------------------------------
-- gateway/monitor/status.lua
-- 监控模块状态查询 API：暴露模块运行状态，支持独立测试
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson   = require("cjson.safe")
local monitor = require("gateway.monitor")

--- 处理状态查询请求
--- GET /admin/monitor/status
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local status = monitor.get_status()

    status.server_info = {
        worker_pid   = ngx.worker.pid(),
        worker_id    = ngx.worker.id(),
        worker_count = ngx.worker.count(),
        ngx_time     = ngx.now(),
    }

    local json = cjson.encode(status)
    if not json then
        ngx.status = 500
        ngx.say(cjson.encode({
            error   = "internal_error",
            message = "failed to serialize monitor status",
        }))
        return
    end

    ngx.status = 200
    ngx.say(json)
end

--- 模块健康检查
function _M.health_check()
    ngx.header["Content-Type"] = "application/json"

    local status = monitor.get_status()

    if status.status == "running" then
        ngx.status = 200
        ngx.say(cjson.encode({
            status             = "healthy",
            module             = "monitor",
            dict_usage_percent = status.shared_dict.usage_percent or 0,
        }))
    else
        ngx.status = 503
        ngx.say(cjson.encode({
            status = "unhealthy",
            module = "monitor",
            reason = "not initialized",
        }))
    end
end

return _M
