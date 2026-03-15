# 路由模块技术设计文档

## 1. 模块概述

路由模块是 OneKey API Gateway 的核心模块，负责将客户端请求根据 URL 路径前缀匹配到对应的第三方 Provider，并完成认证注入、请求头处理、URI 重写等请求转换工作。

### 1.1 模块职责

| 职责 | 说明 |
|------|------|
| 路由匹配 | 根据 URL 前缀匹配 Provider |
| 认证注入 | 为不同 Provider 注入对应的认证信息 |
| 请求头处理 | 过滤 hop-by-hop 头部，注入追踪头部 |
| URI 重写 | 剥离前缀，构造上游 URI |
| 状态暴露 | 提供模块状态查询接口 |

### 1.2 支持的 Provider

| Provider | 路径前缀 | 目标服务 | 认证方式 |
|----------|----------|----------|----------|
| Zerion | `/zerion/*` | `https://api.zerion.io/*` | Basic Auth (API Key 作为用户名) |
| CoinGecko | `/coingecko/*` | `https://api.coingecko.com/*` | Header `x-cg-pro-api-key` |
| Alchemy | `/alchemy/*` | `https://eth-mainnet.g.alchemy.com/*` | API Key 拼接在 URL 路径 |

---

## 2. 架构设计

### 2.1 模块架构图

```
                    ┌──────────────────────────────────────────┐
                    │              nginx.conf                   │
                    │  location /zerion/* ──┐                   │
                    │  location /coingecko/* ├─► access.lua     │
                    │  location /alchemy/*  ─┘                  │
                    └──────────────┬───────────────────────────┘
                                   │
                    ┌──────────────▼───────────────────────────┐
                    │           access.lua (入口)               │
                    │  调用 gateway.router 执行路由流程          │
                    └──────────────┬───────────────────────────┘
                                   │
          ┌────────────────────────▼────────────────────────────┐
          │              gateway/router/init.lua                 │
          │              (路由模块协调器)                         │
          │                                                      │
          │  1. matcher.match(uri)     → 匹配 Provider           │
          │  2. transformer.transform() → 注入认证/处理头部       │
          │  3. 设置 ngx.var 变量       → 控制 proxy_pass         │
          └──┬──────────┬──────────┬────────────────────────────┘
             │          │          │
    ┌────────▼──┐ ┌─────▼─────┐ ┌─▼──────────────┐
    │  matcher   │ │transformer│ │   provider      │
    │  .lua      │ │  .lua     │ │   .lua          │
    │            │ │           │ │                  │
    │ 前缀匹配   │ │ 认证注入   │ │ Provider注册表  │
    │ 路径提取   │ │ 头部过滤   │ │ 配置加载        │
    │ 路由表查询 │ │ 追踪头添加 │ │ 环境变量读取    │
    └───────────┘ └───────────┘ └──────────────────┘
                                         │
                              ┌──────────▼──────────┐
                              │    status.lua        │
                              │  模块状态查询接口     │
                              │  已注册路由列表       │
                              │  Provider 健康信息    │
                              └─────────────────────┘
```

### 2.2 OpenResty 请求处理阶段

```
请求进入
  │
  ├─► init_by_lua        : 加载配置，注册 Provider，构建路由表
  ├─► init_worker_by_lua : Worker 级初始化，定时任务启动
  │
  ├─► access_by_lua      : 路由匹配 → 认证注入 → 头部处理 → URI 重写
  │         │
  │         └─► proxy_pass 转发到上游
  │
  ├─► header_filter_by_lua : 响应头处理（移除敏感头部，添加网关头部）
  ├─► body_filter_by_lua   : 响应体处理（预留扩展）
  └─► log_by_lua           : 记录访问日志（指标采集）
```

---

## 3. 文件路径规范

```
openresty-1.27.1.2-win64/
├── conf/
│   └── nginx.conf                  # Nginx 主配置
├── lua/
│   ├── init.lua                    # init_by_lua 阶段入口
│   ├── init_worker.lua             # init_worker_by_lua 阶段入口
│   ├── access.lua                  # access_by_lua 阶段入口
│   ├── header_filter.lua           # header_filter_by_lua 阶段入口
│   ├── body_filter.lua             # body_filter_by_lua 阶段入口
│   ├── log.lua                     # log_by_lua 阶段入口
│   ├── config.lua                  # 全局配置管理模块
│   └── gateway/
│       └── router/
│           ├── init.lua            # 路由模块主入口（协调器）
│           ├── matcher.lua         # 路由匹配引擎
│           ├── provider.lua        # Provider 配置注册表
│           ├── transformer.lua     # 请求转换器（认证/头部）
│           └── status.lua          # 模块状态查询 API
└── docs/
    └── router-module-design.md     # 本文档
```

---

## 4. 核心代码设计

### 4.1 Provider 注册表 (`gateway/router/provider.lua`)

**职责**：管理所有 Provider 的配置信息，从环境变量加载 API Key。

**数据结构**：

```lua
-- Provider 配置结构
{
    name       = "zerion",              -- Provider 名称
    prefix     = "/zerion",             -- URL 匹配前缀
    upstream   = "zerion_backend",      -- nginx upstream 名称
    host       = "api.zerion.io",       -- 上游 Host
    auth_type  = "basic_auth",          -- 认证类型: basic_auth | header | url_path
    auth_config = {
        env_key  = "ZERION_API_KEY",    -- 环境变量名
        -- basic_auth 类型特有:
        username_is_key = true,         -- API Key 作为用户名
        -- header 类型特有:
        header_name = nil,
        -- url_path 类型特有:
        path_template = nil,
    },
    timeout = {                         -- 超时配置 (可选，覆盖全局默认)
        connect = 5000,
        send    = 30000,
        read    = 30000,
    },
}
```

**核心方法**：

| 方法 | 说明 |
|------|------|
| `provider.init()` | 初始化，注册所有 Provider |
| `provider.get(name)` | 根据名称获取 Provider 配置 |
| `provider.get_all()` | 获取所有 Provider |
| `provider.get_api_key(name)` | 获取指定 Provider 的 API Key |

### 4.2 路由匹配引擎 (`gateway/router/matcher.lua`)

**职责**：根据请求 URI 匹配对应的 Provider，提取后续路径。

**匹配策略**：前缀匹配 + 最长前缀优先

**核心方法**：

| 方法 | 说明 |
|------|------|
| `matcher.init(providers)` | 根据 Provider 列表构建路由表 |
| `matcher.match(uri)` | 匹配 URI，返回 `{provider, captured_path}` |
| `matcher.get_routes()` | 获取当前路由表（调试用） |

**匹配流程**：

```
输入: /zerion/v1/wallets?address=0x123
  │
  ├─ 1. 提取第一段路径: "zerion"
  ├─ 2. 查询路由表: routes["zerion"] → provider_config
  ├─ 3. 提取捕获路径: "v1/wallets"
  ├─ 4. 保留查询参数: "address=0x123"
  │
  └─ 返回: { provider = provider_config, captured_path = "v1/wallets", args = "address=0x123" }
```

### 4.3 请求转换器 (`gateway/router/transformer.lua`)

**职责**：根据 Provider 配置对请求进行认证注入和头部处理。

**核心方法**：

| 方法 | 说明 |
|------|------|
| `transformer.transform(provider, match_result)` | 执行完整的请求转换 |
| `transformer.inject_auth(provider)` | 注入认证信息 |
| `transformer.filter_headers()` | 过滤 hop-by-hop 头部 |
| `transformer.add_trace_header()` | 添加追踪头部 |
| `transformer.rewrite_uri(provider, match_result)` | 重写上游 URI |

**认证注入策略**：

| 认证类型 | 实现方式 |
|----------|----------|
| `basic_auth` | 设置 `Authorization: Basic base64(api_key:)` 头部 |
| `header` | 设置指定的请求头 (如 `x-cg-pro-api-key: <key>`) |
| `url_path` | 将 API Key 拼接到 URI 路径中 (如 `/v2/<key>/eth/...`) |

**需要过滤的 Hop-by-Hop 头部**：

```
host, connection, keep-alive, proxy-authenticate,
proxy-authorization, te, trailers, transfer-encoding, upgrade
```

### 4.4 路由模块协调器 (`gateway/router/init.lua`)

**职责**：作为路由模块的统一入口，协调各子模块完成完整的路由处理流程。

**核心方法**：

| 方法 | 说明 |
|------|------|
| `router.init()` | 模块初始化（在 init_by_lua 阶段调用） |
| `router.process_request()` | 处理请求（在 access_by_lua 阶段调用） |
| `router.get_status()` | 获取模块状态 |

**请求处理流程**：

```
router.process_request()
  │
  ├─ 1. 获取当前 URI 和 Provider 名称
  │     local uri = ngx.var.uri
  │     local provider_name = ngx.var.provider
  │
  ├─ 2. 路由匹配
  │     local match = matcher.match(uri)
  │     if not match then return ngx.exit(404) end
  │
  ├─ 3. 请求转换
  │     transformer.transform(match.provider, match)
  │
  ├─ 4. 设置上游 URI (通过 ngx.var)
  │     ngx.var.backend_uri = match.upstream_uri
  │
  └─ 5. 记录上下文 (供后续阶段使用)
        ngx.ctx.route = match
```

### 4.5 模块状态 API (`gateway/router/status.lua`)

**职责**：暴露路由模块的运行状态，支持独立测试和监控。

**状态接口响应格式**：

```json
{
    "module": "router",
    "version": "1.0.0",
    "status": "running",
    "initialized_at": "2026-03-14T12:00:00Z",
    "providers": {
        "zerion": {
            "prefix": "/zerion",
            "upstream": "zerion_backend",
            "host": "api.zerion.io",
            "auth_type": "basic_auth",
            "api_key_configured": true
        },
        "coingecko": {
            "prefix": "/coingecko",
            "upstream": "coingecko_backend",
            "host": "api.coingecko.com",
            "auth_type": "header",
            "api_key_configured": true
        },
        "alchemy": {
            "prefix": "/alchemy",
            "upstream": "alchemy_backend",
            "host": "eth-mainnet.g.alchemy.com",
            "auth_type": "url_path",
            "api_key_configured": false
        }
    },
    "routes_count": 3,
    "routes": ["/zerion", "/coingecko", "/alchemy"]
}
```

---

## 5. 实现步骤

### Step 1: 实现 Provider 注册表
- 定义 Provider 配置数据结构
- 实现环境变量加载（支持 `os.getenv` 和 `ngx.shared.DICT` 两种方式）
- 实现 Provider 注册和查询方法

### Step 2: 实现路由匹配引擎
- 基于前缀的路由表构建
- URI 解析（前缀提取、路径捕获、查询参数保留）
- 匹配失败的 404 处理

### Step 3: 实现请求转换器
- 三种认证方式的注入逻辑 (Basic Auth / Header / URL Path)
- Hop-by-Hop 头部过滤
- `x-onekey-request-id` 追踪头注入
- URI 重写逻辑

### Step 4: 实现路由协调器
- 整合 matcher + transformer 的完整处理流程
- 设置 ngx.ctx 和 ngx.var 供后续阶段使用
- 错误处理和日志记录

### Step 5: 实现模块状态 API
- 构建状态数据采集逻辑
- 实现 JSON 格式的状态响应
- 在 nginx.conf 中注册 `/admin/router/status` 端点

### Step 6: 集成到请求生命周期
- 编写 access.lua 调用路由模块
- 编写 header_filter.lua 处理响应头
- 编写 body_filter.lua 预留响应体处理
- 编写 log.lua 记录日志

### Step 7: 测试验证
- 启动 OpenResty 验证模块加载
- 通过 `/admin/router/status` 接口查看模块状态
- 使用 curl 测试各 Provider 的路由转发

---

## 6. 测试方案

### 6.1 模块状态检查

```bash
# 查看路由模块状态
curl http://localhost:8080/admin/router/status
```

### 6.2 路由转发测试

```bash
# Zerion (Basic Auth)
curl -v http://localhost:8080/zerion/v1/wallets

# CoinGecko (Header Auth)
curl -v http://localhost:8080/coingecko/api/v3/ping

# Alchemy (URL Path Auth)
curl -v -X POST http://localhost:8080/alchemy/v2/eth_blockNumber \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 未知路由 (应返回 404)
curl -v http://localhost:8080/unknown/path
```

### 6.3 请求头验证

```bash
# 验证追踪头注入
curl -v http://localhost:8080/zerion/v1/wallets 2>&1 | grep x-onekey-request-id

# 验证 hop-by-hop 头过滤（不应转发这些头）
curl -v -H "Connection: keep-alive" -H "Transfer-Encoding: chunked" \
  http://localhost:8080/coingecko/api/v3/ping
```
