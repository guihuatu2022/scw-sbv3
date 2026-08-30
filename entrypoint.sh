#!/bin/sh
set -e

# Scaleway 会在部署时自动注入 PORT，本地调试时给个默认值
export PORT="${PORT:-8080}"

# 必须由部署时的环境变量提供，缺失就直接失败退出，避免用空 UUID 起服务
if [ -z "${UUID}" ]; then
  echo "ERROR: env UUID is required (VLESS user uuid). Deploy with -e UUID=xxxx-xxxx-...." >&2
  exit 1
fi

# WS_PATH 必须显式设置为高熵随机路径（如 /db/<32位hex>.iso）。
# 本仓库是公开的，若用默认值等于路径公开；故强制要求部署时提供，缺失即失败。
if [ -z "${WS_PATH}" ]; then
  echo "ERROR: env WS_PATH is required. Set a high-entropy random path, e.g. WS_PATH=/db/<32-hex>.iso" >&2
  exit 1
fi

# 排障模式：临时开启 debug 日志，排查完成后改回 error
export LOG_LEVEL="${LOG_LEVEL:-error}"

# --- 低资源容器的系统调优（沙箱可能不允许，失败就跳过，不阻塞启动）---
# 1) 调高 fd 上限：mux 场景每个 WS 连接对应多个子流，fd 不够会直接拒绝
ulimit -n 65535 2>/dev/null || true

# 2) sing-box 配置检查（预检）：用 sing-box check 验证生成的 JSON，
#    避免配置写错导致进程起了但实际不工作（浪费冷启动 CPU 周期）
mkdir -p /etc/sing-box

# busybox 没有 envsubst，用 sed 替换自定义占位符（@XXX@），
# 比 envsubst 更可控：只替换我们指定的几个 token，不会误伤 JSON 里其他 $ 字符
sed -e "s/@PORT@/${PORT}/g" \
    -e "s/@UUID@/${UUID}/g" \
    -e "s#@WS_PATH@#${WS_PATH}#g" \
    -e "s/@LOG_LEVEL@/${LOG_LEVEL}/g" \
    /etc/sing-box/config.template.json > /etc/sing-box/config.json

# 预检：配置有错直接 fail-fast，让平台日志立刻看到错误，不用等到请求进来才发现
sing-box check -c /etc/sing-box/config.json || {
  echo "ERROR: sing-box config check failed. Dumping sanitized config:" >&2
  sed -e 's/"uuid": ".*"/"uuid": "***"/' \
      -e 's#"path": ".*"#"path": "***"#' \
      /etc/sing-box/config.json >&2
  exit 2
}

# 启动日志：UUID / WS_PATH 均脱敏，避免敏感信息进入平台日志
echo "Starting sing-box: PORT=${PORT} WS_PATH=*** LOG_LEVEL=${LOG_LEVEL} GOMAXPROCS=${GOMAXPROCS} GOMEMLIMIT=${GOMEMLIMIT} GOGC=${GOGC} ulimit-n=$(ulimit -n)"

# 打印出去除敏感信息后的配置，便于在平台日志里排查启动问题
sed -e 's/"uuid": ".*"/"uuid": "***"/' \
    -e 's#"path": ".*"#"path": "***"#' \
    /etc/sing-box/config.json

exec sing-box run -c /etc/sing-box/config.json
