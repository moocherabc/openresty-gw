--------------------------------------------------------------------------
-- gateway/stability/circuit_breaker/status.lua
-- 熔断器子模块独立状态查询 API
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson           = require("cjson.safe")
local circuit_breaker = require("gateway.stability.circuit_breaker")

--- 处理状态查询请求
--- GET /admin/stability/circuit-breaker/status
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local args = ngx.req.get_uri_args()
    local provider = args.provider

    local result
    if provider and provider ~= "" then
        result = {
            module   = "circuit_breaker",
            provider = circuit_breaker.get_info(provider),
            stats    = circuit_breaker.get_stats(),
        }
    else
        result = circuit_breaker.get_status()
    end

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
            message = "failed to serialize circuit_breaker status",
        }))
        return
    end

    ngx.status = 200
    ngx.say(json)
end

--- 健康检查
function _M.health_check()
    ngx.header["Content-Type"] = "application/json"

    local status = circuit_breaker.get_status()

    local open_count = 0
    if status.providers then
        for _, info in pairs(status.providers) do
            if info.state == "open" then
                open_count = open_count + 1
            end
        end
    end

    if status.status == "running" then
        ngx.status = 200
        ngx.say(cjson.encode({
            status              = open_count > 0 and "degraded" or "healthy",
            module              = "circuit_breaker",
            circuit_breakers_open = open_count,
            total_checks        = status.stats and status.stats.total_checks or 0,
            total_rejected      = status.stats and status.stats.total_rejected or 0,
        }))
    else
        ngx.status = 503
        ngx.say(cjson.encode({
            status = "unhealthy",
            module = "circuit_breaker",
            reason = "not initialized",
        }))
    end
end

return _M
