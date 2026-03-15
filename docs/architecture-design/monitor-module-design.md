# 监控模块技术设计文档

## 1. 模块概述

监控模块负责采集网关运行时的各项指标数据，以 **Prometheus exposition format** 输出，供 Prometheus Server 拉取。

本模块基于 [nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus) 开源库实现，该库提供了成熟的 Counter / Gauge / Histogram 类型支持和标准 Prometheus text format 输出，大幅降低了代码复杂度。

### 1.1 模块职责

| 职责 | 说明 |
|------|------|
| 指标注册 | 在 init_worker 阶段通过库 API 注册所有指标 |
| 数据采集 | 在 log_by_lua 阶段调用 collector 记录每个请求的指标 |
| Prometheus 输出 | 在 `/metrics` 端点调用 `prometheus:collect()` 输出标准格式 |
| 状态暴露 | 提供 `/admin/monitor/status` 查看模块运行状态 |

### 1.2 需要回答的监控问题

| 问题 | 对应指标 |
|------|----------|
| 每个 Provider 的请求量 | `gw_requests_total{provider, method, status}` |
| 每个 Provider 的成功率 | 由 `gw_requests_total` 计算 (status<400 / total) |
| 请求延迟 P50/P95/P99 | `gw_request_duration_seconds{provider}` (Histogram) |
| 活跃连接数 | `gw_connections{state}` (Gauge) |
| 错误频率 | `gw_errors_total{provider, error_type}` |
| Provider 健康状态 | `gw_provider_up{provider}` (Gauge) |
| 熔断器状态 | `gw_circuit_breaker_state{provider}` (Gauge) |
| 熔断拒绝次数 | `gw_circuit_breaker_rejected_total{provider}` |
| 限流拒绝次数 | `gw_rate_limiter_rejected_total{provider, dimension}` |
| 降级响应次数 | `gw_degradation_responses_total{provider, type}` |

### 1.3 使用的开源库

| 库 | 版本 | 说明 |
|----|------|------|
| [nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus) | latest (opm) | Prometheus metric library for Nginx |

---

## 2. 架构设计

### 2.1 模块架构图

```
                        ┌───────────────────────────────────────┐
                        │           Prometheus Server            │
                        │     (每 15s 拉取 /metrics 端点)        │
                        └──────────────┬────────────────────────┘
                                       │ HTTP GET /metrics
                        ┌──────────────▼────────────────────────┐
                        │      metrics.lua (对外入口)             │
                        │                                        │
                        │  调用 monitor.expose()                  │
                        │   → connections gauge 实时更新           │
                        │   → prometheus:collect() 输出文本格式    │
                        └──────────────┬────────────────────────┘
                                       │
                        ┌──────────────▼────────────────────────┐
                        │    gateway/monitor/init.lua             │
                        │    (模块协调器)                          │
                        │                                        │
                        │  init_worker():                         │
                        │   prometheus = require("prometheus")    │
                        │              .init("gw_metrics")        │
                        │   注册 counter / histogram / gauge      │
                        │                                        │
                        │  expose():                              │
                        │   更新连接 gauge → prometheus:collect()  │
                        └──────────────▲────────────────────────┘
                                       │
          ┌────────────────────────────┤
          │                            │
  ┌───────▼─────────┐    ┌────────────▼───────────────────────┐
  │  init_worker.lua │    │  gateway/monitor/collector.lua      │
  │  (调用入口)       │    │  (log_by_lua 阶段)                  │
  │                  │    │                                     │
  │  monitor         │    │  record_request():                  │
  │   .init_worker() │    │   ├─ requests:inc(1, {labels})      │
  │                  │    │   ├─ latency:observe(dur, {labels}) │
  └──────────────────┘    │   ├─ errors:inc(1, {labels})        │
                          │   ├─ bytes:inc(n, {labels})         │
                          │   └─ record_stability()             │
                          └─────────────────────────────────────┘
```

### 2.2 与 nginx-lua-prometheus 库的集成方式

```
┌─ init_worker_by_lua ─────────────────────────────────┐
│                                                       │
│  prometheus = require("prometheus").init("gw_metrics") │
│                                                       │
│  metric_requests = prometheus:counter(...)             │
│  metric_latency  = prometheus:histogram(...)           │
│  metric_errors   = prometheus:counter(...)             │
│  metric_bytes_in = prometheus:counter(...)             │
│  metric_bytes_out= prometheus:counter(...)             │
│  metric_conn     = prometheus:gauge(...)               │
│  metric_provider = prometheus:gauge(...)               │
│                                                       │
└───────────────────────────────────────────────────────┘
         │ 模块级变量，同 Worker 内所有阶段共享
         ▼
┌─ log_by_lua ─────────────┐  ┌─ content_by_lua (/metrics) ──┐
│                           │  │                               │
│ metric_requests:inc(...)  │  │ metric_conn:set(active,...)   │
│ metric_latency:observe()  │  │ prometheus:collect()          │
│ metric_errors:inc(...)    │  │                               │
│                           │  │ → 输出 Prometheus text format │
└───────────────────────────┘  └───────────────────────────────┘
```

### 2.3 OpenResty 请求处理阶段中的监控介入

```
请求进入
  │
  ├─► init_worker_by_lua : prometheus 初始化 + 指标注册
  │
  ├─► access_by_lua      : 路由匹配 (记录 start_time 到 ngx.ctx)
  │
  ├─► proxy_pass          : 转发到上游
  │
  ├─► log_by_lua          : collector.record_request()
  │       ├─ requests counter +1
  │       ├─ latency histogram observe
  │       ├─ errors counter +1 (if 5xx)
  │       ├─ bytes counters +n
  │       └─ stability counters +1
  │            ├─ rate_limiter_rejected (if rate_limited)
  │            ├─ circuit_breaker_rejected (if circuit_open)
  │            └─ degradation_responses (rate_limited/circuit_open)
  │
  └─► GET /metrics        : monitor.expose()
          ├─ connections gauge 实时更新
          ├─ provider health gauge 更新
          ├─ circuit breaker state gauge 更新
          └─ prometheus:collect() 输出
```

---

## 3. 文件路径规范

```
lua/
├── metrics.lua                     # 对外统一入口 (调用 monitor.expose)
└── gateway/
    └── monitor/
        ├── init.lua                # 模块协调器 (初始化 + expose)
        ├── collector.lua           # 数据采集器 (log 阶段)
        └── status.lua              # 模块状态查询 API

docs/
└── monitor-module-design.md        # 本文档
```

对比自定义实现，使用 nginx-lua-prometheus 后模块文件从 6 个精简为 3 个。

---

## 4. 核心代码设计

### 4.1 指标定义总览

| 指标名 | 类型 | 标签 | 说明 |
|--------|------|------|------|
| `gw_requests_total` | Counter | provider, method, status | 请求总量 |
| `gw_request_duration_seconds` | Histogram | provider | 请求延迟分布 |
| `gw_errors_total` | Counter | provider, error_type | 错误计数 |
| `gw_request_bytes_total` | Counter | provider | 接收字节数 |
| `gw_response_bytes_total` | Counter | provider | 发送字节数 |
| `gw_connections` | Gauge | state | 连接数 (active/reading/writing/waiting) |
| `gw_provider_up` | Gauge | provider | Provider 健康 (1=up 0=down) |
| `gw_circuit_breaker_state` | Gauge | provider | 熔断状态 (0=closed 1=open 2=half_open) |
| `gw_circuit_breaker_rejected_total` | Counter | provider | 熔断拒绝总次数 |
| `gw_rate_limiter_rejected_total` | Counter | provider, dimension | 限流拒绝总次数 |
| `gw_degradation_responses_total` | Counter | provider, type | 降级响应总次数 |

### 4.2 Histogram Bucket 定义

```lua
{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 }
```

覆盖 5ms ~ 10s 范围，满足 P50/P95/P99 分位计算需求。

### 4.3 模块协调器核心逻辑 (`gateway/monitor/init.lua`)

```lua
-- init_worker 阶段：初始化 prometheus 实例并注册所有指标
function _M.init_worker()
    prometheus = require("prometheus").init("gw_metrics")

    metric_requests = prometheus:counter(
        "gw_requests_total", "Total HTTP requests", {"provider", "method", "status"})
    metric_latency = prometheus:histogram(
        "gw_request_duration_seconds", "Request latency", {"provider"}, BUCKETS)
    metric_errors = prometheus:counter(
        "gw_errors_total", "Total errors", {"provider", "error_type"})
    ...
end

-- /metrics 端点：实时更新 gauge 后输出
function _M.expose()
    metric_connections:set(ngx.var.connections_reading, {"reading"})
    metric_connections:set(ngx.var.connections_writing, {"writing"})
    metric_connections:set(ngx.var.connections_waiting, {"waiting"})
    metric_connections:set(ngx.var.connections_active,  {"active"})
    prometheus:collect()
end
```

### 4.4 数据采集器核心逻辑 (`gateway/monitor/collector.lua`)

```lua
function _M.record_request()
    local route    = ngx.ctx.route
    local provider = route.provider_name
    local method   = ngx.req.get_method()
    local status   = tostring(ngx.status)
    local duration = ngx.now() - route.start_time

    metrics.requests:inc(1, {provider, method, status})
    metrics.latency:observe(duration, {provider})

    if ngx.status >= 500 then
        metrics.errors:inc(1, {provider, classify_error(...)})
    end

    _M.record_stability(metrics, provider)
end

function _M.record_stability(metrics, provider)
    local action = ngx.ctx.stability_action
    if not action then return end

    if action.type == "rate_limited" then
        metrics.rate_limiter_rejected:inc(1, {provider, action.dimension or "unknown"})
        metrics.degradation_responses:inc(1, {provider, "rate_limited"})
    elseif action.type == "circuit_open" then
        metrics.circuit_breaker_rejected:inc(1, {provider})
        metrics.degradation_responses:inc(1, {provider, "circuit_open"})
    end
end
```

---

## 5. 实现步骤

### Step 1: 安装 nginx-lua-prometheus 库
- Docker 中通过 `opm get knyar/nginx-lua-prometheus` 安装
- 库文件自动放入 OpenResty 的 lualib 目录

### Step 2: 实现模块协调器 (init.lua)
- 在 `init_worker()` 中初始化 prometheus 实例
- 注册所有 Counter / Histogram / Gauge 指标
- 提供 `expose()` 方法供 `/metrics` 端点调用

### Step 3: 实现数据采集器 (collector.lua)
- 从 `ngx.ctx.route` 提取请求上下文
- 调用指标对象的 `inc()` / `observe()` 方法
- 错误类型分类逻辑
- 从 `ngx.ctx.stability_action` 采集限流/熔断相关计数

### Step 4: 实现模块状态 API (status.lua)
- 暴露 shared dict 使用情况
- 暴露已注册指标列表

### Step 5: 集成到请求生命周期
- `init_worker.lua` 调用 `monitor.init_worker()`
- `log.lua` 调用 `collector.record_request()`
- `/metrics` 端点调用 `monitor.expose()`
- 添加 `/admin/monitor/status` 端点

### Step 6: 测试验证
- 启动后访问 `/metrics` 验证 Prometheus 格式输出
- 发送测试请求后观察指标变化
- 访问 `/admin/monitor/status` 查看模块状态

---

## 6. Prometheus 采集配置

```yaml
scrape_configs:
  - job_name: 'onekey-gateway'
    scrape_interval: 15s
    metrics_path: '/metrics'
    static_configs:
      - targets: ['gateway:8080']
```

---

## 7. 常用 PromQL 查询

```promql
# 每个 Provider QPS
sum(rate(gw_requests_total[5m])) by (provider)

# Provider 成功率
sum(rate(gw_requests_total{status=~"2.."}[5m])) by (provider)
/ sum(rate(gw_requests_total[5m])) by (provider)

# P50 / P95 / P99 延迟
histogram_quantile(0.50, sum(rate(gw_request_duration_seconds_bucket[5m])) by (le, provider))
histogram_quantile(0.95, sum(rate(gw_request_duration_seconds_bucket[5m])) by (le, provider))
histogram_quantile(0.99, sum(rate(gw_request_duration_seconds_bucket[5m])) by (le, provider))

# 错误率
sum(rate(gw_errors_total[5m])) by (provider, error_type)

# 熔断状态（0=closed 1=open 2=half_open）
gw_circuit_breaker_state

# 熔断拒绝速率
sum(rate(gw_circuit_breaker_rejected_total[5m])) by (provider)

# 限流拒绝速率（按维度）
sum(rate(gw_rate_limiter_rejected_total[5m])) by (provider, dimension)

# 降级响应速率（按类型）
sum(rate(gw_degradation_responses_total[5m])) by (provider, type)

# 活跃连接
gw_connections{state="active"}
```

---

## 8. 测试方案

```bash
# 1. 查看模块状态
curl http://localhost:8080/admin/monitor/status

# 2. 查看 Prometheus 指标（初始状态）
curl http://localhost:8080/metrics

# 3. 发送测试请求
for i in $(seq 1 10); do
  curl -s http://localhost:8080/coingecko/api/v3/ping > /dev/null
done

# 4. 再次查看指标变化
curl -s http://localhost:8080/metrics | grep gw_requests_total
curl -s http://localhost:8080/metrics | grep gw_request_duration
curl -s http://localhost:8080/metrics | grep gw_connections
curl -s http://localhost:8080/metrics | grep gw_circuit_breaker_state
curl -s http://localhost:8080/metrics | grep gw_rate_limiter_rejected_total
curl -s http://localhost:8080/metrics | grep gw_circuit_breaker_rejected_total
curl -s http://localhost:8080/metrics | grep gw_degradation_responses_total
```
