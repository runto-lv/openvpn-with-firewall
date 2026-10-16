#!/bin/bash
# ============================================================
# 包装入口：仅当执行 ovpn_run 时才注入 iptables 白名单
# ------------------------------------------------------------
# ★ 关键：必须放行 kylemanna 的管理命令
#    (ovpn_genconfig / ovpn_initpki / easyrsa / ovpn_getclient ...)
#    否则这些命令会被误当成 OpenVPN 启动 → 配置生成失败
# ============================================================
set -u

RULES="${IPTABLES_EXTRA_FILE:-/etc/openvpn/iptables}"
WAIT_SEC=60
log() { echo "[$(date '+%F %T')] [entrypoint] $*"; }

# ---------- 放行所有非 ovpn_run 的命令（管理命令、sh、ls ...） ----------
case "${1:-}" in
  ovpn_run|/usr/local/bin/ovpn_run)
    ;; # 走下面的包装逻辑
  *)
    exec "$@"   # 其它命令直接透传
    ;;
esac

# ============================================================
# 以下是 ovpn_run 的包装：启动 OpenVPN 后套用 iptables 白名单
# ============================================================

# 1) 后台启动 OpenVPN
log "启动 OpenVPN (后台)..."
/usr/local/bin/ovpn_run "${@:2}" &
OVPN_PID=$!

# 2) 等待 tun0 就绪
log "等待 tun0 接口就绪 (最多 ${WAIT_SEC}s)..."
tun_ok=0
for i in $(seq 1 "$WAIT_SEC"); do
    if ip link show tun0 >/dev/null 2>&1; then
        log "✅ tun0 已就绪 (用时 ${i}s)"; tun_ok=1; break
    fi
    if ! kill -0 "$OVPN_PID" 2>/dev/null; then
        log "❌ OpenVPN 进程已退出，停止等待"; break
    fi
    sleep 1
done
[ "$tun_ok" = "0" ] && log "⚠️  tun0 未在 ${WAIT_SEC}s 内出现，仍尝试套用规则"
sleep 2

# 3) 套用 iptables 白名单
if [ -f "$RULES" ]; then
    log "套用白名单规则: $RULES"
    if iptables-restore < "$RULES" 2>/tmp/ipt-error.log; then
        log "✅ 白名单已生效"
        iptables -L FORWARD -n --line-numbers 2>/dev/null | head -20 | sed 's/^/    /'
    else
        log "❌ 套用失败:"; sed 's/^/    /' /tmp/ipt-error.log
    fi
else
    log "⚠️  未找到 $RULES —— 不做流量限制"
fi

# 4) 前台等待 OpenVPN
log "进入守护模式，等待 OpenVPN 进程 (PID $OVPN_PID)"
wait "$OVPN_PID"
log "OpenVPN 已退出 (code $?)，容器结束"
