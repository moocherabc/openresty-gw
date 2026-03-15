--------------------------------------------------------------------------
-- gateway/router/provider.lua
-- Provider 配置注册表：管理所有第三方服务 Provider 的配置信息
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local providers = {}
local api_keys  = {}
local initialized = false
local init_time = nil

local DEFAULT_TIMEOUT = {
    connect = 5000,
    send    = 30000,
    read    = 30000,
}

local PROVIDER_DEFS = {
    {
        name       = "zerion",
        prefix     = "/zerion",
        upstream   = "zerion_backend",
        host       = "api.zerion.io",
        scheme     = "https",
        auth_type  = "basic_auth",
        auth_config = {
            env_key         = "ZERION_API_KEY",
            username_is_key = true,
        },
    },
    {
        name       = "coingecko",
        prefix     = "/coingecko",
        upstream   = "coingecko_backend",
        host       = "api.coingecko.com",
        scheme     = "https",
        auth_type  = "header",
        auth_config = {
            env_key     = "COINGECKO_API_KEY",
            header_name = "x-cg-pro-api-key",
        },
    },
    {
        name       = "alchemy",
        prefix     = "/alchemy",
        upstream   = "alchemy_backend",
        host       = "eth-mainnet.g.alchemy.com",
        scheme     = "https",
        auth_type  = "url_path",
        auth_config = {
            env_key       = "ALCHEMY_API_KEY",
            path_template = "/v2/{api_key}",
        },
        timeout = {
            connect = 5000,
            send    = 60000,
            read    = 60000,
        },
    },
}

local function load_api_key(env_key)
    local key = os.getenv(env_key)
    if key and key ~= "" then
        return key
    end

    local dict = ngx.shared.gw_config
    if dict then
        return dict:get("env:" .. env_key)
    end

    return nil
end

function _M.init()
    providers = {}
    api_keys  = {}

    for _, def in ipairs(PROVIDER_DEFS) do
        def.timeout = def.timeout or DEFAULT_TIMEOUT
        providers[def.name] = def

        local key = load_api_key(def.auth_config.env_key)
        if key then
            api_keys[def.name] = key
        else
            ngx.log(ngx.WARN, "[router/provider] API key not found for provider: ",
                     def.name, " (env: ", def.auth_config.env_key, ")")
        end
    end

    initialized = true
    init_time   = ngx.now()
    ngx.log(ngx.INFO, "[router/provider] initialized with ",
            #PROVIDER_DEFS, " providers")
    return true
end

function _M.get(name)
    return providers[name]
end

function _M.get_all()
    return providers
end

function _M.get_api_key(name)
    return api_keys[name]
end

function _M.has_api_key(name)
    return api_keys[name] ~= nil
end

function _M.get_provider_names()
    local names = {}
    for name, _ in pairs(providers) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

function _M.get_info()
    return {
        initialized = initialized,
        init_time   = init_time,
        count       = #PROVIDER_DEFS,
    }
end

return _M
