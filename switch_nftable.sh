#!/bin/bash

clear_screen(){ command -v tput >/dev/null 2>&1 && tput clear || printf "\033c"; }; clear_screen

TARGET_CONF="/etc/nftables.conf"

read_line(){
  local prompt="$1" default="$2" char buf=""; printf "%s" "$prompt"
  while IFS= read -r -s -n1 char; do
    [[ -z "$char" || "$char" == $'\n' || "$char" == $'\r' ]] && { printf "\n"; break; }
    if [[ "$char" == $'\177' || "$char" == $'\010' ]]; then [[ -n "$buf" ]] && { buf=${buf%?}; printf '\b \b'; }; else buf+="$char"; printf '%s' "$char"; fi
  done
  [[ -z "$buf" && -n "$default" ]] && REPLY="$default" || REPLY="$buf"
}

echo "========================================================"
echo "          请选择代理模式"
echo "========================================================"
echo "1) 全局模式(Global Mode —— 仅指定目标走直连(其余全部代理)"
echo "2) 规则模式(Rule Mode   —— 仅指定目标走代理(其余全部直连)"
echo "0) 退出"
read -r -e -p "输入选项 [0-2]: " mode_choice || true
mode_choice="${mode_choice//[[:space:]]/}"
[[ "$mode_choice" == "0" ]] && { echo "已退出。"; exit 0; }

case "$mode_choice" in
  1) MODE="global"; MODE_NAME="全局模式" ;;
  2) MODE="rule";   MODE_NAME="规则模式" ;;
  *) echo "无效选项，退出。"; exit 1 ;;
esac


echo
echo "========================================================"
echo "          请选择透明代理实现方式"
echo "========================================================"
echo "1) 混合模式     —— (TCP Redirect + UDP TPROXY)"
echo "2) 纯TPROXY模式 —— (TCP + UDP TPROXY)"
echo "0) 退出"
read -r -e -p "输入选项 [0-2]: " impl_choice || true
impl_choice="${impl_choice//[[:space:]]/}"
[[ "$impl_choice" == "0" ]] && { echo "已退出。"; exit 0; }

case "$impl_choice" in
  1) IMPL="hybrid"; IMPL_NAME="混合模式" ;;
  2) IMPL="pure";   IMPL_NAME="纯TPROXY模式" ;;
  *) echo "无效选项，退出。"; exit 1 ;;
esac

echo
echo "========================================================"
echo "          端口与Fake-IP参数设置"
echo "========================================================"
read_line "请输入Redirect端口(默认9777): " "9777"; REDIRECT_PORT="$REPLY"
read_line "请输入TPROXY端口(默认9888): " "9888"; TPROXY_PORT="$REPLY"
read_line "请输入Fake_ipv4网段(默认28.0.0.0/8): " "28.0.0.0/8"; FAKE_IPV4_CIDR="$REPLY"
read_line "请输入Fake_ipv6网段(默认 2001:2::/64): " "2001:2::/64"; FAKE_IPV6_CIDR="$REPLY"

echo
echo "将使用配置: "
echo "  代理模式      : $MODE_NAME"
echo "  实现方式      : $IMPL_NAME"
echo "  Redirect端口  : $REDIRECT_PORT"
echo "  TPROXY端口    : $TPROXY_PORT"
echo "  fake_ipv4     : $FAKE_IPV4_CIDR"
echo "  fake_ipv6     : $FAKE_IPV6_CIDR"
echo

SINGBOX_GID="$(ps -o gid= -C sing-box 2>/dev/null | head -n1 | tr -d ' ')"
[[ -z "$SINGBOX_GID" ]] && \
SINGBOX_GID="$(ps -o gid= -C singbox 2>/dev/null | head -n1 | tr -d ' ')"
[[ -z "$SINGBOX_GID" ]] && SINGBOX_GID=0

if [[ "$MODE" == "global" ]]; then
  # 全局模式(Global Mode)
  case "$IMPL" in
    hybrid)
      echo "应用: 全局模式 + 混合模式(TCP Redirect + UDP TPROXY)..."
      cat > "$TARGET_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet singbox {

set china_dns_ipv4 {
    type ipv4_addr;
    elements = { 223.5.5.5, 223.6.6.6, 114.114.114.114, 114.114.115.115 };
}

set china_dns_ipv6 {
    type ipv6_addr;
    elements = { 2400:3200::1, 2400:3200:baba::1 };
}

set fake_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { $FAKE_IPV4_CIDR };
}

set fake_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { $FAKE_IPV6_CIDR };
}

set local_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 };
}

set local_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { ::ffff:0.0.0.0/96, 64:ff9b::/96, 100::/64, 2001:10::/28, 2001:20::/28, 2001:db8::/32, 2002::/16, fe80::/10 };
}

chain redirect-proxy {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    meta l4proto tcp redirect to :$REDIRECT_PORT
}    

chain redirect-prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    meta l4proto != tcp return
    ct state new ct direction original goto redirect-proxy
}

chain redirect-output {
    type nat hook output priority dstnat; policy accept;
    meta l4proto != tcp return
    meta skgid $SINGBOX_GID return
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @fake_ipv4 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip6 daddr @fake_ipv6 meta l4proto tcp redirect to :$REDIRECT_PORT
}

chain tproxy-proxy {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    udp dport {123} return
    ip protocol udp meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 nexthdr udp meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
}

chain tproxy-mark {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    udp dport {123} return
    meta mark set 1
    meta l4proto udp ct mark set 1
}

chain tproxy-prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto != udp return
    ct direction reply return
    ct direction original ct mark 1 meta mark set 1 return
    ct direction original goto tproxy-proxy
}

chain tproxy-output {
    type route hook output priority mangle; policy accept;
    meta l4proto != udp return
    meta skgid $SINGBOX_GID return
    ct direction reply return
    ct direction original ct mark 1 meta mark set 1 return
    ct direction original goto tproxy-mark
}
}
EOF
      ;;
    pure)
      echo "应用: 全局模式 + 纯TPROXY模式(TCP + UDP TPROXY)..."
      cat > "$TARGET_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet singbox {

set china_dns_ipv4 {
    type ipv4_addr;
    elements = { 223.5.5.5, 223.6.6.6, 114.114.114.114, 114.114.115.115 };
}

set china_dns_ipv6 {
    type ipv6_addr;
    elements = { 2400:3200::1, 2400:3200:baba::1 };
}

set fake_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { $FAKE_IPV4_CIDR };
}

set fake_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { $FAKE_IPV6_CIDR };
}

set local_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 };
}

set local_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { ::ffff:0.0.0.0/96, 64:ff9b::/96, 100::/64, 2001:10::/28, 2001:20::/28, 2001:db8::/32, 2002::/16, fe80::/10 };
}

chain tproxy-proxy {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    udp dport {123} return
    ip protocol tcp meta mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 nexthdr tcp meta mark set 1 tproxy ip6 to :$TPROXY_PORT accept
    ip protocol udp meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 nexthdr udp meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
}

chain tproxy-mark {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    udp dport {123} return
    meta mark set 1
    meta l4proto udp ct mark set 1
}

chain tproxy-prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto != { tcp, udp } return
    ct direction reply return
    meta l4proto udp ct direction original ct mark 1 meta mark set 1 return
    ct direction original goto tproxy-proxy
}

chain tproxy-output {
    type route hook output priority mangle; policy accept;
    meta l4proto != { tcp, udp } return
    meta skgid $SINGBOX_GID return
    ct direction reply return
    meta l4proto udp ct direction original ct mark 1 meta mark set 1 return
    meta l4proto tcp ct state new ct direction original goto tproxy-mark
    meta l4proto udp ct direction original goto tproxy-mark
}
}
EOF
      ;;
  esac

else
  # 规则模式(Rule-based Mode)
  case "$IMPL" in
    hybrid)
      echo "应用: 规则模式 + 混合模式(TCP Redirect + UDP TPROXY)..."
      cat > "$TARGET_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet singbox {

set remote_dns_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1 };
}

set remote_dns_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { 2001:4860:4860::8888, 2001:4860:4860::8844, 2606:4700:4700::1111, 2606:4700:4700::1001 };
}

set telegram_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 5.28.192.0/18, 67.198.55.0/24, 91.105.192.0/23, 91.108.0.0/16, 95.161.64.0/20, 109.239.140.0/24, 139.59.210.98/32, 149.154.160.0/20, 185.76.151.0/24, 196.55.216.167/32, 216.239.30.0/24 };
}

set telegram_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { 2001:67c:4e8::/48, 2001:b28:f23c::/47, 2001:b28:f23f::/48, 2a0a:f280::/29 };
}

set fake_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { $FAKE_IPV4_CIDR };
}

set fake_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { $FAKE_IPV6_CIDR };
}

set local_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 };
}

set local_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { ::ffff:0.0.0.0/96, 64:ff9b::/96, 100::/64, 2001:10::/28, 2001:20::/28, 2001:db8::/32, 2002::/16, fe80::/10 };
}

chain redirect-proxy {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @fake_ipv4 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip6 daddr @fake_ipv6 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip daddr @telegram_ipv4 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip6 daddr @telegram_ipv6 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip daddr @remote_dns_ipv4 tcp dport 53 redirect to :$REDIRECT_PORT
    ip6 daddr @remote_dns_ipv6 tcp dport 53 redirect to :$REDIRECT_PORT
}    

chain redirect-prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    meta l4proto != tcp return
    ct state new ct direction original goto redirect-proxy
}

chain redirect-output {
    type nat hook output priority dstnat; policy accept;
    meta l4proto != tcp return
    meta skgid $SINGBOX_GID return
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @fake_ipv4 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip6 daddr @fake_ipv6 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip daddr @telegram_ipv4 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip6 daddr @telegram_ipv6 meta l4proto tcp redirect to :$REDIRECT_PORT
    ip daddr @remote_dns_ipv4 tcp dport 53 redirect to :$REDIRECT_PORT
    ip6 daddr @remote_dns_ipv6 tcp dport 53 redirect to :$REDIRECT_PORT
}

chain tproxy-proxy {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip protocol udp ip daddr @fake_ipv4 meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 nexthdr udp ip6 daddr @fake_ipv6 meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
    ip protocol udp ip daddr @telegram_ipv4 meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 nexthdr udp ip6 daddr @telegram_ipv6 meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
    ip daddr @remote_dns_ipv4 udp dport 53 meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 daddr @remote_dns_ipv6 udp dport 53 meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
}

chain tproxy-prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto != udp return
    ct direction reply return
    ct direction original ct mark 1 meta mark set 1 return
    ct direction original goto tproxy-proxy
}

chain tproxy-output {
    type route hook output priority mangle; policy accept;
    meta l4proto != udp return
    meta skgid $SINGBOX_GID return
    ct direction reply return
    ct direction original ct mark 1 meta mark set 1 return
    ip protocol udp ip daddr @fake_ipv4 meta mark set 1 ct mark set 1 return
    ip6 nexthdr udp ip6 daddr @fake_ipv6 meta mark set 1 ct mark set 1 return
    ip protocol udp ip daddr @telegram_ipv4 meta mark set 1 ct mark set 1 return
    ip6 nexthdr udp ip6 daddr @telegram_ipv6 meta mark set 1 ct mark set 1 return
    ip daddr @remote_dns_ipv4 udp dport 53 meta mark set 1 ct mark set 1 return
    ip6 daddr @remote_dns_ipv6 udp dport 53 meta mark set 1 ct mark set 1 return
}
}
EOF
      ;;
    pure)
      echo "应用: 规则模式 + 纯TPROXY模式(TCP + UDP TPROXY)..."
      cat > "$TARGET_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet singbox {

set remote_dns_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1 };
}

set remote_dns_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { 2001:4860:4860::8888, 2001:4860:4860::8844, 2606:4700:4700::1111, 2606:4700:4700::1001 };
}

set telegram_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 5.28.192.0/18, 67.198.55.0/24, 91.105.192.0/23, 91.108.0.0/16, 95.161.64.0/20, 109.239.140.0/24, 139.59.210.98/32, 149.154.160.0/20, 185.76.151.0/24, 196.55.216.167/32, 216.239.30.0/24 };
}

set telegram_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { 2001:67c:4e8::/48, 2001:b28:f23c::/47, 2001:b28:f23f::/48, 2a0a:f280::/29 };
}

set fake_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { $FAKE_IPV4_CIDR };
}

set fake_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { $FAKE_IPV6_CIDR };
}

chain tproxy-proxy {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @fake_ipv4 ip protocol tcp meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip daddr @fake_ipv4 ip protocol udp meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 daddr @fake_ipv6 ip6 nexthdr tcp meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
    ip6 daddr @fake_ipv6 ip6 nexthdr udp meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
    ip daddr @telegram_ipv4 ip protocol tcp meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip daddr @telegram_ipv4 ip protocol udp meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 daddr @telegram_ipv6 ip6 nexthdr tcp meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
    ip6 daddr @telegram_ipv6 ip6 nexthdr udp meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
    ip daddr @remote_dns_ipv4 tcp dport 53 meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip daddr @remote_dns_ipv4 udp dport 53 meta mark set 1 ct mark set 1 tproxy ip to :$TPROXY_PORT accept
    ip6 daddr @remote_dns_ipv6 tcp dport 53 meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
    ip6 daddr @remote_dns_ipv6 udp dport 53 meta mark set 1 ct mark set 1 tproxy ip6 to :$TPROXY_PORT accept
}

chain tproxy-prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto != { tcp, udp } return
    ct direction reply return
    ct direction original ct mark 1 meta mark set 1 return
    ct direction original goto tproxy-proxy
}

chain tproxy-output {
    type route hook output priority mangle; policy accept;
    meta l4proto != { tcp, udp } return
    meta skgid $SINGBOX_GID return
    ct direction reply return
    ct direction original ct mark 1 meta mark set 1 return
    ip daddr @fake_ipv4 meta mark set 1 ct mark set 1 return
    ip6 daddr @fake_ipv6 meta mark set 1 ct mark set 1 return
    ip daddr @telegram_ipv4 meta mark set 1 ct mark set 1 return
    ip6 daddr @telegram_ipv6 meta mark set 1 ct mark set 1 return
    ip daddr @remote_dns_ipv4 tcp dport 53 meta mark set 1 ct mark set 1 return
    ip daddr @remote_dns_ipv4 udp dport 53 meta mark set 1 ct mark set 1 return
    ip6 daddr @remote_dns_ipv6 tcp dport 53 meta mark set 1 ct mark set 1 return
    ip6 daddr @remote_dns_ipv6 udp dport 53 meta mark set 1 ct mark set 1 return
}
}
EOF
      ;;
  esac
fi

if command -v systemctl &>/dev/null; then
  echo "检查并启用 nftables 服务自启..."
  if ! systemctl is-enabled nftables &>/dev/null; then
    systemctl enable nftables
    echo "已设置 nftables 为开机自启。"
  else
    echo "nftables 已经设置为开机自启。"
  fi

  echo "正在重启 nftables 服务..."
  sudo systemctl restart nftables
else
  echo "加载新配置..."
  nft -f "$TARGET_CONF"
fi

echo "操作完成。"