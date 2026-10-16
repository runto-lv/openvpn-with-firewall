#!/bin/bash
# ============================================================
# 导出客户端配置（含完整性校验与端口修正）
# ------------------------------------------------------------
# 用法:
#   ./export-client.sh                       # 用默认端口 1194
#   ./export-client.sh 58110                 # 指定宿主机映射端口
#   ./export-client.sh 58110 /tmp/vpn.ovpn   # 指定输出路径
# ============================================================
set -euo pipefail

CONTAINER=${CONTAINER:-openvpn-server}
HOST_PORT=${1:-1194}
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=${2:-$BASE/client.ovpn}

echo "导出客户端配置"
echo "  容器      : $CONTAINER"
echo "  宿主机端口: $HOST_PORT"
echo "  输出      : $OUT"

# 容器内端口（从 server.conf 读取，默认 1194）
C_PORT=$(docker exec "$CONTAINER" sh -c 'grep -E "^port " /etc/openvpn/server.conf | awk "{print \$2}"' 2>/dev/null || echo 1194)
C_PORT=${C_PORT:-1194}

docker exec "$CONTAINER" /usr/local/bin/show-client-config > "$OUT" 2>/dev/null

# 端口修正：容器内端口 → 宿主机映射端口
if [ "$C_PORT" != "$HOST_PORT" ]; then
  sed -i "s| $C_PORT udp| $HOST_PORT udp|" "$OUT"
  echo "  · 端口已修正: $C_PORT → $HOST_PORT"
fi

chmod 600 "$OUT"

echo
echo "  --- 关键配置 ---"
grep -nE '^remote |^proto|^dev |^auth |key-direction' "$OUT" | sed 's/^/    /'

echo
echo "  --- 完整性校验 ---"
fail=0
for k in '^client$' '^<ca>' '^<tls-auth>' '^<cert>' '^<key>'; do
  n=$(grep -c "$k" "$OUT" 2>/dev/null || echo 0)
  if [ "$n" -ge 1 ]; then
    echo "    ✅ $k"
  else
    echo "    ❌ $k 缺失"
    fail=1
  fi
done

if [ "$fail" = "1" ]; then
  echo
  echo "  ⚠️ 配置不完整！可能原因："
  echo "     · USE_CLIENT_CERTIFICATE 未设为 true → 不会有 <cert>/<key>"
  echo "     · 客户端证书未签发 → 见 README 常见问题 Q1"
  exit 1
fi

echo
echo "  ✅ 已导出: $OUT"
echo "  ⚠️  该文件包含客户端私钥，请妥善保管，切勿提交到代码库"
