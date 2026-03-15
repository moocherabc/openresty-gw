--------------------------------------------------------------------------
-- gateway/stability/status.lua
-- 稳定性模块聚合状态查询 API：暴露所有子模块运行状态
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson     = require("cjson.safe")
local stability = require("gateway.stability")

--- 处理聚合状态查询请求
--- GET /admin/stability/status
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local status = stability.get_status()

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
            message = "failed to serialize stability status",
        }))
        return
    end

    ngx.status = 200
    ngx.say(json)
end

--- 模块健康检查
function _M.health_check()
    ngx.header["Content-Type"] = "application/json"

    local status = stability.get_status()
    local subs   = status.sub_modules or {}

    local issues = {}

    if subs.circuit_breaker then
        local cb = subs.circuit_breaker
        if cb.providers then
            for name, info in pairs(cb.providers) do
                if info.state == "open" then
                    issues[#issues + 1] = "circuit_breaker:" .. name .. "=OPEN"
                end
            end
        end
    end

    if subs.rate_limiter then
        local rl_stats = subs.rate_limiter.stats or {}
        if rl_stats.total_checked and rl_stats.total_checked > 0 then
            local rate = rl_stats.total_rejected / rl_stats.total_checked
            if rate > 0.5 then
                issues[#issues + 1] = "rate_limiter:rejection_rate=" .. math.floor(rate * 100) .. "%"
            end
        end
    end

    local overall = "healthy"
    if status.status ~= "running" then
        overall = "unhealthy"
    elseif #issues > 0 then
        overall = "degraded"
    end

    local degradation_stats = subs.degradation and subs.degradation.stats or {}

    if overall == "unhealthy" then
        ngx.status = 503
    else
        ngx.status = 200
    end

    ngx.say(cjson.encode({
        status  = overall,
        module  = "stability",
        issues  = #issues > 0 and issues or nil,
        summary = {
            circuit_breaker_checks  = subs.circuit_breaker and subs.circuit_breaker.stats
                                      and subs.circuit_breaker.stats.total_checks or 0,
            rate_limiter_checked    = subs.rate_limiter and subs.rate_limiter.stats
                                      and subs.rate_limiter.stats.total_checked or 0,
            total_degraded          = degradation_stats.total_responses or 0,
        },
    }))
end

return _M
