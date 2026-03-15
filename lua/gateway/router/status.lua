--------------------------------------------------------------------------
-- gateway/router/status.lua
-- 路由模块状态查询 API：暴露模块运行状态，支持独立测试和监控
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson  = require("cjson.safe")
local router = require("gateway.router")

--- 处理状态查询请求 (content_by_lua 阶段)
--- GET /admin/router/status
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local status = router.get_status()

    status.server_info = {
        worker_pid    = ngx.worker.pid(),
        worker_id     = ngx.worker.id(),
        worker_count  = ngx.worker.count(),
        ngx_time      = ngx.now(),
    }

    local json = cjson.encode(status)
    if not json then
        ngx.status = 500
        ngx.say(cjson.encode({
            error   = "internal_error",
            message = "failed to serialize router status",
        }))
        return
    end

    ngx.status = 200
    ngx.say(json)
end

--- 简单的健康检查（仅检查路由模块是否正常加载）
function _M.health_check()
    ngx.header["Content-Type"] = "application/json"

    local status = router.get_status()

    if status.status == "running" and status.routes_count > 0 then
        ngx.status = 200
        ngx.say(cjson.encode({
            status  = "healthy",
            module  = "router",
            routes  = status.routes_count,
        }))
    else
        ngx.status = 503
        ngx.say(cjson.encode({
            status  = "unhealthy",
            module  = "router",
            reason  = status.status ~= "running" and "not initialized"
                      or "no routes registered",
        }))
    end
end

return _M
