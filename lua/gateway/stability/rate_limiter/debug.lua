--------------------------------------------------------------------------
-- gateway/stability/rate_limiter/debug.lua
-- 限流器调试接口：查看漏桶状态、重置统计、模拟超限、强制拒绝
--------------------------------------------------------------------------
local _M = { _VERSION = "2.0.0" }

local cjson        = require("cjson.safe")
local rate_limiter = require("gateway.stability.rate_limiter")

local ACTIONS = {}

--- 查看指定 provider+ip 在所有维度的漏桶状态
--- excess: 当前请求积压量（含本次探测）；status: ok/would_reject
function ACTIONS.get_counters(args)
    local provider = args.provider
    if not provider or provider == "" then
        return 400, {
            error   = "bad_request",
            message = "missing required parameter: provider",
        }
    end

    local ip = args.ip or "0.0.0.0"
    local counters = rate_limiter.get_all_counters(provider, ip)
    if not counters then
        return 500, { error = "internal_error", message = "shared dict not found" }
    end

    return 200, {
        action    = "get_counters",
        provider  = provider,
        client_ip = ip,
        algorithm = "leaky_bucket (resty.limit.req)",
        note      = "excess includes a simulated probe request (commit=false)",
        counters  = counters,
    }
end

--- 重置统计计数（不影响漏桶中的请求积压数据）
function ACTIONS.reset_stats()
    rate_limiter.reset_stats()
    return 200, {
        action = "reset_stats",
        result = "success",
        stats  = rate_limiter.get_stats(),
    }
end

--- 模拟指定维度超限，预览降级响应内容（不真正拦截）
function ACTIONS.simulate_exceeded(args)
    local provider  = args.provider or "unknown"
    local dimension = args.dimension or "provider"

    local config = rate_limiter.get_config()
    local limit, burst, message

    if dimension == "provider" then
        local prov_limits = config.provider_limits or {}
        local prov_cfg = prov_limits[provider] or config.default_provider_limit
        limit   = prov_cfg and prov_cfg.rate or 100
        burst   = prov_cfg and prov_cfg.burst or 50
        message = "The service " .. provider
                  .. " is receiving too many requests, please try again later"
    elseif dimension == "ip_provider" then
        limit   = config.ip_provider_limit and config.ip_provider_limit.rate or 20
        burst   = config.ip_provider_limit and config.ip_provider_limit.burst or 10
        message = "You are sending too many requests to " .. provider
                  .. ", please slow down"
    elseif dimension == "ip_global" then
        limit   = config.ip_global_limit and config.ip_global_limit.rate or 50
        burst   = config.ip_global_limit and config.ip_global_limit.burst or 25
        message = "You are sending too many requests, please slow down"
    else
        return 400, {
            error   = "bad_request",
            message = "dimension must be: provider, ip_provider, or ip_global",
        }
    end

    return 200, {
        action    = "simulate_exceeded",
        provider  = provider,
        dimension = dimension,
        note      = "This is a preview of the degradation response (not actually sent)",
        simulated_response = {
            status_code = 429,
            headers     = {
                ["Retry-After"]  = "1",
                ["Content-Type"] = "application/json",
            },
            body = {
                error       = "rate_limited",
                message     = message,
                provider    = provider,
                dimension   = dimension,
                limit       = limit,
                burst       = burst,
                algorithm   = "leaky_bucket",
                retry_after = 1,
            },
        },
    }
end

--- 启用强制拒绝模式：所有（或指定 provider 的）请求均被限流
function ACTIONS.force_reject(args)
    local dimension = args.dimension or "provider"
    local provider  = args.provider  -- nil = 所有 provider

    if dimension ~= "provider"
       and dimension ~= "ip_provider"
       and dimension ~= "ip_global" then
        return 400, {
            error   = "bad_request",
            message = "dimension must be: provider, ip_provider, or ip_global",
        }
    end

    rate_limiter.set_debug_force_reject(true, dimension, provider)

    return 200, {
        action     = "force_reject",
        result     = "enabled",
        dimension  = dimension,
        provider   = provider or "(all)",
        debug_mode = rate_limiter.get_debug_mode(),
    }
end

--- 关闭强制拒绝模式
function ACTIONS.clear_force_reject()
    rate_limiter.set_debug_force_reject(false, nil, nil)
    return 200, {
        action     = "clear_force_reject",
        result     = "disabled",
        debug_mode = rate_limiter.get_debug_mode(),
    }
end

--- 查看当前 Debug 模式状态
function ACTIONS.get_debug_mode()
    return 200, {
        action     = "get_debug_mode",
        debug_mode = rate_limiter.get_debug_mode(),
    }
end

local ALL_ACTIONS = {
    "get_counters",
    "reset_stats",
    "simulate_exceeded",
    "force_reject",
    "clear_force_reject",
    "get_debug_mode",
}

--- 处理 Debug 请求入口
--- GET/POST /admin/stability/rate-limiter/debug?action=xxx
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local args   = ngx.req.get_uri_args()
    local action = args.action

    if not action or action == "" then
        ngx.status = 200
        ngx.say(cjson.encode({
            module            = "rate_limiter",
            type              = "debug",
            version           = _M._VERSION,
            algorithm         = "leaky_bucket (resty.limit.req)",
            available_actions = ALL_ACTIONS,
            usage             = "GET/POST /admin/stability/rate-limiter/debug?action=<action>&provider=<provider>",
            examples          = {
                "?action=get_counters&provider=zerion&ip=127.0.0.1",
                "?action=simulate_exceeded&provider=zerion&dimension=provider",
                "?action=force_reject&dimension=provider&provider=zerion",
                "?action=clear_force_reject",
                "?action=reset_stats",
            },
        }))
        return
    end

    local handler = ACTIONS[action]
    if not handler then
        ngx.status = 400
        ngx.say(cjson.encode({
            error             = "bad_request",
            message           = "unknown action: " .. tostring(action),
            available_actions = ALL_ACTIONS,
        }))
        return
    end

    local status_code, body = handler(args)
    ngx.status = status_code
    ngx.say(cjson.encode(body))
end

return _M
