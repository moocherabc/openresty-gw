--------------------------------------------------------------------------
-- config.lua
-- 全局配置管理模块：集中管理网关配置，支持热更新
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local cjson = require("cjson.safe")

local config_data = {
    version = "1.0.0",
    gateway = {
        name = "onekey-api-gateway",
        listen_port = 8080,
    },
    providers = {},
}

local loaded = false

function _M.init()
    local provider = require("gateway.router.provider")
    local all = provider.get_all()
    config_data.providers = all
    loaded = true
    ngx.log(ngx.INFO, "[config] configuration loaded")
    return true
end

function _M.get(key)
    if not key then
        return config_data
    end

    local parts = {}
    for part in key:gmatch("[^.]+") do
        parts[#parts + 1] = part
    end

    local current = config_data
    for _, part in ipairs(parts) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[part]
    end

    return current
end

function _M.get_providers()
    local provider = require("gateway.router.provider")
    return provider.get_all()
end

function _M.reload()
    local ok, err = pcall(function()
        local provider = require("gateway.router.provider")
        provider.init()

        local matcher = require("gateway.router.matcher")
        matcher.init(provider.get_all())

        config_data.providers = provider.get_all()
    end)

    if not ok then
        ngx.log(ngx.ERR, "[config] reload failed: ", err)
        return false, err
    end

    ngx.log(ngx.INFO, "[config] configuration reloaded successfully")
    return true
end

function _M.is_loaded()
    return loaded
end

return _M
