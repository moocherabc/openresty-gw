--------------------------------------------------------------------------
-- circuit_breaker.lua
-- 兼容入口：代理到 gateway.stability.circuit_breaker
--------------------------------------------------------------------------
local cb = require("gateway.stability.circuit_breaker")
return cb
