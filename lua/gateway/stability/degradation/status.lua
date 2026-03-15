--------------------------------------------------------------------------
-- gateway/stability/degradation/status.lua
-- 降级器子模块独立状态查询 API
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson       = require("cjson.safe")
local degradation = require("gateway.stability.degradation")

--- 处理状态查询请求
--- GET /admin/stability/degradation/status
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local args  = ngx.req.get_uri_args()
    local limit = tonumber(args.limit) or 20

    local result = degradation.get_status()
    result.recent_events = degradation.get_recent_events(limit)

    result.server_info = {
        worker_pid   = ngx.worker.pid(),
        worker_id    = ngx.worker.id(),
        worker_count = ngx.worker.count(),
        ngx_time     = ngx.now(),
    }

    local json = cjson.encode(result)
    if not json then
        ngx.status = 500
        ngx.say(cjson.encode({
            error   = "internal_error",
            message = "failed to serialize degradation status",
        }))
        return
    end

    ngx.status = 200
    ngx.say(json)
end

--- 健康检查
function _M.health_check()
    ngx.header["Content-Type"] = "application/json"

    local status = degradation.get_status()
    local stats  = status.stats or {}

    if status.status == "running" then
        ngx.status = 200
        ngx.say(cjson.encode({
            status                 = "healthy",
            module                 = "degradation",
            total_responses        = stats.total_responses or 0,
            rate_limited_count     = stats.rate_limited_count or 0,
            circuit_open_count     = stats.circuit_open_count or 0,
            service_degraded_count = stats.service_degraded_count or 0,
        }))
    else
        ngx.status = 503
        ngx.say(cjson.encode({
            status = "unhealthy",
            module = "degradation",
            reason = "not initialized",
        }))
    end
end

return _M
