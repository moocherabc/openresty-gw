--------------------------------------------------------------------------
-- init_worker.lua
-- init_worker_by_lua 阶段入口：Worker 级初始化
--------------------------------------------------------------------------

local worker_id  = ngx.worker.id()
local worker_pid = ngx.worker.pid()

ngx.log(ngx.INFO, "[init_worker] worker started: id=", worker_id, " pid=", worker_pid)

local monitor = require("gateway.monitor")
monitor.init_worker()

ngx.log(ngx.INFO, "[init_worker] monitor module initialized")
