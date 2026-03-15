# 路由模块功能测试报告

## 1. 模块设计概述

### 1.1 模块职责

路由模块是 OneKey API Gateway 的核心模块，负责以下核心功能：


| 职责     | 说明                                                     |
| ------ | ------------------------------------------------------ |
| 路由匹配   | 根据 URL 前缀匹配请求到对应的 Provider                             |
| 认证注入   | 为不同 Provider 注入对应的认证信息（Basic Auth / Header / URL Path） |
| 请求头处理  | 过滤 hop-by-hop 头部，注入追踪头部                                |
| URI 重写 | 剥离前缀，构造上游 URI                                          |
| 状态暴露   | 提供模块状态查询接口                                             |


### 1.2 支持的 Provider


| Provider  | 路径前缀           | 目标服务                                  | 认证方式                        |
| --------- | -------------- | ------------------------------------- | --------------------------- |
| Zerion    | `/zerion/*`    | `https://api.zerion.io/*`             | Basic Auth                  |
| CoinGecko | `/coingecko/*` | `https://api.coingecko.com/*`         | Header (`x-cg-pro-api-key`) |
| Alchemy   | `/alchemy/*`   | `https://eth-mainnet.g.alchemy.com/*` | URL Path (`/v2/{api_key}`)  |


### 1.3 核心子模块

- **provider.lua** - Provider 配置注册表，管理 API Key 加载
- **matcher.lua** - 路由匹配引擎，前缀匹配 + 最长前缀优先
- **transformer.lua** - 请求转换器，认证注入、头部处理、URI 重写
- **init.lua** - 路由协调器，统一入口协调各子模块
- **status.lua** - 模块状态查询 API

### 1.4 模块架构图

```
                    ┌─────────────────────────────────┐
                    │      客户端请求                   │
                    │  /zerion/v1/wallets             │
                    │  /coingecko/api/v3/ping         │
                    │  /alchemy/v2/eth_blockNumber    │
                    └────────────┬────────────────────┘
                                 │
                    ┌────────────▼────────────────────┐
                    │   gateway/router/init.lua        │
                    │   (路由协调器)                    │
                    └────────────┬────────────────────┘
                                 │
          ┌──────────────────────┼──────────────────────┐
          │                      │                      │
    ┌─────▼──────┐      ┌────────▼────────┐    ┌──────▼──────┐
    │  matcher   │      │  transformer    │    │  provider   │
    │  .lua      │      │  .lua           │    │  .lua       │
    │            │      │                 │    │             │
    │ 前缀匹配   │      │ 认证注入        │    │ 配置注册表  │
    │ 路径提取   │      │ 头部处理        │    │ API Key加载 │
    │ 路由查询   │      │ URI 重写        │    │ 环境变量读取│
    └─────┬──────┘      └────────┬────────┘    └──────┬──────┘
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 │
                    ┌────────────▼────────────────────┐
                    │   请求转发到上游服务             │
                    │   (proxy_pass)                  │
                    └────────────┬────────────────────┘
                                 │
          ┌──────────────────────┼──────────────────────┐
          │                      │                      │
    ┌─────▼──────┐      ┌────────▼────────┐    ┌──────▼──────┐
    │  Zerion    │      │  CoinGecko      │    │  Alchemy    │
    │  Backend   │      │  Backend        │    │  Backend    │
    └────────────┘      └─────────────────┘    └─────────────┘
```

### 1.5 请求处理流程

```
1. 请求到达 → 匹配 URL 前缀
   /zerion/v1/wallets → 提取前缀 "zerion"

2. 查询路由表 → 获取 Provider 配置
   routes["zerion"] → provider_config

3. 提取捕获路径 → 保留查询参数
   /zerion/v1/wallets?address=0x123 → v1/wallets + ?address=0x123

4. 注入认证信息 → 根据认证类型
   Basic Auth / Header / URL Path

5. 处理请求头 → 过滤 hop-by-hop 头部，添加追踪头

6. 重写 URI → 构造上游请求
   /v1/wallets?address=0x123

7. 转发请求 → proxy_pass 到上游服务
```

---

## 2. 测试用例与结果

### 2.1 模块初始化测试

#### 用例 2.1.1：Provider 配置加载

**目标**：验证 Provider 配置正确加载

```bash
# 测试命令
curl -s http://localhost:8080/admin/router/status

# 预期结果
- 返回状态码 200
- 模块状态为 "running"
- 加载 3 个 Provider（zerion, coingecko, alchemy）
```

**测试结果**：✓ PASS

---

### 2.2 路由匹配测试

#### 用例 2.2.1：基本路由匹配

**目标**：验证各 Provider 路由前缀正确匹配

```bash
# Zerion 路由测试
curl http://localhost:8080/zerion/v1/wallets

# CoinGecko 路由测试
curl http://localhost:8080/coingecko/api/v3/ping

# Alchemy 路由测试
curl -X POST http://localhost:8080/alchemy/v2/eth_blockNumber \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 预期结果
- 请求成功转发到对应的上游服务
- 返回状态码 200 或上游服务的响应
```

**测试结果**：✓ PASS

#### 用例 2.2.2：未知路由处理

**目标**：验证未匹配的路由返回 404

```bash
# 测试命令
curl http://localhost:8080/unknown/path

# 预期结果
HTTP/1.1 404 Not Found
{
  "error": "not_found",
  "message": "route not matched: ..."
}
```

**测试结果**：✓ PASS

---

### 2.3 请求处理测试

#### 用例 2.3.1：查询参数保留

**目标**：验证查询参数在转发时保留

```bash
# 测试命令
curl "http://localhost:8080/coingecko/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"

# 预期结果
- 查询参数完整保留并转发到上游
```

**测试结果**：✓ PASS

---

### 2.4 错误处理测试

#### 用例 2.4.1：无效路由错误

**目标**：验证无效路由返回正确的错误响应

```bash
# 测试命令
curl http://localhost:8080/invalid/path

# 预期结果
HTTP/1.1 404 Not Found
Content-Type: application/json
```

**测试结果**：✓ PASS

---

### 2.5 状态查询测试

#### 用例 2.5.1：模块状态查询

**目标**：验证状态接口返回正确信息

```bash
# 测试命令
curl http://localhost:8080/admin/router/status

# 预期结果
{
  "module": "router",
  "status": "running",
  "routes_count": 3,
  "providers": { ... }
}
```

**测试结果**：✓ PASS

#### 用例 2.5.2：健康检查

**目标**：验证健康检查接口正常响应

```bash
# 测试命令
curl http://localhost:8080/admin/router/health

# 预期结果
{
  "status": "healthy",
  "module": "router",
  "routes": 3
}
```

**测试结果**：✓ PASS

---

## 3. 功能验证汇总

### 3.1 核心功能验证

| 功能 | 测试用例 | 结果 | 备注 |
|------|---------|------|------|
| 模块初始化 | 2.1.1 | ✓ PASS | Provider 配置正确加载 |
| 基本路由匹配 | 2.2.1 | ✓ PASS | 3 个 Provider 路由正确 |
| 未知路由处理 | 2.2.2 | ✓ PASS | 返回 404 错误 |
| 查询参数保留 | 2.3.1 | ✓ PASS | 参数完整保留 |
| 无效路由错误 | 2.4.1 | ✓ PASS | 返回 404 错误 |
| 模块状态查询 | 2.5.1 | ✓ PASS | 状态信息正确 |
| 健康检查 | 2.5.2 | ✓ PASS | 健康状态正确 |

### 3.2 总体评估

**模块状态**：✓ 功能完整，运行稳定

**验证结果**：所有基本功能测试通过

**结论**：路由模块基本功能正常，可投入使用。

---

## 4. 测试命令速查

### 4.1 基础测试

```bash
# 查看模块状态
curl http://localhost:8080/admin/router/status

# 健康检查
curl http://localhost:8080/admin/router/health

# Zerion 路由测试
curl http://localhost:8080/zerion/v1/wallets

# CoinGecko 路由测试
curl http://localhost:8080/coingecko/api/v3/ping

# Alchemy 路由测试
curl -X POST http://localhost:8080/alchemy/v2/eth_blockNumber \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 测试未知路由
curl http://localhost:8080/unknown/path
```

### 4.2 调试命令

```bash
# 重启 OpenResty
./openresty -s reload

# 检查配置语法
./openresty -t

# 查看实时日志
tail -f logs/error.log | grep router
```

---

## 5. 附录

### 5.1 环境变量配置

```bash
# 设置 API Keys
export ZERION_API_KEY="your_zerion_api_key"
export COINGECKO_API_KEY="your_coingecko_api_key"
export ALCHEMY_API_KEY="your_alchemy_api_key"
```

### 5.2 常见问题排查

| 问题 | 排查步骤 |
|------|---------|
| 路由不匹配 | 检查 URL 前缀是否正确，查看 `/admin/router/status` 中的 routes 列表 |
| 模块未加载 | 查看错误日志，确认 init_by_lua 阶段是否正常执行 |
| 404 错误 | 验证请求路径是否匹配已注册的 Provider 前缀 |


