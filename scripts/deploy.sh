#!/bin/bash
# ============================================================
# 一键部署 OpenVPN（无 LDAP，纯证书认证）
# ------------------------------------------------------------
# 基于 wheelybird/openvpn-server-ldap-otp，通过 USE_CLIENT_CERTIFICATE=true
# 关闭 LDAP，改用客户端证书。
#
# 用法:
#   ./deploy.sh -c vpn.example.com -t 192.0.2.10 -p 1194
#   ./deploy.sh -c vpn.example.com -t 192.0.2.10,192.0.2.11 -p 1194 -P 58110
# ============================================================
set -euo pipefail

# ---------------- 默认参数 ----------------
IMG=${IMG:-openvpn-no-ldap:v1}
SRC_REPO=${SRC_REPO:-https://github.com/wheelybird/openvpn-server-ldap-otp.git}
SERVER_CN="vpn.example.com"
TARGETS=""                       # OVPN_ROUTES
CONTAINER_PORT=1194              # 容器内端口
HOST_PORT=1194                   # 宿主机映射端口
VPN_NETWORK="172.28.0.0 255.255.255.0"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$BASE/data"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit 0
}

while getopts "c:t:p:P:n:i:h" opt; do
  case $opt in
    c) SERVER_CN="$OPTARG" ;;
    t) TARGETS="$OPTARG" ;;
    p) CONTAINER_PORT="$OPTARG" ;;
    P) HOST_PORT="$OPTARG" ;;
    n) VPN_NETWORK="$OPTARG" ;;
    i) IMG="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [ -z "$TARGETS" ]; then
  echo "❌ 必须指定目标 (-t)，例如 -t 192.0.2.10"
  echo "   目标会同时用于：push route + iptables MASQUERADE"
  exit 1
fi

echo "=================================================================="
echo " 部署 OpenVPN（无 LDAP / 纯证书）"
echo "=================================================================="
echo "  镜像      : $IMG"
echo "  服务端 CN : $SERVER_CN"
echo "  VPN 网段  : $VPN_NETWORK"
echo "  目标      : $TARGETS"
echo "  端口      : $CONTAINER_PORT (容器) → $HOST_PORT (宿主)"
echo

# ---------------- 1) 构建镜像 ----------------
echo "### 1) 检查/构建镜像 ###"
if docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "  ✅ 镜像已存在: $IMG"
else
  TMP=$(mktemp -d)
  echo "  克隆上游源码到 $TMP ..."
  git clone --depth 1 "$SRC_REPO" "$TMP/src"
  echo "  构建镜像（需要联网下载 apt 包与 PAM 模块）..."
  docker build -t "$IMG" "$TMP/src"
  rm -rf "$TMP"
  echo "  ✅ 镜像构建完成"
fi

mkdir -p "$DATA"

# ---------------- 2) 首次启动（生成服务端 PKI）----------------
echo
echo "### 2) 生成服务端 PKI ###"
if [ -f "$DATA/pki/issued/${SERVER_CN}.crt" ]; then
  echo "  ℹ️  PKI 已存在，跳过"
else
  echo "  首次启动（预期会因缺客户端证书而退出，这是正常的）..."
  docker run --rm -v "$DATA:/etc/openvpn" \
    -e USE_CLIENT_CERTIFICATE=true \
    -e OVPN_SERVER_CN="$SERVER_CN" \
    -e OVPN_NETWORK="$VPN_NETWORK" \
    -e OVPN_ROUTES="$TARGETS" \
    "$IMG" /usr/local/bin/entrypoint 2>&1 | tail -5 || true
  echo "  ✅ 服务端 PKI 已生成"
fi

# ---------------- 3) 签发客户端证书 ----------------
echo
echo "### 3) 签发客户端证书 [client] ###"
if [ -f "$DATA/pki/issued/client.crt" ] && [ -f "$DATA/pki/private/client.key" ]; then
  echo "  ℹ️  客户端证书已存在，跳过"
else
  docker run --rm -v "$DATA:/etc/openvpn" --entrypoint sh "$IMG" -c '
    export EASYRSA_PKI=/etc/openvpn/pki
    sed -i "s/^RANDFILE/#RANDFILE/g" /opt/easyrsa/openssl-easyrsa.cnf
    /opt/easyrsa/easyrsa --batch build-client-full client nopass
  ' 2>&1 | tail -8
fi

if [ ! -f "$DATA/pki/issued/client.crt" ] || [ ! -f "$DATA/pki/private/client.key" ]; then
  echo "  ❌ 客户端证书签发失败，请检查上一步输出"
  exit 1
fi
echo "  ✅ client.crt / client.key 已就绪"

# ---------------- 4) 生成 compose 并启动 ----------------
echo
echo "### 4) 生成 docker-compose.yml 并启动 ###"
cat > "$BASE/docker-compose.yml" <<YAML
version: '3.8'

services:
  openvpn:
    image: $IMG
    container_name: openvpn-server
    volumes:
      - ./data:/etc/openvpn
    ports:
      - "$HOST_PORT:$CONTAINER_PORT/udp"
    environment:
      - USE_CLIENT_CERTIFICATE=true
      - OVPN_SERVER_CN=$SERVER_CN
      - OVPN_PORT=$CONTAINER_PORT
      - OVPN_PROTOCOL=udp
      - OVPN_INTERFACE_NAME=tun
      - OVPN_NETWORK=$VPN_NETWORK
      - OVPN_DEFAULT_SERVER=true
      - OVPN_NAT=true
      - OVPN_ROUTES=$TARGETS
      - LOG_TO_STDOUT=true
      - OVPN_VERBOSITY=3
      - REGENERATE_CERTS=false
      - KEY_LENGTH=2048
      - FAIL2BAN_ENABLED=false
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    restart: always
YAML

cd "$BASE"
docker compose up -d 2>&1 | grep -v 'obsolete' || true
sleep 15

# ---------------- 5) 验证 ----------------
echo
echo "### 5) 验证 ###"
docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}|{{.Status}}' | grep openvpn-server | sed 's/^/  /' || echo "  ⚠️ 容器未运行"

echo
echo "  --- 自动生成的 NAT 规则（应命中 >0）---"
docker exec openvpn-server iptables -t nat -L POSTROUTING -n -v 2>&1 | grep -E 'MASQUERADE|pkts' | sed 's/^/    /'

echo
echo "  --- 推送的路由 ---"
docker exec openvpn-server sh -c 'grep "^push" /etc/openvpn/server.conf' 2>/dev/null | sed 's/^/    /'

# ---------------- 6) 导出客户端配置 ----------------
echo
echo "### 6) 导出客户端配置 ###"
docker exec openvpn-server /usr/local/bin/show-client-config > "$BASE/client.ovpn" 2>/dev/null
# 端口修正：容器内端口 → 宿主机端口
sed -i "s| $CONTAINER_PORT udp| $HOST_PORT udp|" "$BASE/client.ovpn"
chmod 600 "$BASE/client.ovpn"
echo "  ✅ $BASE/client.ovpn"
grep -E '^remote ' "$BASE/client.ovpn" | sed 's/^/    /'
echo
echo "  --- 配置完整性 ---"
for k in '^client$' '^<ca>' '^<tls-auth>' '^<cert>' '^<key>'; do
  n=$(grep -c "$k" "$BASE/client.ovpn" || echo 0)
  [ "$n" -ge 1 ] && echo "    ✅ $k ($n)" || echo "    ❌ $k 缺失"
done

echo
echo "=================================================================="
echo " 部署完成"
echo "  客户端配置: $BASE/client.ovpn"
echo "  提示: 每次重建 PKI 后，ta.key/CA 会变化，必须重新分发客户端配置"
echo "=================================================================="
