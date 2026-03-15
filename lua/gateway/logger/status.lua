--------------------------------------------------------------------------
-- gateway/logger/status.lua
-- 日志模块状态查询 API：暴露模块运行状态和日志统计
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson  = require("cjson.safe")
local logger = require("gateway.logger")

--- 处理状态查询请求
--- GET /admin/logger/status
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local status = logger.get_status()

    status.server_info = {
        worker_pid   = ngx.worker.pid(),
        worker_id    = ngx.worker.id(),
        worker_count = ngx.worker.count(),
        ngx_time     = ngx.now(),
    }

    status.log_output = {
        access_log = "stdout (/dev/stdout)",
        error_log  = "stderr (/dev/stderr)",
        format     = "JSON (structured)",
    }

    local json = cjson.encode(status)
    if not json then
        ngx.status = 500
        ngx.say(cjson.encode({
            error   = "internal_error",
            message = "failed to serialize logger status",
        }))
        return
    end

    ngx.status = 200
    ngx.say(json)
end

--- 模块健康检查
function _M.health_check()
    ngx.header["Content-Type"] = "application/json"

    local status = logger.get_status()

    if status.status == "running" then
        ngx.status = 200
        ngx.say(cjson.encode({
            status     = "healthy",
            module     = "logger",
            log_counts = status.log_counts,
        }))
    else
        ngx.status = 503
        ngx.say(cjson.encode({
            status = "unhealthy",
            module = "logger",
            reason = "not initialized",
        }))
    end
end

return _M
