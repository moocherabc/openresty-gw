--------------------------------------------------------------------------
-- gateway/stability/circuit_breaker/init.lua
-- 三态熔断器：CLOSED → OPEN → HALF_OPEN → CLOSED
-- 基于 ngx.shared.gw_circuit 存储状态，跨 Worker 共享
--------------------------------------------------------------------------
local _M = { _VERSION = "1.0.0" }

local DICT_NAME = "gw_circuit"

local STATE_CLOSED    = 0
local STATE_OPEN      = 1
local STATE_HALF_OPEN = 2

local STATE_NAMES = {
    [STATE_CLOSED]    = "closed",
    [STATE_OPEN]      = "open",
    [STATE_HALF_OPEN] = "half_open",
}

_M.STATE_CLOSED    = STATE_CLOSED
_M.STATE_OPEN      = STATE_OPEN
_M.STATE_HALF_OPEN = STATE_HALF_OPEN
_M.STATE_NAMES     = STATE_NAMES

local DEFAULT_CONFIG = {
    failure_threshold       = 1,
    recovery_timeout        = 30,
    half_open_max_requests  = 3,
    success_threshold       = 2,
}

local provider_configs = {}

local stats = {
    total_checks       = 0,
    total_rejected     = 0,
    total_successes    = 0,
    total_failures     = 0,
    state_transitions  = 0,
}

local initialized = false
local init_time   = nil

local function get_dict()
    return ngx.shared[DICT_NAME]
end

local function key(provider, field)
    return "cb:" .. provider .. ":" .. field
end

local function get_state(dict, provider)
    return dict:get(key(provider, "state")) or STATE_CLOSED
end

local function set_state(dict, provider, state)
    dict:set(key(provider, "state"), state)
end

local function get_config(provider)
    return provider_configs[provider] or DEFAULT_CONFIG
end

--- 初始化：可为每个 provider 配置独立参数
function _M.init(configs)
    if configs then
        for name, cfg in pairs(configs) do
            provider_configs[name] = {
                failure_threshold      = cfg.failure_threshold or DEFAULT_CONFIG.failure_threshold,
                recovery_timeout       = cfg.recovery_timeout or DEFAULT_CONFIG.recovery_timeout,
                half_open_max_requests = cfg.half_open_max_requests or DEFAULT_CONFIG.half_open_max_requests,
                success_threshold      = cfg.success_threshold or DEFAULT_CONFIG.success_threshold,
            }
        end
    end

    initialized = true
    init_time   = ngx.now()
    ngx.log(ngx.INFO, "[stability/circuit_breaker] initialized")
end

--- 请求前检查：true=放行, false=拦截
function _M.before_request(provider)
    local dict = get_dict()
    if not dict then
        return true
    end

    stats.total_checks = stats.total_checks + 1

    local state = get_state(dict, provider)
    local cfg = get_config(provider)

    if state == STATE_CLOSED then
        return true
    end

    if state == STATE_OPEN then
        local last_failure = dict:get(key(provider, "last_failure_time")) or 0
        local elapsed = ngx.now() - last_failure

        if elapsed >= cfg.recovery_timeout then
            set_state(dict, provider, STATE_HALF_OPEN)
            dict:set(key(provider, "half_open_requests"), 0)
            dict:set(key(provider, "half_open_successes"), 0)
            stats.state_transitions = stats.state_transitions + 1
            ngx.log(ngx.INFO, "[circuit_breaker] ", provider,
                    " OPEN → HALF_OPEN after ", elapsed, "s")

            dict:incr(key(provider, "half_open_requests"), 1, 0)
            return true
        end

        stats.total_rejected = stats.total_rejected + 1
        return false, cfg.recovery_timeout - elapsed
    end

    if state == STATE_HALF_OPEN then
        local current = dict:get(key(provider, "half_open_requests")) or 0
        if current >= cfg.half_open_max_requests then
            stats.total_rejected = stats.total_rejected + 1
            return false, cfg.recovery_timeout
        end
        dict:incr(key(provider, "half_open_requests"), 1, 0)
        return true
    end

    return true
end

--- 记录成功
function _M.record_success(provider)
    local dict = get_dict()
    if not dict then return end

    stats.total_successes = stats.total_successes + 1
    local state = get_state(dict, provider)

    if state == STATE_CLOSED then
        dict:set(key(provider, "failures"), 0)
        return
    end

    if state == STATE_HALF_OPEN then
        local cfg = get_config(provider)
        local successes = dict:incr(key(provider, "half_open_successes"), 1, 0)

        if successes >= cfg.success_threshold then
            set_state(dict, provider, STATE_CLOSED)
            dict:set(key(provider, "failures"), 0)
            dict:set(key(provider, "half_open_requests"), 0)
            dict:set(key(provider, "half_open_successes"), 0)
            stats.state_transitions = stats.state_transitions + 1
            ngx.log(ngx.WARN, "[circuit_breaker] ", provider,
                    " HALF_OPEN → CLOSED (recovered)")
        end
    end
end

--- 记录失败
function _M.record_failure(provider)
    local dict = get_dict()
    if not dict then return end

    stats.total_failures = stats.total_failures + 1
    local state = get_state(dict, provider)
    local cfg = get_config(provider)

    if state == STATE_CLOSED then
        local failures = dict:incr(key(provider, "failures"), 1, 0)
        dict:set(key(provider, "last_failure_time"), ngx.now())

        if failures >= cfg.failure_threshold then
            set_state(dict, provider, STATE_OPEN)
            stats.state_transitions = stats.state_transitions + 1
            ngx.log(ngx.ERR, "[circuit_breaker] ", provider,
                    " CLOSED → OPEN (failures=", failures, ")")
        end
        return
    end

    if state == STATE_HALF_OPEN then
        set_state(dict, provider, STATE_OPEN)
        dict:set(key(provider, "last_failure_time"), ngx.now())
        dict:set(key(provider, "half_open_requests"), 0)
        dict:set(key(provider, "half_open_successes"), 0)
        stats.state_transitions = stats.state_transitions + 1
        ngx.log(ngx.ERR, "[circuit_breaker] ", provider,
                " HALF_OPEN → OPEN (probe failed)")
    end
end

--- 强制设置 Provider 的熔断器状态（Debug 用）
function _M.force_state(provider, target_state)
    local dict = get_dict()
    if not dict then
        return false, "shared dict not found"
    end

    local old_state = get_state(dict, provider)
    set_state(dict, provider, target_state)

    if target_state == STATE_CLOSED then
        dict:set(key(provider, "failures"), 0)
        dict:set(key(provider, "half_open_requests"), 0)
        dict:set(key(provider, "half_open_successes"), 0)
    elseif target_state == STATE_OPEN then
        dict:set(key(provider, "last_failure_time"), ngx.now())
    elseif target_state == STATE_HALF_OPEN then
        dict:set(key(provider, "half_open_requests"), 0)
        dict:set(key(provider, "half_open_successes"), 0)
    end

    stats.state_transitions = stats.state_transitions + 1
    ngx.log(ngx.WARN, "[circuit_breaker] DEBUG force_state: ", provider,
            " ", STATE_NAMES[old_state], " → ", STATE_NAMES[target_state])

    return true
end

--- 重置指定 Provider 的所有熔断器数据
function _M.reset(provider)
    local dict = get_dict()
    if not dict then
        return false, "shared dict not found"
    end

    dict:delete(key(provider, "state"))
    dict:delete(key(provider, "failures"))
    dict:delete(key(provider, "last_failure_time"))
    dict:delete(key(provider, "half_open_requests"))
    dict:delete(key(provider, "half_open_successes"))

    ngx.log(ngx.WARN, "[circuit_breaker] DEBUG reset: ", provider)
    return true
end

--- 重置所有 Provider 的熔断器数据
function _M.reset_all()
    local provider_mod = require("gateway.router.provider")
    local names = provider_mod.get_provider_names()
    for _, name in ipairs(names) do
        _M.reset(name)
    end
    return true
end

--- 获取指定 Provider 的熔断器信息
function _M.get_info(provider)
    local dict = get_dict()
    if not dict then
        return { state = "unknown", message = "shared dict not found" }
    end

    local state = get_state(dict, provider)
    local cfg = get_config(provider)
    local failures = dict:get(key(provider, "failures")) or 0
    local last_failure = dict:get(key(provider, "last_failure_time")) or 0

    local info = {
        provider      = provider,
        state         = STATE_NAMES[state] or "unknown",
        state_code    = state,
        failures      = failures,
        config        = cfg,
    }

    if state == STATE_OPEN then
        local elapsed = ngx.now() - last_failure
        info.time_in_open    = math.floor(elapsed * 100) / 100
        info.recovery_in     = math.max(0, math.floor((cfg.recovery_timeout - elapsed) * 100) / 100)
    end

    if state == STATE_HALF_OPEN then
        info.half_open_requests  = dict:get(key(provider, "half_open_requests")) or 0
        info.half_open_successes = dict:get(key(provider, "half_open_successes")) or 0
    end

    return info
end

--- 获取所有 Provider 的熔断器信息
function _M.get_all_info()
    local provider_mod = require("gateway.router.provider")
    local names = provider_mod.get_provider_names()
    local result = {}
    for _, name in ipairs(names) do
        result[name] = _M.get_info(name)
    end
    return result
end

--- 获取统计数据
function _M.get_stats()
    return stats
end

--- 获取完整模块状态
function _M.get_status()
    local dict = get_dict()
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
        module         = "circuit_breaker",
        version        = _M._VERSION,
        status         = initialized and "running" or "not_initialized",
        initialized_at = init_time,
        stats          = stats,
        providers      = _M.get_all_info(),
        dict_info      = dict_info,
    }
end

return _M
