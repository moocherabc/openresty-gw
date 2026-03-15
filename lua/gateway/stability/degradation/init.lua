--------------------------------------------------------------------------
-- gateway/stability/degradation/init.lua
-- 优雅降级：在限流、熔断、上游不可用时返回友好的 JSON 错误响应
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson = require("cjson.safe")

local stats = {
    total_responses        = 0,
    rate_limited_count     = 0,
    circuit_open_count     = 0,
    service_degraded_count = 0,
}

local recent_events = {}
local MAX_RECENT_EVENTS = 50

local initialized = false
local init_time   = nil

local function add_event(event_type, provider, detail)
    local event = {
        type      = event_type,
        provider  = provider,
        detail    = detail,
        timestamp = ngx.now(),
    }

    table.insert(recent_events, 1, event)
    if #recent_events > MAX_RECENT_EVENTS then
        table.remove(recent_events)
    end
end

local function respond(status_code, body, retry_after)
    ngx.status = status_code
    ngx.header["Content-Type"] = "application/json"

    if retry_after and retry_after > 0 then
        ngx.header["Retry-After"] = tostring(math.ceil(retry_after))
    end

    ngx.say(cjson.encode(body))
    return ngx.exit(status_code)
end

--- 模块初始化
function _M.init()
    initialized = true
    init_time   = ngx.now()
    ngx.log(ngx.INFO, "[stability/degradation] initialized")
end

--- 限流降级响应 (429 Too Many Requests)
--- @param provider string
--- @param dimension string 触发维度 (provider / ip_provider / ip_global)
--- @param limit number 对应限流阈值
function _M.respond_rate_limited(provider, dimension, limit)
    local messages = {
        provider    = "The service " .. (provider or "") .. " is receiving too many requests, please try again later",
        ip_provider = "You are sending too many requests to " .. (provider or "") .. ", please slow down",
        ip_global   = "You are sending too many requests, please slow down",
    }

    local body = {
        error       = "rate_limited",
        message     = messages[dimension] or "Too many requests, please try again later",
        provider    = provider,
        dimension   = dimension,
        limit       = limit,
        retry_after = 1,
    }

    stats.total_responses    = stats.total_responses + 1
    stats.rate_limited_count = stats.rate_limited_count + 1
    add_event("rate_limited", provider, { dimension = dimension, limit = limit })

    ngx.log(ngx.WARN, "[degradation] rate_limited: provider=", provider,
            " dimension=", dimension, " limit=", limit or "")

    return respond(429, body, 1)
end

--- 熔断降级响应 (503 Service Unavailable)
--- @param provider string
--- @param retry_after number 建议重试等待秒数
function _M.respond_circuit_open(provider, retry_after)
    retry_after = retry_after or 30

    local body = {
        error       = "circuit_open",
        message     = "Service " .. (provider or "unknown") .. " is temporarily unavailable, recovering in progress",
        provider    = provider,
        retry_after = math.ceil(retry_after),
    }

    stats.total_responses    = stats.total_responses + 1
    stats.circuit_open_count = stats.circuit_open_count + 1
    add_event("circuit_open", provider, { retry_after = math.ceil(retry_after) })

    ngx.log(ngx.WARN, "[degradation] circuit_open: provider=", provider,
            " retry_after=", retry_after)

    return respond(503, body, retry_after)
end

--- 上游不可用降级响应 (503 Service Unavailable)
--- @param provider string
function _M.respond_service_degraded(provider)
    local body = {
        error       = "service_degraded",
        message     = "Upstream service " .. (provider or "unknown") .. " is currently unavailable, please try again later",
        provider    = provider,
        retry_after = 10,
    }

    stats.total_responses        = stats.total_responses + 1
    stats.service_degraded_count = stats.service_degraded_count + 1
    add_event("service_degraded", provider, {})

    ngx.log(ngx.ERR, "[degradation] service_degraded: provider=", provider)

    return respond(503, body, 10)
end

--- 构建限流降级响应体（仅构建不发送，用于 Debug 预览）
function _M.build_rate_limited_body(provider, dimension, limit)
    local messages = {
        provider    = "The service " .. (provider or "") .. " is receiving too many requests, please try again later",
        ip_provider = "You are sending too many requests to " .. (provider or "") .. ", please slow down",
        ip_global   = "You are sending too many requests, please slow down",
    }

    return {
        status_code = 429,
        headers     = { ["Retry-After"] = "1", ["Content-Type"] = "application/json" },
        body        = {
            error       = "rate_limited",
            message     = messages[dimension] or "Too many requests, please try again later",
            provider    = provider,
            dimension   = dimension,
            limit       = limit,
            retry_after = 1,
        },
    }
end

--- 构建熔断降级响应体（仅构建不发送，用于 Debug 预览）
function _M.build_circuit_open_body(provider, retry_after)
    retry_after = retry_after or 30

    return {
        status_code = 503,
        headers     = { ["Retry-After"] = tostring(math.ceil(retry_after)), ["Content-Type"] = "application/json" },
        body        = {
            error       = "circuit_open",
            message     = "Service " .. (provider or "unknown") .. " is temporarily unavailable, recovering in progress",
            provider    = provider,
            retry_after = math.ceil(retry_after),
        },
    }
end

--- 构建上游不可用降级响应体（仅构建不发送，用于 Debug 预览）
function _M.build_service_degraded_body(provider)
    return {
        status_code = 503,
        headers     = { ["Retry-After"] = "10", ["Content-Type"] = "application/json" },
        body        = {
            error       = "service_degraded",
            message     = "Upstream service " .. (provider or "unknown") .. " is currently unavailable, please try again later",
            provider    = provider,
            retry_after = 10,
        },
    }
end

--- 获取统计数据
function _M.get_stats()
    return stats
end

--- 获取最近的降级事件
function _M.get_recent_events(limit)
    limit = limit or 20
    local result = {}
    for i = 1, math.min(limit, #recent_events) do
        result[i] = recent_events[i]
    end
    return result
end

--- 重置统计计数
function _M.reset_stats()
    stats.total_responses        = 0
    stats.rate_limited_count     = 0
    stats.circuit_open_count     = 0
    stats.service_degraded_count = 0
    recent_events = {}
end

--- 获取完整模块状态
function _M.get_status()
    return {
        module         = "degradation",
        version        = _M._VERSION,
        status         = initialized and "running" or "not_initialized",
        initialized_at = init_time,
        stats          = stats,
        recent_events  = _M.get_recent_events(10),
    }
end

return _M
