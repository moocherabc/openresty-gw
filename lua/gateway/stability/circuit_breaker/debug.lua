--------------------------------------------------------------------------
-- gateway/stability/circuit_breaker/debug.lua
-- 熔断器调试接口：强制状态变更、模拟故障、重置
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson           = require("cjson.safe")
local circuit_breaker = require("gateway.stability.circuit_breaker")

local ACTIONS = {}

function ACTIONS.force_open(args)
    local provider = args.provider
    if not provider or provider == "" then
        return 400, { error = "bad_request", message = "missing required parameter: provider" }
    end

    local ok, err = circuit_breaker.force_state(provider, circuit_breaker.STATE_OPEN)
    if not ok then
        return 500, { error = "internal_error", message = err }
    end

    return 200, {
        action   = "force_open",
        provider = provider,
        result   = "success",
        current  = circuit_breaker.get_info(provider),
    }
end

function ACTIONS.force_closed(args)
    local provider = args.provider
    if not provider or provider == "" then
        return 400, { error = "bad_request", message = "missing required parameter: provider" }
    end

    local ok, err = circuit_breaker.force_state(provider, circuit_breaker.STATE_CLOSED)
    if not ok then
        return 500, { error = "internal_error", message = err }
    end

    return 200, {
        action   = "force_closed",
        provider = provider,
        result   = "success",
        current  = circuit_breaker.get_info(provider),
    }
end

function ACTIONS.force_half_open(args)
    local provider = args.provider
    if not provider or provider == "" then
        return 400, { error = "bad_request", message = "missing required parameter: provider" }
    end

    local ok, err = circuit_breaker.force_state(provider, circuit_breaker.STATE_HALF_OPEN)
    if not ok then
        return 500, { error = "internal_error", message = err }
    end

    return 200, {
        action   = "force_half_open",
        provider = provider,
        result   = "success",
        current  = circuit_breaker.get_info(provider),
    }
end

function ACTIONS.reset(args)
    local provider = args.provider
    if not provider or provider == "" then
        return 400, { error = "bad_request", message = "missing required parameter: provider" }
    end

    local ok, err = circuit_breaker.reset(provider)
    if not ok then
        return 500, { error = "internal_error", message = err }
    end

    return 200, {
        action   = "reset",
        provider = provider,
        result   = "success",
        current  = circuit_breaker.get_info(provider),
    }
end

function ACTIONS.reset_all()
    circuit_breaker.reset_all()
    return 200, {
        action = "reset_all",
        result = "success",
        current = circuit_breaker.get_all_info(),
    }
end

function ACTIONS.simulate_failures(args)
    local provider = args.provider
    if not provider or provider == "" then
        return 400, { error = "bad_request", message = "missing required parameter: provider" }
    end

    local count = tonumber(args.count) or 5
    if count < 1 or count > 100 then
        return 400, { error = "bad_request", message = "count must be between 1 and 100" }
    end

    local before = circuit_breaker.get_info(provider)

    for _ = 1, count do
        circuit_breaker.record_failure(provider)
    end

    local after = circuit_breaker.get_info(provider)

    return 200, {
        action         = "simulate_failures",
        provider       = provider,
        simulated_count = count,
        before         = before,
        after          = after,
    }
end

function ACTIONS.get_info(args)
    local provider = args.provider
    if provider and provider ~= "" then
        return 200, {
            action   = "get_info",
            provider = circuit_breaker.get_info(provider),
        }
    end

    return 200, {
        action    = "get_info",
        providers = circuit_breaker.get_all_info(),
        stats     = circuit_breaker.get_stats(),
    }
end

--- 处理 Debug 请求
--- GET/POST /admin/stability/circuit-breaker/debug?action=xxx&provider=xxx
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local args = ngx.req.get_uri_args()
    local action = args.action

    if not action or action == "" then
        ngx.status = 200
        ngx.say(cjson.encode({
            module = "circuit_breaker",
            type   = "debug",
            available_actions = {
                "force_open", "force_closed", "force_half_open",
                "reset", "reset_all", "simulate_failures", "get_info",
            },
            usage = "GET/POST /admin/stability/circuit-breaker/debug?action=<action>&provider=<provider>",
        }))
        return
    end

    local handler = ACTIONS[action]
    if not handler then
        ngx.status = 400
        ngx.say(cjson.encode({
            error   = "bad_request",
            message = "unknown action: " .. tostring(action),
            available_actions = {
                "force_open", "force_closed", "force_half_open",
                "reset", "reset_all", "simulate_failures", "get_info",
            },
        }))
        return
    end

    local status_code, body = handler(args)
    ngx.status = status_code
    ngx.say(cjson.encode(body))
end

return _M
