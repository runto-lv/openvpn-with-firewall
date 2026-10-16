# OpenVPN 无 LDAP 部署方案（纯证书认证）

基于 [`wheelybird/openvpn-server-ldap-otp`](https://github.com/wheelybird/openvpn-server-ldap-otp) 镜像，通过环境变量开关**关闭 LDAP 认证、改用客户端证书**，保留镜像原有的其余全部能力（自动路由、自动 NAT、fail2ban、管理接口等）。

## 项目背景

原镜像 `wheelybird/openvpn-server-ldap-otp` 默认使用 **LDAP/AD 域账号 + 可选 TOTP 双因子** 作为身份认证。

某些场景（如自动化系统间通信、AI Agent 专用通道）不需要或无法使用域账号，需要**纯客户端证书认证**。

**上游已内置该能力** —— 只需设置环境变量即可，无需修改代码：

```yaml
environment:
  - USE_CLIENT_CERTIFICATE=true    # ★ 关闭 LDAP，启用纯证书认证
```

## 核心机制

### 1. `USE_CLIENT_CERTIFICATE` 开关

| 值 | 认证方式 | 是否需 LDAP 变量 | PAM/OTP |
|---|---|---|---|
| `true` | **客户端证书** | ❌ 不需要 | ❌ 不加载 |
| `false`（默认）| LDAP + 可选 TOTP | ✅ 必需 | ✅ 加载 |

**内核逻辑**（`create_server_config.sh`）：
```bash
if [ "${USE_CLIENT_CERTIFICATE,,}" != "true" ] ; then
  plugin ... openvpn-plugin-auth-pam.so openvpn
  verify-client-cert optional
  username-as-common-name
fi
```

**注意**：`USE_CLIENT_CERTIFICATE=true` 时，镜像**不会自动生成客户端证书**，需**提前签发**（见下文「重要陷阱」）。

### 2. 自动路由 + 自动 NAT（本方案的关键）

镜像的 `setup_networking.sh` 会**根据 `OVPN_ROUTES` 自动**：

1. **推送路由给客户端**：`push "route <route>"`
2. **创建 NAT 规则**：`iptables -t nat -A POSTROUTING -s <VPN网段> -d <目标网段> -o eth0 -j MASQUERADE`

**这正是让客户端能访问内网目标的核心** —— 且无需手工维护 iptables。

```
# 部署后自动生成（示例）
-A POSTROUTING -s 172.28.0.0/24 -d 192.168.120.0/24 -o eth0 -j MASQUERADE
```

## 快速开始

### 1. 构建镜像

```bash
git clone https://github.com/wheelybird/openvpn-server-ldap-otp.git
cd openvpn-server-ldap-otp
docker build -t openvpn-no-ldap:v1 .
```

### 2. 准备目录

```bash
mkdir -p data
```

### 3. 首次启动（生成 PKI）

```bash
docker run --rm -v "$PWD/data:/etc/openvpn" \
  -e USE_CLIENT_CERTIFICATE=true \
  -e OVPN_SERVER_CN=vpn.example.com \
  -e OVPN_NETWORK="172.28.0.0 255.255.255.0" \
  -e OVPN_ROUTES="192.0.2.10" \
  openvpn-no-ldap:v1 \
  /usr/local/bin/entrypoint || true
```

> ⚠️ 首次启动会**因缺少客户端证书而失败**，但**服务端 PKI 已生成**。这是预期行为。

### 4. 签发客户端证书

```bash
docker run --rm -v "$PWD/data:/etc/openvpn" --entrypoint sh openvpn-no-ldap:v1 -c '
  export EASYRSA_PKI=/etc/openvpn/pki
  sed -i "s/^RANDFILE/#RANDFILE/g" /opt/easyrsa/openssl-easyrsa.cnf
  /opt/easyrsa/easyrsa --batch build-client-full client nopass
'
```

> ⚠️ 上游 `setup_pki.sh` 里的 `build-client-full` 在某些情况下会静默失败，**务必手动确认 `pki/issued/client.crt` 和 `pki/private/client.key` 存在**。

### 5. 启动服务

```bash
docker compose up -d
docker logs -f openvpn-server
```

正常启动的日志应包含：

```
routes: adding route 192.0.2.10 to server config
iptables: masquerade from 172.28.0.0/24 to 192.0.2.10/24 via eth0
Initialization Sequence Completed
```

### 6. 导出客户端配置

```bash
docker exec openvpn-server /usr/local/bin/show-client-config > client.ovpn
sed -i 's| 1194 udp| 1194 udp|' client.ovpn   # 按实际映射端口调整
chmod 600 client.ovpn
```

客户端配置中应包含：`<ca>`、`<tls-auth>`、`<cert>`、`<key>` 四段。

## 配置说明

| 环境变量 | 示例值 | 说明 |
|---|---|---|
| **`USE_CLIENT_CERTIFICATE`** | `true` | ★ **关闭 LDAP，启用证书认证** |
| `OVPN_SERVER_CN` | `vpn.example.com` | 服务端证书 CN（也是客户端配置里的 remote 域名）|
| `OVPN_NETWORK` | `172.28.0.0 255.255.255.0` | **VPN 内部网段**（避开办公网/云 VPC）|
| **`OVPN_ROUTES`** | `192.0.2.10` | ★ **目标网段/主机** → 自动 push route + 自动 NAT |
| `OVPN_NAT` | `true` | 启用 NAT（默认 true）|
| `OVPN_PORT` | `1194` | 容器内端口（由 Docker 映射到宿主机）|
| `OVPN_PROTOCOL` | `udp` | 协议 |
| `OVPN_INTERFACE_NAME` | `tun` | 隧道接口名 |
| `OVPN_DNS_SERVERS` | （留空）| 不下发 DNS 就留空 |
| `FAIL2BAN_ENABLED` | `false` | 是否启用 fail2ban（与认证方式无关）|
| `REGENERATE_CERTS` | `false` | 是否重新生成 PKI |
| `KEY_LENGTH` | `2048` | 证书密钥长度 |

## 常见问题

### Q1: 启动失败 `USE_CLIENT_CERTIFICATE was set to 'true', but the client certificates weren't generated`

**原因**：镜像**不会自动签发客户端证书**，但启动时校验其存在。

**解决**：按上文第 4 步手动签发 `client` 证书，再启动。

```bash
# 验证
ls -la data/pki/issued/client.crt data/pki/private/client.key
```

### Q2: 客户端报 `TLS Error: cannot locate HMAC in incoming packet`

**原因**：客户端使用的 `.ovpn` 与当前服务端的加密材料（`ta.key`、CA）不匹配 —— 通常是**复用了旧环境导出的配置**。

**解决**：**重新导出**客户端配置：

```bash
docker exec openvpn-server /usr/local/bin/show-client-config > new.ovpn
```

每次重建 PKI 后，`ta.key` 和 CA 都会变化，必须重新分发配置。

### Q3: 连上 VPN 后无法访问目标主机

按顺序排查：

1. **服务端是否有 NAT 规则？**
   ```bash
   docker exec openvpn-server iptables -t nat -L POSTROUTING -n -v
   # 应有并命中：-s <VPN网段> -d <目标网段> -o eth0 -j MASQUERADE
   ```
   若命中数为 0 → 确认 `OVPN_ROUTES` 与 `OVPN_NAT=true` 已设置。

2. **客户端是否收到路由？**
   服务端 `server.conf` 应有 `push "route <目标>"`。

3. **目标机是否可达？**
   在宿主机上测试：`nc -zv <目标> <端口>`。

### Q4: 连上 VPN 后客户端无法上网

**原因**：服务端推送了 `redirect-gateway def1`（劫持默认路由）或 `block-outside-dns`（阻断外部 DNS）。

**解决**：本方案中 `OVPN_ROUTES` 仅列出目标，**不推送默认路由**；若仍出现，检查是否手工添加了 `push "redirect-gateway"`。

### Q5: Docker 网络子网冲突（`Pool overlaps with other one`）

**解决**：**不要**在 `docker-compose.yml` 中定义 `networks` 段，让 Docker 从地址池自动分配。若需固定，在 `/etc/docker/daemon.json` 配置：

```json
{
  "default-address-pools": [
    { "base": "172.27.0.0/16", "size": 24 }
  ]
}
```

> ⚠️ 地址池务必避开办公网、数据中心、云 VPC 网段。

## 能力对照

选择本方案（纯证书）时需要注意的能力取舍：

| 能力 | 纯证书 | LDAP 模式 |
|---|---|---|
| 客户端证书认证 | ✅ | ✅（可选）|
| **AD 组准入控制** | ❌ | ✅ |
| **TOTP 双因子** | ❌ | ✅ |
| fail2ban | ✅ | ✅ |
| 集中式用户管理 | ❌（需签发/吊销证书）| ✅（AD 账号）|
| 自动路由 / 自动 NAT | ✅ | ✅ |

**若需要 AD 组管控或双因子，请使用 LDAP 模式**（即 `USE_CLIENT_CERTIFICATE=false` + LDAP 环境变量）。

## 安全建议

- 🔒 `.ovpn` 文件含客户端私钥，权限设 `600`，**切勿提交代码库**
- 🔒 定期轮换客户端证书；吊销：`easyrsa revoke <name>` 后重新生成 CRL
- 🔒 VPN 网段避免与办公网 / 数据中心 / 云 VPC 重叠
- 🔒 目标访问范围通过 `OVPN_ROUTES` 精确限定

## 许可

MIT

## 致谢

- [wheelybird/openvpn-server-ldap-otp](https://github.com/wheelybird/openvpn-server-ldap-otp) —— 基础镜像
