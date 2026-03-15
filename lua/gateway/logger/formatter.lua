--------------------------------------------------------------------------
-- gateway/logger/formatter.lua
-- 结构化 JSON 日志构建器：构建标准化的访问日志条目
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson    = require("cjson.safe")
local sanitizer = require("gateway.logger.sanitizer")

local BODY_LOG_THRESHOLD    = 2048
local BODY_TRUNCATE_MAX     = 10240
local MAX_LOG_HEADERS       = 15

local ERROR_TYPE_MAP = {
    [400] = "bad_request",
    [401] = "unauthorized",
    [403] = "forbidden",
    [404] = "not_found",
    [408] = "request_timeout",
    [429] = "rate_limited",
    [502] = "bad_gateway",
    [503] = "service_unavailable",
    [504] = "gateway_timeout",
}

--- 截断大 Body
--- @param body string|nil
--- @param max_len number
--- @return string|nil
function _M.truncate_body(body, max_len)
    if not body then
        return nil
    end

    max_len = max_len or BODY_TRUNCATE_MAX
    local len = #body

    if len <= BODY_LOG_THRESHOLD then
        return body
    end

    if len <= max_len then
        return body:sub(1, BODY_LOG_THRESHOLD) .. "[truncated: " .. len .. " bytes total]"
    end

    return "[body_size: " .. len .. " bytes]"
end

--- 提取安全的头部子集（脱敏 + 限制数量）
--- @param raw_headers table
--- @param max_count number
--- @return table
function _M.safe_headers(raw_headers, max_count)
    if not raw_headers then
        return {}
    end

    max_count = max_count or MAX_LOG_HEADERS

    local sanitized = sanitizer.sanitize_headers(raw_headers)
    local result = {}
    local count = 0

    for name, value in pairs(sanitized) do
        if count >= max_count then
            break
        end
        result[name] = value
        count = count + 1
    end

    return result
end

--- 构建错误信息对象
function _M.build_error_info(status)
    if status < 400 then
        return cjson.null
    end

    local err_type = ERROR_TYPE_MAP[status] or ("http_" .. tostring(status))

    local upstream_status = ngx.var.upstream_status
    local err_msg = nil

    if status >= 500 then
        local upstream_addr = ngx.var.upstream_addr or ""
        if status == 504 then
            err_msg = "upstream timed out"
        elseif status == 502 then
            err_msg = "bad gateway from upstream " .. upstream_addr
        elseif status == 503 then
            err_msg = "service unavailable"
        end
    end

    return {
        type            = err_type,
        message         = err_msg,
        upstream_status = upstream_status,
    }
end

--- 构建完整的结构化访问日志条目
--- @return string JSON 字符串
function _M.build_access_log()
    local route = ngx.ctx.route or {}
    local status = ngx.status or 0

    local request_time
    if route.start_time then
        request_time = ngx.now() - route.start_time
    else
        request_time = tonumber(ngx.var.request_time) or 0
    end

    local upstream_time = tonumber(ngx.var.upstream_response_time) or 0

    local req_headers = ngx.req.get_headers(20) or {}
    local resp_headers = ngx.ctx.response_headers or {}

    local entry = {
        timestamp  = ngx.var.time_iso8601,
        level      = status >= 500 and "ERROR" or (status >= 400 and "WARN" or "INFO"),
        type       = "access",
        request_id = route.request_id or ngx.var.request_id or "",
        provider   = route.provider_name or ngx.var.provider or "",

        request = {
            method         = ngx.req.get_method(),
            uri            = sanitizer.sanitize_uri(ngx.var.uri or ""),
            query_string   = sanitizer.sanitize_args(ngx.var.args or ""),
            content_length = tonumber(ngx.var.request_length) or 0,
            remote_addr    = ngx.var.remote_addr or "",
            headers        = _M.safe_headers(req_headers, MAX_LOG_HEADERS),
        },

        upstream = {
            uri           = sanitizer.sanitize_uri(route.upstream_uri or ""),
            addr          = ngx.var.upstream_addr or "",
            status        = tonumber(ngx.var.upstream_status) or cjson.null,
            response_time = upstream_time,
        },

        response = {
            status         = status,
            body_bytes_sent = tonumber(ngx.var.body_bytes_sent) or 0,
            headers        = _M.safe_headers(resp_headers, 10),
        },

        latency = {
            total_ms    = math.floor(request_time * 1000 * 100) / 100,
            upstream_ms = math.floor(upstream_time * 1000 * 100) / 100,
        },

        error = _M.build_error_info(status),
    }

    return cjson.encode(entry)
end

return _M
