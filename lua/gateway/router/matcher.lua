--------------------------------------------------------------------------
-- gateway/router/matcher.lua
-- 路由匹配引擎：根据请求 URI 前缀匹配对应的 Provider
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local route_table   = {}
local prefix_list   = {}
local initialized   = false

--- 从 URI 中提取第一段路径作为 Provider 标识
--- 例如 /zerion/v1/wallets → "zerion"
local function extract_prefix(uri)
    return uri:match("^/([^/]+)")
end

--- 从 URI 中提取前缀之后的捕获路径
--- 例如 /zerion/v1/wallets → "v1/wallets"
local function extract_captured_path(uri, prefix)
    local pattern = "^/" .. prefix .. "/(.*)"
    local captured = uri:match(pattern)
    return captured or ""
end

function _M.init(providers)
    route_table = {}
    prefix_list = {}

    for name, provider in pairs(providers) do
        local prefix = provider.prefix:match("^/(.+)") or name
        route_table[prefix] = provider
        prefix_list[#prefix_list + 1] = prefix
    end

    table.sort(prefix_list, function(a, b) return #a > #b end)

    initialized = true
    ngx.log(ngx.INFO, "[router/matcher] route table built with ",
            #prefix_list, " routes: ", table.concat(prefix_list, ", "))
    return true
end

--- 匹配请求 URI 到 Provider
--- @param uri string 请求 URI (如 /zerion/v1/wallets)
--- @return table|nil match_result { provider, prefix, captured_path }
function _M.match(uri)
    if not uri or uri == "" then
        return nil, "empty uri"
    end

    local prefix = extract_prefix(uri)
    if not prefix then
        return nil, "no prefix found in uri: " .. uri
    end

    local provider = route_table[prefix]
    if not provider then
        return nil, "no route matched for prefix: " .. prefix
    end

    local captured_path = extract_captured_path(uri, prefix)

    return {
        provider      = provider,
        prefix        = prefix,
        captured_path = captured_path,
    }
end

function _M.get_routes()
    local routes = {}
    for prefix, provider in pairs(route_table) do
        routes[#routes + 1] = {
            prefix   = "/" .. prefix,
            provider = provider.name,
            upstream = provider.upstream,
            host     = provider.host,
        }
    end
    table.sort(routes, function(a, b) return a.prefix < b.prefix end)
    return routes
end

function _M.get_info()
    return {
        initialized  = initialized,
        routes_count = #prefix_list,
        prefixes     = prefix_list,
    }
end

return _M
