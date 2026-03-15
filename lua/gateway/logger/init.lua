--------------------------------------------------------------------------
-- gateway/logger/init.lua
-- 日志模块协调器：统一管理结构化日志输出、脱敏处理和请求追踪
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson     = require("cjson.safe")
local formatter = require("gateway.logger.formatter")

local initialized = false
local init_time   = nil

local log_counts = {
    total = 0,
    info  = 0,
    warn  = 0,
    error = 0,
}

local config = {
    body_log_threshold = 2048,
    body_truncate_max  = 10240,
    max_log_headers    = 15,
    log_request_body   = false,
    log_response_body  = false,
}

--- 模块初始化
function _M.init()
    initialized = true
    init_time   = ngx.now()
    ngx.log(ngx.INFO, "[logger] module initialized")
    return true
end

--- 在 header_filter 阶段捕获响应头信息（存入 ngx.ctx）
function _M.capture_response_info()
    local resp_headers = ngx.resp.get_headers(20)
    if resp_headers then
        local safe = {}
        for k, v in pairs(resp_headers) do
            safe[k] = v
        end
        ngx.ctx.response_headers = safe
    end
end

--- 输出结构化访问日志（在 log_by_lua 阶段调用）
function _M.log_request()
    local route = ngx.ctx.route
    if not route then
        return
    end

    local json = formatter.build_access_log()
    if not json then
        ngx.log(ngx.ERR, "[logger] failed to build access log entry")
        return
    end

    local status = ngx.status or 0

    log_counts.total = log_counts.total + 1

    if status >= 500 then
        ngx.log(ngx.ERR, "[access] ", json)
        log_counts.error = log_counts.error + 1
    elseif status >= 400 then
        ngx.log(ngx.WARN, "[access] ", json)
        log_counts.warn = log_counts.warn + 1
    else
        ngx.log(ngx.INFO, "[access] ", json)
        log_counts.info = log_counts.info + 1
    end
end

--- 获取模块状态
function _M.get_status()
    return {
        module         = "logger",
        version        = _M._VERSION,
        status         = initialized and "running" or "not_initialized",
        initialized_at = init_time,
        config         = config,
        log_counts     = log_counts,
    }
end

return _M
