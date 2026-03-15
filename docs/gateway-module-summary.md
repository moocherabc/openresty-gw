# OneKey API Gateway — 功能模块总结

> **版本**: 1.0.0  
> **基于**: OpenResty 1.27.1.2  
> **监听端口**: 8080  
> **架构**: Lua 模块化 + nginx 请求生命周期

---

## 1. 系统总览

OneKey API Gateway 是基于 OpenResty 构建的 API 代理网关，将客户端请求路由到多个第三方 Provider（Zerion / CoinGecko / Alchemy），并提供认证注入、限流、熔断、降级、监控、日志六大核心能力。

### 1.1 模块概览


| 模块                        | 实现功能                                           | 核心文件                                 |
| ------------------------- | ---------------------------------------------- | ------------------------------------ |
| **路由模块** (router)         | URL 前缀匹配 → Provider 识别 → 认证注入 → 头部处理 → URI 重写  | `gateway/router/`                    |
| **稳定性模块** (stability)     | 协调限流、熔断、降级三个子模块，保障网关可用性                        | `gateway/stability/init.lua`         |
| **限流器** (rate_limiter)    | 三维度漏桶限流（Provider / IP+Provider / IP 全局），防止流量过载 | `gateway/stability/rate_limiter/`    |
| **熔断器** (circuit_breaker) | 三态状态机（CLOSED / OPEN / HALF_OPEN），上游持续出错时快速失败   | `gateway/stability/circuit_breaker/` |
| **降级器** (degradation)     | 限流或熔断触发时返回友好 JSON 错误响应，含 Retry-After           | `gateway/stability/degradation/`     |
| **监控模块** (monitor)        | Prometheus 指标采集与暴露（请求量、延迟、错误、连接数等）             | `gateway/monitor/`                   |
| **日志模块** (logger)         | 结构化 JSON 访问日志、敏感信息脱敏、大 Body 截断                 | `gateway/logger/`                    |
| **配置模块** (config)         | 全局配置管理，支持热更新                                   | `config.lua`                         |


### 1.2 请求生命周期总流程

```
请求进入 (8080 端口)
  │
  ├─► init_by_lua           加载 Provider 配置，构建路由表，初始化所有模块
  ├─► init_worker_by_lua    Worker 级初始化，Prometheus 指标注册
  │
  ├─► access_by_lua         ① router.process_request()  路由匹配 + 认证注入 + URI 重写
  │                         ② stability.check_request() 限流检查 → 熔断检查
  │                            ├─ 限流触发 → degradation 返回 429
  │                            ├─ 熔断触发 → degradation 返回 503
  │                            └─ 全部通过 → proxy_pass 转发到上游
  │
  ├─► header_filter_by_lua  捕获响应头（存入 ngx.ctx 供日志使用）
  ├─► body_filter_by_lua    预留响应体处理扩展
  │
  └─► log_by_lua            ① collector.record_request()   Prometheus 指标采集
                            ② logger.log_request()         结构化日志输出
                            ③ stability.after_request()     熔断器成功/失败反馈
```

### 1.3 共享内存字典


| 字典名          | 大小   | 用途                   |
| ------------ | ---- | -------------------- |
| `gw_metrics` | 10MB | Prometheus 指标数据存储    |
| `gw_limiter` | 10MB | 限流器漏桶状态存储            |
| `gw_circuit` | 5MB  | 熔断器状态存储（跨 Worker 共享） |
| `gw_config`  | 5MB  | 全局配置存储               |
| `gw_locks`   | 1MB  | 分布式锁                 |


### 1.4 支持的 Provider


| Provider  | 路径前缀           | 目标上游                            | 认证方式                           |
| --------- | -------------- | ------------------------------- | ------------------------------ |
| Zerion    | `/zerion/*`    | `api.zerion.io:443`             | Basic Auth（API Key 作为用户名）      |
| CoinGecko | `/coingecko/*` | `api.coingecko.com:443`         | Header `x-cg-pro-api-key`      |
| Alchemy   | `/alchemy/*`   | `eth-mainnet.g.alchemy.com:443` | URL Path（Key 拼入路径 `/v2/{key}`) |


---

## 2. 路由模块 (Router)

### 2.1 功能概述

路由模块负责将客户端请求按 URL 路径前缀匹配到 Provider，完成认证注入、请求头处理和 URI 重写，是网关的核心请求分发引擎。

### 2.2 子模块与主要函数


| 子模块    | 文件                       | 主要函数                           | 功能                                          |
| ------ | ------------------------ | ------------------------------ | ------------------------------------------- |
| 协调器    | `router/init.lua`        | `init()`                       | 初始化 Provider 和路由表（init_by_lua 阶段）           |
|        |                          | `process_request()`            | 执行路由匹配 → 转换 → 设置上下文（access_by_lua 阶段）       |
|        |                          | `get_status()`                 | 获取模块运行状态                                    |
| 匹配引擎   | `router/matcher.lua`     | `init(providers)`              | 根据 Provider 列表构建路由表（最长前缀优先）                 |
|        |                          | `match(uri)`                   | 前缀匹配，返回 `{provider, prefix, captured_path}` |
|        |                          | `get_routes()`                 | 获取当前路由表                                     |
| 转换器    | `router/transformer.lua` | `transform(provider, match)`   | 执行完整请求转换（过滤 → 认证 → 追踪头 → URI 重写）            |
|        |                          | `inject_auth(provider, match)` | 按类型注入认证（basic_auth / header / url_path）     |
|        |                          | `filter_headers()`             | 过滤 hop-by-hop 头部                            |
|        |                          | `add_trace_header()`           | 注入 `x-onekey-request-id`                    |
|        |                          | `rewrite_uri(provider, match)` | 重写上游 URI                                    |
| 注册表    | `router/provider.lua`    | `init()`                       | 注册 Provider，从环境变量加载 API Key                 |
|        |                          | `get(name)` / `get_all()`      | 查询 Provider 配置                              |
|        |                          | `get_api_key(name)`            | 获取指定 Provider 的 API Key                     |
| 状态 API | `router/status.lua`      | `handle()`                     | `GET /admin/router/status` 返回模块状态           |
|        |                          | `health_check()`               | `GET /admin/router/health` 健康检查             |


### 2.3 关键配置

```nginx
# nginx.conf — Provider 路由 location
location ~ ^/zerion/(.*)     { set $provider 'zerion';    ... proxy_pass https://zerion_backend/$1$is_args$args; }
location ~ ^/coingecko/(.*)  { set $provider 'coingecko'; ... proxy_pass https://coingecko_backend/$1$is_args$args; }
location ~ ^/alchemy/(.*)    { set $provider 'alchemy';   ... proxy_pass https://alchemy_backend$backend_uri; }
```

```lua
-- Provider 配置结构（provider.lua）
{ name="zerion", prefix="/zerion", upstream="zerion_backend", host="api.zerion.io",
  auth_type="basic_auth", auth_config={ env_key="ZERION_API_KEY", username_is_key=true } }
```

### 2.4 流程图

```
客户端请求: GET /zerion/v1/wallets?address=0x123
  │
  ├─ 1. matcher.match("/zerion/v1/wallets")
  │     ├─ 提取前缀: "zerion"
  │     ├─ 查路由表: routes["zerion"] → zerion provider config
  │     └─ 捕获路径: "v1/wallets"
  │
  ├─ 2. transformer.transform(provider, match)
  │     ├─ filter_headers()      过滤 hop-by-hop 头部
  │     ├─ inject_auth()         注入 Authorization: Basic base64(key:)
  │     ├─ add_trace_header()    注入 x-onekey-request-id
  │     ├─ set Host header       Host: api.zerion.io
  │     └─ rewrite_uri()         upstream_uri = /v1/wallets?address=0x123
  │
  ├─ 3. 设置 ngx.ctx.route（供后续阶段使用）
  │
  └─ 4. proxy_pass → https://zerion_backend/v1/wallets?address=0x123
```

---

## 3. 稳定性模块 (Stability)

### 3.1 功能概述

稳定性模块作为协调器，串联限流器 → 熔断器的检查流程，并在 log 阶段反馈请求结果给熔断器。保障网关在上游异常或流量过载时的可用性。

### 3.2 主要函数


| 函数                | 调用阶段          | 功能                     |
| ----------------- | ------------- | ---------------------- |
| `init(config)`    | init_by_lua   | 初始化三个子模块               |
| `check_request()` | access_by_lua | 串联限流 → 熔断检查；任一拦截则调用降级器 |
| `after_request()` | log_by_lua    | 根据上游响应状态向熔断器反馈成功/失败    |
| `get_status()`    | Admin API     | 聚合三个子模块状态              |


### 3.3 流程图

```
stability.check_request()
  │
  ├─ 1. rate_limiter.check(provider, client_ip)
  │     ├─ 通过 → 继续
  │     └─ 拒绝 → ngx.ctx.stability_action = {type="rate_limited", dimension=...}
  │              → degradation.respond_rate_limited() → 429 终止
  │
  ├─ 2. circuit_breaker.before_request(provider)
  │     ├─ 放行 → 继续
  │     └─ 拦截 → ngx.ctx.stability_action = {type="circuit_open"}
  │              → degradation.respond_circuit_open() → 503 终止
  │
  └─ 3. 全部通过 → return true → proxy_pass

stability.after_request()  (log_by_lua)
  │
  ├─ status >= 500 → circuit_breaker.record_failure(provider)
  └─ status <  500 → circuit_breaker.record_success(provider)
```

---

## 4. 限流器子模块 (Rate Limiter)

### 4.1 功能概述

基于 `resty.limit.req` 漏桶算法实现三维度并行限流，保护 Provider 不被过载、防止单 IP 恶意请求。支持 `burst` 突发容量和 `uncommit` 公平性回退机制。

### 4.2 主要函数


| 函数                                              | 功能                                          |
| ----------------------------------------------- | ------------------------------------------- |
| `init(config)`                                  | 创建漏桶实例，清理旧数据                                |
| `check(provider, client_ip)`                    | 三维度串行检查，返回 `(passed, dimension, limit)`     |
| `get_all_counters(provider, ip)`                | Debug: 使用 `incoming(key, false)` 无副作用探测漏桶状态 |
| `set_debug_force_reject(enabled, dim, prov)`    | Debug: 启用/关闭强制拒绝模式                          |
| `get_stats()` / `get_config()` / `get_status()` | 查询统计、配置、完整状态                                |


### 4.3 关键配置

```lua
config = {
    provider_limits = {
        zerion    = { rate = 100, burst = 50  },   -- 100 req/s, 突发 50
        coingecko = { rate = 100, burst = 50  },
        alchemy   = { rate = 200, burst = 100 },
    },
    default_provider_limit = { rate = 100, burst = 50  },
    ip_provider_limit      = { rate = 20,  burst = 10  },  -- 单 IP 对单 Provider
    ip_global_limit        = { rate = 50,  burst = 25  },  -- 单 IP 全局
}
```

### 4.4 限流检查流程与数据结构返回

```
rate_limiter.check("zerion", "192.168.1.1")
  │
  ├─► 维度 1: Provider 全局   key="prov:zerion"           rate=100, burst=50
  │     incoming(key, true) → 放行
  │
  ├─► 维度 2: IP+Provider     key="ip_prov:192.168.1.1:zerion"  rate=20, burst=10
  │     incoming(key, true) → 放行
  │
  └─► 维度 3: IP 全局         key="ip:192.168.1.1"        rate=50, burst=25
        incoming(key, true) → 超限 rejected!
          ├─ uncommit 维度 1: prov_limiter:uncommit("prov:zerion")
          ├─ uncommit 维度 2: ip_provider_limiter:uncommit("ip_prov:192.168.1.1:zerion")
          └─ return false, "ip_global", 50
```

**限流触发时降级响应数据结构**：

```json
{
    "error": "rate_limited",
    "message": "You are sending too many requests, please slow down",
    "provider": "zerion",
    "dimension": "ip_global",
    "limit": 50,
    "retry_after": 1
}
```

HTTP 状态码: `429`，Header: `Retry-After: 1`

**限流器统计数据结构**：

```lua
stats = {
    total_checked           = 1000,  -- check() 总调用次数
    total_allowed           = 980,   -- 放行总次数
    total_rejected          = 20,    -- 拒绝总次数
    rejected_by_provider    = 5,     -- Provider 维度拒绝
    rejected_by_ip_provider = 10,    -- IP+Provider 维度拒绝
    rejected_by_ip_global   = 5,     -- IP 全局维度拒绝
}
```

---

## 5. 熔断器子模块 (Circuit Breaker)

### 5.1 功能概述

基于 `ngx.shared.gw_circuit` 实现跨 Worker 共享的三态状态机（CLOSED → OPEN → HALF_OPEN → CLOSED），当 Provider 持续返回 5xx 错误时自动熔断，避免雪崩效应。

### 5.2 主要函数


| 函数                                      | 功能                                           |
| --------------------------------------- | -------------------------------------------- |
| `init(configs)`                         | 初始化，支持按 Provider 独立配置参数                      |
| `before_request(provider)`              | 请求前检查: `true`=放行, `false`=拦截（返回 retry_after） |
| `record_success(provider)`              | 记录成功: HALF_OPEN 累计达标则恢复 CLOSED               |
| `record_failure(provider)`              | 记录失败: CLOSED 累计达标则进入 OPEN                    |
| `force_state(provider, state)`          | Debug: 强制设置状态                                |
| `reset(provider)` / `reset_all()`       | Debug: 重置数据                                  |
| `get_info(provider)` / `get_all_info()` | 查询熔断器状态                                      |


### 5.3 关键配置


| 参数                       | 默认值 | 说明                          |
| ------------------------ | --- | --------------------------- |
| `failure_threshold`      | 5   | 连续失败次数触发熔断                  |
| `recovery_timeout`       | 30s | OPEN 持续时间，之后进入 HALF_OPEN    |
| `half_open_max_requests` | 3   | HALF_OPEN 允许的最大探测请求数        |
| `success_threshold`      | 2   | HALF_OPEN 连续成功次数，恢复为 CLOSED |


### 5.4 状态机流程与数据结构返回

```
          失败次数 ≥ failure_threshold (5)
  ┌──────────────────────────────────┐
  │                                  ▼
┌──────┐                        ┌──────┐
│CLOSED│                        │ OPEN │ ← 快速失败，不转发
└──┬───┘                        └──┬───┘
   ▲                                │
   │ HALF_OPEN 内连续               │ 等待 recovery_timeout (30s)
   │ 成功 ≥ success_threshold (2)   │
   │                                ▼
   │                          ┌──────────┐
   └──────────────────────────│HALF_OPEN │ ← 允许最多 3 个探测请求
                              └────┬─────┘
                                   │ 探测失败 → 回到 OPEN
                                   └──────────────────┘
```

**共享内存存储（`ngx.shared.gw_circuit`）**：


| Key 格式                              | 类型     | 说明                                   |
| ----------------------------------- | ------ | ------------------------------------ |
| `cb:<provider>:state`               | number | 当前状态 (0=CLOSED, 1=OPEN, 2=HALF_OPEN) |
| `cb:<provider>:failures`            | number | 连续失败计数                               |
| `cb:<provider>:last_failure_time`   | number | 最近失败时间戳                              |
| `cb:<provider>:half_open_requests`  | number | HALF_OPEN 已放行请求数                     |
| `cb:<provider>:half_open_successes` | number | HALF_OPEN 连续成功数                      |


**熔断触发时降级响应数据结构**：

```json
{
    "error": "circuit_open",
    "message": "Service zerion is temporarily unavailable, recovering in progress",
    "provider": "zerion",
    "retry_after": 25
}
```

HTTP 状态码: `503`，Header: `Retry-After: 25`

**熔断器统计数据结构**：

```lua
stats = {
    total_checks      = 500,  -- before_request 总调用
    total_rejected    = 30,   -- 被拦截总次数
    total_successes   = 400,  -- record_success 总次数
    total_failures    = 70,   -- record_failure 总次数
    state_transitions = 8,    -- 状态变迁总次数
}
```

---

## 6. 降级器子模块 (Degradation)

### 6.1 功能概述

在限流或熔断触发时构造友好的 JSON 错误响应，附带 `Retry-After` 头部指引客户端重试。记录触发统计和最近降级事件。

### 6.2 主要函数


| 函数                                                 | 功能                  |
| -------------------------------------------------- | ------------------- |
| `respond_rate_limited(provider, dimension, limit)` | 返回 429 限流降级响应（终止请求） |
| `respond_circuit_open(provider, retry_after)`      | 返回 503 熔断降级响应（终止请求） |
| `respond_service_degraded(provider)`               | 返回 503 上游不可用降级响应    |
| `build_rate_limited_body(...)`                     | Debug: 仅构建响应体预览     |
| `build_circuit_open_body(...)`                     | Debug: 仅构建响应体预览     |
| `get_stats()` / `get_recent_events(limit)`         | 查询统计和最近事件           |


### 6.3 降级响应数据结构汇总


| 场景    | HTTP 状态码 | error_type         | Retry-After           |
| ----- | -------- | ------------------ | --------------------- |
| 限流触发  | 429      | `rate_limited`     | 1s                    |
| 熔断触发  | 503      | `circuit_open`     | recovery_timeout 剩余时间 |
| 上游不可用 | 503      | `service_degraded` | 10s                   |


**降级器统计数据结构**：

```lua
stats = {
    total_responses        = 50,
    rate_limited_count     = 30,
    circuit_open_count     = 15,
    service_degraded_count = 5,
}
```

### 6.4 流程图

```
降级器被调用（由 stability 协调器触发）
  │
  ├─► respond_rate_limited(provider, dimension, limit)
  │     ├─ 构建 JSON: {error:"rate_limited", message:..., provider, dimension, limit, retry_after:1}
  │     ├─ 设置 ngx.status = 429
  │     ├─ 设置 Header: Content-Type=application/json, Retry-After=1
  │     ├─ 统计计数 +1，记录事件
  │     └─ ngx.exit(429) 终止请求
  │
  ├─► respond_circuit_open(provider, retry_after)
  │     ├─ 构建 JSON: {error:"circuit_open", message:..., provider, retry_after}
  │     ├─ 设置 ngx.status = 503
  │     ├─ 设置 Header: Retry-After=<剩余恢复时间>
  │     └─ ngx.exit(503) 终止请求
  │
  └─► respond_service_degraded(provider)
        ├─ 构建 JSON: {error:"service_degraded", message:..., provider, retry_after:10}
        └─ ngx.exit(503) 终止请求
```

---

## 7. 监控模块 (Monitor)

### 7.1 功能概述

基于 [nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus) 库实现 Prometheus 指标采集与暴露。在 `init_worker` 阶段注册指标，`log_by_lua` 阶段采集数据，`/metrics` 端点输出标准 Prometheus text format。

### 7.2 子模块与主要函数


| 子模块    | 文件                      | 主要函数                            | 功能                                          |
| ------ | ----------------------- | ------------------------------- | ------------------------------------------- |
| 协调器    | `monitor/init.lua`      | `init_worker()`                 | Worker 级初始化，创建 prometheus 实例并注册所有指标         |
|        |                         | `expose()`                      | 实时更新连接 Gauge + 熔断器状态 Gauge，输出 Prometheus 格式 |
|        |                         | `get_metrics()`                 | 获取指标对象供 collector 使用                        |
| 采集器    | `monitor/collector.lua` | `record_request()`              | 在 log 阶段记录每个请求的指标（计数、延迟、错误、字节数）             |
|        |                         | `record_stability(m, provider)` | 采集限流/熔断拒绝相关 Prometheus 计数器                  |
| 状态 API | `monitor/status.lua`    | `handle()`                      | `GET /admin/monitor/status` 返回模块状态          |


### 7.3 Prometheus 指标一览


| 指标名                                 | 类型        | 标签                       | 说明                                   |
| ----------------------------------- | --------- | ------------------------ | ------------------------------------ |
| `gw_requests_total`                 | Counter   | provider, method, status | 请求总量                                 |
| `gw_request_duration_seconds`       | Histogram | provider                 | 请求延迟分布 (buckets: 5ms~10s)            |
| `gw_errors_total`                   | Counter   | provider, error_type     | 错误计数                                 |
| `gw_request_bytes_total`            | Counter   | provider                 | 接收字节数                                |
| `gw_response_bytes_total`           | Counter   | provider                 | 发送字节数                                |
| `gw_connections`                    | Gauge     | state                    | 连接数 (active/reading/writing/waiting) |
| `gw_provider_up`                    | Gauge     | provider                 | Provider 健康状态 (1=up, 0=down)         |
| `gw_circuit_breaker_state`          | Gauge     | provider                 | 熔断器状态 (0/1/2)                        |
| `gw_circuit_breaker_rejected_total` | Counter   | provider                 | 熔断拒绝次数                               |
| `gw_rate_limiter_rejected_total`    | Counter   | provider, dimension      | 限流拒绝次数                               |
| `gw_degradation_responses_total`    | Counter   | provider, type           | 降级响应次数                               |


### 7.4 配置说明

```nginx
# nginx.conf — 共享内存
lua_shared_dict gw_metrics 10m;

# /metrics 端点
location = /metrics {
    access_log off;
    content_by_lua_block { require("metrics").expose() }
}
```

### 7.5 流程图

```
init_worker_by_lua
  │
  └─► monitor.init_worker()
        ├─ prometheus = require("prometheus").init("gw_metrics")
        └─ 注册 11 个指标 (counter / histogram / gauge)

log_by_lua (每个请求)
  │
  └─► collector.record_request()
        ├─ requests:inc(1, {provider, method, status})
        ├─ latency:observe(duration, {provider})
        ├─ errors:inc(1, {provider, error_type})      -- 仅 5xx
        ├─ request_bytes:inc(n, {provider})
        ├─ response_bytes:inc(n, {provider})
        └─ record_stability()
              ├─ rate_limiter_rejected:inc(...)        -- 限流拦截时
              ├─ circuit_breaker_rejected:inc(...)     -- 熔断拦截时
              └─ degradation_responses:inc(...)        -- 降级响应时

GET /metrics
  │
  └─► monitor.expose()
        ├─ connections gauge 实时更新 (active/reading/writing/waiting)
        ├─ circuit_breaker_state gauge 更新 (从 gw_circuit dict 读取)
        ├─ provider_up gauge 更新 (基于熔断状态)
        └─ prometheus:collect() → 输出 Prometheus text format
```

---

## 8. 日志模块 (Logger)

### 8.1 功能概述

输出结构化 JSON 访问日志，支持敏感信息自动脱敏（API Key / Authorization / Cookie）、大 Body 截断、请求全生命周期追踪，兼容 Docker logs 和日志收集器。

### 8.2 子模块与主要函数


| 子模块    | 文件                     | 主要函数                          | 功能                                       |
| ------ | ---------------------- | ----------------------------- | ---------------------------------------- |
| 协调器    | `logger/init.lua`      | `init()`                      | 模块初始化                                    |
|        |                        | `capture_response_info()`     | header_filter 阶段捕获响应头存入 ngx.ctx          |
|        |                        | `log_request()`               | log 阶段输出结构化 JSON（按状态码区分级别 INFO/WARN/ERR） |
| 构建器    | `logger/formatter.lua` | `build_access_log()`          | 构建完整 JSON 访问日志条目                         |
|        |                        | `build_error_info(status)`    | 构建错误信息（HTTP 状态码 → 语义化 error_type）        |
|        |                        | `truncate_body(body, max)`    | Body 截断（≤2KB 完整 / ≤10KB 截断 / >10KB 仅记大小） |
|        |                        | `safe_headers(headers, max)`  | 脱敏 + 限制头部数量                              |
| 脱敏器    | `logger/sanitizer.lua` | `sanitize_headers(headers)`   | 脱敏请求/响应头（Authorization → "Basic ****"）   |
|        |                        | `sanitize_uri(uri)`           | 脱敏 URI 路径中的长字符串（≥20 字符视为 API Key）        |
|        |                        | `sanitize_args(query_string)` | 脱敏查询参数中的 api_key/token/secret 等          |
|        |                        | `mask(value, keep_prefix)`    | 通用掩码函数（保留前 4 字符 + ****）                  |
| 状态 API | `logger/status.lua`    | `handle()`                    | `GET /admin/logger/status` 返回模块状态        |


### 8.3 关键配置

```lua
-- 日志配置
config = {
    body_log_threshold = 2048,   -- Body ≤ 2KB 完整记录
    body_truncate_max  = 10240,  -- Body ≤ 10KB 截断记录
    max_log_headers    = 15,     -- 最多记录 15 个请求头
    log_request_body   = false,
    log_response_body  = false,
}
```

```nginx
# nginx.conf — 日志输出
log_format gw_json escape=json '{...JSON 模板...}';
access_log /dev/stdout gw_json;     # 结构化 JSON → stdout (Docker 兼容)
error_log  /dev/stderr info;        # 应用日志 → stderr
```

### 8.4 流程图

```
header_filter_by_lua
  │
  └─► logger.capture_response_info()
        └─ ngx.ctx.response_headers = ngx.resp.get_headers()

log_by_lua
  │
  └─► logger.log_request()
        │
        ├─ formatter.build_access_log()
        │     ├─ 从 ngx.ctx.route 提取 provider, request_id, start_time
        │     ├─ 从 ngx.var 提取 uri, args, status, upstream_*
        │     ├─ sanitizer.sanitize_uri(uri)            脱敏 URI
        │     ├─ sanitizer.sanitize_args(args)          脱敏查询参数
        │     ├─ safe_headers(req_headers)              脱敏 + 限数量
        │     ├─ build_error_info(status)               构建错误信息
        │     └─ cjson.encode(entry) → JSON 字符串
        │
        └─ 按状态码输出:
              ├─ status ≥ 500 → ngx.log(ERR, json)
              ├─ status ≥ 400 → ngx.log(WARN, json)
              └─ status < 400 → ngx.log(INFO, json)
```

---

## 9. 配置模块 (Config)

### 9.1 功能概述

集中管理网关全局配置，支持通过 `/admin/reload` 端点热更新 Provider 和路由表。

### 9.2 主要函数


| 函数                | 功能                               |
| ----------------- | -------------------------------- |
| `init()`          | 加载所有 Provider 配置                 |
| `get(key)`        | 按点号分隔路径获取配置值（如 `"gateway.name"`） |
| `get_providers()` | 获取所有 Provider 配置                 |
| `reload()`        | 热更新：重新初始化 Provider → 重建路由表       |
| `is_loaded()`     | 检查配置是否已加载                        |


### 9.3 配置热更新

```nginx
# nginx.conf — 仅允许本机访问
location = /admin/reload {
    allow 127.0.0.1;
    deny all;
    content_by_lua_block { ... config.reload() ... }
}
```

---

## 10. Admin API 端点汇总


| 端点                                        | 方法       | 所属模块 | 说明              |
| ----------------------------------------- | -------- | ---- | --------------- |
| `/health`                                 | GET      | 全局   | 网关健康检查          |
| `/metrics`                                | GET      | 监控   | Prometheus 指标输出 |
| `/admin/reload`                           | POST     | 配置   | 热更新配置（仅本机）      |
| `/admin/router/status`                    | GET      | 路由   | 路由模块状态          |
| `/admin/router/health`                    | GET      | 路由   | 路由模块健康检查        |
| `/admin/monitor/status`                   | GET      | 监控   | 监控模块状态          |
| `/admin/monitor/health`                   | GET      | 监控   | 监控模块健康检查        |
| `/admin/logger/status`                    | GET      | 日志   | 日志模块状态          |
| `/admin/logger/health`                    | GET      | 日志   | 日志模块健康检查        |
| `/admin/stability/status`                 | GET      | 稳定性  | 三子模块聚合状态        |
| `/admin/stability/health`                 | GET      | 稳定性  | 稳定性聚合健康检查       |
| `/admin/stability/circuit-breaker/status` | GET      | 熔断器  | 熔断器状态与统计        |
| `/admin/stability/circuit-breaker/debug`  | GET/POST | 熔断器  | 强制状态/模拟故障/重置    |
| `/admin/stability/rate-limiter/status`    | GET      | 限流器  | 限流器状态与统计        |
| `/admin/stability/rate-limiter/debug`     | GET/POST | 限流器  | 查看漏桶/强制拒绝/重置    |
| `/admin/stability/degradation/status`     | GET      | 降级器  | 降级器状态与统计        |
| `/admin/stability/degradation/debug`      | GET/POST | 降级器  | 预览降级响应/查看事件     |
| `/admin/circuit`                          | GET      | 兼容   | 旧版熔断器状态查询       |


---

## 11. nginx.conf 关键配置速览

```nginx
# 通用超时
proxy_connect_timeout 5s;
proxy_send_timeout    30s;
proxy_read_timeout    30s;

# 重试策略（仅幂等方法）
proxy_next_upstream       error timeout http_502 http_503 http_504;
proxy_next_upstream_tries     2;
proxy_next_upstream_timeout  10s;

# DNS
resolver 8.8.8.8 114.114.114.114 valid=30s ipv6=off;

# 环境变量（API Key）
env ZERION_API_KEY;
env COINGECKO_API_KEY;
env ALCHEMY_API_KEY;
```

---

## 12. 文件目录结构

```
openresty-1.27.1.2-win64/
├── conf/
│   └── nginx.conf                              # Nginx 主配置
├── lua/
│   ├── init.lua                                # init_by_lua 入口
│   ├── init_worker.lua                         # init_worker_by_lua 入口
│   ├── access.lua                              # access_by_lua 入口 (路由+稳定性)
│   ├── header_filter.lua                       # header_filter_by_lua 入口
│   ├── body_filter.lua                         # body_filter_by_lua 入口
│   ├── log.lua                                 # log_by_lua 入口 (监控+日志+稳定性反馈)
│   ├── config.lua                              # 全局配置管理
│   ├── metrics.lua                             # /metrics 端点入口
│   ├── circuit_breaker.lua                     # 兼容入口 (代理到 stability 子模块)
│   └── gateway/
│       ├── router/
│       │   ├── init.lua                        # 路由协调器
│       │   ├── matcher.lua                     # 路由匹配引擎
│       │   ├── provider.lua                    # Provider 注册表
│       │   ├── transformer.lua                 # 请求转换器
│       │   └── status.lua                      # 路由状态 API
│       ├── stability/
│       │   ├── init.lua                        # 稳定性协调器
│       │   ├── status.lua                      # 聚合状态 API
│       │   ├── circuit_breaker/
│       │   │   ├── init.lua                    # 熔断器核心 (三态状态机)
│       │   │   ├── status.lua                  # 熔断器状态 API
│       │   │   └── debug.lua                   # 熔断器调试接口
│       │   ├── rate_limiter/
│       │   │   ├── init.lua                    # 限流器核心 (漏桶算法)
│       │   │   ├── status.lua                  # 限流器状态 API
│       │   │   └── debug.lua                   # 限流器调试接口
│       │   └── degradation/
│       │       ├── init.lua                    # 降级器核心 (响应构造)
│       │       ├── status.lua                  # 降级器状态 API
│       │       └── debug.lua                   # 降级器调试接口
│       ├── monitor/
│       │   ├── init.lua                        # 监控协调器 (Prometheus)
│       │   ├── collector.lua                   # 数据采集器
│       │   └── status.lua                      # 监控状态 API
│       └── logger/
│           ├── init.lua                        # 日志协调器
│           ├── formatter.lua                   # JSON 日志构建器
│           ├── sanitizer.lua                   # 敏感信息脱敏器
│           └── status.lua                      # 日志状态 API
└── docs/
    └── architecture-design/                    # 技术设计文档
```

