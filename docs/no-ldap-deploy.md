# 关闭 LDAP：原理与验证

本文说明如何让 `wheelybird/openvpn-server-ldap-otp` 镜像**以纯客户端证书方式运行**，以及验证方法。

## 一、开关原理

上游镜像通过一个环境变量控制认证模式：

```yaml
USE_CLIENT_CERTIFICATE=true     # 纯证书
USE_CLIENT_CERTIFICATE=false    # LDAP（默认）
```

### 受影响的三处代码

**1. `set_defaults.sh`** —— LDAP 变量仅在非证书模式下必填

```bash
if [ "${USE_CLIENT_CERTIFICATE,,}" != "true" ]; then
   if [ "${LDAP_URI}x" == "x" ]; then show_error LDAP_URI ; fi
   if [ "${LDAP_BASE_DN}x" == "x" ]; then show_error LDAP_BASE_DN ; fi
fi
```

**2. `create_server_config.sh`** —— 证书模式不加载 PAM 插件

```bash
if [ "${USE_CLIENT_CERTIFICATE,,}" != "true" ] ; then
  plugin ... openvpn-plugin-auth-pam.so openvpn
  verify-client-cert optional
  username-as-common-name
fi
```

**3. `entrypoint`** —— 证书模式跳过 OTP 配置

```bash
if [ "${USE_CLIENT_CERTIFICATE,,}" != "true" ] ; then
  source "$CONFIGFILES/setup_otp.sh"
fi
```

**结论**：设了 `USE_CLIENT_CERTIFICATE=true` 后，**PAM/LDAP/OTP 相关流程全部跳过**，无需提供任何 LDAP 变量。

## 二、不受影响的能力

以下能力**与认证方式无关**，证书模式下**照常工作**：

| 能力 | 实现位置 | 说明 |
|---|---|---|
| **自动推送路由** | `setup_networking.sh` | 读 `OVPN_ROUTES` → `push "route ..."` |
| **自动 NAT** | `setup_networking.sh` | 读 `OVPN_ROUTES` → `iptables MASQUERADE` |
| **fail2ban** | `setup_fail2ban.sh` | `FAIL2BAN_ENABLED=true` 即可 |
| **管理接口** | `create_server_config.sh` | `OVPN_MANAGEMENT_ENABLE=true` |
| **PKI 管理** | `setup_pki.sh` | easy-rsa 全套命令 |
| **TLS 加密套件** | `create_server_config.sh` | `OVPN_TLS_CIPHERS` |

## 三、会失去的能力

| 能力 | 说明 |
|---|---|
| **AD 组准入控制** | `GROUP_DN` / `LDAP_FILTER` 是 LDAP 专属 |
| **TOTP 双因子** | 走 PAM 模块，证书模式不加载 |
| **集中式用户管理** | 证书模式需手动签发/吊销证书 |
| **用户名审计** | 证书模式只有证书 CN（默认 `client`）|

> 💡 若必须同时拥有「证书 + 双因子」，需要改造 `create_server_config.sh`
> （如启用 PAM 插件并配 `verify-client-cert required`），本项目未包含该改造。

## 四、验证方法

### 1. 确认 server.conf 里没有 PAM

```bash
docker exec openvpn-server sh -c 'grep -nE "plugin|username-as-common-name|verify-client-cert" /etc/openvpn/server.conf'
# 期望：无输出
```

### 2. 确认客户端配置含证书

```bash
docker exec openvpn-server /usr/local/bin/show-client-config | grep -cE '^<cert>|^<key>'
# 期望：2
```

### 3. 确认自动 NAT 已生成并命中

```bash
docker exec openvpn-server iptables -t nat -L POSTROUTING -n -v
```

期望输出形如：

```
 pkts bytes target     prot opt in     out     source               destination
   15   892 MASQUERADE  all  --  *      eth0    172.28.0.0/24        192.0.2.0/24
```

**判读**：
- 规则存在 = `OVPN_NAT=true` 且 `OVPN_ROUTES` 已设置 ✅
- `pkts` 持续增长 = 流量确实在转发 ✅
- `pkts` 恒为 0 = 客户端流量未到（检查客户端路由、隧道是否建立）

### 4. 端到端验证

```bash
# 客户端侧（连接 VPN 后）
Test-NetConnection <目标IP> -Port <端口>
```

## 五、PKI 生命周期

证书模式下的日常运维：

| 操作 | 命令 |
|---|---|
| **签发新客户端** | `easyrsa --batch build-client-full <name> nopass` |
| **导出其配置** | 需改 `show-client-config` 或手工组装（上游默认只导出 `client`）|
| **吊销证书** | `easyrsa revoke <name>` → `easyrsa gen-crl` |
| **查看已签发** | `easyrsa show-req <name>` 或查看 `pki/index.txt` |
| **重新生成 PKI** | `REGENERATE_CERTS=true`（⚠️ **所有客户端的配置都会失效**）|

> ⚠️ **重建 PKI 会导致 `ta.key` 与 CA 变化** → 所有已分发的 `.ovpn` 立即失效，必须重新导出分发。

## 六、踩坑记录

| 现象 | 原因 | 解决 |
|---|---|---|
| `USE_CLIENT_CERTIFICATE was set to 'true', but the client certificates weren't generated` | 镜像**不会自动签发客户端证书** | 手动执行 `easyrsa build-client-full client nopass` |
| 客户端 `TLS Error: cannot locate HMAC in incoming packet` | `.ovpn` 与当前服务端 `ta.key`/CA 不匹配（复用了旧配置）| 重新 `show-client-config` 导出 |
| 客户端连上但访问不到目标 | NAT 规则 `pkts=0` | 确认 `OVPN_ROUTES` 有值且 `OVPN_NAT=true` |
| 客户端连上后无法上网 | 推送了 `redirect-gateway`/`block-outside-dns` | 本方案只推目标路由，不推默认路由；检查是否手工加了 push |
| 容器反复重启 | 上述客户端证书缺失 | 先签发证书再启动 |
