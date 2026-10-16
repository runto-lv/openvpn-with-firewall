#!/bin/bash
# ============================================================
# 一键部署 OpenVPN + iptables 白名单
# ------------------------------------------------------------
# 用法:
#   ./deploy.sh -u udp://vpn.example.com:1194 \
#               -s 172.28.0.0/24 \
#               -t 192.0.2.10 \
#               -p 3389,5985,8088 \
#               -c client1
#
# 作用:
#   1. 构建镜像（若不存在）
#   2. 生成服务端配置（-d -b 不劫持路由 + -p 推路由）
#   3. 初始化 PKI
#   4. 生成客户端证书并导出配置
#   5. 生成 iptables 白名单
#   6. 生成 docker-compose.yml 并启动
# ============================================================
set -euo pipefail

# ---------------- 参数 ----------------
IMG=${IMG:-openvpn-firewall:v1}
SRV_URL="udp://vpn.example.com:1194"
SUBNET="172.28.0.0/24"
TARGET=""
PORTS=""
CLIENT="client1"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$BASE/data"

usage() {
  grep '^#' "$0" | sed 's/^# \?//' | head -20
  exit 0
}

while getopts "u:s:t:p:c:h" opt; do
  case $opt in
    u) SRV_URL="$OPTARG" ;;
    s) SUBNET="$OPTARG" ;;
    t) TARGET="$OPTARG" ;;
    p) PORTS="$OPTARG" ;;
    c) CLIENT="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ -z "$TARGET" ] || [ -z "$PORTS" ]; then
  echo "❌ 必须指定目标 IP (-t) 和端口 (-p)"
  echo "   例: $0 -u udp://vpn.example.com:1194 -s 172.28.0.0/24 -t 192.0.2.10 -p 3389,8088 -c client1"
  exit 1
fi

echo "=================================================================="
echo " 部署 OpenVPN + iptables 白名单"
echo "=================================================================="
echo "  镜像    : $IMG"
echo "  服务地址: $SRV_URL"
echo "  VPN 网段: $SUBNET"
echo "  目标    : $TARGET  端口: $PORTS"
echo "  客户端  : $CLIENT"
echo

# ---------------- 1) 镜像 ----------------
echo "### 1) 检查镜像 ###"
if docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "  ✅ 镜像已存在: $IMG"
else
  echo "  构建镜像..."
  docker build -t "$IMG" "$BASE"
fi

mkdir -p "$DATA"

# ---------------- 2) 服务端配置 ----------------
echo
echo "### 2) 生成服务端配置 ###"
#   -d : 不推送 redirect-gateway（不劫持默认路由）+ 不禁用外部 DNS
#   -b : 不推送 block-outside-dns
#   -p : 推送路由给客户端（关键：客户端据此决定哪些目标走 VPN）
docker run --rm -v "$DATA:/etc/openvpn" "$IMG" \
  ovpn_genconfig \
  -u "$SRV_URL" \
  -s "$SUBNET" \
  -d -b \
  -p "route $TARGET 255.255.255.255" \
  -C AES-256-CBC \
  -a SHA256

# 修正 genconfig 遗留问题
sed -i 's/^cipher SHA256$/cipher AES-256-CBC/' "$DATA/openvpn.conf"
sed -i '/dhcp-option DNS 8\.8\./d' "$DATA/openvpn.conf"
echo "  ✅ 服务端配置已生成"
grep -E '^server |^cipher |push' "$DATA/openvpn.conf" | sed 's/^/    /'

# ---------------- 3) PKI ----------------
echo
echo "### 3) 初始化 PKI ###"
if [ -f "$DATA/pki/ca.crt" ]; then
  echo "  ⚠️  PKI 已存在，跳过（如需重建请先删除 $DATA/pki）"
else
  docker run --rm -v "$DATA:/etc/openvpn" -e EASYRSA_BATCH=1 \
    "$IMG" ovpn_initpki nopass
  echo "  ✅ PKI 已初始化"
fi

# ---------------- 4) 客户端证书 ----------------
echo
echo "### 4) 生成客户端证书 [$CLIENT] ###"
if docker run --rm -v "$DATA:/etc/openvpn" "$IMG" \
     sh -c "[ -f /etc/openvpn/pki/issued/$CLIENT.crt ]" 2>/dev/null; then
  echo "  ⚠️  证书已存在，跳过"
else
  docker run --rm -v "$DATA:/etc/openvpn" -e EASYRSA_BATCH=1 \
    "$IMG" easyrsa build-client-full "$CLIENT" nopass
  echo "  ✅ 已生成"
fi

# 导出并修正客户端配置
docker run --rm -v "$DATA:/etc/openvpn" "$IMG" \
  ovpn_getclient "$CLIENT" > "$BASE/$CLIENT.ovpn"

python3 - "$BASE/$CLIENT.ovpn" <<'PYEOF'
import sys
p = sys.argv[1]
out = []
for ln in open(p, encoding='utf-8').read().splitlines():
    s = ln.strip()
    if s.startswith('cipher '):
        # 新版客户端(2.5+)需要 data-ciphers，否则 hmac/cipher 协商失败
        out.append('data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC')
        continue
    if s == 'duplicate-cn':
        continue      # 服务端专用参数，客户端不允许出现
    out.append(ln)
open(p, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PYEOF
chmod 600 "$BASE/$CLIENT.ovpn"
echo "  ✅ 客户端配置: $BASE/$CLIENT.ovpn"

# ---------------- 5) iptables 白名单 ----------------
echo
echo "### 5) 生成 iptables 白名单 ###"
{
  echo '*filter'
  echo ':INPUT ACCEPT [0:0]'
  echo ':FORWARD ACCEPT [0:0]'
  echo ':OUTPUT ACCEPT [0:0]'
  echo '-A INPUT -p icmp -j ACCEPT'
  echo '-A INPUT -i lo -j ACCEPT'
  echo '-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
  echo '-A INPUT -i tun0 -j ACCEPT'
  echo '-A FORWARD -p icmp -j ACCEPT'
  echo '-A FORWARD -i tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
  echo
  echo "# === 白名单 ==="
  echo "-A FORWARD -i tun0 -p tcp -m multiport --dports $PORTS -d $TARGET -j ACCEPT"
  echo
  echo "# === 默认拒绝 ==="
  echo '-A FORWARD -i tun0 -j DROP'
  echo 'COMMIT'
} > "$DATA/iptables"
echo "  ✅ 白名单: $DATA/iptables"
grep 'FORWARD.*-d ' "$DATA/iptables" | sed 's/^/    /'

# ---------------- 6) compose + 启动 ----------------
echo
echo "### 6) 生成 compose 并启动 ###"
PORT=$(echo "$SRV_URL" | sed -E 's/.*:([0-9]+).*/\1/')
cat > "$BASE/docker-compose.yml" <<YAML
version: '3.8'

services:
  openvpn:
    image: $IMG
    container_name: openvpn-server
    volumes:
      - ./data:/etc/openvpn
    ports:
      - "$PORT:1194/udp"
    environment:
      - IPTABLES_EXTRA_FILE=/etc/openvpn/iptables
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    restart: always
YAML

cd "$BASE"
docker compose up -d 2>&1 | grep -v 'obsolete' || true
sleep 10

echo
echo "### 7) 验证 ###"
docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}|{{.Status}}' | grep openvpn-server | sed 's/^/  /' || echo "  ⚠️ 容器未运行"
echo
docker logs openvpn-server --tail 15 2>&1 | grep -E 'Initialization|entrypoint|ACCEPT|DROP' | sed 's/^/  /'
echo
echo "=================================================================="
echo " 部署完成"
echo "  客户端配置: $BASE/$CLIENT.ovpn"
echo "  白名单文件: $DATA/iptables"
echo "=================================================================="
