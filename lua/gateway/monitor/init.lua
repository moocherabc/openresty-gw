--------------------------------------------------------------------------
-- gateway/monitor/init.lua
-- 监控模块协调器：基于 nginx-lua-prometheus 库实现指标注册与暴露
-- 库地址: https://github.com/knyar/nginx-lua-prometheus
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local prometheus
local initialized   = false
local init_time     = nil

local SHARED_DICT   = "gw_metrics"

local LATENCY_BUCKETS = {
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10
}

local metrics = {}

local REGISTERED_METRICS = {
    "gw_requests_total",
    "gw_request_duration_seconds",
    "gw_errors_total",
    "gw_request_bytes_total",
    "gw_response_bytes_total",
    "gw_connections",
    "gw_provider_up",
    "gw_circuit_breaker_state",
    "gw_circuit_breaker_rejected_total",
    "gw_rate_limiter_rejected_total",
    "gw_degradation_responses_total",
}

--- Worker 级初始化（在 init_worker_by_lua 阶段调用）
--- 初始化 prometheus 实例并注册所有指标
function _M.init_worker()
    prometheus = require("prometheus").init(SHARED_DICT)

    metrics.requests = prometheus:counter(
        "gw_requests_total",
        "Total number of HTTP requests processed",
        {"provider", "method", "status"})

    metrics.latency = prometheus:histogram(
        "gw_request_duration_seconds",
        "HTTP request duration in seconds",
        {"provider"},
        LATENCY_BUCKETS)

    metrics.errors = prometheus:counter(
        "gw_errors_total",
        "Total number of errors by provider and type",
        {"provider", "error_type"})

    metrics.request_bytes = prometheus:counter(
        "gw_request_bytes_total",
        "Total bytes received in requests",
        {"provider"})

    metrics.response_bytes = prometheus:counter(
        "gw_response_bytes_total",
        "Total bytes sent in responses",
        {"provider"})

    metrics.connections = prometheus:gauge(
        "gw_connections",
        "Number of HTTP connections",
        {"state"})

    metrics.provider_up = prometheus:gauge(
        "gw_provider_up",
        "Whether provider is healthy (1=up 0=down)",
        {"provider"})

    -- 稳定性模块指标
    metrics.circuit_breaker_state = prometheus:gauge(
        "gw_circuit_breaker_state",
        "Circuit breaker state per provider (0=closed 1=open 2=half_open)",
        {"provider"})

    metrics.circuit_breaker_rejected = prometheus:counter(
        "gw_circuit_breaker_rejected_total",
        "Total requests rejected by circuit breaker",
        {"provider"})

    metrics.rate_limiter_rejected = prometheus:counter(
        "gw_rate_limiter_rejected_total",
        "Total requests rejected by rate limiter",
        {"provider", "dimension"})

    metrics.degradation_responses = prometheus:counter(
        "gw_degradation_responses_total",
        "Total degradation responses sent",
        {"provider", "type"})

    local provider_mod = require("gateway.router.provider")
    local names = provider_mod.get_provider_names()
    for _, name in ipairs(names) do
        metrics.provider_up:set(1, {name})
        metrics.circuit_breaker_state:set(0, {name})
    end

    initialized = true
    init_time   = ngx.now()

    ngx.log(ngx.INFO, "[monitor] initialized with nginx-lua-prometheus, dict=", SHARED_DICT)
end

--- 获取指标对象（供 collector 使用）
function _M.get_metrics()
    return metrics
end

--- 获取 prometheus 实例
function _M.get_prometheus()
    return prometheus
end

--- 输出 Prometheus 格式指标（在 /metrics 端点调用）
function _M.expose()
    if not prometheus then
        ngx.status = 503
        ngx.header["Content-Type"] = "text/plain"
        ngx.say("# monitor module not initialized")
        return
    end

    metrics.connections:set(tonumber(ngx.var.connections_active)  or 0, {"active"})
    metrics.connections:set(tonumber(ngx.var.connections_reading) or 0, {"reading"})
    metrics.connections:set(tonumber(ngx.var.connections_writing) or 0, {"writing"})
    metrics.connections:set(tonumber(ngx.var.connections_waiting) or 0, {"waiting"})

    local ok, cb = pcall(require, "gateway.stability.circuit_breaker")
    if ok and cb then
        local provider_mod = require("gateway.router.provider")
        local names = provider_mod.get_provider_names()
        for _, name in ipairs(names) do
            local info = cb.get_info(name)
            if info and info.state_code then
                metrics.circuit_breaker_state:set(info.state_code, {name})
                local is_up = (info.state_code == 0) and 1 or 0
                metrics.provider_up:set(is_up, {name})
            end
        end
    end

    prometheus:collect()
end

--- 获取模块状态
function _M.get_status()
    local dict = ngx.shared[SHARED_DICT]
    local dict_info = {}

    if dict then
        local capacity = dict:capacity()
        local free     = dict:free_space()
        dict_info = {
            name           = SHARED_DICT,
            capacity_bytes = capacity,
            free_bytes     = free,
            used_bytes     = capacity - free,
            usage_percent  = math.floor((1 - free / capacity) * 10000) / 100,
        }
    end

    return {
        module             = "monitor",
        version            = _M._VERSION,
        status             = initialized and "running" or "not_initialized",
        initialized_at     = init_time,
        library            = "nginx-lua-prometheus",
        library_url        = "https://github.com/knyar/nginx-lua-prometheus",
        shared_dict        = dict_info,
        metrics_registered = REGISTERED_METRICS,
    }
end

return _M
