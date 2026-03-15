--------------------------------------------------------------------------
-- gateway/logger/sanitizer.lua
-- 敏感信息脱敏处理器：对 API Key、Authorization 等进行掩码处理
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local SENSITIVE_HEADERS = {
    ["authorization"]     = true,
    ["proxy-authorization"] = true,
    ["x-cg-pro-api-key"]  = true,
    ["x-api-key"]          = true,
    ["api-key"]            = true,
    ["cookie"]             = true,
    ["set-cookie"]         = true,
}

local SENSITIVE_PARAMS = {
    ["api_key"]    = true,
    ["apikey"]     = true,
    ["key"]        = true,
    ["token"]      = true,
    ["secret"]     = true,
    ["password"]   = true,
    ["access_token"] = true,
}

--- 通用掩码函数
--- @param value string 原始值
--- @param keep_prefix number 保留前缀字符数 (默认 4)
--- @return string 掩码后的值
function _M.mask(value, keep_prefix)
    if not value or value == "" then
        return ""
    end

    keep_prefix = keep_prefix or 4
    local len = #value

    if len <= keep_prefix then
        return string.rep("*", len)
    end

    return value:sub(1, keep_prefix) .. string.rep("*", math.min(len - keep_prefix, 8))
end

--- 脱敏单个 Header 值
local function sanitize_header_value(name, value)
    if not value or value == "" then
        return value
    end

    local lower_name = name:lower()

    if not SENSITIVE_HEADERS[lower_name] then
        return value
    end

    if lower_name == "authorization" or lower_name == "proxy-authorization" then
        local auth_type, _ = value:match("^(%S+)%s+(.+)$")
        if auth_type then
            return auth_type .. " ****"
        end
        return "****"
    end

    return _M.mask(value)
end

--- 脱敏请求/响应头部
--- @param headers table 头部表
--- @return table 脱敏后的头部表
function _M.sanitize_headers(headers)
    if not headers then
        return {}
    end

    local sanitized = {}
    for name, value in pairs(headers) do
        if type(value) == "table" then
            local vals = {}
            for _, v in ipairs(value) do
                vals[#vals + 1] = sanitize_header_value(name, v)
            end
            sanitized[name] = vals
        else
            sanitized[name] = sanitize_header_value(name, value)
        end
    end

    return sanitized
end

--- 脱敏 URI 中的敏感路径段
--- 检测类似 /v2/<api_key>/eth 的模式，将中间的长字符串掩码
--- @param uri string
--- @return string
function _M.sanitize_uri(uri)
    if not uri then
        return ""
    end

    return uri:gsub("/([%w%-_]{20,})/", function(segment)
        return "/" .. _M.mask(segment, 4) .. "/"
    end)
end

--- 脱敏查询参数中的密钥
--- @param query_string string
--- @return string
function _M.sanitize_args(query_string)
    if not query_string or query_string == "" then
        return ""
    end

    return query_string:gsub("([%w_]+)=([^&]+)", function(key, value)
        if SENSITIVE_PARAMS[key:lower()] then
            return key .. "=" .. _M.mask(value)
        end
        return key .. "=" .. value
    end)
end

return _M
