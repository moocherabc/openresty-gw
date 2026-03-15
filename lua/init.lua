--------------------------------------------------------------------------
-- init.lua
-- init_by_lua 阶段入口：全局初始化所有模块
--------------------------------------------------------------------------

local router    = require("gateway.router")
local config    = require("config")
local logger    = require("gateway.logger")
local stability = require("gateway.stability")

ngx.log(ngx.INFO, "========================================")
ngx.log(ngx.INFO, " OpenResty  API Gateway starting...")
ngx.log(ngx.INFO, "========================================")

router.init()
config.init()
logger.init()
stability.init()

ngx.log(ngx.INFO, "[init] gateway initialization complete")
