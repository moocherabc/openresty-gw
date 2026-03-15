# 稳定性模块技术设计文档

> **子模块拆分详细设计**见 → [stability-submodule-design.md](stability-submodule-design.md)

## 1. 模块概述

稳定性模块提供熔断、限流、降级三大核心能力，在上游服务异常或流量过载时保障网关自身的可用性。

每个子模块独立运行、独立测试，提供状态查询接口和 Debug 调试接口。

### 1.1 模块职责

| 子模块 | 职责 |
|--------|------|
| 熔断器 (circuit_breaker) | 当 Provider 持续出错时快速失败，避免雪崩 |
| 限流器 (rate_limiter) | 多维度并行限流：Provider 维度 + IP 维度 |
| 降级器 (degradation) | 上游不可用时返回友好提示，支持 Retry-After |

### 1.2 介入时机

```
请求进入
  │
  ├─► access_by_lua (路由匹配之后)
  │      │
  │      ├─ 1. rate_limiter.check()   ── 限流检查 → 触发则降级 429
  │      ├─ 2. circuit_breaker.check() ── 熔断检查 → 触发则降级 503
  │      └─ 3. 放行 → proxy_pass
  │
  └─► log_by_lua (响应完成后)
         │
         ├─ status >= 500 → circuit_breaker.record_failure()
         └─ status <  500 → circuit_breaker.record_success()
```

---

## 2. 架构设计

### 2.1 模块层次结构

```
                        ┌───────────────────────────────┐
                        │     stability/init.lua         │
                        │       模块协调器               │
                        │  check_request / after_request │
                        └──────┬────────┬────────┬──────┘
                               │        │        │
                 ┌─────────────┤        │        ├─────────────┐
                 ▼             │        ▼        │             ▼
    ┌────────────────────┐     │  ┌───────────────────┐  ┌───────────────────┐
    │  circuit_breaker/  │     │  │  rate_limiter/     │  │  degradation/     │
    │  ├── init.lua      │     │  │  ├── init.lua      │  │  ├── init.lua     │
    │  │  (核心状态机)   │     │  │  │  (计数器限流)   │  │  │  (响应构造)    │
    │  ├── status.lua    │     │  │  ├── status.lua    │  │  ├── status.lua   │
    │  │  (状态+统计)    │     │  │  │  (状态+统计)    │  │  │  (状态+统计)   │
    │  └── debug.lua     │     │  │  └── debug.lua     │  │  └── debug.lua    │
    │     (强制状态/模拟)│     │  │     (重置/模拟)    │  │     (测试响应)    │
    └────────────────────┘     │  └───────────────────┘  └───────────────────┘
                               │
                        ┌──────┴──────┐
                        │ status.lua  │
                        │ 聚合状态API │
                        └─────────────┘
```

### 2.2 请求生命周期集成

```
┌─────────────────────────────────────────────────────────────────┐
│                      access.lua (access_by_lua)                  │
│                                                                  │
│  1. router.process_request()     路由匹配                        │
│  2. stability.check_request()    稳定性检查                      │
│       │                                                          │
│       ├─► rate_limiter.check(provider, ip)                       │
│       │     ├─ Provider 维度限流  (gw_limiter dict)              │
│       │     ├─ IP + Provider 维度限流                            │
│       │     └─ IP 全局维度限流                                   │
│       │                                                          │
│       ├─► circuit_breaker.before_request(provider)               │
│       │     ├─ CLOSED  → 放行                                    │
│       │     ├─ OPEN    → 快速失败                                │
│       │     └─ HALF_OPEN → 有限放行                              │
│       │                                                          │
│       └─► 如被拦截 → degradation.respond(type, provider)         │
│                         └─ 返回友好 JSON 错误 + Retry-After      │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                       log.lua (log_by_lua)                       │
│                                                                  │
│  stability.after_request()                                       │
│   ├─ status < 500 → circuit_breaker.record_success(provider)    │
│   └─ status >= 500 → circuit_breaker.record_failure(provider)   │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 熔断器状态机

```
            失败次数 ≥ failure_threshold
    ┌────────────────────────────────┐
    │                                ▼
 ┌──────┐                       ┌──────┐
 │CLOSED│                       │ OPEN │ ◄── 快速失败，不转发
 └──┬───┘                       └──┬───┘
    ▲                               │
    │ half_open 内连续               │ 等待 recovery_timeout
    │ 成功 ≥ success_threshold       │
    │                               ▼
    │                          ┌─────────┐
    └──────────────────────────│HALF_OPEN│ ◄── 允许少量探测请求
                               └────┬────┘
                                    │ 探测失败 → 回到 OPEN
                                    └───────────────┐
                                                    ▼
                                                 ┌──────┐
                                                 │ OPEN │
                                                 └──────┘
```

**熔断器配置**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| failure_threshold | 5 | 连续失败次数触发熔断 |
| recovery_timeout | 30s | OPEN 状态持续时间，之后进入 HALF_OPEN |
| half_open_max_requests | 3 | HALF_OPEN 允许的最大探测请求数 |
| success_threshold | 2 | HALF_OPEN 中连续成功次数，恢复为 CLOSED |

### 2.4 多维度限流策略

```
请求到达
  │
  ├─► 维度 1: Provider 全局限流
  │     key = "rl:prov:<provider>:<window>"
  │     limit = 100 req/s (可配置)
  │
  ├─► 维度 2: IP + Provider 限流
  │     key = "rl:ip_prov:<ip>:<provider>:<window>"
  │     limit = 20 req/s (可配置)
  │
  └─► 维度 3: IP 全局限流
        key = "rl:ip:<ip>:<window>"
        limit = 50 req/s (可配置)

  任一维度触发 → 返回 429 Too Many Requests
```

**限流算法**：漏桶算法（Leaky Bucket），基于 OpenResty 内置 `resty.limit.req` 模块，每个维度支持 `burst` 突发容量

> 详细设计见 → [rate-limiter-module-design.md](rate-limiter-module-design.md)

### 2.5 降级响应设计

| 场景 | HTTP 状态码 | error_type | 响应示例 |
|------|-------------|------------|----------|
| 限流触发 | 429 | `rate_limited` | `{"error":"rate_limited","message":"...","retry_after":1}` |
| 熔断触发 | 503 | `circuit_open` | `{"error":"circuit_open","message":"...","retry_after":30}` |
| 上游不可用 | 503 | `service_degraded` | `{"error":"service_degraded","message":"...","provider":"zerion"}` |

---

## 3. 文件路径规范

```
lua/
├── access.lua                              # access 阶段入口
├── log.lua                                 # log 阶段入口
├── circuit_breaker.lua                     # 兼容入口（代理到 stability 子模块）
└── gateway/
    └── stability/
        ├── init.lua                        # 模块协调器（串联限流→熔断检查）
        ├── status.lua                      # 聚合状态查询 API
        │
        ├── circuit_breaker/                # ★ 熔断器子模块
        │   ├── init.lua                    # 核心逻辑：三态状态机
        │   ├── status.lua                  # 独立状态/统计查询 API
        │   └── debug.lua                   # Debug：强制状态、模拟故障
        │
        ├── rate_limiter/                   # ★ 限流器子模块
        │   ├── init.lua                    # 核心逻辑：多维度固定窗口计数器
        │   ├── status.lua                  # 独立状态/统计查询 API
        │   └── debug.lua                   # Debug：重置计数、模拟超限
        │
        └── degradation/                    # ★ 降级器子模块
            ├── init.lua                    # 核心逻辑：构造友好降级 JSON 响应
            ├── status.lua                  # 独立状态/统计查询 API
            └── debug.lua                   # Debug：测试各场景降级响应

docs/
├── stability-module-design.md              # 本文档
└── stability-submodule-design.md           # 子模块拆分详细设计
```

**require 路径映射**（Lua 自动查找 `init.lua`，向后兼容）：

| require 路径 | 实际文件 |
|-------------|---------|
| `gateway.stability` | `lua/gateway/stability/init.lua` |
| `gateway.stability.circuit_breaker` | `lua/gateway/stability/circuit_breaker/init.lua` |
| `gateway.stability.circuit_breaker.status` | `lua/gateway/stability/circuit_breaker/status.lua` |
| `gateway.stability.circuit_breaker.debug` | `lua/gateway/stability/circuit_breaker/debug.lua` |
| `gateway.stability.rate_limiter` | `lua/gateway/stability/rate_limiter/init.lua` |
| `gateway.stability.rate_limiter.status` | `lua/gateway/stability/rate_limiter/status.lua` |
| `gateway.stability.rate_limiter.debug` | `lua/gateway/stability/rate_limiter/debug.lua` |
| `gateway.stability.degradation` | `lua/gateway/stability/degradation/init.lua` |
| `gateway.stability.degradation.status` | `lua/gateway/stability/degradation/status.lua` |
| `gateway.stability.degradation.debug` | `lua/gateway/stability/degradation/debug.lua` |

---

## 4. 核心代码设计

### 4.1 熔断器 (`circuit_breaker/init.lua`)

**存储（`ngx.shared.gw_circuit`）**：

| Key | 类型 | 说明 |
|-----|------|------|
| `cb:<provider>:state` | number | 当前状态 (0=CLOSED, 1=OPEN, 2=HALF_OPEN) |
| `cb:<provider>:failures` | number | 连续失败计数 |
| `cb:<provider>:last_failure_time` | number | 最近一次失败的时间戳 |
| `cb:<provider>:half_open_requests` | number | HALF_OPEN 期间已放行的请求数 |
| `cb:<provider>:half_open_successes` | number | HALF_OPEN 期间连续成功数 |

**核心方法**：

| 方法 | 说明 |
|------|------|
| `before_request(provider)` | 请求前检查：返回 true=放行, false=拦截 |
| `record_success(provider)` | 记录成功：HALF_OPEN 计数，达标则恢复 CLOSED |
| `record_failure(provider)` | 记录失败：CLOSED 累计，达标则进入 OPEN |
| `get_info(provider)` | 获取指定 Provider 的熔断器状态 |
| `get_all_info()` | 获取所有 Provider 的熔断器信息 |
| `get_stats()` | 获取统计数据（checks/rejected/successes/failures/transitions）|
| `get_status()` | 获取完整模块状态（含 providers、stats、dict_info） |
| `force_state(provider, state)` | Debug：强制设置 Provider 熔断器状态 |
| `reset(provider)` | Debug：重置指定 Provider 所有熔断器数据 |
| `reset_all()` | Debug：重置所有 Provider 的熔断器数据 |

**统计数据（进程内 Worker 级别）**：

```lua
local stats = {
    total_checks       = 0,   -- before_request 总调用次数
    total_rejected     = 0,   -- 被拦截总次数
    total_successes    = 0,   -- record_success 总次数
    total_failures     = 0,   -- record_failure 总次数
    state_transitions  = 0,   -- 状态变迁总次数
}
```

### 4.2 限流器 (`rate_limiter/init.lua`)

**算法**：漏桶（Leaky Bucket），基于 `resty.limit.req`，支持 `burst` 突发容量

**核心方法**：

| 方法 | 说明 |
|------|------|
| `check(provider, client_ip)` | 三维度串行检查，使用 uncommit 回退机制 |
| `get_info()` | 获取限流器配置、统计和共享内存使用情况 |
| `get_stats()` | 获取统计计数 |
| `get_config()` | 获取当前限流配置 |
| `get_status()` | 获取完整模块状态 |
| `get_all_counters(provider, ip)` | Debug：通过 incoming(key,false) 探测漏桶状态 |
| `set_debug_force_reject(enabled, dim, prov)` | Debug：启用/关闭强制拒绝模式 |
| `get_debug_mode()` | Debug：获取当前 Debug 模式状态 |
| `reset_stats()` | Debug：重置统计计数 |

**限流配置**：

```lua
{
    provider_limits = {
        zerion    = { rate = 100, burst = 50  },
        coingecko = { rate = 100, burst = 50  },
        alchemy   = { rate = 200, burst = 100 },
    },
    default_provider_limit = { rate = 100, burst = 50  },
    ip_provider_limit      = { rate = 20,  burst = 10  },
    ip_global_limit        = { rate = 50,  burst = 25  },
}
```

**统计数据**：

```lua
local stats = {
    total_checked           = 0,
    total_allowed           = 0,
    total_rejected          = 0,
    rejected_by_provider    = 0,
    rejected_by_ip_provider = 0,
    rejected_by_ip_global   = 0,
}
```

### 4.3 降级器 (`degradation/init.lua`)

**核心方法**：

| 方法 | 说明 |
|------|------|
| `respond_rate_limited(provider, dimension, limit)` | 限流降级响应 (429)，终止请求 |
| `respond_circuit_open(provider, retry_after)` | 熔断降级响应 (503)，终止请求 |
| `respond_service_degraded(provider)` | 上游不可用降级响应 (503)，终止请求 |
| `build_rate_limited_body(provider, dimension, limit)` | Debug：构建限流降级响应体（仅预览） |
| `build_circuit_open_body(provider, retry_after)` | Debug：构建熔断降级响应体（仅预览） |
| `build_service_degraded_body(provider)` | Debug：构建上游不可用响应体（仅预览） |
| `get_stats()` | 获取触发统计 |
| `get_recent_events(limit)` | 获取最近降级事件（最多 50 条） |
| `reset_stats()` | Debug：重置统计和事件记录 |

**统计数据**：

```lua
local stats = {
    total_responses        = 0,
    rate_limited_count     = 0,
    circuit_open_count     = 0,
    service_degraded_count = 0,
}
```

### 4.4 协调器 (`stability/init.lua`)

```lua
function _M.check_request()
    -- 1. rate_limiter.check(provider, client_ip)
    --    失败 → degradation.respond_rate_limited()
    -- 2. circuit_breaker.before_request(provider)
    --    失败 → degradation.respond_circuit_open()
    -- 3. 全部通过 → return true
end

function _M.after_request()
    -- status >= 500 → circuit_breaker.record_failure(provider)
    -- status <  500 → circuit_breaker.record_success(provider)
end

function _M.get_status()
    -- 聚合三个子模块的 get_status() 返回值
end
```

---

## 5. Admin API 端点

| 端点 | 方法 | 说明 |
|------|------|------|
| `/admin/stability/status` | GET | 聚合所有子模块状态 |
| `/admin/stability/health` | GET | 模块健康检查（含问题检测） |
| `/admin/stability/circuit-breaker/status` | GET | 熔断器独立状态与统计 |
| `/admin/stability/circuit-breaker/debug` | GET/POST | 熔断器调试（force_open/force_closed/force_half_open/reset/reset_all/simulate_failures/get_info） |
| `/admin/stability/rate-limiter/status` | GET | 限流器独立状态与统计 |
| `/admin/stability/rate-limiter/debug` | GET/POST | 限流器调试（get_counters/reset_stats/simulate_exceeded） |
| `/admin/stability/degradation/status` | GET | 降级器独立状态与统计 |
| `/admin/stability/degradation/debug` | GET/POST | 降级器调试（test_rate_limited/test_circuit_open/test_service_degraded/recent_events/reset_stats） |
| `/admin/circuit` | GET | 兼容旧端点 |

---

## 6. 实现步骤

### Step 1: 创建子模块目录结构
- 将原 `circuit_breaker.lua`、`rate_limiter.lua`、`degradation.lua` 拆分为独立目录
- 各子模块核心逻辑放在 `init.lua` 中，保持 require 路径向后兼容

### Step 2: 实现熔断器子模块
- `circuit_breaker/init.lua` — 三态状态机 + 统计计数 + force_state/reset 方法
- `circuit_breaker/status.lua` — 独立状态查询接口
- `circuit_breaker/debug.lua` — 调试接口（强制状态、模拟故障、重置）

### Step 3: 实现限流器子模块
- `rate_limiter/init.lua` — 多维度固定窗口计数器 + 计数器查询方法
- `rate_limiter/status.lua` — 独立状态查询接口
- `rate_limiter/debug.lua` — 调试接口（查看计数、重置统计、模拟超限）

### Step 4: 实现降级器子模块
- `degradation/init.lua` — 降级响应 + 触发统计 + 最近事件记录 + build_*_body 预览方法
- `degradation/status.lua` — 独立状态查询接口
- `degradation/debug.lua` — 调试接口（预览各类降级响应、查看事件）

### Step 5: 更新模块协调器
- `stability/init.lua` — require 路径不变，新增 degradation.init()
- `stability/status.lua` — 聚合三子模块状态，新增问题检测

### Step 6: 配置 Admin 端点
- 在 `nginx.conf` 中新增 6 个 Admin location（每个子模块 status + debug）

### Step 7: 删除旧文件
- 删除 `lua/gateway/stability/` 下原有平铺的 `circuit_breaker.lua`、`rate_limiter.lua`、`degradation.lua`

---

## 7. nginx 超时与重试策略

已在 `nginx.conf` 中配置：

```nginx
# 超时配置
proxy_connect_timeout 5s;    # 连接超时
proxy_send_timeout    30s;   # 发送超时
proxy_read_timeout    30s;   # 读取超时

# 重试策略（仅在安全的错误类型时重试）
proxy_next_upstream       error timeout http_502 http_503 http_504;
proxy_next_upstream_tries     2;       # 最多重试 2 次
proxy_next_upstream_timeout  10s;      # 重试总超时
```

**幂等性考虑**：nginx `proxy_next_upstream` 默认仅对幂等方法 (GET/HEAD) 重试，非幂等方法需要显式配置 `non_idempotent`，当前未启用，保证 POST/PUT 等不会被意外重试。

---

## 8. 测试方案

### 8.1 模块状态查询

```bash
# 聚合状态
curl http://localhost:8080/admin/stability/status | python3 -m json.tool

# 各子模块独立状态
curl http://localhost:8080/admin/stability/circuit-breaker/status
curl http://localhost:8080/admin/stability/rate-limiter/status
curl http://localhost:8080/admin/stability/degradation/status
```

### 8.2 熔断器测试

```bash
# 强制 zerion 进入 OPEN
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=force_open&provider=zerion"

# 验证请求被熔断（期望 503）
curl -v http://localhost:8080/zerion/v1/test

# 强制恢复 CLOSED
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=force_closed&provider=zerion"

# 模拟连续失败 10 次
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=simulate_failures&provider=zerion&count=10"
```

### 8.3 限流器测试

```bash
# 快速发送大量请求触发限流
for i in $(seq 1 60); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/coingecko/api/v3/ping
done

# 查看计数器
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=coingecko&ip=127.0.0.1"
```

### 8.4 降级器测试

```bash
# 预览各种降级响应
curl "http://localhost:8080/admin/stability/degradation/debug?action=test_rate_limited&provider=zerion&dimension=provider"
curl "http://localhost:8080/admin/stability/degradation/debug?action=test_circuit_open&provider=zerion&retry_after=30"
curl "http://localhost:8080/admin/stability/degradation/debug?action=test_service_degraded&provider=zerion"

# 查看最近降级事件
curl "http://localhost:8080/admin/stability/degradation/debug?action=recent_events&limit=10"
```

### 8.5 综合场景测试

```bash
# 1. 重置所有状态
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=reset_all"

# 2. 模拟连续失败触发熔断
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=simulate_failures&provider=zerion&count=5"

# 3. 确认熔断器已 OPEN
curl http://localhost:8080/admin/stability/circuit-breaker/status

# 4. 验证请求被降级
curl -v http://localhost:8080/zerion/v1/test

# 5. 查看降级统计
curl http://localhost:8080/admin/stability/degradation/status
```
