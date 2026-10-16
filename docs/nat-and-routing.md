# 网络机制：自动路由与自动 NAT

本项目能访问内网目标的核心，是镜像 `setup_networking.sh` 提供的**自动化网络配置**。

## 一、为什么需要它

OpenVPN 客户端要访问内网某台主机，需要两件事同时成立：

| 环节 | 作用 | 缺失后果 |
|---|---|---|
| **① 路由** | 让客户端知道「这个目标要走 VPN」 | 流量根本不进隧道 |
| **② NAT** | 让服务端把 VPN 源地址转成自己的地址 | 目标机回包找不到路，连接超时 |

两者缺一不可，且**路由必须先于 NAT**（否则客户端不会把流量发过来）。

## 二、上游的实现

`setup_networking.sh` 遍历 `OVPN_ROUTES`，对每个条目做两件事：

```bash
# 1. 推送给客户端
echo "push \"route $this_route\"" >> /tmp/routes_config.txt

# 2. 创建 NAT 规则（当 OVPN_NAT=true）
this_net=$(echo $this_route | awk '{ print $1 }')
this_cidr=$(ipcalc -nb $this_route | grep ^Netmask | awk '{ print $NF }')
to_masquerade="${this_net}/${this_cidr}"
iptables -t nat -A POSTROUTING -s "$ovpn_net" -d "$to_masquerade" -o "$this_natdevice" -j MASQUERADE
```

其中：
- `ovpn_net` = `OVPN_NETWORK` 的 CIDR 形式（VPN 内部网段）
- `this_natdevice` = 默认路由网卡（容器内通常是 `eth0`）

**生成结果示例**：

```
push "route 192.0.2.10"
iptables -t nat -A POSTROUTING -s 172.28.0.0/24 -d 192.0.2.10/32 -o eth0 -j MASQUERADE
```

## 三、与「手工配置」的对比

如果不使用该机制（例如用其他镜像手工维护），常见错误：

| 错误做法 | 后果 |
|---|---|
| 只写 `route <目标>` 到服务端配置 | 客户端**收不到**该路由（`route` 只在服务端生效，需用 `push "route ..."`）|
| MASQUERADE 不限定目标网段（`-d` 缺失）| 规则过于宽泛，且容易与其他规则冲突 |
| MASQUERADE 的源/目标写反（如 `-s <目标IP>`）| 规则完全不生效（`pkts` 恒为 0）|
| 用 `redirect-gateway` 代替精确路由 | 客户端**全部流量**被劫持，导致其无法上网 |

**本方案通过 `OVPN_ROUTES` 单点配置**，上述问题全部由镜像自动处理。

## 四、配置方式

```yaml
environment:
  - OVPN_NAT=true
  - OVPN_ROUTES=192.0.2.10,192.0.2.11/24,192.0.2.0/24
```

| 写法 | 生成的路由 | 生成的 NAT |
|---|---|---|
| `192.0.2.10` | `push "route 192.0.2.10"` | `-d 192.0.2.10/32` |
| `192.0.2.11/24` | `push "route 192.0.2.11/24"` | `-d 192.0.2.0/24` |
| `192.0.2.0/24` | `push "route 192.0.2.0/24"` | `-d 192.0.2.0/24` |

**多个目标用英文逗号分隔，不要有空格。**

## 五、验证

```bash
# 1) 推送的路由
docker exec openvpn-server sh -c 'grep "^push" /etc/openvpn/server.conf'

# 2) NAT 规则（关注 pkts 是否增长）
docker exec openvpn-server iptables -t nat -L POSTROUTING -n -v

# 3) 容器内路由表
docker exec openvpn-server ip route

# 4) 客户端侧（连接后）
route print | findstr "<目标IP>"       # Windows
```

## 六、常见故障对应

| 现象 | 定位 | 结论 |
|---|---|---|
| NAT `pkts` 始终为 0 | 客户端根本没把流量发进隧道 | 路由推送未生效 / 客户端未收到 |
| NAT `pkts` 增长，但访问超时 | 去程通了，回程失败 | 目标机回包路由问题，或目标侧防火墙 |
| 服务端 FORWARD 全部 0 命中 | 流量未到达容器 | 检查隧道建立情况、宿主机转发 |
| 客户端无法上网 | 检查是否推送了 `redirect-gateway` 或 `block-outside-dns` | 本方案默认不推 |

## 七、与 iptables 白名单的关系

**本机制只解决「可达」**（路由 + NAT），**不限制「可达范围之外」**。

若需**最小权限**（只允许访问特定 IP 的特定端口，其余拒绝），需额外在白名单层面限制 —— 即在容器内追加 FORWARD 链规则，并保证 `-A FORWARD -i tun0 -j DROP` 位于最后。

⚠️ 注意：`OVPN_ROUTES` 只是**路由**层面的可达范围；若要**强制**拒绝 `OVPN_ROUTES` 之外的访问，需要在 FORWARD 链显式 DROP。

**安全建议**：`OVPN_ROUTES` 精确到单个主机或最小网段，不要整段放行大网段。
