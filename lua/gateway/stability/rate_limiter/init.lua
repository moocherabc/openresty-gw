--------------------------------------------------------------------------
-- gateway/stability/rate_limiter/init.lua
-- 多维度限流器：基于 resty.limit.req（漏桶算法）
-- 维度：Provider 全局 + IP+Provider + IP 全局
-- 任一维度超限 → 返回 429 Too Many Requests
--------------------------------------------------------------------------
local _M = { _VERSION = "2.0.0" }

local limit_req = require("resty.limit.req")

local DICT_NAME = "gw_limiter"

local config = {
    provider_limits = {
        zerion    = { rate = 10, burst = 1 },
        coingecko = { rate = 10, burst = 1 },
        alchemy   = { rate = 20, burst = 1 },
    },
    default_provider_limit = { rate = 10, burst = 1 },
    ip_provider_limit      = { rate = 20,  burst = 1 },
    ip_global_limit        = { rate = 50,  burst = 1 },
}

local stats = {
    total_checked           = 0,
    total_allowed           = 0,
    total_rejected          = 0,
    rejected_by_provider    = 0,
    rejected_by_ip_provider = 0,
    rejected_by_ip_global   = 0,
}

local provider_limiters = {}
local ip_provider_limiter
local ip_global_limiter

local initialized = false
local init_time   = nil

local debug_mode = {
    force_reject           = false,
    force_reject_dimension = nil,
    force_reject_provider  = nil,
}

local function create_limiter(rate, burst)
    local lim, err = limit_req.new(DICT_NAME, rate, burst)
    if not lim then
        ngx.log(ngx.ERR, "[rate_limiter] failed to create limiter: ", err)
        return nil, err
    end
    return lim
end

local function get_provider_limiter(provider)
    if provider_limiters[provider] then
        return provider_limiters[provider]
    end

    local prov_cfg = config.provider_limits[provider] or config.default_provider_limit
    local lim, err = create_limiter(prov_cfg.rate, prov_cfg.burst)
    if not lim then
        return nil, err
    end

    provider_limiters[provider] = lim
    return lim
end

--- 初始化限流器
function _M.init(custom_config)
    if custom_config then
        if custom_config.provider_limits then
            for name, cfg in pairs(custom_config.provider_limits) do
                config.provider_limits[name] = cfg
            end
        end
        if custom_config.default_provider_limit then
            config.default_provider_limit = custom_config.default_provider_limit
        end
        if custom_config.ip_provider_limit then
            config.ip_provider_limit = custom_config.ip_provider_limit
        end
        if custom_config.ip_global_limit then
            config.ip_global_limit = custom_config.ip_global_limit
        end
    end

    -- 清理旧算法残留数据（固定窗口 → 漏桶迁移）
    local dict = ngx.shared[DICT_NAME]
    if dict then
        dict:flush_all()
        dict:flush_expired()
    end

    local err

    ip_provider_limiter, err = create_limiter(
        config.ip_provider_limit.rate,
        config.ip_provider_limit.burst
    )
    if not ip_provider_limiter then
        ngx.log(ngx.ERR, "[rate_limiter] failed to init ip_provider limiter: ", err)
    end

    ip_global_limiter, err = create_limiter(
        config.ip_global_limit.rate,
        config.ip_global_limit.burst
    )
    if not ip_global_limiter then
        ngx.log(ngx.ERR, "[rate_limiter] failed to init ip_global limiter: ", err)
    end

    for name, cfg in pairs(config.provider_limits) do
        local lim
        lim, err = create_limiter(cfg.rate, cfg.burst)
        if lim then
            provider_limiters[name] = lim
        else
            ngx.log(ngx.ERR, "[rate_limiter] failed to init limiter for ", name, ": ", err)
        end
    end

    initialized = true
    init_time   = ngx.now()
    ngx.log(ngx.INFO, "[stability/rate_limiter] initialized (resty.limit.req)")
end

--- 三维度串行限流检查
--- 使用 uncommit 机制：后续维度拒绝时回退前序维度的计数
--- @param provider string Provider 名称
--- @param client_ip string 客户端 IP
--- @return boolean passed true=放行
--- @return string|nil dimension 被限流的维度
--- @return number|nil limit 被限流时的速率阈值
function _M.check(provider, client_ip)
    stats.total_checked = stats.total_checked + 1

    if debug_mode.force_reject then
        if not debug_mode.force_reject_provider
           or debug_mode.force_reject_provider == provider then
            local dim = debug_mode.force_reject_dimension or "provider"
            local limit_val
            if dim == "provider" then
                local cfg = config.provider_limits[provider] or config.default_provider_limit
                limit_val = cfg.rate
            elseif dim == "ip_provider" then
                limit_val = config.ip_provider_limit.rate
            else
                limit_val = config.ip_global_limit.rate
            end
            stats.total_rejected = stats.total_rejected + 1
            if dim == "provider" then
                stats.rejected_by_provider = stats.rejected_by_provider + 1
            elseif dim == "ip_provider" then
                stats.rejected_by_ip_provider = stats.rejected_by_ip_provider + 1
            else
                stats.rejected_by_ip_global = stats.rejected_by_ip_global + 1
            end
            return false, dim, limit_val
        end
    end

    -- 维度 1: Provider 全局限流
    local prov_key = "prov:" .. provider
    local prov_limiter = get_provider_limiter(provider)
    if prov_limiter then
        local delay, prov_err = prov_limiter:incoming(prov_key, true)
        if not delay then
            if prov_err == "rejected" then
                stats.total_rejected = stats.total_rejected + 1
                stats.rejected_by_provider = stats.rejected_by_provider + 1
                local prov_cfg = config.provider_limits[provider]
                                 or config.default_provider_limit
                return false, "provider", prov_cfg.rate
            end
            ngx.log(ngx.ERR, "[rate_limiter] provider check error: ", prov_err)
        end
    end

    -- 维度 2: IP + Provider 限流
    local ip_prov_key = "ip_prov:" .. client_ip .. ":" .. provider
    if ip_provider_limiter then
        local delay, ip_prov_err = ip_provider_limiter:incoming(ip_prov_key, true)
        if not delay then
            if ip_prov_err == "rejected" then
                if prov_limiter then
                    prov_limiter:uncommit(prov_key)
                end
                stats.total_rejected = stats.total_rejected + 1
                stats.rejected_by_ip_provider = stats.rejected_by_ip_provider + 1
                return false, "ip_provider", config.ip_provider_limit.rate
            end
            ngx.log(ngx.ERR, "[rate_limiter] ip_provider check error: ", ip_prov_err)
        end
    end

    -- 维度 3: IP 全局限流
    local ip_key = "ip:" .. client_ip
    if ip_global_limiter then
        local delay, ip_err = ip_global_limiter:incoming(ip_key, true)
        if not delay then
            if ip_err == "rejected" then
                if prov_limiter then
                    prov_limiter:uncommit(prov_key)
                end
                if ip_provider_limiter then
                    ip_provider_limiter:uncommit(ip_prov_key)
                end
                stats.total_rejected = stats.total_rejected + 1
                stats.rejected_by_ip_global = stats.rejected_by_ip_global + 1
                return false, "ip_global", config.ip_global_limit.rate
            end
            ngx.log(ngx.ERR, "[rate_limiter] ip_global check error: ", ip_err)
        end
    end

    stats.total_allowed = stats.total_allowed + 1
    return true
end

--- 查看指定 provider+ip 的所有维度状态（Debug）
--- 使用 incoming(key, false) 模拟探测，不影响实际计数
function _M.get_all_counters(provider, client_ip)
    local result = {}
    client_ip = client_ip or "0.0.0.0"

    local prov_cfg = config.provider_limits[provider] or config.default_provider_limit

    local prov_limiter = get_provider_limiter(provider)
    if prov_limiter then
        local delay, excess = prov_limiter:incoming("prov:" .. provider, false)
        result.provider = {
            key     = "prov:" .. provider,
            excess  = excess or 0,
            rate    = prov_cfg.rate,
            burst   = prov_cfg.burst,
            status  = delay and "ok" or "would_reject",
        }
    end

    if ip_provider_limiter then
        local key = "ip_prov:" .. client_ip .. ":" .. provider
        local delay, excess = ip_provider_limiter:incoming(key, false)
        result.ip_provider = {
            key     = key,
            excess  = excess or 0,
            rate    = config.ip_provider_limit.rate,
            burst   = config.ip_provider_limit.burst,
            status  = delay and "ok" or "would_reject",
        }
    end

    if ip_global_limiter then
        local key = "ip:" .. client_ip
        local delay, excess = ip_global_limiter:incoming(key, false)
        result.ip_global = {
            key     = key,
            excess  = excess or 0,
            rate    = config.ip_global_limit.rate,
            burst   = config.ip_global_limit.burst,
            status  = delay and "ok" or "would_reject",
        }
    end

    return result
end

--- 设置 Debug 强制拒绝模式
function _M.set_debug_force_reject(enabled, dimension, provider)
    debug_mode.force_reject           = enabled
    debug_mode.force_reject_dimension = dimension
    debug_mode.force_reject_provider  = provider
end

--- 获取 Debug 模式状态
function _M.get_debug_mode()
    return debug_mode
end

--- 重置统计计数
function _M.reset_stats()
    stats.total_checked           = 0
    stats.total_allowed           = 0
    stats.total_rejected          = 0
    stats.rejected_by_provider    = 0
    stats.rejected_by_ip_provider = 0
    stats.rejected_by_ip_global   = 0
end

--- 获取统计数据
function _M.get_stats()
    return stats
end

--- 获取当前配置
function _M.get_config()
    return config
end

--- 获取限流器信息（含共享内存使用情况）
function _M.get_info()
    local dict = ngx.shared[DICT_NAME]
    local dict_info = {}
    if dict then
        local capacity = dict:capacity()
        local free     = dict:free_space()
        dict_info = {
            name           = DICT_NAME,
            capacity_bytes = capacity,
            free_bytes     = free,
            usage_percent  = math.floor((1 - free / capacity) * 10000) / 100,
        }
    end

    return {
        algorithm  = "leaky_bucket",
        library    = "resty.limit.req",
        config     = config,
        stats      = stats,
        dict_info  = dict_info,
        debug_mode = debug_mode,
    }
end

--- 获取完整模块状态
function _M.get_status()
    return {
        module         = "rate_limiter",
        version        = _M._VERSION,
        algorithm      = "leaky_bucket",
        implementation = "resty.limit.req",
        status         = initialized and "running" or "not_initialized",
        initialized_at = init_time,
        config         = config,
        stats          = stats,
        debug_mode     = debug_mode,
        dict_info      = _M.get_info().dict_info,
    }
end

return _M
