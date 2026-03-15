--------------------------------------------------------------------------
-- gateway/stability/rate_limiter/status.lua
-- 限流器子模块独立状态查询 API
--------------------------------------------------------------------------
local _M = { _VERSION = "2.0.0" }

local cjson        = require("cjson.safe")
local rate_limiter = require("gateway.stability.rate_limiter")

--- 处理状态查询请求
--- GET /admin/stability/rate-limiter/status
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local result = rate_limiter.get_status()

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
            message = "failed to serialize rate_limiter status",
        }))
        return
    end

    ngx.status = 200
    ngx.say(json)
end

--- 健康检查
--- GET /admin/stability/rate-limiter/health
function _M.health_check()
    ngx.header["Content-Type"] = "application/json"

    local status = rate_limiter.get_status()
    local sts    = status.stats or {}
    local dbg    = status.debug_mode or {}

    local rejection_rate = 0
    if sts.total_checked and sts.total_checked > 0 then
        rejection_rate = math.floor(sts.total_rejected / sts.total_checked * 10000) / 100
    end

    local issues = {}

    if dbg.force_reject then
        issues[#issues + 1] = "debug_force_reject_enabled"
    end
    if rejection_rate > 50 then
        issues[#issues + 1] = "high_rejection_rate:" .. rejection_rate .. "%"
    end

    local overall
    if status.status ~= "running" then
        overall = "unhealthy"
    elseif #issues > 0 then
        overall = "degraded"
    else
        overall = "healthy"
    end

    local http_status = (overall == "unhealthy") and 503 or 200
    ngx.status = http_status
    ngx.say(cjson.encode({
        status         = overall,
        module         = "rate_limiter",
        algorithm      = status.algorithm or "leaky_bucket",
        total_checked  = sts.total_checked or 0,
        total_allowed  = sts.total_allowed or 0,
        total_rejected = sts.total_rejected or 0,
        rejection_rate = rejection_rate .. "%",
        issues         = #issues > 0 and issues or nil,
    }))
end

return _M
