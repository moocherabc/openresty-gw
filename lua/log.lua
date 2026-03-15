--------------------------------------------------------------------------
-- log.lua
-- log_by_lua 阶段入口：监控采集 + 日志记录 + 稳定性反馈
--------------------------------------------------------------------------

local collector = require("gateway.monitor.collector")
local logger    = require("gateway.logger")
local stability = require("gateway.stability")

local route = ngx.ctx.route
if not route then
    return
end

collector.record_request()

logger.log_request()

stability.after_request()
