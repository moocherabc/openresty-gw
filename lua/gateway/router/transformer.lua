--------------------------------------------------------------------------
-- gateway/router/transformer.lua
-- 请求转换器：认证注入、头部过滤、追踪头添加、URI 重写
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local ngx_encode_base64 = ngx.encode_base64
local provider_mod = require("gateway.router.provider")

local HOP_BY_HOP_HEADERS = {
    ["connection"]          = true,
    ["keep-alive"]          = true,
    ["proxy-authenticate"]  = true,
    ["proxy-authorization"] = true,
    ["te"]                  = true,
    ["trailers"]            = true,
    ["transfer-encoding"]   = true,
    ["upgrade"]             = true,
}

local STRIP_REQUEST_HEADERS = {
    ["host"]       = true,
    ["connection"] = true,
}

--- 注入 Basic Auth 认证
--- Authorization: Basic base64(api_key:)
local function inject_basic_auth(provider_name)
    local api_key = provider_mod.get_api_key(provider_name)
    if not api_key then
        ngx.log(ngx.ERR, "[router/transformer] missing API key for basic_auth provider: ",
                provider_name)
        return false, "missing api key"
    end

    local credential = ngx_encode_base64(api_key .. ":")
    ngx.req.set_header("Authorization", "Basic " .. credential)
    return true
end

--- 注入 Header 认证
--- 将 API Key 设置为指定的请求头
local function inject_header_auth(provider_name, auth_config)
    local api_key = provider_mod.get_api_key(provider_name)
    if not api_key then
        ngx.log(ngx.ERR, "[router/transformer] missing API key for header provider: ",
                provider_name)
        return false, "missing api key"
    end

    local header_name = auth_config.header_name
    if not header_name then
        ngx.log(ngx.ERR, "[router/transformer] missing header_name in auth_config for: ",
                provider_name)
        return false, "missing header_name"
    end

    ngx.req.set_header(header_name, api_key)
    return true
end

--- 注入 URL Path 认证
--- 将 API Key 拼接到上游 URI 路径中
--- 例如 Alchemy: /v2/{api_key}/eth_blockNumber
local function inject_url_path_auth(provider_name, auth_config, match_result)
    local api_key = provider_mod.get_api_key(provider_name)
    if not api_key then
        ngx.log(ngx.ERR, "[router/transformer] missing API key for url_path provider: ",
                provider_name)
        return false, "missing api key"
    end

    local template = auth_config.path_template or "/v2/{api_key}"
    local auth_path = template:gsub("{api_key}", api_key)
    local captured = match_result.captured_path or ""

    if captured ~= "" then
        match_result.upstream_uri = auth_path .. "/" .. captured
    else
        match_result.upstream_uri = auth_path
    end

    return true
end

--- 根据 Provider 认证类型注入认证信息
function _M.inject_auth(provider, match_result)
    local auth_type = provider.auth_type
    local name      = provider.name
    local config    = provider.auth_config

    if auth_type == "basic_auth" then
        return inject_basic_auth(name)
    elseif auth_type == "header" then
        return inject_header_auth(name, config)
    elseif auth_type == "url_path" then
        return inject_url_path_auth(name, config, match_result)
    else
        ngx.log(ngx.WARN, "[router/transformer] unknown auth_type: ", auth_type,
                " for provider: ", name)
        return true
    end
end

--- 过滤不应转发的 Hop-by-Hop 头部
function _M.filter_headers()
    local headers = ngx.req.get_headers()
    for name, _ in pairs(headers) do
        local lower_name = name:lower()
        if HOP_BY_HOP_HEADERS[lower_name] or STRIP_REQUEST_HEADERS[lower_name] then
            ngx.req.clear_header(name)
        end
    end
end

--- 添加请求追踪头部
function _M.add_trace_header()
    local request_id = ngx.var.request_id
    if not request_id or request_id == "" then
        request_id = ngx.var.connection .. "-" .. ngx.now()
    end
    ngx.req.set_header("x-onekey-request-id", request_id)
    ngx.ctx.request_id = request_id
end

--- 重写上游 URI
--- 对于非 url_path 类型，直接使用捕获路径
--- 对于 url_path 类型，upstream_uri 已在 inject_url_path_auth 中设置
function _M.rewrite_uri(provider, match_result)
    if not match_result.upstream_uri then
        local captured = match_result.captured_path or ""
        match_result.upstream_uri = "/" .. captured
    end

    local args = ngx.var.args
    if args and args ~= "" then
        match_result.upstream_uri = match_result.upstream_uri .. "?" .. args
    end

    return match_result.upstream_uri
end

--- 执行完整的请求转换流程
function _M.transform(provider, match_result)
    _M.filter_headers()

    local ok, err = _M.inject_auth(provider, match_result)
    if not ok then
        ngx.log(ngx.ERR, "[router/transformer] auth injection failed: ", err)
        return false, err
    end

    _M.add_trace_header()

    ngx.req.set_header("Host", provider.host)

    local upstream_uri = _M.rewrite_uri(provider, match_result)
    match_result.upstream_uri = upstream_uri

    return true
end

return _M
