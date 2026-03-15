FROM openresty/openresty:1.27.1.2-alpine-fat

LABEL maintainer="OpenResty Gateway Team"
LABEL description="OpenResty API Gateway - OpenResty based proxy"

# 安装 nginx-lua-prometheus 库
# https://github.com/knyar/nginx-lua-prometheus
RUN luarocks install nginx-lua-prometheus

ENV ZERION_API_KEY=""
ENV COINGECKO_API_KEY=""
ENV ALCHEMY_API_KEY=""

ARG PREFIX=/usr/local/openresty/nginx

RUN mkdir -p ${PREFIX}/lua/gateway/router \
             ${PREFIX}/lua/gateway/monitor \
             ${PREFIX}/lua/gateway/logger \
             ${PREFIX}/lua/gateway/stability \
             ${PREFIX}/lua/gateway/stability/circuit_breaker \
             ${PREFIX}/lua/gateway/stability/rate_limiter \
             ${PREFIX}/lua/gateway/stability/degradation \
             ${PREFIX}/logs

COPY conf/nginx.conf ${PREFIX}/conf/nginx.conf

# 阶段入口文件
COPY lua/init.lua            ${PREFIX}/lua/init.lua
COPY lua/init_worker.lua     ${PREFIX}/lua/init_worker.lua
COPY lua/access.lua          ${PREFIX}/lua/access.lua
COPY lua/header_filter.lua   ${PREFIX}/lua/header_filter.lua
COPY lua/body_filter.lua     ${PREFIX}/lua/body_filter.lua
COPY lua/log.lua             ${PREFIX}/lua/log.lua
COPY lua/config.lua          ${PREFIX}/lua/config.lua
COPY lua/metrics.lua         ${PREFIX}/lua/metrics.lua
COPY lua/circuit_breaker.lua ${PREFIX}/lua/circuit_breaker.lua

# 路由模块
COPY lua/gateway/router/init.lua        ${PREFIX}/lua/gateway/router/init.lua
COPY lua/gateway/router/provider.lua    ${PREFIX}/lua/gateway/router/provider.lua
COPY lua/gateway/router/matcher.lua     ${PREFIX}/lua/gateway/router/matcher.lua
COPY lua/gateway/router/transformer.lua ${PREFIX}/lua/gateway/router/transformer.lua
COPY lua/gateway/router/status.lua      ${PREFIX}/lua/gateway/router/status.lua

# 监控模块
COPY lua/gateway/monitor/init.lua       ${PREFIX}/lua/gateway/monitor/init.lua
COPY lua/gateway/monitor/collector.lua  ${PREFIX}/lua/gateway/monitor/collector.lua
COPY lua/gateway/monitor/status.lua     ${PREFIX}/lua/gateway/monitor/status.lua

# 日志模块
COPY lua/gateway/logger/init.lua        ${PREFIX}/lua/gateway/logger/init.lua
COPY lua/gateway/logger/formatter.lua   ${PREFIX}/lua/gateway/logger/formatter.lua
COPY lua/gateway/logger/sanitizer.lua   ${PREFIX}/lua/gateway/logger/sanitizer.lua
COPY lua/gateway/logger/status.lua      ${PREFIX}/lua/gateway/logger/status.lua

# 稳定性模块 — 协调器 + 聚合状态
COPY lua/gateway/stability/init.lua            ${PREFIX}/lua/gateway/stability/init.lua
COPY lua/gateway/stability/status.lua          ${PREFIX}/lua/gateway/stability/status.lua

# 稳定性模块 — 熔断器子模块
COPY lua/gateway/stability/circuit_breaker/init.lua   ${PREFIX}/lua/gateway/stability/circuit_breaker/init.lua
COPY lua/gateway/stability/circuit_breaker/status.lua ${PREFIX}/lua/gateway/stability/circuit_breaker/status.lua
COPY lua/gateway/stability/circuit_breaker/debug.lua  ${PREFIX}/lua/gateway/stability/circuit_breaker/debug.lua

# 稳定性模块 — 限流器子模块
COPY lua/gateway/stability/rate_limiter/init.lua   ${PREFIX}/lua/gateway/stability/rate_limiter/init.lua
COPY lua/gateway/stability/rate_limiter/status.lua ${PREFIX}/lua/gateway/stability/rate_limiter/status.lua
COPY lua/gateway/stability/rate_limiter/debug.lua  ${PREFIX}/lua/gateway/stability/rate_limiter/debug.lua

# 稳定性模块 — 降级器子模块
COPY lua/gateway/stability/degradation/init.lua   ${PREFIX}/lua/gateway/stability/degradation/init.lua
COPY lua/gateway/stability/degradation/status.lua ${PREFIX}/lua/gateway/stability/degradation/status.lua
COPY lua/gateway/stability/degradation/debug.lua  ${PREFIX}/lua/gateway/stability/degradation/debug.lua

EXPOSE 8080

STOPSIGNAL SIGQUIT

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -sf http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/usr/local/openresty/bin/openresty"]
CMD ["-g", "daemon off;", "-p", "/usr/local/openresty/nginx"]
