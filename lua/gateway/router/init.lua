--------------------------------------------------------------------------
-- gateway/router/init.lua
-- 路由模块协调器：统一入口，协调 matcher/transformer/provider 完成路由处理
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson       = require("cjson.safe")
local provider    = require("gateway.router.provider")
local matcher     = require("gateway.router.matcher")
local transformer = require("gateway.router.transformer")

local initialized = false
local init_time   = nil

--- 模块初始化（在 init_by_lua 阶段调用）
function _M.init()
    provider.init()
    matcher.init(provider.get_all())

    initialized = true
    init_time   = ngx.now()
    ngx.log(ngx.INFO, "[router] module initialized successfully")
    return true
end

--- 核心请求处理（在 access_by_lua 阶段调用）
function _M.process_request()
    local uri           = ngx.var.uri
    local provider_name = ngx.var.provider

    if not provider_name or provider_name == "" then
        ngx.log(ngx.WARN, "[router] no provider variable set for uri: ", uri)
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode({
            error   = "not_found",
            message = "no provider matched for this route",
        }))
        return ngx.exit(404)
    end

    local match_result, err = matcher.match(uri)
    if not match_result then
        ngx.log(ngx.WARN, "[router] route match failed: ", err)
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode({
            error   = "not_found",
            message = "route not matched: " .. (err or "unknown"),
        }))
        return ngx.exit(404)
    end

    local prov = match_result.provider

    local ok, transform_err = transformer.transform(prov, match_result)
    if not ok then
        ngx.log(ngx.ERR, "[router] request transform failed for provider ",
                prov.name, ": ", transform_err)
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode({
            error   = "transform_failed",
            message = "failed to prepare request: " .. (transform_err or "unknown"),
        }))
        return ngx.exit(502)
    end

    if prov.auth_type == "url_path" then
        ngx.var.backend_uri = match_result.upstream_uri
    end

    ngx.ctx.route = {
        provider_name = prov.name,
        prefix        = match_result.prefix,
        captured_path = match_result.captured_path,
        upstream_uri  = match_result.upstream_uri,
        request_id    = ngx.ctx.request_id,
        start_time    = ngx.now(),
    }

    ngx.log(ngx.DEBUG, "[router] request routed: provider=", prov.name,
            " upstream_uri=", match_result.upstream_uri)
end

--- 获取模块状态
function _M.get_status()
    local prov_info = {}
    local all_providers = provider.get_all()

    for name, p in pairs(all_providers) do
        prov_info[name] = {
            prefix             = p.prefix,
            upstream           = p.upstream,
            host               = p.host,
            auth_type          = p.auth_type,
            api_key_configured = provider.has_api_key(name),
        }
    end

    local routes = matcher.get_routes()
    local route_prefixes = {}
    for _, r in ipairs(routes) do
        route_prefixes[#route_prefixes + 1] = r.prefix
    end

    return {
        module       = "router",
        version      = _M._VERSION,
        status       = initialized and "running" or "not_initialized",
        initialized_at = init_time,
        providers    = prov_info,
        routes_count = #routes,
        routes       = route_prefixes,
        matcher      = matcher.get_info(),
        provider_registry = provider.get_info(),
    }
end

return _M
