# ============================================================
# 定制 openvpn 镜像：kylemanna/openvpn + iptables 文件规则支持
# ------------------------------------------------------------
# 目标：保持与现有 openvpn-ldap 环境一致的「data/iptables 白名单」体验
#       —— 容器启动时自动加载 /etc/openvpn/iptables 中的规则
# 基础镜像：kylemanna/openvpn
# ============================================================
FROM kylemanna/openvpn

LABEL maintainer="openvpn-with-firewall" \
      description="OpenVPN (kylemanna) with iptables file-based whitelist support"

# iptables 已内置于基础镜像，确认可用
RUN which iptables && iptables --version

# ---------- 包装入口：启动 OpenVPN 后套用 iptables 白名单 ----------
COPY ovpn-entrypoint.sh /usr/local/bin/ovpn-entrypoint.sh
RUN chmod +x /usr/local/bin/ovpn-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/ovpn-entrypoint.sh"]
CMD ["ovpn_run"]
