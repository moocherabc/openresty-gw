--------------------------------------------------------------------------
-- header_filter.lua
-- header_filter_by_lua 阶段入口：处理上游响应头 + 捕获响应信息供日志使用
--------------------------------------------------------------------------

local logger = require("gateway.logger")

local route = ngx.ctx.route

if route then
    ngx.header["x-onekey-request-id"] = route.request_id
    ngx.header["x-onekey-provider"]   = route.provider_name
end

ngx.header["x-powered-by"] = nil
ngx.header["server"]       = "onekey-gw"

logger.capture_response_info()
