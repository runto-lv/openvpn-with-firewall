#!/bin/bash
# ============================================================
# 导出客户端配置（自动适配新版 OpenVPN 客户端）
# ------------------------------------------------------------
# 用法:
#   ./export-client.sh <客户端名> [输出文件]
#   ./export-client.sh client1
#   ./export-client.sh client1 /tmp/myvpn.ovpn
#
# 作用:
#   - 调用容器内 ovpn_getclient 导出配置
#   - 将 cipher 替换为 data-ciphers（兼容 OpenVPN 2.5+）
#   - 移除客户端不允许出现的服务端参数（duplicate-cn）
#   - 输出文件权限设为 600
# ============================================================
set -euo pipefail

IMG=${IMG:-openvpn-firewall:v1}
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$BASE/data"

if [ $# -lt 1 ]; then
  echo "用法: $0 <客户端名> [输出文件]"
  echo "  例: $0 client1"
  echo "  例: $0 client1 /tmp/myvpn.ovpn"
  exit 1
fi

CLIENT="$1"
OUT="${2:-$BASE/$CLIENT.ovpn}"

if [ ! -f "$DATA/pki/issued/$CLIENT.crt" ]; then
  echo "❌ 未找到客户端证书: $DATA/pki/issued/$CLIENT.crt"
  echo "   可用的客户端:"
  docker run --rm -v "$DATA:/etc/openvpn" "$IMG" ovpn_listclients 2>/dev/null | sed 's/^/     /'
  exit 1
fi

echo "导出客户端配置: $CLIENT"

docker run --rm -v "$DATA:/etc/openvpn" "$IMG" \
  ovpn_getclient "$CLIENT" > "$OUT"

# 后处理：修正新旧客户端兼容性 + 移除服务端专用参数
python3 - "$OUT" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p, encoding='utf-8').read().splitlines()
out, changed = [], []
for ln in lines:
    s = ln.strip()
    if s.startswith('cipher '):
        out.append('data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC')
        changed.append('cipher → data-ciphers')
        continue
    if s == 'duplicate-cn':
        changed.append('移除 duplicate-cn（服务端专用）')
        continue
    out.append(ln)
open(p, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
for c in changed:
    print(f"  · {c}")
PYEOF

chmod 600 "$OUT"

echo "  ✅ 已导出: $OUT"
echo
echo "  --- 关键配置 ---"
grep -nE '^remote |^proto|^data-ciphers|^auth |route|redirect-gateway|dhcp-option' "$OUT" | sed 's/^/    /'
echo
echo "  ⚠️  该文件包含私钥，请妥善保管，切勿提交到代码库"
