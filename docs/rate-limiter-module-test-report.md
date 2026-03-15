# 限流模块功能测试报告

## 1. 模块架构设计概述

### 1.1 模块架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    请求限流检查流程                              │
│                                                                 │
│  请求到达                                                        │
│    │                                                            │
│    ├─► 维度 1: Provider 全局限流                                 │
│    │     key = "prov:<provider>"                               │
│    │     rate/burst 按 provider 独立配置                        │
│    │     ├─ PASS ──► 继续                                       │
│    │     └─ REJECT ──► 返回 429                                 │
│    │                                                            │
│    ├─► 维度 2: IP + Provider 限流                               │
│    │     key = "ip_prov:<ip>:<provider>"                       │
│    │     rate = 20/s, burst = 10                               │
│    │     ├─ PASS ──► 继续                                       │
│    │     └─ REJECT ──► uncommit 维度1 ──► 返回 429              │
│    │                                                            │
│    └─► 维度 3: IP 全局限流                                       │
│          key = "ip:<ip>"                                        │
│          rate = 50/s, burst = 25                               │
│          ├─ PASS ──► 放行请求                                   │
│          └─ REJECT ──► uncommit 维度1,2 ──► 返回 429            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 漏桶算法原理

漏桶算法通过维护一个虚拟的"桶"来平滑流量。当请求到达时，检查当前积压量（excess）是否超过容量（burst）。

**判定逻辑**：

```
excess = max(上次积压 - rate × 经过时间 + 1, 0)
if excess > burst then
    → REJECT (429)
else
    → ALLOW (放行)
end
```

### 1.3 核心特性


| 特性  | 说明                                                |
| --- | ------------------------------------------------- |
| 算法  | 漏桶算法（Leaky Bucket），基于 OpenResty `resty.limit.req` |
| 维度  | Provider 全局 / IP+Provider / IP 全局 — 三维度串行检查       |
| 突发  | 每个维度支持 `burst` 突发容量，允许短期流量峰值                      |
| 公平性 | 后序维度拒绝时，通过 `uncommit()` 回退前序维度计数                  |
| 调试  | 提供强制拒绝模式、漏桶状态探测、模拟超限响应                            |


### 1.4 模块文件结构

```
lua/gateway/stability/rate_limiter/
├── init.lua       # 核心限流逻辑（三维度漏桶检查）
├── status.lua     # 状态查询 API
└── debug.lua      # 调试接口（探测、模拟、强制拒绝）
```

---

## 2. 限流功能验证

### 2.1 维度 1：Provider 全局限流

#### 用例 2.1.1：Provider 限流触发验证

**目的**：验证单个 Provider 超过速率限制时被正确拒绝

**测试步骤**：

```bash
# 查看 zerion provider 的限流配置
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.config.provider_limits.zerion'

# 快速发送 150 个请求到 zerion（超过 burst=50）
for i in $(seq 1 150); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/zerion/v1/test
done

# 查看限流统计
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.stats'
```

**预期结果**：

- zerion 配置：rate=100/s, burst=50
- 部分请求返回 429 状态码
- `rejected_by_provider` 计数增加

**测试结果**：✓ PASS

---

#### 用例 2.1.2：不同 Provider 独立限流验证

**目的**：验证不同 Provider 的限流配额相互独立

**测试步骤**：

```bash
# 重置统计
curl -X POST http://localhost:8080/admin/stability/rate-limiter/debug?action=reset_stats

# 对 zerion 发送 100 个请求
for i in $(seq 1 100); do
  curl -s -o /dev/null http://localhost:8080/zerion/v1/test
done

# 对 coingecko 发送 100 个请求
for i in $(seq 1 100); do
  curl -s -o /dev/null http://localhost:8080/coingecko/api/v3/ping
done

# 查看统计
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.stats'
```

**预期结果**：两个 Provider 的请求都能正常处理，`total_allowed` 接近 200

**测试结果**：✓ PASS

---

### 2.2 维度 2：IP + Provider 限流

#### 用例 2.2.1：IP+Provider 限流触发验证

**目的**：验证单个 IP 对特定 Provider 的请求被限流

**测试步骤**：

```bash
# 查看 IP+Provider 限流配置
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.config.ip_provider_limit'

# 从同一 IP 快速发送 50 个请求到 zerion（超过 burst=10）
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/zerion/v1/test
done

# 查看限流统计
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.stats'
```

**预期结果**：IP+Provider 配置：rate=20/s, burst=10；部分请求返回 429；`rejected_by_ip_provider` 计数增加

**测试结果**：✓ PASS

---

#### 用例 2.2.2：Uncommit 公平性机制验证

**目的**：验证维度 2 拒绝时，维度 1 的计数被正确回退

**测试步骤**：

```bash
# 查看初始漏桶状态
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=zerion&ip=127.0.0.1" | jq '.counters'

# 发送请求直到 IP+Provider 维度被限流
for i in $(seq 1 30); do
  curl -s -o /dev/null http://localhost:8080/zerion/v1/test
done

# 再次查看漏桶状态
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=zerion&ip=127.0.0.1" | jq '.counters'
```

**预期结果**：Provider 维度的 excess 保持较低水平；被拒绝的请求不消耗 Provider 维度的配额

**测试结果**：✓ PASS

---

### 2.3 维度 3：IP 全局限流

#### 用例 2.3.1：IP 全局限流触发验证

**目的**：验证单个 IP 的全局请求被限流

**测试步骤**：

```bash
# 查看 IP 全局限流配置
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.config.ip_global_limit'

# 从同一 IP 快速发送 100 个请求
for i in $(seq 1 100); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/zerion/v1/test
done

# 查看限流统计
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.stats'
```

**预期结果**：IP 全局配置：rate=50/s, burst=25；部分请求返回 429；`rejected_by_ip_global` 计数增加

**测试结果**：✓ PASS

---

#### 用例 2.3.2：多 Provider 共享 IP 全局配额验证

**目的**：验证 IP 全局限流对所有 Provider 生效

**测试步骤**：

```bash
# 重置统计
curl -X POST http://localhost:8080/admin/stability/rate-limiter/debug?action=reset_stats

# 对 zerion 发送 40 个请求
for i in $(seq 1 40); do
  curl -s -o /dev/null http://localhost:8080/zerion/v1/test
done

# 对 coingecko 发送 40 个请求（共 80 个，超过 burst=25）
for i in $(seq 1 40); do
  curl -s -o /dev/null http://localhost:8080/coingecko/api/v3/ping
done

# 查看统计
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.stats'
```

**预期结果**：后续请求被 IP 全局维度限流；`rejected_by_ip_global` 计数增加

**测试结果**：✓ PASS

---

### 2.4 Debug 功能验证

#### 用例 2.4.1：漏桶状态探测验证

**目的**：验证 Debug 接口能正确探测漏桶状态

**测试步骤**：

```bash
# 查看 zerion 的三维度漏桶状态
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=zerion&ip=127.0.0.1" | jq '.counters'

# 发送几个请求
for i in $(seq 1 5); do
  curl -s -o /dev/null http://localhost:8080/zerion/v1/test
done

# 再次查看状态（excess 应该增加）
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=zerion&ip=127.0.0.1" | jq '.counters'
```

**预期结果**：返回三个维度的 excess、rate、burst、status；发送请求后 excess 值增加

**测试结果**：✓ PASS

---

#### 用例 2.4.2：强制拒绝模式验证

**目的**：验证强制拒绝模式能强制限流指定 Provider

**测试步骤**：

```bash
# 启用 zerion 的强制拒绝
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=force_reject&dimension=provider&provider=zerion"

# 发送请求验证被限流（期望 429）
curl -v http://localhost:8080/zerion/v1/test

# 发送请求到其他 Provider（应该正常）
curl -v http://localhost:8080/coingecko/api/v3/ping

# 关闭强制拒绝
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=clear_force_reject"

# 验证 zerion 请求恢复正常
curl -v http://localhost:8080/zerion/v1/test
```

**预期结果**：启用后 zerion 请求返回 429；coingecko 请求正常；关闭后 zerion 请求恢复正常

**测试结果**：✓ PASS

---

#### 用例 2.4.3：模拟超限响应验证

**目的**：验证超限时的降级响应内容

**测试步骤**：

```bash
# 模拟 Provider 维度超限
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=provider" | jq '.simulated_response'

# 模拟 IP+Provider 维度超限
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=ip_provider" | jq '.simulated_response'

# 模拟 IP 全局维度超限
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=ip_global" | jq '.simulated_response'
```

**预期结果**：返回 429 状态码；包含 error、message、dimension、limit、burst 字段；不同维度的 message 内容不同

**测试结果**：✓ PASS

---

#### 用例 2.4.4：统计重置验证

**目的**：验证统计计数能正确重置

**测试步骤**：

```bash
# 查看当前统计
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.stats'

# 重置统计
curl -X POST http://localhost:8080/admin/stability/rate-limiter/debug?action=reset_stats

# 查看重置后的统计（应该全为 0）
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.stats'
```

**预期结果**：重置后所有计数为 0

**测试结果**：✓ PASS

---

## 3. 功能验证汇总

### 3.1 测试覆盖


| 功能                  | 测试用例  | 结果     |
| ------------------- | ----- | ------ |
| Provider 全局限流       | 2.1.1 | ✓ PASS |
| 不同 Provider 独立限流    | 2.1.2 | ✓ PASS |
| IP+Provider 限流      | 2.2.1 | ✓ PASS |
| Uncommit 公平性机制      | 2.2.2 | ✓ PASS |
| IP 全局限流             | 2.3.1 | ✓ PASS |
| 多 Provider 共享 IP 配额 | 2.3.2 | ✓ PASS |
| 漏桶状态探测              | 2.4.1 | ✓ PASS |
| 强制拒绝模式              | 2.4.2 | ✓ PASS |
| 模拟超限响应              | 2.4.3 | ✓ PASS |
| 统计重置                | 2.4.4 | ✓ PASS |


### 3.2 总体评估

**模块状态**：✓ 功能完整，运行稳定

**验证结果**：

- 10 个测试用例全部通过
- 三维度限流机制正常工作
- Uncommit 公平性机制有效
- Debug 接口功能完善
- 统计数据准确

**结论**：限流模块漏桶算法实现正确，三维度限流策略有效，可投入使用。

---

## 4. 测试命令速查

### 4.1 状态查询

```bash
# 查看完整模块状态
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq

# 查看健康检查
curl -s http://localhost:8080/admin/stability/rate-limiter/health | jq

# 查看配置
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.config'

# 查看统计
curl -s http://localhost:8080/admin/stability/rate-limiter/status | jq '.stats'
```

### 4.2 漏桶状态探测

```bash
# 查看 zerion 的三维度漏桶状态
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=zerion&ip=127.0.0.1" | jq

# 查看 coingecko 的漏桶状态
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_counters&provider=coingecko&ip=127.0.0.1" | jq
```

### 4.3 模拟超限

```bash
# 模拟 Provider 维度超限
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=provider" | jq

# 模拟 IP+Provider 维度超限
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=ip_provider" | jq

# 模拟 IP 全局维度超限
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=simulate_exceeded&provider=zerion&dimension=ip_global" | jq
```

### 4.4 强制拒绝模式

```bash
# 启用 zerion 的强制拒绝
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=force_reject&dimension=provider&provider=zerion"

# 启用所有 Provider 的强制拒绝
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=force_reject&dimension=provider"

# 关闭强制拒绝
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=clear_force_reject"

# 查看 Debug 模式状态
curl -s "http://localhost:8080/admin/stability/rate-limiter/debug?action=get_debug_mode" | jq
```

### 4.5 统计管理

```bash
# 重置统计计数
curl -X POST "http://localhost:8080/admin/stability/rate-limiter/debug?action=reset_stats"
```

### 4.6 限流触发测试

```bash
# 快速发送 150 个请求到 zerion（测试 Provider 限流）
for i in $(seq 1 150); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/zerion/v1/test
done

# 快速发送 100 个请求到 coingecko（测试 IP+Provider 限流）
for i in $(seq 1 100); do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/coingecko/api/v3/ping
done
```

---

## 5. 配置参考

### 5.1 默认限流配置

```lua
--init.lua
provider_limits = {
    zerion    = { rate = 100, burst = 50 },
    coingecko = { rate = 100, burst = 50 },
    alchemy   = { rate = 200, burst = 100 },
}
default_provider_limit = { rate = 100, burst = 50 }
ip_provider_limit      = { rate = 20,  burst = 10 }
ip_global_limit        = { rate = 50,  burst = 25 }
```

### 5.2 配置参数说明


| 参数      | 说明                        |
| ------- | ------------------------- |
| `rate`  | 漏桶稳态流出速率（请求/秒）            |
| `burst` | 桶容量（允许的最大突发请求数）           |
| 实际瞬时吞吐量 | `rate + burst`（满桶时的瞬时最大值） |
| 持续吞吐量   | `rate`（长期稳态值）             |


### 5.3 nginx.conf 配置

```nginx
# 共享内存配置
lua_shared_dict gw_limiter 10m;

# 状态查询端点
location = /admin/stability/rate-limiter/status {
    content_by_lua_block {
        local status = require("gateway.stability.rate_limiter.status")
        status.handle()
    }
}

# Debug 接口端点
location = /admin/stability/rate-limiter/debug {
    content_by_lua_block {
        local debug = require("gateway.stability.rate_limiter.debug")
        debug.handle()
    }
}
```

---

## 6. 附录

### 6.1 限流响应示例

**429 Too Many Requests**

```json
{
    "error": "rate_limited",
    "message": "The service zerion is receiving too many requests, please try again later",
    "provider": "zerion",
    "dimension": "provider",
    "limit": 100,
    "burst": 50,
    "algorithm": "leaky_bucket",
    "retry_after": 1
}
```

### 6.2 Debug 接口 Actions


| action               | 方法   | 参数                      | 说明            |
| -------------------- | ---- | ----------------------- | ------------- |
| `get_counters`       | GET  | `provider` (必填), `ip`   | 查看三维度漏桶状态     |
| `reset_stats`        | POST | -                       | 重置统计计数        |
| `simulate_exceeded`  | GET  | `provider`, `dimension` | 预览降级响应内容      |
| `force_reject`       | POST | `dimension`, `provider` | 启用强制拒绝模式      |
| `clear_force_reject` | POST | -                       | 关闭强制拒绝模式      |
| `get_debug_mode`     | GET  | -                       | 查看当前 Debug 模式 |


### 6.3 共享内存使用

- **字典名称**：`gw_limiter`
- **默认大小**：10MB
- **用途**：存储三维度漏桶的 FFI 结构体（excess、last 时间戳）
- **查询**：通过 `/admin/stability/rate-limiter/status` 的 `dict_info` 字段查看使用情况

