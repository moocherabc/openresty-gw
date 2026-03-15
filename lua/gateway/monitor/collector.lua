--------------------------------------------------------------------------
-- gateway/monitor/collector.lua
-- 数据采集器：在 log_by_lua 阶段调用，记录每个请求的指标数据
-- 使用 nginx-lua-prometheus 库的 Counter/Histogram API
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local monitor = require("gateway.monitor")

local ERROR_TYPES = {
    [502] = "bad_gateway",
    [503] = "service_unavailable",
    [504] = "gateway_timeout",
}

local function classify_error(status, upstream_status)
    if ERROR_TYPES[status] then
        return ERROR_TYPES[status]
    end

    local us = tonumber(upstream_status)
    if not us or us == 0 then
        return "connect_failed"
    elseif us >= 500 then
        return "upstream_5xx"
    else
        return "http_" .. tostring(status)
    end
end

--- 记录单次请求的所有指标（在 log_by_lua 调用）
function _M.record_request()
    local route = ngx.ctx.route
    if not route then
        return
    end

    local m = monitor.get_metrics()
    if not m or not m.requests then
        return
    end

    local provider = route.provider_name or "unknown"
    local method   = ngx.req.get_method() or "UNKNOWN"
    local status   = tostring(ngx.status or 0)

    local duration
    if route.start_time then
        duration = ngx.now() - route.start_time
    else
        duration = tonumber(ngx.var.request_time) or 0
    end

    m.requests:inc(1, { provider, method, status })

    m.latency:observe(duration, { provider })

    if ngx.status >= 500 then
        local us = ngx.var.upstream_status or ""
        local err_type = classify_error(ngx.status, us)
        m.errors:inc(1, { provider, err_type })
    end

    local bytes_recv = tonumber(ngx.var.request_length) or 0
    local bytes_sent = tonumber(ngx.var.body_bytes_sent) or 0
    m.request_bytes:inc(bytes_recv, { provider })
    m.response_bytes:inc(bytes_sent, { provider })

    _M.record_stability(m, provider)
end

--- 记录稳定性模块相关指标（限流/熔断拒绝、降级响应）
function _M.record_stability(m, provider)
    local action = ngx.ctx.stability_action
    if not action then
        return
    end

    if action.type == "rate_limited" then
        if m.rate_limiter_rejected then
            m.rate_limiter_rejected:inc(1, { provider, action.dimension or "unknown" })
        end
        if m.degradation_responses then
            m.degradation_responses:inc(1, { provider, "rate_limited" })
        end
    elseif action.type == "circuit_open" then
        if m.circuit_breaker_rejected then
            m.circuit_breaker_rejected:inc(1, { provider })
        end
        if m.degradation_responses then
            m.degradation_responses:inc(1, { provider, "circuit_open" })
        end
    end
end

return _M
