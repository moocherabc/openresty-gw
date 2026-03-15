--------------------------------------------------------------------------
-- gateway/stability/init.lua
-- 稳定性模块协调器：串联限流 → 熔断检查，反馈请求结果
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local circuit_breaker = require("gateway.stability.circuit_breaker")
local rate_limiter    = require("gateway.stability.rate_limiter")
local degradation     = require("gateway.stability.degradation")

local initialized = false
local init_time   = nil

--- 模块初始化（在 init_by_lua 阶段调用）
function _M.init(config)
    config = config or {}

    circuit_breaker.init(config.circuit_breaker)
    rate_limiter.init(config.rate_limiter)
    degradation.init()

    initialized = true
    init_time   = ngx.now()
    ngx.log(ngx.INFO, "[stability] module initialized (circuit_breaker + rate_limiter + degradation)")
    return true
end

--- 请求前检查（在 access_by_lua 阶段，路由匹配之后调用）
--- 串联: 限流 → 熔断
function _M.check_request()
    local route = ngx.ctx.route
    if not route then
        return true
    end

    local provider  = route.provider_name
    local client_ip = ngx.var.remote_addr or "0.0.0.0"

    local rl_ok, rl_dimension, rl_limit = rate_limiter.check(provider, client_ip)
    if not rl_ok then
        ngx.ctx.stability_action = {
            type      = "rate_limited",
            provider  = provider,
            dimension = rl_dimension,
        }
        return degradation.respond_rate_limited(provider, rl_dimension, rl_limit)
    end

    local cb_ok, cb_retry_after = circuit_breaker.before_request(provider)
    if not cb_ok then
        ngx.ctx.stability_action = {
            type     = "circuit_open",
            provider = provider,
        }
        return degradation.respond_circuit_open(provider, cb_retry_after)
    end

    return true
end

--- 请求完成后反馈（在 log_by_lua 阶段调用）
function _M.after_request()
    local route = ngx.ctx.route
    if not route then
        return
    end

    local provider = route.provider_name
    local status   = ngx.status or 0

    if status >= 500 then
        circuit_breaker.record_failure(provider)
    else
        circuit_breaker.record_success(provider)
    end
end

--- 获取模块聚合状态
function _M.get_status()
    return {
        module         = "stability",
        version        = _M._VERSION,
        status         = initialized and "running" or "not_initialized",
        initialized_at = init_time,
        sub_modules    = {
            circuit_breaker = circuit_breaker.get_status(),
            rate_limiter    = rate_limiter.get_status(),
            degradation     = degradation.get_status(),
        },
    }
end

--- 暴露子模块以兼容旧接口
_M.circuit_breaker = circuit_breaker
_M.rate_limiter    = rate_limiter
_M.degradation     = degradation

return _M
