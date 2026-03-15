# 日志模块技术设计文档

## 1. 模块概述

日志模块负责网关的结构化访问日志输出和应用日志管理，支持请求全生命周期追踪、敏感信息脱敏、大 Body 截断，并兼容 `docker logs` 查看和日志收集器（Filebeat/Fluentd/Vector）采集。

### 1.1 模块职责

| 职责 | 说明 |
|------|------|
| 结构化访问日志 | 以 JSON 格式输出每个请求的完整信息，包含 provider、request_id 等维度 |
| 敏感信息脱敏 | 自动对 API Key、Authorization 等敏感头部进行掩码处理 |
| 大 Body 截断 | 限制日志中 request/response body 长度，防止日志膨胀 |
| 请求生命周期追踪 | 通过 request_id 串联请求各阶段的日志 |
| 错误日志增强 | 对 4xx/5xx 请求输出详细的上下文信息 |
| Docker logs 兼容 | access_log → stdout，error_log → stderr，直接 `docker logs` 查看 |
| 状态暴露 | 提供 `/admin/logger/status` 查看模块配置和运行状态 |

### 1.2 日志分类

| 日志类型 | 输出目标 | 格式 | 说明 |
|----------|----------|------|------|
| 访问日志 (access log) | stdout (`/dev/stdout`) | JSON 每行一条 | 每个请求一条，供日志收集器采集 |
| 应用日志 (error log) | stderr (`/dev/stderr`) | nginx 标准格式 | Lua 代码的 `ngx.log()` 输出 |

---

## 2. 架构设计

### 2.1 模块架构图

```
┌──────────────────────────────────────────────────────────────────┐
│                        请求生命周期                               │
│                                                                  │
│  access_by_lua         header_filter         log_by_lua          │
│  ┌──────────┐          ┌──────────┐          ┌──────────────┐    │
│  │ 记录      │          │ 捕获响应  │          │ logger       │    │
│  │ start_time│   ───►   │ 状态码   │   ───►   │ .log_request │    │
│  │ request_id│          │ 响应头   │          │              │    │
│  └──────────┘          └──────────┘          └──────┬───────┘    │
│                                                      │            │
└──────────────────────────────────────────────────────┤────────────┘
                                                       │
                          ┌────────────────────────────▼──────────┐
                          │     gateway/logger/init.lua            │
                          │     (日志模块协调器)                    │
                          │                                        │
                          │  log_request():                         │
                          │   ├─ formatter.build_log_entry()        │
                          │   ├─ sanitizer.sanitize()               │
                          │   └─ ngx.log() 输出                    │
                          └──┬────────────────┬───────────────────┘
                             │                │
                    ┌────────▼──────┐  ┌──────▼──────────┐
                    │  formatter    │  │   sanitizer      │
                    │  .lua         │  │   .lua           │
                    │               │  │                  │
                    │ 构建结构化    │  │ API Key 掩码     │
                    │ JSON 日志     │  │ Header 脱敏      │
                    │ Body 截断    │  │ Body 内容清理     │
                    └───────────────┘  └──────────────────┘
```

### 2.2 日志在 Docker 中的输出链路

```
┌─── OpenResty 内部 ────────────────────────────────────────────┐
│                                                                │
│  nginx access_log ──► /dev/stdout ──► Docker stdout            │
│                                            │                   │
│  ngx.log()        ──► /dev/stderr ──► Docker stderr            │
│  (error_log)                               │                   │
└────────────────────────────────────────────┤───────────────────┘
                                             │
                                             ▼
                                     ┌───────────────┐
                                     │  docker logs   │
                                     │  onekey-gw     │
                                     │                │
                                     │ 结构化 JSON    │
                                     │ 每行一条记录    │
                                     └───────┬───────┘
                                             │
                              ┌──────────────▼──────────────┐
                              │  日志收集器 (可选)            │
                              │  Filebeat / Fluentd / Vector │
                              │                              │
                              │  解析 JSON → Elasticsearch   │
                              │            → Loki            │
                              │            → ClickHouse      │
                              └──────────────────────────────┘
```

### 2.3 结构化访问日志字段

```json
{
    "timestamp": "2026-03-14T17:30:00+08:00",
    "level": "INFO",
    "type": "access",
    "request_id": "abc123def456",
    "provider": "zerion",

    "request": {
        "method": "GET",
        "uri": "/zerion/v1/fungibles",
        "query_string": "currency=usd",
        "content_length": 0,
        "remote_addr": "172.17.0.1",
        "headers": {
            "user-agent": "curl/7.88.1",
            "accept": "*/*"
        }
    },

    "upstream": {
        "uri": "/v1/fungibles?currency=usd",
        "addr": "104.18.10.35:443",
        "status": 200,
        "response_time": 0.235
    },

    "response": {
        "status": 200,
        "body_bytes_sent": 15234,
        "headers": {
            "content-type": "application/json"
        }
    },

    "latency": {
        "total_ms": 238.5,
        "upstream_ms": 235.0
    },

    "error": null
}
```

**错误请求时 error 字段**：

```json
{
    "error": {
        "type": "gateway_timeout",
        "message": "upstream timed out (110: Connection timed out)",
        "upstream_status": 504
    }
}
```

---

## 3. 文件路径规范

```
lua/
├── log.lua                         # log_by_lua 阶段入口
├── header_filter.lua               # header_filter 阶段（捕获响应信息）
├── body_filter.lua                 # body_filter 阶段（捕获响应体摘要）
└── gateway/
    └── logger/
        ├── init.lua                # 日志模块协调器
        ├── formatter.lua           # 结构化 JSON 日志构建器
        ├── sanitizer.lua           # 敏感信息脱敏处理器
        └── status.lua              # 模块状态查询 API

docs/
└── logger-module-design.md         # 本文档
```

---

## 4. 核心代码设计

### 4.1 脱敏处理器 (`gateway/logger/sanitizer.lua`)

**需要脱敏的内容**：

| 类型 | 规则 | 示例 |
|------|------|------|
| Authorization 头 | 保留类型前缀，掩码凭证 | `Basic ****` |
| API Key 头 | 保留前 4 字符，其余掩码 | `sk-l****` |
| URL 中的 Key | 替换路径中的 Key 段 | `/v2/****/eth...` |
| 请求参数中的 Key | 替换 key/token 参数值 | `api_key=****` |

**核心方法**：

| 方法 | 说明 |
|------|------|
| `sanitizer.sanitize_headers(headers)` | 脱敏请求/响应头 |
| `sanitizer.sanitize_uri(uri)` | 脱敏 URI 中的敏感路径段 |
| `sanitizer.sanitize_args(query_string)` | 脱敏查询参数中的密钥 |
| `sanitizer.mask(value, keep_prefix)` | 通用掩码函数 |

**敏感头/参数名清单**：

```lua
local SENSITIVE_HEADERS = {
    ["authorization"]       = true,
    ["proxy-authorization"] = true,
    ["x-cg-pro-api-key"]   = true,
    ["x-api-key"]           = true,
    ["api-key"]             = true,
    ["cookie"]              = true,
    ["set-cookie"]          = true,
}

local SENSITIVE_PARAMS = {
    ["api_key"] = true, ["apikey"] = true, ["key"]   = true,
    ["token"]   = true, ["secret"] = true, ["password"] = true,
    ["access_token"] = true,
}
```

**通用掩码函数**：

```lua
function _M.mask(value, keep_prefix)
    if not value or value == "" then return "" end
    keep_prefix = keep_prefix or 4
    local len = #value
    if len <= keep_prefix then
        return string.rep("*", len)
    end
    return value:sub(1, keep_prefix) .. string.rep("*", math.min(len - keep_prefix, 8))
end
```

**Header 脱敏** — 识别 Authorization 类型前缀（`Bearer`/`Basic`），其余敏感头走通用掩码：

```lua
function _M.sanitize_headers(headers)
    if not headers then return {} end
    local sanitized = {}
    for name, value in pairs(headers) do
        if type(value) == "table" then
            local vals = {}
            for _, v in ipairs(value) do
                vals[#vals + 1] = sanitize_header_value(name, v)
            end
            sanitized[name] = vals
        else
            sanitized[name] = sanitize_header_value(name, value)
        end
    end
    return sanitized
end
```

**URI 路径段脱敏** — 自动检测路径中 ≥20 字符的长字符串并掩码（典型 API Key 嵌入路径的场景）：

```lua
function _M.sanitize_uri(uri)
    if not uri then return "" end
    return uri:gsub("/([%w%-_]{20,})/", function(segment)
        return "/" .. _M.mask(segment, 4) .. "/"
    end)
end
```

**查询参数脱敏** — 匹配 `SENSITIVE_PARAMS` 中的 key 名称：

```lua
function _M.sanitize_args(query_string)
    if not query_string or query_string == "" then return "" end
    return query_string:gsub("([%w_]+)=([^&]+)", function(key, value)
        if SENSITIVE_PARAMS[key:lower()] then
            return key .. "=" .. _M.mask(value)
        end
        return key .. "=" .. value
    end)
end
```

### 4.2 日志构建器 (`gateway/logger/formatter.lua`)

**核心方法**：

| 方法 | 说明 |
|------|------|
| `formatter.build_access_log()` | 构建完整的访问日志 JSON 字符串 |
| `formatter.build_error_info(status)` | 构建错误信息对象 |
| `formatter.truncate_body(body, max_len)` | 截断大 Body |
| `formatter.safe_headers(headers, max_count)` | 提取安全的头部子集 |

**常量与错误类型映射**：

```lua
local BODY_LOG_THRESHOLD    = 2048
local BODY_TRUNCATE_MAX     = 10240
local MAX_LOG_HEADERS       = 15

local ERROR_TYPE_MAP = {
    [400] = "bad_request",      [401] = "unauthorized",
    [403] = "forbidden",        [404] = "not_found",
    [408] = "request_timeout",  [429] = "rate_limited",
    [502] = "bad_gateway",      [503] = "service_unavailable",
    [504] = "gateway_timeout",
}
```

**Body 截断策略**：

| 条件 | 处理方式 |
|------|----------|
| Body ≤ 2KB | 完整记录 |
| 2KB < Body ≤ 10KB | 截断并标注 `"[truncated: 8532 bytes]"` |
| Body > 10KB | 仅记录大小 `"[body_size: 102400 bytes]"` |

```lua
function _M.truncate_body(body, max_len)
    if not body then return nil end
    max_len = max_len or BODY_TRUNCATE_MAX
    local len = #body
    if len <= BODY_LOG_THRESHOLD then
        return body
    end
    if len <= max_len then
        return body:sub(1, BODY_LOG_THRESHOLD) .. "[truncated: " .. len .. " bytes total]"
    end
    return "[body_size: " .. len .. " bytes]"
end
```

**安全头部提取** — 先调 sanitizer 脱敏，再限制最大数量：

```lua
function _M.safe_headers(raw_headers, max_count)
    if not raw_headers then return {} end
    max_count = max_count or MAX_LOG_HEADERS
    local sanitized = sanitizer.sanitize_headers(raw_headers)
    local result, count = {}, 0
    for name, value in pairs(sanitized) do
        if count >= max_count then break end
        result[name] = value
        count = count + 1
    end
    return result
end
```

**错误信息构建** — 将 HTTP 状态码映射为语义化 error_type：

```lua
function _M.build_error_info(status)
    if status < 400 then return cjson.null end
    local err_type = ERROR_TYPE_MAP[status] or ("http_" .. tostring(status))
    local upstream_status = ngx.var.upstream_status
    local err_msg = nil
    if status >= 500 then
        local upstream_addr = ngx.var.upstream_addr or ""
        if status == 504 then
            err_msg = "upstream timed out"
        elseif status == 502 then
            err_msg = "bad gateway from upstream " .. upstream_addr
        elseif status == 503 then
            err_msg = "service unavailable"
        end
    end
    return {
        type            = err_type,
        message         = err_msg,
        upstream_status = upstream_status,
    }
end
```

**构建完整访问日志条目** — 从 `ngx.ctx.route` / `ngx.var` 提取上下文，组装标准化 JSON：

```lua
function _M.build_access_log()
    local route  = ngx.ctx.route or {}
    local status = ngx.status or 0

    local request_time
    if route.start_time then
        request_time = ngx.now() - route.start_time
    else
        request_time = tonumber(ngx.var.request_time) or 0
    end
    local upstream_time = tonumber(ngx.var.upstream_response_time) or 0

    local req_headers  = ngx.req.get_headers(20) or {}
    local resp_headers = ngx.ctx.response_headers or {}

    local entry = {
        timestamp  = ngx.var.time_iso8601,
        level      = status >= 500 and "ERROR" or (status >= 400 and "WARN" or "INFO"),
        type       = "access",
        request_id = route.request_id or ngx.var.request_id or "",
        provider   = route.provider_name or ngx.var.provider or "",

        request = {
            method         = ngx.req.get_method(),
            uri            = sanitizer.sanitize_uri(ngx.var.uri or ""),
            query_string   = sanitizer.sanitize_args(ngx.var.args or ""),
            content_length = tonumber(ngx.var.request_length) or 0,
            remote_addr    = ngx.var.remote_addr or "",
            headers        = _M.safe_headers(req_headers, MAX_LOG_HEADERS),
        },

        upstream = {
            uri           = sanitizer.sanitize_uri(route.upstream_uri or ""),
            addr          = ngx.var.upstream_addr or "",
            status        = tonumber(ngx.var.upstream_status) or cjson.null,
            response_time = upstream_time,
        },

        response = {
            status          = status,
            body_bytes_sent = tonumber(ngx.var.body_bytes_sent) or 0,
            headers         = _M.safe_headers(resp_headers, 10),
        },

        latency = {
            total_ms    = math.floor(request_time * 1000 * 100) / 100,
            upstream_ms = math.floor(upstream_time * 1000 * 100) / 100,
        },

        error = _M.build_error_info(status),
    }

    return cjson.encode(entry)
end
```

### 4.3 日志模块协调器 (`gateway/logger/init.lua`)

**核心方法**：

| 方法 | 说明 |
|------|------|
| `logger.init()` | 模块初始化（配置加载） |
| `logger.log_request()` | 输出结构化访问日志（log 阶段调用） |
| `logger.capture_response_info()` | 捕获响应信息（header_filter 阶段调用） |
| `logger.get_status()` | 获取模块运行状态 |

**模块配置与日志统计**：

```lua
local log_counts = {
    total = 0,
    info  = 0,
    warn  = 0,
    error = 0,
}

local config = {
    body_log_threshold = 2048,
    body_truncate_max  = 10240,
    max_log_headers    = 15,
    log_request_body   = false,
    log_response_body  = false,
}
```

**header_filter 阶段捕获响应头**：

```lua
function _M.capture_response_info()
    local resp_headers = ngx.resp.get_headers(20)
    if resp_headers then
        local safe = {}
        for k, v in pairs(resp_headers) do
            safe[k] = v
        end
        ngx.ctx.response_headers = safe
    end
end
```

**log_by_lua 阶段输出结构化访问日志** — 按状态码区分日志级别：

```lua
function _M.log_request()
    local route = ngx.ctx.route
    if not route then return end

    local json = formatter.build_access_log()
    if not json then
        ngx.log(ngx.ERR, "[logger] failed to build access log entry")
        return
    end

    local status = ngx.status or 0
    log_counts.total = log_counts.total + 1

    if status >= 500 then
        ngx.log(ngx.ERR, "[access] ", json)
        log_counts.error = log_counts.error + 1
    elseif status >= 400 then
        ngx.log(ngx.WARN, "[access] ", json)
        log_counts.warn = log_counts.warn + 1
    else
        ngx.log(ngx.INFO, "[access] ", json)
        log_counts.info = log_counts.info + 1
    end
end
```

**模块状态查询**：

```lua
function _M.get_status()
    return {
        module         = "logger",
        version        = _M._VERSION,
        status         = initialized and "running" or "not_initialized",
        initialized_at = init_time,
        config         = config,
        log_counts     = log_counts,
    }
end
```

### 4.4 模块状态 API (`gateway/logger/status.lua`)

**核心方法**：

| 方法 | 说明 |
|------|------|
| `status.handle()` | 处理 `GET /admin/logger/status` 请求，返回模块详细状态 |
| `status.health_check()` | 模块健康检查，返回简要健康信息 |

**状态查询处理** — 聚合 logger 模块状态、Worker 信息与日志输出配置：

```lua
function _M.handle()
    ngx.header["Content-Type"] = "application/json"

    local status = logger.get_status()

    status.server_info = {
        worker_pid   = ngx.worker.pid(),
        worker_id    = ngx.worker.id(),
        worker_count = ngx.worker.count(),
        ngx_time     = ngx.now(),
    }

    status.log_output = {
        access_log = "stdout (/dev/stdout)",
        error_log  = "stderr (/dev/stderr)",
        format     = "JSON (structured)",
    }

    local json = cjson.encode(status)
    if not json then
        ngx.status = 500
        ngx.say(cjson.encode({
            error   = "internal_error",
            message = "failed to serialize logger status",
        }))
        return
    end

    ngx.status = 200
    ngx.say(json)
end
```

**健康检查** — 检测模块是否正常初始化：

```lua
function _M.health_check()
    ngx.header["Content-Type"] = "application/json"
    local status = logger.get_status()

    if status.status == "running" then
        ngx.status = 200
        ngx.say(cjson.encode({
            status     = "healthy",
            module     = "logger",
            log_counts = status.log_counts,
        }))
    else
        ngx.status = 503
        ngx.say(cjson.encode({
            status = "unhealthy",
            module = "logger",
            reason = "not initialized",
        }))
    end
end
```

---

## 5. 实现步骤

### Step 1: 实现脱敏处理器
- Authorization / API Key 头部掩码
- URI 路径段和查询参数中的密钥掩码
- 通用掩码工具函数

### Step 2: 实现日志构建器
- 从 `ngx.ctx` / `ngx.var` 提取请求上下文
- 构建标准化 JSON 结构
- Body 截断逻辑
- 安全头部提取（过滤敏感头，限制数量）

### Step 3: 实现模块协调器
- 整合 formatter + sanitizer 的完整日志流程
- 按请求状态区分日志级别 (INFO / WARN / ERR)
- 提供 header_filter 阶段的响应捕获方法

### Step 4: 实现模块状态 API
- 暴露当前日志配置（级别、Body 截断阈值等）
- 暴露已处理日志计数

### Step 5: 集成到请求生命周期
- 更新 `log.lua` 调用 logger 模块
- 更新 `header_filter.lua` 捕获响应信息
- 更新 `nginx.conf` 日志输出到 stdout/stderr
- 添加 `/admin/logger/status` 端点

### Step 6: Docker 适配
- Dockerfile 中创建 `/dev/stdout` 和 `/dev/stderr` 软链
- 验证 `docker logs` 输出结构化 JSON

---

## 6. nginx.conf 日志配置

```nginx
# 结构化 JSON 访问日志 — 输出到 stdout (Docker 兼容)
log_format gw_json escape=json
'{'
    '"timestamp":"$time_iso8601",'
    '"request_id":"$request_id",'
    '"provider":"$provider",'
    '"remote_addr":"$remote_addr",'
    '"method":"$request_method",'
    '"uri":"$uri",'
    '"args":"$args",'
    '"status":$status,'
    '"body_bytes_sent":$body_bytes_sent,'
    '"request_length":$request_length,'
    '"request_time":$request_time,'
    '"upstream_addr":"$upstream_addr",'
    '"upstream_status":"$upstream_status",'
    '"upstream_response_time":"$upstream_response_time",'
    '"http_user_agent":"$http_user_agent",'
    '"http_referer":"$http_referer"'
'}';

access_log /dev/stdout gw_json;
error_log  /dev/stderr warn;
```

---

## 7. 测试方案

```bash
# 1. 查看日志模块状态
curl http://localhost:8080/admin/logger/status

# 2. 发送请求后查看 Docker 日志
curl http://localhost:8080/coingecko/api/v3/ping
docker logs onekey-gw --tail 5

# 3. 验证错误日志（触发 404）
curl http://localhost:8080/unknown/path
docker logs onekey-gw --tail 3

# 4. 验证日志字段完整性
docker logs onekey-gw --tail 1 2>&1 | python3 -m json.tool

# 5. 验证敏感信息不出现在日志中
docker logs onekey-gw 2>&1 | grep -i "api_key\|authorization\|bearer"
```
