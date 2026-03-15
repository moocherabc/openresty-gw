--------------------------------------------------------------------------
-- access.lua
-- access_by_lua 阶段入口：路由匹配 → 稳定性检查（限流 + 熔断）
--------------------------------------------------------------------------
local router    = require("gateway.router")
local stability = require("gateway.stability")

router.process_request()

stability.check_request()
