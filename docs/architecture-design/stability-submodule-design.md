# 稳定性子模块拆分技术设计文档

## 1. 概述

本文档描述将稳定性模块（stability）拆分为三个独立子模块的技术方案：
- **熔断器（circuit_breaker）**：Provider 级三态熔断，防止雪崩
- **限流器（rate_limiter）**：多维度固定窗口计数器限流
- **降级器（degradation）**：统一友好降级响应，含 Retry-After

每个子模块均可独立运行、独立测试，并提供状态查询接口和 Debug 调试接口。

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
请求进入
  │
  ├─► access_by_lua (路由匹配之后)
  │      │
  │      ├─ 1. rate_limiter.check(provider, ip)
  │      │     任一维度超限 → degradation.respond_rate_limited() → 429
  │      │
  │      ├─ 2. circuit_breaker.before_request(provider)
  │      │     OPEN 状态 → degradation.respond_circuit_open() → 503
  │      │
  │      └─ 3. 全部通过 → proxy_pass 转发到上游
  │
  └─► log_by_lua (响应完成后)
         │
         ├─ status >= 500 → circuit_breaker.record_failure(provider)
         └─ status <  500 → circuit_breaker.record_success(provider)
```

### 2.3 共享内存字典

| 字典名 | 大小 | 用途 |
|--------|------|------|
| `gw_circuit` | 5m | 熔断器状态存储（跨 Worker 共享） |
| `gw_limiter` | 10m | 限流计数器存储（TTL 自动过期） |
| `gw_config` | 5m | 全局配置存储 |

### 2.4 熔断器状态机

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

### 2.5 多维度限流策略

```
请求到达
  │
  ├─► 维度 1: Provider 全局限流
  │     key = "rl:prov:<provider>:<window_id>"
  │     limit = 100 req/s (可配置)
  │
  ├─► 维度 2: IP + Provider 限流
  │     key = "rl:ip_prov:<ip>:<provider>:<window_id>"
  │     limit = 20 req/s (可配置)
  │
  └─► 维度 3: IP 全局限流
        key = "rl:ip:<ip>:<window_id>"
        limit = 50 req/s (可配置)

  任一维度触发 → 返回 429 Too Many Requests
```

### 2.6 降级响应设计

| 场景 | HTTP 状态码 | error_type | Retry-After |
|------|-------------|------------|-------------|
| 限流触发 | 429 | `rate_limited` | 1s |
| 熔断触发 | 503 | `circuit_open` | recovery_timeout 剩余时间 |
| 上游不可用 | 503 | `service_degraded` | 10s |

### 2.7 与监控模块的 Prometheus 指标对接

稳定性模块本身不直接写 Prometheus；它通过 `ngx.ctx.stability_action` 把本次请求的稳定性动作传递给监控采集器 `gateway/monitor/collector.lua`，由采集器在 `log_by_lua` 阶段统一计数。

**上下文字段约定**：

| 字段 | 示例值 | 说明 |
|------|--------|------|
| `ngx.ctx.stability_action.type` | `rate_limited` / `circuit_open` | 稳定性动作类型 |
| `ngx.ctx.stability_action.dimension` | `provider` / `ip_provider` / `ip_global` | 限流维度（仅限流动作） |

**Prometheus 指标映射（由 monitor/collector 记录）**：

| 触发场景 | 指标名 | 标签 |
|---------|--------|------|
| 限流拦截 | `gw_rate_limiter_rejected_total` | `provider`, `dimension` |
| 熔断拦截 | `gw_circuit_breaker_rejected_total` | `provider` |
| 限流/熔断降级响应 | `gw_degradation_responses_total` | `provider`, `type` |

此外，`gateway/monitor/init.lua` 在 `/metrics` 暴露阶段会同步设置 `gw_circuit_breaker_state{provider}`（0=closed, 1=open, 2=half_open），并据此更新 `gw_provider_up{provider}`。

---

## 3. 文件路径规范

```
lua/
├── access.lua                              # access 阶段入口（无需修改）
├── log.lua                                 # log 阶段入口（无需修改）
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
```

**require 路径映射**（Lua 自动查找 `init.lua`，保持向后兼容）：

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

## 4. Admin API 端点设计

### 4.1 端点一览

| 端点 | 方法 | 说明 |
|------|------|------|
| `/admin/stability/status` | GET | 聚合所有子模块状态 |
| `/admin/stability/health` | GET | 模块健康检查 |
| `/admin/stability/circuit-breaker/status` | GET | 熔断器状态与统计 |
| `/admin/stability/circuit-breaker/debug` | GET/POST | 熔断器调试接口 |
| `/admin/stability/rate-limiter/status` | GET | 限流器状态与统计 |
| `/admin/stability/rate-limiter/debug` | GET/POST | 限流器调试接口 |
| `/admin/stability/degradation/status` | GET | 降级器状态与统计 |
| `/admin/stability/degradation/debug` | GET/POST | 降级器调试接口 |

### 4.2 Debug 接口详细设计

#### 4.2.1 熔断器 Debug (`/admin/stability/circuit-breaker/debug`)

| 参数 action | 附加参数 | 说明 |
|-------------|---------|------|
| `force_open` | `provider` | 强制指定 Provider 进入 OPEN 状态 |
| `force_closed` | `provider` | 强制指定 Provider 恢复 CLOSED 状态 |
| `force_half_open` | `provider` | 强制指定 Provider 进入 HALF_OPEN 状态 |
| `reset` | `provider` | 重置指定 Provider 的所有熔断器数据 |
| `reset_all` | - | 重置所有 Provider 的熔断器数据 |
| `simulate_failures` | `provider`, `count` | 模拟连续失败 N 次 |

**示例**：

```bash
# 强制 zerion 熔断器进入 OPEN 状态
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=force_open&provider=zerion"

# 模拟 zerion 连续失败 10 次
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=simulate_failures&provider=zerion&count=10"

# 重置所有熔断器
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=reset_all"
```

#### 4.2.2 限流器 Debug (`/admin/stability/rate-limiter/debug`)

| 参数 action | 附加参数 | 说明 |
|-------------|---------|------|
| `get_counters` | `provider`, `ip` | 通过 incoming(key,false) 探测漏桶状态 |
| `reset_stats` | - | 重置统计计数 |
| `simulate_exceeded` | `provider`, `dimension` | 预览指定维度超限的降级响应内容 |
| `force_reject` | `dimension`, `provider` | 启用强制拒绝模式 |
| `clear_force_reject` | - | 关闭强制拒绝模式 |
| `get_debug_mode` | - | 查看当前 Debug 模式状态 |

**示例**：

```bash
# 查看 zerion 漏桶状态（excess/rate/burst/status）
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=zerion&ip=127.0.0.1"

# 模拟 provider 维度超限
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=provider"

# 启用强制拒绝（测试降级链路）
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=force_reject&dimension=provider&provider=zerion"

# 关闭强制拒绝
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=clear_force_reject"
```

#### 4.2.3 降级器 Debug (`/admin/stability/degradation/debug`)

| 参数 action | 附加参数 | 说明 |
|-------------|---------|------|
| `test_rate_limited` | `provider`, `dimension` | 预览限流降级响应内容（不真正拦截） |
| `test_circuit_open` | `provider`, `retry_after` | 预览熔断降级响应内容 |
| `test_service_degraded` | `provider` | 预览上游不可用降级响应内容 |
| `reset_stats` | - | 重置降级触发统计 |

**示例**：

```bash
# 预览限流降级响应
curl "http://localhost:8080/admin/stability/degradation/debug?action=test_rate_limited&provider=zerion&dimension=provider"

# 预览熔断降级响应
curl "http://localhost:8080/admin/stability/degradation/debug?action=test_circuit_open&provider=zerion&retry_after=30"
```

---

## 5. 核心代码设计

### 5.1 熔断器核心逻辑 (`circuit_breaker/init.lua`)

**存储 Key 规范（`ngx.shared.gw_circuit`）**：

| Key | 类型 | 说明 |
|-----|------|------|
| `cb:<provider>:state` | number | 当前状态 (0=CLOSED, 1=OPEN, 2=HALF_OPEN) |
| `cb:<provider>:failures` | number | 连续失败计数 |
| `cb:<provider>:last_failure_time` | number | 最近失败时间戳 |
| `cb:<provider>:half_open_requests` | number | HALF_OPEN 已放行请求数 |
| `cb:<provider>:half_open_successes` | number | HALF_OPEN 连续成功数 |

**配置参数**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `failure_threshold` | 5 | 连续失败次数触发熔断 |
| `recovery_timeout` | 30s | OPEN 持续时间，之后进入 HALF_OPEN |
| `half_open_max_requests` | 3 | HALF_OPEN 允许的最大探测请求数 |
| `success_threshold` | 2 | HALF_OPEN 连续成功次数，恢复为 CLOSED |

**核心方法**：

```lua
function _M.before_request(provider)
    -- CLOSED  → return true（放行）
    -- OPEN    → 检查 recovery_timeout，超时则切 HALF_OPEN 并放行
    --           未超时则 return false, retry_after（拦截）
    -- HALF_OPEN → 未超过 max_requests 则放行，否则拦截
end

function _M.record_success(provider)
    -- CLOSED    → 重置失败计数
    -- HALF_OPEN → 累加成功数，达 success_threshold 则切回 CLOSED
end

function _M.record_failure(provider)
    -- CLOSED    → 累加失败数，达 failure_threshold 则切入 OPEN
    -- HALF_OPEN → 直接回到 OPEN（探测失败）
end
```

**统计数据（进程内 Worker 级别）**：

```lua
local stats = {
    total_checks     = 0,  -- before_request 总调用次数
    total_rejected   = 0,  -- 被拦截总次数
    total_successes  = 0,  -- record_success 总次数
    total_failures   = 0,  -- record_failure 总次数
    state_transitions = 0, -- 状态变迁总次数
}
```

### 5.2 限流器核心逻辑 (`rate_limiter/init.lua`)

> 详细设计见 → [rate-limiter-module-design.md](rate-limiter-module-design.md)

**算法**：漏桶（Leaky Bucket），基于 `resty.limit.req`

```lua
-- 每个维度使用独立的 resty.limit.req 实例
-- Provider 维度: 按 provider 缓存（不同 rate/burst）
-- IP+Provider / IP 全局: 全局共享实例（统一 rate/burst，按 key 区分）

local limit_req = require("resty.limit.req")
local lim = limit_req.new("gw_limiter", rate, burst)
local delay, err = lim:incoming(key, true)  -- true=commit
if not delay and err == "rejected" then ... end
```

**三维度串行检查 + uncommit 公平性机制**：

```lua
function _M.check(provider, client_ip)
    -- 维度 1: Provider 全局限流 key="prov:<provider>"
    --   incoming(key, true) → rejected → return false
    -- 维度 2: IP+Provider 限流  key="ip_prov:<ip>:<provider>"
    --   rejected → uncommit 维度 1 → return false
    -- 维度 3: IP 全局限流       key="ip:<ip>"
    --   rejected → uncommit 维度 1+2 → return false
    -- 全部通过 → return true
end
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

### 5.3 降级器核心逻辑 (`degradation/init.lua`)

**内部通用响应函数**：

```lua
local function respond(status_code, body, retry_after)
    ngx.status = status_code
    ngx.header["Content-Type"] = "application/json"
    if retry_after > 0 then
        ngx.header["Retry-After"] = tostring(math.ceil(retry_after))
    end
    ngx.say(cjson.encode(body))
    return ngx.exit(status_code)
end
```

**三种降级场景**：

| 方法 | 状态码 | error_type | 触发来源 |
|------|--------|------------|---------|
| `respond_rate_limited(provider, dimension, limit)` | 429 | rate_limited | 限流器 |
| `respond_circuit_open(provider, retry_after)` | 503 | circuit_open | 熔断器 |
| `respond_service_degraded(provider)` | 503 | service_degraded | 上游异常 |

**统计数据**：

```lua
local stats = {
    total_responses       = 0,
    rate_limited_count    = 0,
    circuit_open_count    = 0,
    service_degraded_count = 0,
}
```

### 5.4 协调器 (`stability/init.lua`)

```lua
function _M.check_request()
    -- 1. rate_limiter.check(provider, client_ip)
    --    失败 → ngx.ctx.stability_action={type="rate_limited",dimension=...}
    --         → degradation.respond_rate_limited()
    -- 2. circuit_breaker.before_request(provider)
    --    失败 → ngx.ctx.stability_action={type="circuit_open"}
    --         → degradation.respond_circuit_open()
    -- 3. 全部通过 → return true
end

function _M.after_request()
    -- status >= 500 → circuit_breaker.record_failure(provider)
    -- status <  500 → circuit_breaker.record_success(provider)
end
```

---

## 6. 实现步骤

### Step 1: 创建目录结构

将原 `stability/circuit_breaker.lua`、`rate_limiter.lua`、`degradation.lua` 拆分为目录形式，各子模块的核心逻辑放在 `init.lua` 中。

### Step 2: 实现熔断器子模块

1. `circuit_breaker/init.lua` — 迁移核心状态机逻辑，新增统计计数
2. `circuit_breaker/status.lua` — 独立状态查询接口，含统计数据
3. `circuit_breaker/debug.lua` — 调试接口（强制状态、模拟故障、重置）

### Step 3: 实现限流器子模块

1. `rate_limiter/init.lua` — 迁移多维度限流逻辑，保持统计计数
2. `rate_limiter/status.lua` — 独立状态查询接口，含计数详情
3. `rate_limiter/debug.lua` — 调试接口（查看计数、重置、模拟超限）

### Step 4: 实现降级器子模块

1. `degradation/init.lua` — 迁移降级响应逻辑，新增触发统计
2. `degradation/status.lua` — 独立状态查询接口，含触发统计
3. `degradation/debug.lua` — 调试接口（预览各类降级响应）

### Step 5: 更新模块协调器

1. 更新 `stability/init.lua` — require 路径不变（Lua 自动解析 `init.lua`）
2. 更新 `stability/status.lua` — 聚合所有子模块状态

### Step 6: 配置 Admin 端点

在 `nginx.conf` 中添加各子模块的独立 status 和 debug 端点。

### Step 7: 删除旧文件

删除 `lua/gateway/stability/` 下原有的三个平铺文件。

---

## 7. 测试方案

### 7.1 模块状态查询

```bash
# 聚合状态
curl http://localhost:8080/admin/stability/status | python3 -m json.tool

# 各子模块独立状态
curl http://localhost:8080/admin/stability/circuit-breaker/status
curl http://localhost:8080/admin/stability/rate-limiter/status
curl http://localhost:8080/admin/stability/degradation/status
```

### 7.2 熔断器测试

```bash
# 查看熔断器状态
curl http://localhost:8080/admin/stability/circuit-breaker/status

# 强制 zerion 进入 OPEN
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=force_open&provider=zerion"

# 验证请求被熔断
curl -v http://localhost:8080/zerion/v1/test  # 期望 503

# 强制恢复 CLOSED
curl -X POST "http://localhost:8080/admin/stability/circuit-breaker/debug?action=force_closed&provider=zerion"
```

### 7.3 限流器测试

```bash
# 查看当前限流状态
curl http://localhost:8080/admin/stability/rate-limiter/status

# 快速发送大量请求测试限流
for i in $(seq 1 60); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/coingecko/api/v3/ping
done

# 查看计数器
curl "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=coingecko&ip=127.0.0.1"
```

### 7.4 降级器测试

```bash
# 预览各种降级响应
curl "http://localhost:8080/admin/stability/degradation/debug?action=test_rate_limited&provider=zerion&dimension=provider"
curl "http://localhost:8080/admin/stability/degradation/debug?action=test_circuit_open&provider=zerion&retry_after=30"
curl "http://localhost:8080/admin/stability/degradation/debug?action=test_service_degraded&provider=zerion"
```

### 7.5 综合场景测试

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
