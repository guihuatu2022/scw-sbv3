# syntax=docker/dockerfile:1

# ---- 构建阶段：从源码编译，不加任何 -tags，只保留 VLESS + WS 需要的核心功能 ----
FROM golang:1.24-alpine AS builder

ARG SING_BOX_VERSION=v1.13.12
ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64

# 不加 -tags：VLESS 协议和 WS 传输都是核心内置功能，不依赖 with_quic/with_gvisor/
# with_wireguard/with_utls/with_acme/with_clash_api/with_tailscale/with_grpc 等可选特性。
# 这些可选特性只服务于 QUIC/TUN/WireGuard/Reality/ACME/gRPC/Clash面板——本项目一个都用不到。
RUN go install -trimpath -ldflags "-s -w" \
    github.com/sagernet/sing-box/cmd/sing-box@${SING_BOX_VERSION}

# ---- 运行阶段：busybox 代替 debian-slim，镜像从 ~80MB 降到几 MB ----
FROM busybox:1.36-musl

COPY --from=builder /go/bin/sing-box /usr/local/bin/sing-box
COPY config.template.json /etc/sing-box/config.template.json
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/sing-box

# Scaleway 会在部署时把 Port 参数通过 PORT 环境变量注入，这里只是本地调试默认值
# GOMAXPROCS/GOMEMLIMIT/GOGC 是给 128MB/100mCPU 这种极限资源准备的安全阀：
# - GOMAXPROCS=1     避免 Go 运行时按宿主机核心数（而非 cgroup 配额）开线程，浪费调度开销
# - GOMEMLIMIT=90MiB 堆内存软上限降到 90MiB（不是 100MiB）：
#                    留 38MB 给栈/二进制/mux 连接控制块等非堆内存，避免堆刚到 100MiB 就触发 OOM
#                    GOMEMLIMIT 触发的是"GC 强制执行"而非直接 kill，设低一些让 GC 在安全边际内工作
# - GOGC=80          从 off 改为 80（默认 100）：
#                    完全关 GC = 堆碎片严重 → malloc 变慢 + 物理内存逼近 128MB 被平台 OOM Kill 断流
#                    80 比默认更"勤"一点，但配合 GOMEMLIMIT 双保险：堆涨得快时 GOGC 触发，逼近 90MiB 时 GOMEMLIMIT 兜底强制 GC
#                    实测在 0.1vCPU 下，少量可控的 GC 开销 < 频繁 OOM 重连的开销（重连 = WS 握手 + TLS + VLESS 认证，全是 CPU 大头）
ENV PORT=8080 \
    GOMAXPROCS=1 \
    GOMEMLIMIT=90MiB \
    GOGC=80

ENTRYPOINT ["/entrypoint.sh"]
