# OpenVPN + iptables 防火墙白名单（Docker）

基于 [`kylemanna/openvpn`](https://github.com/kylemanna/docker-openvpn) 定制的 OpenVPN 容器镜像，**新增「文件化 iptables 白名单」能力**。

## 特性

- 🔐 **证书认证**（PKI，无需 LDAP/AD 域账号）
- 🛡️ **文件化防火墙白名单** —— 通过 `data/iptables` 文件定义客户端可访问的 IP:端口，其余流量一律拒绝
- 🐳 **Docker 化部署** —— 单容器、单端口、配置持久化
- 🚀 **一键导出客户端配置** —— 生成的 `.ovpn` 直接可用
- ⚡ **轻量** —— 镜像仅 ~15 MB

## 为什么需要这个项目

原版 `kylemanna/openvpn` 使用 `iptables` 时：

- **没有内置的规则文件加载机制**，只能靠手动 `docker exec` 执行，容器重建即丢失
- 默认会推送 `redirect-gateway def1`（劫持客户端全部流量）和 `block-outside-dns`（阻断外部 DNS），导致**连上 VPN 后客户端无法上网**
- 默认生成 `cipher SHA256`（**无效配置**，SHA256 是哈希算法而非加密算法）

本项目通过在镜像中注入一个**入口包装脚本**，在 OpenVPN 启动后自动加载 `data/iptables` 中的规则，并修复上述默认行为，做到：

1. **白名单可持久化** —— 规则写在文件里、随容器启动自动生效
2. **VPN 分流** —— 仅目标 IP 走 VPN，其余流量走本地，**不影响正常上网**
3. **零配置生成坑** —— 开箱即用

## 目录结构

```
.
├── README.md                       # 本文档
├── Dockerfile                      # 定制镜像
├── ovpn-entrypoint.sh              # 入口包装脚本（核心：注入 iptables）
├── docker-compose.yml.example      # Compose 示例
├── config/
│   ├── openvpn.conf.example        # 服务端配置示例
│   └── iptables.example            # 白名单规则示例
├── scripts/
│   ├── deploy.sh                   # 一键部署脚本
│   └── export-client.sh            # 导出客户端配置
└── .gitignore
```

## 快速开始

### 1. 构建镜像

```bash
docker build -t openvpn-firewall:v1 .
```

### 2. 生成服务端配置

```bash
export OVPN_DATA="$PWD/data"
mkdir -p "$OVPN_DATA"

# 生成服务端配置
#   -u  服务端对外地址与端口
#   -s  VPN 内部网段（请使用不与内网/云 VPC 冲突的网段）
#   -d  不推送 redirect-gateway（不劫持客户端默认路由）+ 不阻断外部 DNS
#   -b  不推送 block-outside-dns
#   -p  推送给客户端的路由（仅这些网段/主机走 VPN）
docker run --rm -v "$OVPN_DATA:/etc/openvpn" openvpn-firewall:v1 \
  ovpn_genconfig \
  -u udp://vpn.example.com:1194 \
  -s 172.28.0.0/24 \
  -d -b \
  -p "route 192.0.2.10 255.255.255.255"
```

> ⚠️ **关于 `-p` 与 `-r` 的区别**
>
> | 参数 | 生成内容 | 作用范围 |
> |---|---|---|
> | `-r 192.0.2.10/32` | `route 192.0.2.10 255.255.255.255` | **仅服务端**，客户端收不到 |
> | `-p "route 192.0.2.10 255.255.255.255"` | `push "route ..."` | **推送给客户端** ✅ |
>
> 想让客户端访问目标，**必须用 `-p`**。

### 3. 初始化 PKI

```bash
docker run --rm -v "$OVPN_DATA:/etc/openvpn" -e EASYRSA_BATCH=1 \
  openvpn-firewall:v1 ovpn_initpki nopass
```

### 4. 生成客户端证书并导出配置

```bash
CLIENT=myclient

# 生成证书
docker run --rm -v "$OVPN_DATA:/etc/openvpn" -e EASYRSA_BATCH=1 \
  openvpn-firewall:v1 easyrsa build-client-full "$CLIENT" nopass

# 导出客户端配置
docker run --rm -v "$OVPN_DATA:/etc/openvpn" \
  openvpn-firewall:v1 ovpn_getclient "$CLIENT" > "$CLIENT.ovpn"
chmod 600 "$CLIENT.ovpn"
```

> ⚠️ **新版客户端兼容性**：如果你的客户端是 OpenVPN **2.5 / 2.6+**，
> 导出的配置里若只有 `cipher` 而无 `data-ciphers`，连接会失败：
>
> ```
> DEPRECATED OPTION: --cipher set to 'AES-256-CBC' but missing in --data-ciphers
> ```
>
> 解决：把配置中的 `cipher AES-256-CBC` 替换为：
>
> ```
> data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
> ```
>
> `scripts/export-client.sh` 已自动处理这一步。

### 5. 定义防火墙白名单

编辑 `data/iptables`（格式与 `iptables-restore` 一致）：

```iptables
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i tun0 -j ACCEPT
-A FORWARD -p icmp -j ACCEPT
-A FORWARD -i tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# === 白名单：仅允许访问以下目标 ===
# 示例：允许 RDP / HTTPS / 自定义端口
-A FORWARD -i tun0 -p tcp -m multiport --dports 3389 -d 192.0.2.10 -j ACCEPT
-A FORWARD -i tun0 -p tcp -m multiport --dports 443  -d 192.0.2.10 -j ACCEPT
-A FORWARD -i tun0 -p tcp -m multiport --dports 8088 -d 192.0.2.10 -j ACCEPT

# === 默认拒绝 ===
-A FORWARD -i tun0 -j DROP
COMMIT
```

### 6. 启动

```bash
cp docker-compose.yml.example docker-compose.yml
docker compose up -d
docker logs -f openvpn-server
```

启动日志应包含：

```
[entrypoint] ✅ tun0 已就绪
[entrypoint] ✅ 白名单已生效
Chain FORWARD (policy ACCEPT)
1  ACCEPT  icmp
...
6  DROP    all          ← 默认拒绝
```

## 工作原理

### 入口包装脚本

原版镜像的 `ENTRYPOINT` 直接执行 `ovpn_run`，本项目替换为包装脚本：

```
┌─────────────────────────────────────────────┐
│ ovpn-entrypoint.sh                          │
├─────────────────────────────────────────────┤
│ 1. 判断命令：                                │
│    • ovpn_run  → 走包装逻辑                  │
│    • 其它命令  → 直接透传（关键！）           │
│        否则 ovpn_genconfig / easyrsa 等      │
│        管理命令会被误当成启动 VPN            │
│ 2. 后台启动 ovpn_run                         │
│ 3. 等待 tun0 接口就绪                        │
│ 4. iptables-restore < /etc/openvpn/iptables  │
│ 5. 前台等待 OpenVPN 进程                     │
└─────────────────────────────────────────────┘
```

> ⚠️ **第 1 步至关重要**：包装脚本必须放行 `ovpn_genconfig`、`ovpn_initpki`、
> `easyrsa`、`ovpn_getclient` 等管理命令，否则初始化阶段会静默失败
> （表现为 `openvpn.conf` 为空、`ovpn_env.sh` 缺失）。

### 白名单生效流程

```
客户端拨入
    ↓
OpenVPN 建立 tun0
    ↓
entrypoint 加载 data/iptables
    ↓
FORWARD 链：目标在白名单 → ACCEPT
            其余            → DROP
```

## 配置说明

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `IPTABLES_EXTRA_FILE` | `/etc/openvpn/iptables` | 白名单规则文件路径 |

## 常见问题

### Q1: 连上 VPN 后无法上网

**原因**：服务端推送了 `redirect-gateway def1`（劫持全部流量）或 `block-outside-dns`（阻断外部 DNS）。

**解决**：生成配置时加 `-d`（禁用默认路由 + 不阻断 DNS）和 `-b`（不推 block-outside-dns）：

```bash
ovpn_genconfig ... -d -b -p "route <目标> 255.255.255.255"
```

### Q2: 连上了，但访问不到目标主机

按顺序排查：

1. **目标 IP 是否推送给了客户端？**
   服务端 `openvpn.conf` 里应存在 `push "route <目标> 255.255.255.255"`。
   若只写了裸 `route ...`，客户端收不到 → 改用 `-p "route ..."`。

2. **iptables 白名单是否包含该目标？**
   `data/iptables` 中需有对应的 `-A FORWARD ... -d <目标> -j ACCEPT`。

3. **端口是否正确？**
   `--dports` 需包含目标端口。

### Q3: 客户端报错 `Options error: --duplicate-cn requires --mode server`

**原因**：客户端配置中混入了服务端专用参数 `duplicate-cn`。

**解决**：从 `.ovpn` 客户端配置中删除该行。
本项目的 `scripts/export-client.sh` 会自动清理。

### Q4: 客户端报错 `Unrecognized option ... data-ciphers`

**原因**：服务端 OpenVPN 版本低于 2.5（如 2.4.x），不支持 `data-ciphers`。

**解决**：服务端保留 `cipher AES-256-CBC`（不要加 `data-ciphers`）；
客户端改用 `data-ciphers`（见上文「新版客户端兼容性」）。

### Q5: 容器重建后白名单丢失

**原因**：规则未持久化。

**解决**：确保 `data/iptables` 文件存在且被挂载（`./data:/etc/openvpn`）。
入口脚本会在每次启动时重新加载。

### Q6: Docker 网络子网冲突（`Pool overlaps with other one`）

**原因**：在 `docker-compose.yml` 中写死了与已有网络重叠的 `subnet`。

**解决**：**不要在 compose 中定义 `networks` 段**，让 Docker 从地址池自动分配。
若需固定网段，请在 `/etc/docker/daemon.json` 中配置 `default-address-pools`：

```json
{
  "default-address-pools": [
    { "base": "172.27.0.0/16", "size": 24 }
  ]
}
```

> ⚠️ 选择地址池时务必避开办公网、数据中心、云 VPC 网段。

## 安全建议

- 🔒 **客户端 `.ovpn` 文件包含私钥**，权限设为 `600`，切勿提交到代码库
- 🔒 **定期轮换客户端证书**：`ovpn_revokeclient <name> remove`
- 🔒 **白名单最小化**：只开放业务必需的目标 IP 与端口
- 🔒 **不要使用与内网重叠的 VPN 网段**

## 许可

MIT

## 致谢

- [kylemanna/docker-openvpn](https://github.com/kylemanna/docker-openvpn) —— 基础镜像
