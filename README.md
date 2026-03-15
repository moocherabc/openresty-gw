# OpenResty API Gateway

> **版本**: 1.0.0  
> **基础镜像**: openresty/openresty:1.27.1.2-alpine-fat  
> **监听端口**: 8080  
> **架构**: OpenResty + Lua 模块化网关
> **介绍**: OpenResty API Gateway 高性能API网关

---

## 1. 网关整体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         客户端请求                                   │
│                      (HTTP/HTTPS)                                   │
└────────────────────────────┬────────────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │  OpenResty 8080 │
                    └────────┬────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
   ┌─────────┐          ┌─────────┐          ┌─────────┐
   │ Router  │          │Stability│          │ Monitor │
   │ Module  │          │ Module  │          │ Module  │
   └────┬────┘          └────┬────┘          └────┬────┘
        │                    │                    │
        │ ┌──────────────────┼──────────────────┐ │
        │ │                  │                  │ │
        ▼ ▼                  ▼                  ▼ ▼
   ┌──────────────────────────────────────────────────┐
   │  Access Phase (路由匹配 + 认证注入 + 限流检查)    │
   │  ├─ Provider 识别                                │
   │  ├─ 认证信息注入 (Basic/Header/URL)              │
   │  ├─ 限流检查 (3维度漏桶)                         │
   │  └─ 熔断检查 (3态状态机)                         │
   └──────────────────┬───────────────────────────────┘
                      │
        ┌─────────────┼─────────────┐
        │             │             │
        ▼             ▼             ▼
   ┌─────────┐  ┌─────────┐  ┌─────────┐
   │ Zerion  │  │CoinGecko│  │ Alchemy │
   │ API     │  │ API     │  │ API     │
   │ (HTTPS) │  │ (HTTPS) │  │ (HTTPS) │
   └─────────┘  └─────────┘  └─────────┘
        │             │             │
        └─────────────┼─────────────┘
                      │
        ┌─────────────▼─────────────┐
        │   Response Processing     │
        │  ├─ Header Filter         │
        │  ├─ Body Filter           │
        │  └─ Logging & Metrics     │
        └───────────────────────────┘
```

**详细设计**: 参考 [gateway-module-summary.md](docs/gateway-module-summary.md) 了解网关整体架构设计方案

---

## 2. 模块功能说明表格


| 模块                  | 功能      | 核心能力                                | 关键文件                                 | 方案设计                                                                                    | 功能测试                                                                                |
| ------------------- | ------- | ----------------------------------- | ------------------------------------ | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Router**          | 请求路由与转换 | URL前缀匹配 → Provider识别 → 认证注入 → URI重写 | `gateway/router/`                    | [router-module-design.md](docs/architecture-design/router-module-design.md)             | [router-module-test-report.md](docs/router-module-test-report.md)                   |
| **Stability**       | 稳定性保障   | 协调限流、熔断、降级三个子模块                     | `gateway/stability/`                 | [stability-module-design.md](docs/architecture-design/stability-module-design.md)       | -                                                                                   |
| **Rate Limiter**    | 限流保护    | 3维度漏桶算法 (Provider/IP+Provider/IP全局) | `gateway/stability/rate_limiter/`    | [rate-limiter-module-design.md](docs/architecture-design/rate-limiter-module-design.md) | [rate-limiter-module-test-report.md](docs/rate-limiter-module-test-report.md)       |
| **Circuit Breaker** | 熔断保护    | 3态状态机 (CLOSED/OPEN/HALF_OPEN)       | `gateway/stability/circuit_breaker/` | [stability-submodule-design.md](docs/architecture-design/stability-submodule-design.md) | [circuit-breaker-module-test-report.md](docs/circuit-breaker-module-test-report.md) |
| **Degradation**     | 优雅降级    | 限流/熔断触发时返回友好JSON错误                  | `gateway/stability/degradation/`     | [stability-submodule-design.md](docs/architecture-design/stability-submodule-design.md) | [degradation-module-test-report.md](docs/degradation-module-test-report.md)         |
| **Monitor**         | 监控指标    | Prometheus指标采集与暴露                   | `gateway/monitor/`                   | [monitor-module-design.md](docs/architecture-design/monitor-module-design.md)           | [monitor-module-test-report.md](docs/monitor-module-test-report.md)                 |
| **Logger**          | 结构化日志   | JSON访问日志 + 敏感信息脱敏                   | `gateway/logger/`                    | [logger-module-design.md](docs/architecture-design/logger-module-design.md)             | [logger-module-test-report.md](docs/logger-module-test-report.md)                   |
| **Config**          | 配置管理    | 全局配置 + 热更新支持                        | `config.lua`                         | -                                                                                       | -                                                                                   |


---

## 3. 快速启动说明

### 3.1 前置要求

- Docker & Docker Compose
- Linux 环境 (Ubuntu 20.04+ 或 CentOS 7+)
- 网络连接 (需访问外部API)

### 3.2 启动步骤

**1. 配置环境变量**

创建 `.env` 文件 (可选，docker-compose.yml 已有默认值):

```bash
ZERION_API_KEY=your_zerion_key
COINGECKO_API_KEY=your_coingecko_key
ALCHEMY_API_KEY=your_alchemy_key
```

**2. 启动容器**

```bash
docker compose up -d --build
```

**3. 验证网关运行**

```bash
# 健康检查
curl http://localhost:8080/health

# 查看日志
docker-compose logs -f gateway

# 停止容器
docker-compose down
```

### 3.3 快速测试

```bash
# 测试 Zerion 路由
curl -v -X GET "http://localhost:8080/zerion/v1/wallets?address=0x123"

# 测试 CoinGecko 路由
curl -v -X GET "http://localhost:8080/coingecko/api/v3/simple/price?ids=bitcoin"

# 测试 Alchemy路由
curl -v -X POST http://localhost:8080/alchemy/v2/eth_blockNumber \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 查看 Prometheus 指标
curl http://localhost:8080/metrics
```

### 3.4 网络问题解决说明 (可选)

如果网关无法访问外部API（如Zerion、CoinGecko、Alchemy），可能是网络连接问题。可通过配置代理来解决。

**配置代理环境变量**:

在 `docker-compose.yml` 中的 `gateway` 服务添加环境变量：

```yaml
environment:
  http_proxy: "http://ip_addr:port"
  https_proxy: "http://ip_addr:port"
  no_proxy: "localhost,127.0.0.1,.local"
```

其中：
- `ip_addr`: 代理服务器地址
- `port`: 代理服务器端口
- `no_proxy`: 不走代理的地址列表（本地地址、内网地址等）

**重启容器**:

```bash
# 停止容器
docker-compose down

# 重新启动并重新构建
docker-compose up -d --build
```

**验证代理配置**:

```bash
# 进入容器检查环境变量
docker exec openresty-gw env | grep -i proxy

# 测试外部API连接
curl -v http://localhost:8080/health
```

---

## 4. 网关模块简略说明和关键配置

### 4.1 Router 模块 — 请求路由与转换

**功能**: 根据URL前缀匹配Provider，完成认证注入、请求头处理、URI重写。

**支持的 Provider**:


| Provider  | 路径前缀           | 上游地址                          | 认证方式                      |
| --------- | -------------- | ----------------------------- | ------------------------- |
| Zerion    | `/zerion/`*    | api.zerion.io:443             | Basic Auth (API Key作为用户名) |
| CoinGecko | `/coingecko/`* | api.coingecko.com:443         | Header `x-cg-pro-api-key` |
| Alchemy   | `/alchemy/`*   | eth-mainnet.g.alchemy.com:443 | URL Path (`/v2/{key}`)    |


### 4.2 Stability 模块 — 稳定性保障

**功能**: 协调限流、熔断、降级三个子模块，保障网关可用性。

**关键配置**:

```lua
-- lua/gateway/stability/rate_limiter/init.lua
-- 限流: 3维度漏桶
Provider全局: rate=10/s, burst=1
IP+Provider: rate=20/s, burst=1
IP全局: rate=50/s, burst=1
-- lua/gateway/stability/circuit_breaker/init.lua
-- 熔断: 3态状态机
failure_threshold = 1 (连续失败次数)
recovery_timeout = 30s (OPEN持续时间)
half_open_max_requests = 3 (探测请求数)
success_threshold = 2 (恢复所需成功次数)
```

**流程**:

```
请求到达
  ├─ rate_limiter.check() → 限流检查 (3维度)
  ├─ circuit_breaker.before_request() → 熔断检查
  └─ 全部通过 → proxy_pass 转发
```

### 4.3 Monitor 模块 — Prometheus 监控

**关键指标**:


| 指标名                              | 类型        | 说明     |
| -------------------------------- | --------- | ------ |
| `gw_requests_total`              | Counter   | 请求总量   |
| `gw_request_duration_seconds`    | Histogram | 请求延迟分布 |
| `gw_errors_total`                | Counter   | 错误计数   |
| `gw_connections`                 | Gauge     | 连接数    |
| `gw_circuit_breaker_state`       | Gauge     | 熔断器状态  |
| `gw_rate_limiter_rejected_total` | Counter   | 限流拒绝次数 |


### 4.4 Logger 模块 — 结构化日志

**功能**: 输出JSON访问日志，自动脱敏敏感信息。

**脱敏规则**:

- Authorization 头: `Basic` ****
- API Key 参数: 保留前4字符 + `*`***
- Cookie: 完全脱敏

---

## 5. 网关API端点说明

### 5.1 业务端点


| 端点             | 方法                  | 说明               |
| -------------- | ------------------- | ---------------- |
| `/zerion/`*    | GET/POST/PUT/DELETE | Zerion API 代理    |
| `/coingecko/`* | GET/POST/PUT/DELETE | CoinGecko API 代理 |
| `/alchemy/`*   | GET/POST/PUT/DELETE | Alchemy API 代理   |


### 5.2 健康检查端点


| 端点                        | 方法  | 说明        |
| ------------------------- | --- | --------- |
| `/health`                 | GET | 网关健康检查    |
| `/admin/router/health`    | GET | 路由模块健康检查  |
| `/admin/monitor/health`   | GET | 监控模块健康检查  |
| `/admin/logger/health`    | GET | 日志模块健康检查  |
| `/admin/stability/health` | GET | 稳定性模块健康检查 |


### 5.3 状态查询端点


| 端点                                        | 方法  | 说明        |
| ----------------------------------------- | --- | --------- |
| `/admin/router/status`                    | GET | 路由模块状态    |
| `/admin/monitor/status`                   | GET | 监控模块状态    |
| `/admin/logger/status`                    | GET | 日志模块状态    |
| `/admin/stability/status`                 | GET | 稳定性模块聚合状态 |
| `/admin/stability/circuit-breaker/status` | GET | 熔断器状态     |
| `/admin/stability/rate-limiter/status`    | GET | 限流器状态     |
| `/admin/stability/degradation/status`     | GET | 降级器状态     |


### 5.4 调试端点


| 端点                                       | 方法       | 说明    |
| ---------------------------------------- | -------- | ----- |
| `/admin/stability/circuit-breaker/debug` | GET/POST | 熔断器调试 |
| `/admin/stability/rate-limiter/debug`    | GET/POST | 限流器调试 |
| `/admin/stability/degradation/debug`     | GET/POST | 降级器调试 |


### 5.5 管理端点


| 端点              | 方法   | 说明                   |
| --------------- | ---- | -------------------- |
| `/admin/reload` | POST | 热更新配置 (仅本机127.0.0.1) |
| `/metrics`      | GET  | Prometheus 指标输出      |


---

## 6. 测试指南说明

### 6.1 基础功能测试

**测试路由转发**:

```bash
# Zerion 路由
curl -v http://localhost:8080/zerion/v1/wallets?address=0x123

# CoinGecko 路由
curl -v http://localhost:8080/coingecko/api/v3/simple/price?ids=bitcoin

# Alchemy 路由
curl -v http://localhost:8080/alchemy/v2/eth_blockNumber
```

### 6.2 限流测试

**触发限流 (IP全局维度)**:

```bash
# 快速发送50+个请求，触发 IP 全局限流 (rate=50/s)
for i in {1..60}; do
    curl -s http://localhost:8080/health &
done
wait

# 查看限流统计
curl http://localhost:8080/admin/stability/rate-limiter/status
```

**预期响应** (429):

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

### 6.3 熔断测试

**模拟上游故障**:

```bash
# 强制设置熔断器为 OPEN 状态
curl -X POST http://localhost:8080/admin/stability/circuit-breaker/debug \
  -d '{"action":"force_state","provider":"zerion","state":"OPEN"}'

# 发送请求，应返回 503
curl http://localhost:8080/zerion/v1/wallets

# 查看熔断器状态
curl http://localhost:8080/admin/stability/circuit-breaker/status

# 重置熔断器
curl -X POST http://localhost:8080/admin/stability/circuit-breaker/debug \
  -d '{"action":"reset","provider":"zerion"}'
```

**预期响应** (503):

```json
{
    "error": "circuit_open",
    "message": "Service zerion is temporarily unavailable, recovering in progress",
    "provider": "zerion",
    "retry_after": 25
}
```

### 6.4 监控指标测试

**查看 Prometheus 指标**:

```bash
curl http://localhost:8080/metrics | head -50
```

### 6.5 日志测试

**查看结构化日志**:

```bash
# 实时查看日志
docker-compose logs -f gateway

# 过滤特定 provider 的日志
docker-compose logs gateway | grep '"provider":"zerion"'

# 查看错误日志
docker-compose logs gateway | grep '"status":5'
```

---

## 7. Prometheus 集成说明

### 7.1 Prometheus 配置

创建 `prometheus.yml`:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'openresty-gateway'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scrape_interval: 10s
```

### 7.2 启动 Prometheus

```bash
docker run -d \
  --name prometheus \
  -p 9090:9090 \
  -v $(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml \
  prom/prometheus
```

### 7.3 常用查询

```promql
# 请求速率 (req/s)
rate(gw_requests_total[1m])

# 错误率
rate(gw_errors_total[1m]) / rate(gw_requests_total[1m])

# P95 延迟
histogram_quantile(0.95, gw_request_duration_seconds_bucket)

# 熔断器状态
gw_circuit_breaker_state{provider="zerion"}

# 限流拒绝率
rate(gw_rate_limiter_rejected_total[1m])
```

---

## 8. 基础组件版本依赖说明

### 8.1 核心依赖


| 组件             | 版本       | 说明            |
| -------------- | -------- | ------------- |
| Docker         | 20.10+   | 容器运行环境        |
| Docker Compose | 2.0+     | 容器编排工具        |
| OpenResty      | 1.27.1.2 | 基础运行环境        |
| Nginx          | 1.27.1   | 内置于 OpenResty |
| LuaJIT         | 2.1      | Lua 即时编译器     |
| Alpine Linux   | 3.x      | 容器基础镜像        |


### 8.2 Lua 库依赖


| 库                    | 版本     | 用途              |
| -------------------- | ------ | --------------- |
| nginx-lua-prometheus | latest | Prometheus 指标采集 |
| cjson                | 内置     | JSON 编解码        |
| resty.limit.req      | 内置     | 漏桶限流算法          |
| resty.http           | 内置     | HTTP 客户端        |


---

## 9. 快速参考

### 启动/停止

```bash
# 启动
docker compose up -d --build

# 停止
docker-compose down

# 查看日志
docker-compose logs -f gateway

# 重启
docker-compose restart gateway
```

### 常用命令

```bash
# 健康检查
curl http://localhost:8080/health

# 查看指标
curl http://localhost:8080/metrics

# 查看路由状态
curl http://localhost:8080/admin/router/status

# 查看稳定性状态
curl http://localhost:8080/admin/stability/status

# 热更新配置
curl -X POST http://localhost:8080/admin/reload
```

### 调试技巧

```bash
# 进入容器
docker exec -it openresty-gw sh

# 查看 Nginx 进程
docker exec openresty-gw ps aux | grep nginx

# 查看 Nginx 配置
docker exec openresty-gw cat /usr/local/openresty/nginx/conf/nginx.conf

# 测试 Nginx 配置
docker exec openresty-gw openresty -t
```

---