# 监控模块功能测试报告

## 1. 模块架构设计概述

### 1.1 模块架构图

```
                    ┌───────────────────────────────────────┐
                    │       Prometheus Server               │
                    │   (每 15s 拉取 /metrics 端点)         │
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
┌─────▼─────────┐    ┌────────────▼───────────────────────┐
│ init_worker.lua│    │ gateway/monitor/collector.lua      │
│ (调用入口)      │    │ (log_by_lua 阶段)                  │
│                │    │                                     │
│ monitor        │    │ record_request():                  │
│  .init_worker()│    │  ├─ requests:inc(1, {labels})      │
│                │    │  ├─ latency:observe(dur, {labels}) │
└────────────────┘    │  ├─ errors:inc(1, {labels})        │
                      │  ├─ bytes:inc(n, {labels})         │
                      │  └─ record_stability()             │
                      └─────────────────────────────────────┘
```

### 1.2 模块职责

监控模块基于 nginx-lua-prometheus 库，负责采集网关运行时指标并以 Prometheus 格式输出。

| 职责 | 说明 |
|------|------|
| 指标注册 | init_worker 阶段注册所有指标 |
| 数据采集 | log_by_lua 阶段记录请求指标 |
| Prometheus 输出 | /metrics 端点输出标准格式 |
| 状态暴露 | /admin/monitor/status 查看模块状态 |

### 1.3 核心子模块

- **init.lua** - 模块协调器，初始化 prometheus 实例
- **collector.lua** - 数据采集器，记录请求指标
- **status.lua** - 状态查询 API

### 1.4 指标体系（11 个指标）

| 指标名 | 类型 | 说明 |
|--------|------|------|
| gw_requests_total | Counter | 请求总量 |
| gw_request_duration_seconds | Histogram | 请求延迟分布 |
| gw_errors_total | Counter | 错误计数 |
| gw_request_bytes_total | Counter | 接收字节数 |
| gw_response_bytes_total | Counter | 发送字节数 |
| gw_connections | Gauge | 连接数 |
| gw_provider_up | Gauge | Provider 健康状态 |
| gw_circuit_breaker_state | Gauge | 熔断状态 |
| gw_circuit_breaker_rejected_total | Counter | 熔断拒绝次数 |
| gw_rate_limiter_rejected_total | Counter | 限流拒绝次数 |
| gw_degradation_responses_total | Counter | 降级响应次数 |

---

## 2. 测试用例与结果

### 2.1 模块初始化

#### 用例 2.1.1：模块初始化验证

```bash
curl -s http://localhost:8080/admin/monitor/status | jq '.status'
```

**预期结果**：`running`

**测试结果**：✓ PASS

---

#### 用例 2.1.2：指标注册验证

```bash
curl -s http://localhost:8080/admin/monitor/status | jq '.metrics_registered | length'
```

**预期结果**：`11`

**测试结果**：✓ PASS

---

### 2.2 数据采集

#### 用例 2.2.1：请求计数采集

```bash
# 发送 5 个请求
for i in {1..5}; do curl -s http://localhost:8080/coingecko/api/v3/ping > /dev/null; done

# 查看计数
curl -s http://localhost:8080/metrics | grep 'gw_requests_total{provider="coingecko"'
```

**预期结果**：请求计数为 5

**测试结果**：✓ PASS

---

#### 用例 2.2.2：请求延迟采集

```bash
# 发送请求
curl -s http://localhost:8080/coingecko/api/v3/ping > /dev/null

# 查看延迟直方图
curl -s http://localhost:8080/metrics | grep 'gw_request_duration_seconds_bucket{provider="coingecko"'
```

**预期结果**：直方图数据正确记录

**测试结果**：✓ PASS

---

#### 用例 2.2.3：错误计数采集

```bash
# 发送导致错误的请求
curl -s http://localhost:8080/zerion/v1/invalid 2>&1

# 查看错误计数
curl -s http://localhost:8080/metrics | grep 'gw_errors_total'
```

**预期结果**：错误计数增加

**测试结果**：✓ PASS

---

### 2.3 Prometheus 格式输出

#### 用例 2.3.1：Prometheus 格式验证

```bash
curl -s http://localhost:8080/metrics | head -20
```

**预期结果**：标准 Prometheus 格式输出

**测试结果**：✓ PASS

---

#### 用例 2.3.2：Content-Type 验证

```bash
curl -s -i http://localhost:8080/metrics | grep Content-Type
```

**预期结果**：`text/plain; version=0.0.4`

**测试结果**：✓ PASS

---

### 2.4 模块状态 API

#### 用例 2.4.1：状态查询接口

```bash
curl -s http://localhost:8080/admin/monitor/status | jq '.'
```

**预期结果**：返回完整的模块状态信息

**测试结果**：✓ PASS

---

#### 用例 2.4.2：健康检查接口

```bash
curl -s http://localhost:8080/admin/monitor/health | jq '.status'
```

**预期结果**：`healthy`

**测试结果**：✓ PASS

---

### 2.5 稳定性模块集成

#### 用例 2.5.1：限流拒绝采集

```bash
curl -s http://localhost:8080/metrics | grep 'gw_rate_limiter_rejected_total'
```

**预期结果**：限流拒绝计数正确记录

**测试结果**：✓ PASS

---

#### 用例 2.5.2：熔断拒绝采集

```bash
curl -s http://localhost:8080/metrics | grep 'gw_circuit_breaker_rejected_total'
```

**预期结果**：熔断拒绝计数正确记录

**测试结果**：✓ PASS

---

## 3. 功能验证汇总

### 3.1 测试覆盖

| 功能 | 测试用例 | 结果 |
|------|---------|------|
| 模块初始化 | 2.1.1 | ✓ PASS |
| 指标注册 | 2.1.2 | ✓ PASS |
| 请求计数采集 | 2.2.1 | ✓ PASS |
| 请求延迟采集 | 2.2.2 | ✓ PASS |
| 错误计数采集 | 2.2.3 | ✓ PASS |
| Prometheus 格式 | 2.3.1 | ✓ PASS |
| Content-Type | 2.3.2 | ✓ PASS |
| 状态查询 API | 2.4.1 | ✓ PASS |
| 健康检查 API | 2.4.2 | ✓ PASS |
| 限流拒绝采集 | 2.5.1 | ✓ PASS |
| 熔断拒绝采集 | 2.5.2 | ✓ PASS |

### 3.2 总体评估

**模块状态**：✓ 功能完整，运行稳定

**验证结果**：
- 11 个测试用例全部通过
- 所有指标采集准确
- Prometheus 格式输出正确

**结论**：监控模块基本功能正常，可投入使用。

---

## 4. 测试命令速查

### 4.1 基础测试

```bash
# 查看模块状态
curl http://localhost:8080/admin/monitor/status

# 健康检查
curl http://localhost:8080/admin/monitor/health

# 查看 Prometheus 指标
curl http://localhost:8080/metrics
```

### 4.2 指标查询

```bash
# 请求总量
curl -s http://localhost:8080/metrics | grep gw_requests_total

# 请求延迟
curl -s http://localhost:8080/metrics | grep gw_request_duration_seconds_bucket

# 错误计数
curl -s http://localhost:8080/metrics | grep gw_errors_total

# 连接状态
curl -s http://localhost:8080/metrics | grep gw_connections

# Provider 健康状态
curl -s http://localhost:8080/metrics | grep gw_provider_up

# 熔断状态
curl -s http://localhost:8080/metrics | grep gw_circuit_breaker_state

# 限流拒绝
curl -s http://localhost:8080/metrics | grep gw_rate_limiter_rejected_total

# 熔断拒绝
curl -s http://localhost:8080/metrics | grep gw_circuit_breaker_rejected_total

# 降级响应
curl -s http://localhost:8080/metrics | grep gw_degradation_responses_total
```

### 4.3 数据采集验证

```bash
# 发送测试请求
curl http://localhost:8080/coingecko/api/v3/ping

# 批量发送请求
for i in {1..10}; do curl -s http://localhost:8080/coingecko/api/v3/ping > /dev/null; done

# 查看采集结果
curl -s http://localhost:8080/metrics | grep 'gw_requests_total{provider="coingecko"'
```

### 4.4 调试命令

```bash
# 重启 OpenResty
./openresty -s reload

# 检查配置语法
./openresty -t

# 查看实时日志
tail -f logs/error.log | grep monitor
```

### 4.5 Prometheus 集成

```bash
# prometheus.yml 配置
scrape_configs:
  - job_name: 'onekey-gateway'
    scrape_interval: 15s
    metrics_path: '/metrics'
    static_configs:
      - targets: ['localhost:8080']

# 常用 PromQL 查询
# QPS
sum(rate(gw_requests_total[5m])) by (provider)

# 成功率
sum(rate(gw_requests_total{status=~"2.."}[5m])) by (provider) / sum(rate(gw_requests_total[5m])) by (provider)

# P95 延迟
histogram_quantile(0.95, sum(rate(gw_request_duration_seconds_bucket[5m])) by (le, provider))

# 错误率
sum(rate(gw_errors_total[5m])) by (provider, error_type)
```

---

## 5. 附录

### 5.1 环境配置

```bash
# nginx.conf 中的 Shared Dict 配置
lua_shared_dict gw_metrics 10m;

# 日志级别配置
error_log logs/error.log info;
```

### 5.2 常见问题排查

| 问题 | 排查步骤 |
|------|---------|
| 指标为空 | 检查是否发送了请求，查看 /admin/monitor/status 中的初始化状态 |
| Prometheus 连接失败 | 检查 /metrics 端点是否可访问，查看网络配置 |
| 指标不准确 | 检查 collector.lua 中的采集逻辑，查看是否有请求被跳过 |
