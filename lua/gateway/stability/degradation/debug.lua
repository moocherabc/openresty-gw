--------------------------------------------------------------------------
-- gateway/stability/degradation/debug.lua
-- 降级器调试接口：预览各类降级响应、查看最近事件、重置统计
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson       = require("cjson.safe")
local degradation = require("gateway.stability.degradation")

local ACTIONS = {}

function ACTIONS.test_rate_limited(args)
    local provider  = args.provider or "test_provider"
    local dimension = args.dimension or "provider"
    local limit     = tonumber(args.limit) or 100

    local valid_dimensions = { provider = true, ip_provider = true, ip_global = true }
    if not valid_dimensions[dimension] then
        return 400, { error = "bad_request", message = "dimension must be: provider, ip_provider, or ip_global" }
    end

    local preview = degradation.build_rate_limited_body(provider, dimension, limit)

    return 200, {
        action  = "test_rate_limited",
        note    = "This is a preview only, no actual request was blocked",
        preview = preview,
    }
end

function ACTIONS.test_circuit_open(args)
    local provider    = args.provider or "test_provider"
    local retry_after = tonumber(args.retry_after) or 30

    local preview = degradation.build_circuit_open_body(provider, retry_after)

    return 200, {
        action  = "test_circuit_open",
        note    = "This is a preview only, no actual request was blocked",
        preview = preview,
    }
end

function ACTIONS.test_service_degraded(args)
    local provider = args.provider or "test_provider"

    local preview = degradation.build_service_degraded_body(provider)

    return 200, {
        action  = "test_service_degraded",
        note    = "This is a preview only, no actual request was blocked",
        preview = preview,
    }
end

function ACTIONS.recent_events(args)
    local limit = tonumber(args.limit) or 20
    local events = degradation.get_recent_events(limit)

    return 200, {
        action = "recent_events",
        count  = #events,
        events = events,
    }
end

function ACTIONS.reset_stats()
    degradation.reset_stats()
    return 200, {
        action = "reset_stats",
        result = "success",
        stats  = degradation.get_stats(),
    }
end

--- 处理 Debug 请求
--- GET/POST /admin/stability/degradation/debug?action=xxx
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local args = ngx.req.get_uri_args()
    local action = args.action

    if not action or action == "" then
        ngx.status = 200
        ngx.say(cjson.encode({
            module = "degradation",
            type   = "debug",
            available_actions = {
                "test_rate_limited", "test_circuit_open", "test_service_degraded",
                "recent_events", "reset_stats",
            },
            usage = "GET/POST /admin/stability/degradation/debug?action=<action>&provider=<provider>",
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
                "test_rate_limited", "test_circuit_open", "test_service_degraded",
                "recent_events", "reset_stats",
            },
        }))
        return
    end

    local status_code, body = handler(args)
    ngx.status = status_code
    ngx.say(cjson.encode(body))
end

return _M
