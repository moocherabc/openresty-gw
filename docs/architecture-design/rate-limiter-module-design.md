# 限流器子模块技术设计文档

> **版本**: v2.0.0 — 基于 `resty.limit.req` 漏桶算法重构  
> **所属模块**: `gateway.stability.rate_limiter`  
> **父文档**: [stability-module-design.md](stability-module-design.md) / [stability-submodule-design.md](stability-submodule-design.md)

---

## 1. 模块概述

限流器子模块提供 **多维度并行限流** 能力，在流量过载时保护上游 Provider 和网关自身。

### 1.1 核心特性

| 特性 | 说明 |
|------|------|
| 算法 | 漏桶算法（Leaky Bucket），基于 OpenResty 内置 `resty.limit.req` |
| 维度 | Provider 全局 / IP+Provider / IP 全局 — 三维度串行检查 |
| 突发 | 每个维度支持 `burst` 突发容量，允许短期流量峰值 |
| 公平性 | 后序维度拒绝时，通过 `uncommit()` 回退前序维度计数 |
| 调试 | 提供强制拒绝模式、漏桶状态探测、模拟超限响应 |
| 独立性 | 可独立运行、独立测试，提供 status/debug/health 接口 |

### 1.2 与 v1.0 的区别

| 对比项 | v1.0（固定窗口） | v2.0（漏桶） |
|--------|------------------|--------------|
| 算法 | `ngx.shared.DICT:incr()` 固定窗口计数器 | `resty.limit.req` 漏桶（Leaky Bucket） |
| 边界效应 | 窗口边界处可能突发 2x 流量 | 平滑限流，无窗口边界问题 |
| 突发处理 | 无 burst 支持 | 支持 burst 突发容量 |
| 公平性 | 无 uncommit | 后序维度拒绝时 uncommit 前序维度 |
| 数据格式 | `number`（`dict:incr()` 存储） | FFI `struct`（二进制存储） |
| Debug | 直接读取计数器 | 通过 `incoming(key, false)` 探测状态 |

---

## 2. 架构设计

### 2.1 模块层次结构

```
lua/gateway/stability/rate_limiter/
├── init.lua       核心限流逻辑（resty.limit.req 漏桶算法）
├── status.lua     独立状态/统计查询 API
└── debug.lua      调试接口（探测、模拟、强制拒绝）
```

### 2.2 漏桶算法原理

```
               ┌─────────────────────────────────┐
               │           漏  桶                 │
               │                                  │
  请求流入 ──► │  ┌───┐ ┌───┐ ┌───┐ ┌───┐       │ ──► 以 rate 速率匀速流出
  (rate+burst) │  │ R │ │ R │ │ R │ │ R │       │     (处理请求)
               │  └───┘ └───┘ └───┘ └───┘       │
               │  ◄──── excess (积压量) ────►    │
               │                                  │
               │  当 excess > burst 时 → REJECT   │
               └─────────────────────────────────┘
                        │
                   溢出 → 429
```

**关键参数**：

| 参数 | 说明 |
|------|------|
| `rate` | 漏桶稳态流出速率（请求/秒） |
| `burst` | 桶容量（允许的最大突发请求数） |
| `excess` | 当前积压量（随时间按 rate 速率衰减） |

**判定逻辑**：

```
excess = max(上次积压 - rate × 经过时间 + 1, 0)
if excess > burst then
    → REJECT (429)
else
    → ALLOW (放行)
end
```

### 2.3 多维度限流策略

```
请求到达
  │
  ├─► 维度 1: Provider 全局限流
  │     key = "prov:<provider>"
  │     rate / burst 按 provider 独立配置
  │     用途：保护单个上游 Provider 不被过载
  │
  ├─► 维度 2: IP + Provider 限流
  │     key = "ip_prov:<ip>:<provider>"
  │     rate = 20/s, burst = 10 (可配置)
  │     用途：防止单个 IP 独占某 Provider 配额
  │
  └─► 维度 3: IP 全局限流
        key = "ip:<ip>"
        rate = 50/s, burst = 25 (可配置)
        用途：防止单个 IP 全局恶意请求

  任一维度超限 → 触发 uncommit 机制 → 返回 429
```

### 2.4 uncommit 公平性机制

```
维度 1 (Provider) ──PASS──► 维度 2 (IP+Provider) ──PASS──► 维度 3 (IP Global) ──REJECT
                                                                    │
                                                                    ▼
                                                            uncommit 维度 1
                                                            uncommit 维度 2
                                                            return 429
```

当后序维度拒绝请求时，调用 `resty.limit.req:uncommit()` 回退前序维度的计数，避免被拒绝的请求"白白消耗"前序维度的配额。

### 2.5 请求生命周期集成

```
┌─────────────────────────────────────────────────────────┐
│                access.lua (access_by_lua)                 │
│                                                          │
│  1. router.process_request()     路由匹配                │
│  2. stability.check_request()                            │
│       │                                                  │
│       └─► rate_limiter.check(provider, client_ip)        │
│             │                                            │
│             ├─ 维度 1: Provider 全局  (resty.limit.req)  │
│             ├─ 维度 2: IP + Provider  (resty.limit.req)  │
│             ├─ 维度 3: IP 全局        (resty.limit.req)  │
│             │                                            │
│             ├─ 全部通过 → 继续熔断检查                    │
│             └─ 任一超限 → uncommit → degradation → 429   │
└─────────────────────────────────────────────────────────┘
```

---

## 3. 文件路径规范

```
lua/gateway/stability/rate_limiter/
├── init.lua                    # 核心逻辑：三维度漏桶限流
│                               #   _M.init(config)
│                               #   _M.check(provider, client_ip)
│                               #   _M.get_all_counters(provider, ip)
│                               #   _M.set_debug_force_reject(...)
│                               #   _M.get_stats() / get_config() / get_status()
│
├── status.lua                  # 独立状态查询 API
│                               #   _M.handle()       → GET /admin/stability/rate-limiter/status
│                               #   _M.health_check() → GET /admin/stability/rate-limiter/health
│
└── debug.lua                   # 调试接口
                                #   _M.handle()       → GET/POST /admin/stability/rate-limiter/debug
                                #   Actions: get_counters, reset_stats, simulate_exceeded,
                                #            force_reject, clear_force_reject, get_debug_mode
```

**require 路径映射**：

| require 路径 | 实际文件 |
|-------------|---------|
| `gateway.stability.rate_limiter` | `lua/gateway/stability/rate_limiter/init.lua` |
| `gateway.stability.rate_limiter.status` | `lua/gateway/stability/rate_limiter/status.lua` |
| `gateway.stability.rate_limiter.debug` | `lua/gateway/stability/rate_limiter/debug.lua` |

---

## 4. 核心代码设计

### 4.1 数据结构

**共享内存字典**：`ngx.shared.gw_limiter`（10MB）

每个限流维度的 key 对应一个 `resty.limit.req` 内部 FFI 结构体：

```c
struct lua_resty_limit_req_rec {
    unsigned long  excess;   /* 当前积压量 × 1000 */
    uint64_t       last;     /* 最近一次请求时间 (ms) */
};
```

**Key 命名规范**：

| 维度 | Key 格式 | 示例 |
|------|---------|------|
| Provider 全局 | `prov:<provider>` | `prov:zerion` |
| IP + Provider | `ip_prov:<ip>:<provider>` | `ip_prov:192.168.1.1:zerion` |
| IP 全局 | `ip:<ip>` | `ip:192.168.1.1` |

### 4.2 限流器实例管理

```lua
-- 每个速率配置对应一个 resty.limit.req 实例
-- Provider 限流器：按 provider 缓存（不同 provider 可能有不同 rate/burst）
local provider_limiters = {}   -- { [provider] = resty.limit.req_instance }

-- IP+Provider / IP 全局：全局共享实例（同一速率，不同 key 区分）
local ip_provider_limiter      -- rate=20, burst=10
local ip_global_limiter        -- rate=50, burst=25
```

### 4.3 核心检查流程

```lua
function _M.check(provider, client_ip)
    stats.total_checked = stats.total_checked + 1

    -- Debug 强制拒绝模式
    if debug_mode.force_reject then ... end

    -- 维度 1: Provider 全局
    local prov_key = "prov:" .. provider
    local delay, err = prov_limiter:incoming(prov_key, true)
    if not delay and err == "rejected" then
        return false, "provider", rate
    end

    -- 维度 2: IP + Provider
    local ip_prov_key = "ip_prov:" .. client_ip .. ":" .. provider
    local delay, err = ip_provider_limiter:incoming(ip_prov_key, true)
    if not delay and err == "rejected" then
        prov_limiter:uncommit(prov_key)       -- 回退维度 1
        return false, "ip_provider", rate
    end

    -- 维度 3: IP 全局
    local ip_key = "ip:" .. client_ip
    local delay, err = ip_global_limiter:incoming(ip_key, true)
    if not delay and err == "rejected" then
        prov_limiter:uncommit(prov_key)       -- 回退维度 1
        ip_provider_limiter:uncommit(ip_prov_key) -- 回退维度 2
        return false, "ip_global", rate
    end

    stats.total_allowed = stats.total_allowed + 1
    return true
end
```

### 4.4 配置参数

```lua
local config = {
    provider_limits = {
        zerion    = { rate = 100, burst = 50  },  -- 100 req/s, 允许突发 50
        coingecko = { rate = 100, burst = 50  },
        alchemy   = { rate = 200, burst = 100 },
    },
    default_provider_limit = { rate = 100, burst = 50  },
    ip_provider_limit      = { rate = 20,  burst = 10  },
    ip_global_limit        = { rate = 50,  burst = 25  },
}
```

| 参数 | 类型 | 说明 |
|------|------|------|
| `rate` | number | 漏桶稳态速率（请求/秒） |
| `burst` | number | 突发容量（允许超过 rate 的额外请求数） |

**实际瞬时吞吐量**：`rate + burst`（满桶时的瞬时最大值）  
**持续吞吐量**：`rate`（长期稳态值）

### 4.5 统计数据

```lua
local stats = {
    total_checked           = 0,  -- check() 总调用次数
    total_allowed           = 0,  -- 放行总次数
    total_rejected          = 0,  -- 拒绝总次数
    rejected_by_provider    = 0,  -- Provider 维度拒绝次数
    rejected_by_ip_provider = 0,  -- IP+Provider 维度拒绝次数
    rejected_by_ip_global   = 0,  -- IP 全局维度拒绝次数
}
```

> 统计数据为 Worker 进程级别，不跨进程共享。

### 4.6 Debug 模式

```lua
local debug_mode = {
    force_reject           = false,  -- 是否启用强制拒绝
    force_reject_dimension = nil,    -- 强制拒绝的维度
    force_reject_provider  = nil,    -- 限定的 provider（nil=全部）
}
```

启用后，所有（或指定 provider 的）限流检查直接返回拒绝，用于测试降级响应链路。

---

## 5. Admin API 端点

### 5.1 状态查询

**GET** `/admin/stability/rate-limiter/status`

返回完整模块状态，包含配置、统计、共享内存使用情况。

**响应示例**：

```json
{
    "module": "rate_limiter",
    "version": "2.0.0",
    "algorithm": "leaky_bucket",
    "implementation": "resty.limit.req",
    "status": "running",
    "initialized_at": 1710000000.123,
    "config": {
        "provider_limits": {
            "zerion": { "rate": 100, "burst": 50 }
        },
        "default_provider_limit": { "rate": 100, "burst": 50 },
        "ip_provider_limit": { "rate": 20, "burst": 10 },
        "ip_global_limit": { "rate": 50, "burst": 25 }
    },
    "stats": {
        "total_checked": 1000,
        "total_allowed": 980,
        "total_rejected": 20,
        "rejected_by_provider": 5,
        "rejected_by_ip_provider": 10,
        "rejected_by_ip_global": 5
    },
    "debug_mode": {
        "force_reject": false
    },
    "dict_info": {
        "name": "gw_limiter",
        "capacity_bytes": 10485760,
        "free_bytes": 10400000,
        "usage_percent": 0.82
    },
    "server_info": {
        "worker_pid": 12345,
        "worker_id": 0,
        "worker_count": 4,
        "ngx_time": 1710000100.456
    }
}
```

### 5.2 Debug 接口

**GET/POST** `/admin/stability/rate-limiter/debug?action=<action>`

#### 5.2.1 查看漏桶状态

```bash
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=zerion&ip=127.0.0.1"
```

**响应**：

```json
{
    "action": "get_counters",
    "provider": "zerion",
    "client_ip": "127.0.0.1",
    "algorithm": "leaky_bucket (resty.limit.req)",
    "note": "excess includes a simulated probe request (commit=false)",
    "counters": {
        "provider": {
            "key": "prov:zerion",
            "excess": 0.5,
            "rate": 100,
            "burst": 50,
            "status": "ok"
        },
        "ip_provider": {
            "key": "ip_prov:127.0.0.1:zerion",
            "excess": 0,
            "rate": 20,
            "burst": 10,
            "status": "ok"
        },
        "ip_global": {
            "key": "ip:127.0.0.1",
            "excess": 1.2,
            "rate": 50,
            "burst": 25,
            "status": "ok"
        }
    }
}
```

#### 5.2.2 模拟超限

```bash
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=provider"
```

#### 5.2.3 启用强制拒绝

```bash
# 强制所有 Provider 的请求被限流
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=force_reject&dimension=provider"

# 仅强制 zerion 被限流
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=force_reject&dimension=provider&provider=zerion"
```

#### 5.2.4 关闭强制拒绝

```bash
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=clear_force_reject"
```

#### 5.2.5 重置统计

```bash
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=reset_stats"
```

#### 5.2.6 查看 Debug 模式状态

```bash
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_debug_mode"
```

### 5.3 Actions 汇总

| action | 方法 | 参数 | 说明 |
|--------|------|------|------|
| `get_counters` | GET | `provider` (必填), `ip` | 查看三维度漏桶状态 |
| `reset_stats` | POST | - | 重置统计计数 |
| `simulate_exceeded` | GET | `provider`, `dimension` | 预览降级响应内容 |
| `force_reject` | POST | `dimension`, `provider` | 启用强制拒绝模式 |
| `clear_force_reject` | POST | - | 关闭强制拒绝模式 |
| `get_debug_mode` | GET | - | 查看当前 Debug 模式 |

---

## 6. 实现步骤

### Step 1: 替换限流算法

- 移除固定窗口计数器逻辑（`ngx.shared.DICT:incr()`）
- 引入 `resty.limit.req` 漏桶算法
- 配置增加 `burst` 参数

### Step 2: 实现限流器实例管理

- Provider 维度：按 provider 名称缓存独立的 `resty.limit.req` 实例
- IP+Provider / IP 全局维度：各使用一个全局共享实例
- `init()` 阶段预创建所有已知 provider 的限流器

### Step 3: 实现 uncommit 公平性机制

- 维度 2 拒绝 → uncommit 维度 1
- 维度 3 拒绝 → uncommit 维度 1 + 2
- 避免被拒绝请求消耗前序维度配额

### Step 4: 增强 Debug 接口

- 新增 `force_reject` / `clear_force_reject` 强制拒绝模式
- `get_counters` 使用 `incoming(key, false)` 无副作用探测漏桶状态
- `simulate_exceeded` 预览包含 `burst` 字段的降级响应

### Step 5: 更新状态查询接口

- 状态返回中增加 `algorithm`、`implementation` 字段
- 健康检查增加 Debug 模式异常检测

### Step 6: 初始化时清理旧数据

- `init()` 中执行 `dict:flush_all()` 清理 v1.0 固定窗口的残留数据
- 漏桶 FFI 结构与旧 number 格式不兼容，必须清理

---

## 7. 与其他模块的交互

### 7.1 协调器调用链

```lua
-- stability/init.lua
function _M.check_request()
    local rl_ok, rl_dimension, rl_limit = rate_limiter.check(provider, client_ip)
    if not rl_ok then
        ngx.ctx.stability_action = {
            type      = "rate_limited",
            provider  = provider,
            dimension = rl_dimension,
        }
        return degradation.respond_rate_limited(provider, rl_dimension, rl_limit)
    end
    -- ... 继续熔断检查
end
```

### 7.2 Prometheus 指标对接

限流器本身不写 Prometheus；通过 `ngx.ctx.stability_action` 传递给 `monitor/collector.lua`：

| 字段 | 示例值 | 说明 |
|------|--------|------|
| `type` | `rate_limited` | 动作类型 |
| `dimension` | `provider` / `ip_provider` / `ip_global` | 限流维度 |

对应 Prometheus 指标：`gw_rate_limiter_rejected_total{provider, dimension}`

### 7.3 降级器联动

限流触发后由 `degradation.respond_rate_limited()` 构造 429 响应：

```json
{
    "error": "rate_limited",
    "message": "...",
    "provider": "zerion",
    "dimension": "provider",
    "limit": 100,
    "retry_after": 1
}
```

---

## 8. 测试方案

### 8.1 状态查询测试

```bash
# 查看限流器完整状态
curl http://localhost:8080/admin/stability/rate-limiter/status | python3 -m json.tool
```

### 8.2 限流触发测试

```bash
# 快速发送大量请求测试限流
for i in $(seq 1 200); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/coingecko/api/v3/ping
done

# 查看限流器统计（观察 rejected 计数增长）
curl http://localhost:8080/admin/stability/rate-limiter/status | python3 -m json.tool
```

### 8.3 漏桶状态探测

```bash
# 查看 zerion 当前漏桶状态
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=zerion&ip=127.0.0.1"
```

### 8.4 强制拒绝测试

```bash
# 1. 启用强制拒绝 zerion
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=force_reject&dimension=provider&provider=zerion"

# 2. 发送请求验证被限流（期望 429）
curl -v http://localhost:8080/zerion/v1/test

# 3. 查看限流统计
curl http://localhost:8080/admin/stability/rate-limiter/status

# 4. 关闭强制拒绝
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=clear_force_reject"

# 5. 验证请求恢复正常
curl -v http://localhost:8080/zerion/v1/test
```

### 8.5 模拟超限预览

```bash
# 预览 Provider 维度超限的降级响应
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=provider"

# 预览 IP+Provider 维度超限
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=ip_provider"

# 预览 IP 全局维度超限
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=ip_global"
```

### 8.6 综合场景测试

```bash
# 1. 重置统计
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=reset_stats"

# 2. 启用 zerion 强制拒绝
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=force_reject&dimension=provider&provider=zerion"

# 3. 发送请求验证 429 + 降级响应
curl -v http://localhost:8080/zerion/v1/test

# 4. 检查聚合状态（限流+降级统计）
curl http://localhost:8080/admin/stability/status | python3 -m json.tool

# 5. 关闭 Debug 并重置
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=clear_force_reject"
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=reset_stats"
```

---

## 9. 配置参考

### 9.1 nginx.conf 共享内存

```nginx
lua_shared_dict gw_limiter 10m;   # 限流器漏桶状态存储
```

### 9.2 nginx.conf Admin 端点

```nginx
# 限流器状态查询
location = /admin/stability/rate-limiter/status {
    content_by_lua_block {
        local status = require("gateway.stability.rate_limiter.status")
        status.handle()
    }
}

# 限流器调试接口
location = /admin/stability/rate-limiter/debug {
    content_by_lua_block {
        local debug = require("gateway.stability.rate_limiter.debug")
        debug.handle()
    }
}
```

### 9.3 自定义限流配置

在 `init_by_lua` 阶段通过 `stability.init()` 传入：

```lua
stability.init({
    rate_limiter = {
        provider_limits = {
            zerion    = { rate = 100, burst = 50  },
            coingecko = { rate = 100, burst = 50  },
            alchemy   = { rate = 200, burst = 100 },
            new_provider = { rate = 150, burst = 75 },
        },
        default_provider_limit = { rate = 100, burst = 50  },
        ip_provider_limit      = { rate = 20,  burst = 10  },
        ip_global_limit        = { rate = 50,  burst = 25  },
    },
})
```
