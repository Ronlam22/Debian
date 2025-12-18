#!/usr/bin/env bash
set -euo pipefail

clear_screen(){ command -v tput >/dev/null 2>&1 && tput clear || printf "\033c"; }
pause(){ echo; read -r -e -p "按回车继续..." _ || true; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo " 请用 root 执行：sudo $0"; exit 1; fi
if [[ -t 0 ]]; then stty sane 2>/dev/null || true; stty erase '^?' 2>/dev/null || stty erase '^H' 2>/dev/null || true; fi

NFT_CONF="/etc/nftables.conf"
PORTSYNC_SCRIPT="/usr/local/sbin/nftables-port-sync.sh"
DEFAULTS_FILE="/etc/default/nftables-port-sync"
SVC_FILE="/etc/systemd/system/nftables-port-sync.service"

trim(){ awk '{$1=$1};1' <<<"${1:-}"; }

normalize_ports(){
  local raw p; local out=()
  raw="$(trim "${1:-}")"; raw="${raw//,/ }"; raw="$(echo "$raw" | tr -s ' ' ' ')"
  [[ -z "$raw" ]] && { echo ""; return 0; }
  for p in $raw; do
    [[ "$p" =~ ^[0-9]+$ ]] || { echo " 端口必须是数字：$p" >&2; return 1; }
    (( p>=1 && p<=65535 )) || { echo " 端口范围必须 1-65535：$p" >&2; return 1; }
    out+=("$p")
  done
  printf "%s\n" "${out[@]}" | sort -n -u | paste -sd, -
}

guess_ssh_ports(){
  local ports=""
  ports="$(ss -lntpH 2>/dev/null | awk '$1=="LISTEN" && index($0, "users:((\"sshd\"")>0 { addr=$4; gsub(/.*:/,"",addr); if (addr ~ /^[0-9]+$/) print addr }' | sort -n -u | paste -sd, - || true)"
  if [[ -z "$ports" && -f /etc/ssh/sshd_config ]]; then ports="$(awk 'BEGIN{IGNORECASE=1} $1=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null | sort -n -u | paste -sd, - || true)"; fi
  [[ -z "$ports" ]] && ports="22"
  echo "$ports"
}

sanitize_proc(){
  local s="${1:-}"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(echo "$s" | sed 's/[^a-z0-9_]/_/g; s/__*/_/g; s/^_//; s/_$//')"
  [[ -z "$s" ]] && s="unknown"
  echo "$s"
}

scan_listen_ports(){
  echo "========== 扫描监听端口 =========="
  ss -lntupH 2>/dev/null | awk '{ proto=$1; addr=$5; gsub(/.*:/,"",addr); if (addr !~ /^[0-9]+$/) next; proc="(unknown)"; pos=index($0,"users:((\""); if (pos>0){t=substr($0,pos+9); sub(/".*/,"",t); gsub(/"/,"",t); if(t!="") proc=t} printf "%-4s %-6s %s\n", proto, addr, proc }' | sort -k1,1 -k2,2n -k3,3
  echo
  ss -lntupH 2>/dev/null | awk '{
    proto=$1; addr=$5; gsub(/.*:/,"",addr); if (addr !~ /^[0-9]+$/) next
    proc="(unknown)"; pos=index($0,"users:((\""); if (pos>0){t=substr($0,pos+9); sub(/".*/,"",t); gsub(/"/,"",t); if(t!="") proc=t}
    ports[proc, proto] = ports[proc, proto] (ports[proc, proto] ? "," : "") addr
    seen_proc[proc]=1; seen_proto[proc, proto]=1
  } END{
    for (p in seen_proc) {
      print p " =>"
      if (seen_proto[p,"tcp"]) printf "  - %-4s: %s\n", "tcp", ports[p,"tcp"]
      if (seen_proto[p,"udp"]) printf "  - %-4s: %s\n", "udp", ports[p,"udp"]
      print ""
    }
  }' | sed '/^$/N;/^\n$/D'
}

scan_proc_ports_tab(){
  ss -lntupH 2>/dev/null | awk '{
    addr=$5; gsub(/.*:/,"",addr); if (addr !~ /^[0-9]+$/) next
    proc="(unknown)"; pos=index($0,"users:((\""); if (pos>0){t=substr($0,pos+9); sub(/".*/,"",t); gsub(/"/,"",t); if(t!="") proc=t}
    print proc "\t" addr
  }' | sort -u | awk -F'\t' '{
    p=$1; port=$2; gsub(/"/,"",p)
    if (p=="" || port=="") next
    ports[p]=ports[p] (ports[p] ? "," : "") port
    procs[p]=1
  } END{
    for (p in procs) print p "\t" ports[p]
  }'
}

restore_or_remove_nft_conf(){
  cat >"$NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input   { type filter hook input priority filter; policy accept; }
  chain forward { type filter hook forward priority filter; policy accept; }
  chain output  { type filter hook output priority filter; policy accept; }
}
EOF
  echo " 已写回默认 nftables.conf 模板：$NFT_CONF"
}

write_nft_conf_dynamic(){
  local ssh_ports="$1" allow_ping="$2"; shift 2; local lines=("$@")

  cat >"$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  set ssh_ports { type inet_service; elements = { ${ssh_ports} } }
EOF

  local line proc ports p_s setname
  for line in "${lines[@]}"; do
    proc="${line%%$'\t'*}"; ports="${line#*$'\t'}"
    [[ -z "${proc// /}" || -z "${ports// /}" ]] && continue
    p_s="$(sanitize_proc "$proc")"; setname="listen_${p_s}_ports"
    echo "  set ${setname} { type inet_service; elements = { ${ports} } }" >>"$NFT_CONF"
  done

  cat >>"$NFT_CONF" <<'EOF'

  chain input {
    type filter hook input priority 0;
    policy drop;

    iif lo accept
    ct state established,related accept

    ip6 nexthdr icmpv6 icmpv6 type {
      nd-router-solicit, nd-router-advert,
      nd-neighbor-solicit, nd-neighbor-advert,
      nd-redirect,
      packet-too-big, time-exceeded, parameter-problem,
      destination-unreachable
    } accept
EOF

  if [[ "$allow_ping" == "yes" ]]; then
    cat >>"$NFT_CONF" <<'EOF'

    icmp type echo-request accept
    icmpv6 type echo-request accept
EOF
  else
    cat >>"$NFT_CONF" <<'EOF'

    icmp type echo-request drop
    icmpv6 type echo-request drop
EOF
  fi

  cat >>"$NFT_CONF" <<'EOF'

    tcp dport @ssh_ports ct state new limit rate 10/minute accept
    tcp dport @ssh_ports drop
EOF

  for line in "${lines[@]}"; do
    proc="${line%%$'\t'*}"; ports="${line#*$'\t'}"
    [[ -z "${proc// /}" || -z "${ports// /}" ]] && continue
    p_s="$(sanitize_proc "$proc")"; setname="listen_${p_s}_ports"
    cat >>"$NFT_CONF" <<EOF

    meta l4proto { tcp, udp, sctp, dccp } th dport @${setname} accept  # ${proc}
EOF
  done

  cat >>"$NFT_CONF" <<'EOF'
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
    ct state established,related accept
    iifname "docker0" accept
    oifname "docker0" accept
    iifname "br-*" accept
    oifname "br-*" accept
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOF
}

write_files_install(){
  local ssh_ports="$1" allow_ping="$2" allow_procs_str="$3"; shift 3; local allow_lines=("$@")
  write_nft_conf_dynamic "$ssh_ports" "$allow_ping" "${allow_lines[@]}"

  cat >"$PORTSYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

NFT_CONF="/etc/nftables.conf"
DEFAULTS_FILE="/etc/default/nftables-port-sync"

trim(){ awk '{$1=$1};1' <<<"${1:-}"; }

sanitize_proc() {
  local s="${1:-}"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(echo "$s" | sed 's/[^a-z0-9_]/_/g; s/__*/_/g; s/^_//; s/_$//')"
  [[ -z "$s" ]] && s="unknown"
  echo "$s"
}

guess_ssh_ports() {
  local ports=""
  ports="$(ss -lntpH 2>/dev/null | awk '/sshd/ {addr=$4; gsub(/.*:/,"",addr); if(addr~/^[0-9]+$/) print addr}' \
    | sort -n -u | paste -sd, - || true)"
  [[ -z "$ports" && -f /etc/ssh/sshd_config ]] && ports="$(awk 'BEGIN{IGNORECASE=1} $1=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null \
    | sort -n -u | paste -sd, - || true)"
  [[ -z "$ports" ]] && ports="22"
  echo "$ports"
}

scan_proc_ports_tab() {
  ss -lntupH 2>/dev/null | awk '{
    addr=$5; gsub(/.*:/,"",addr); if (addr !~ /^[0-9]+$/) next
    proc="(unknown)"; pos=index($0,"users:((\""); if (pos>0){t=substr($0,pos+9); sub(/".*/,"",t); gsub(/"/,"",t); if(t!="") proc=t}
    print proc "\t" addr
  }' | sort -u | awk -F'\t' '{
    p=$1; port=$2; gsub(/"/,"",p)
    if (p=="" || port=="") next
    ports[p]=ports[p] (ports[p] ? "," : "") port
    procs[p]=1
  } END{
    for (p in procs) print p "\t" ports[p]
  }'
}

SSH_PORTS_OVERRIDE=""
ALLOW_PING="yes"
ALLOW_PROCS=""
[[ -f "$DEFAULTS_FILE" ]] && source "$DEFAULTS_FILE" || true
ALLOW_PING="${ALLOW_PING:-yes}"

ssh_ports=""
if [[ -n "${SSH_PORTS_OVERRIDE:-}" ]]; then ssh_ports="$(trim "${SSH_PORTS_OVERRIDE:-}")"; else ssh_ports="$(guess_ssh_ports)"; fi
ssh_ports="$(trim "$ssh_ports")"; [[ -z "$ssh_ports" ]] && exit 0

declare -A MAP=()
while IFS=$'\t' read -r p csv; do p="$(trim "${p//\"/}")"; [[ -z "$p" ]] && continue; MAP["$p"]="$csv"; done < <(scan_proc_ports_tab)

allow_lines=()
for p in ${ALLOW_PROCS:-}; do csv="${MAP[$p]:-}"; [[ -z "${csv// /}" ]] && continue; allow_lines+=("$p"$'\t'"$csv"); done

tmp="$(mktemp /tmp/nftables.conf.XXXXXX)"

cat >"$tmp" <<EOF2
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  set ssh_ports { type inet_service; elements = { ${ssh_ports} } }
EOF2

for line in "${allow_lines[@]}"; do
  proc="${line%%$'\t'*}"
  ports="${line#*$'\t'}"
  [[ -z "${proc// /}" || -z "${ports// /}" ]] && continue
  p_s="$(sanitize_proc "$proc")"
  setname="listen_${p_s}_ports"
  echo "  set ${setname} { type inet_service; elements = { ${ports} } }" >>"$tmp"
done

cat >>"$tmp" <<'EOF2'

  chain input {
    type filter hook input priority 0;
    policy drop;

    iif lo accept
    ct state established,related accept

    ip6 nexthdr icmpv6 icmpv6 type {
      nd-router-solicit, nd-router-advert,
      nd-neighbor-solicit, nd-neighbor-advert,
      nd-redirect,
      packet-too-big, time-exceeded, parameter-problem,
      destination-unreachable
    } accept
EOF2

if [[ "$ALLOW_PING" == "yes" ]]; then
  cat >>"$tmp" <<'EOF2'

    icmp type echo-request accept
    icmpv6 type echo-request accept
EOF2
else
  cat >>"$tmp" <<'EOF2'

    icmp type echo-request drop
    icmpv6 type echo-request drop
EOF2
fi

cat >>"$tmp" <<'EOF2'

    tcp dport @ssh_ports ct state new limit rate 10/minute accept
    tcp dport @ssh_ports drop
EOF2

for line in "${allow_lines[@]}"; do
  proc="${line%%$'\t'*}"
  ports="${line#*$'\t'}"
  [[ -z "${proc// /}" || -z "${ports// /}" ]] && continue
  p_s="$(sanitize_proc "$proc")"
  setname="listen_${p_s}_ports"
  cat >>"$tmp" <<EOF2

    meta l4proto { tcp, udp, sctp, dccp } th dport @${setname} accept  # ${proc}
EOF2
done

cat >>"$tmp" <<'EOF2'
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
    ct state established,related accept
    iifname "docker0" accept
    oifname "docker0" accept
    iifname "br-*" accept
    oifname "br-*" accept
  }
  chain output {
    type filter hook output priority 0;
    policy accept;
  }  
}
EOF2

nft -c -f "$tmp"
install -m 0644 "$tmp" "$NFT_CONF"
rm -f "$tmp"
nft -f "$NFT_CONF"
EOF
  chmod 0755 "$PORTSYNC_SCRIPT"

  cat >"$DEFAULTS_FILE" <<EOF
SSH_PORTS_OVERRIDE="${ssh_ports}"
ALLOW_PING="${allow_ping}"
ALLOW_PROCS="${allow_procs_str}"
EOF
  chmod 0644 "$DEFAULTS_FILE"

  cat >"$SVC_FILE" <<'EOF'
[Unit]
Description=Sync nftables.conf from current listening ports (boot-time safety)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/sbin/nftables-port-sync.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

install_fw(){
  echo "========== 安装 =========="; echo
  scan_listen_ports; read -r -e -p "(已显示当前监听端口) 按回车继续进入端口配置..." _ || true; echo

  local default_ssh in_ssh ssh_ports
  default_ssh="$(guess_ssh_ports)"; echo "检测到 SSH 端口：${default_ssh}"
  read -r -e -p "请输入要放行的 SSH 端口（可多端口，空格/逗号分隔）[默认: ${default_ssh}] : " in_ssh || true
  in_ssh="$(trim "${in_ssh:-}")"; [[ -z "$in_ssh" ]] && in_ssh="$default_ssh"
  ssh_ports="$(normalize_ports "$in_ssh")"; echo

  declare -A PROC_DEF=()
  local proc csv
  while IFS=$'\t' read -r proc csv; do proc="$(trim "${proc//\"/}")"; [[ -z "$proc" ]] && continue; PROC_DEF["$proc"]="$csv"; done < <(scan_proc_ports_tab)
  mapfile -t PROCS < <(printf "%s\n" "${!PROC_DEF[@]}" | sort)

  declare -A ALLOW_MAP=()
  local in ports
  for proc in "${PROCS[@]}"; do
    [[ "$proc" == "sshd" || "$proc" == "(unknown)" ]] && continue
    csv="${PROC_DEF[$proc]}"; [[ -z "${csv// /}" ]] && continue
    echo "检测到 ${proc} 端口：${csv}"
    read -r -e -p "请输入要放行的 ${proc} 端口（可多端口，空格/逗号分隔）[默认: ${csv}]: " in || true
    in="$(trim "${in:-}")"
    [[ "$in" == "-" ]] && { echo; continue; }
    [[ -z "$in" ]] && in="$csv"
    ports="$(normalize_ports "$in")"; [[ -n "${ports// /}" ]] && ALLOW_MAP["$proc"]="$ports"
    echo
  done

  local in_ping allow_ping="yes"
  read -r -e -p "是否允许 Ping（ICMP echo-request）？[Y/n] : " in_ping || true
  in_ping="$(trim "${in_ping:-}")"
  case "${in_ping,,}" in ""|"y"|"yes") allow_ping="yes" ;; "n"|"no") allow_ping="no" ;; *) echo " 输入无效，默认允许 Ping"; allow_ping="yes" ;; esac

  allow_lines=(); allow_procs_str=""
  for proc in "${!ALLOW_MAP[@]}"; do allow_lines+=("$proc"$'\t'"${ALLOW_MAP[$proc]}"); allow_procs_str+="$proc "; done
  allow_procs_str="$(trim "$allow_procs_str")"

  echo; echo "端口配置汇总："
  echo "  SSH 放行端口（仅 TCP + 限速）：${ssh_ports}"
  if [[ ${#allow_lines[@]} -gt 0 ]]; then
    echo "  动态进程放行："
    for line in "${allow_lines[@]}"; do echo "    - ${line%%$'\t'*} : ${line#*$'\t'}"; done
    echo "  动态放行策略：端口型协议 tcp/udp/sctp/dccp 全放行"
  else
    echo "  动态进程放行：无（你全部跳过了）"
  fi
  echo "  Ping：$([[ "$allow_ping" == "yes" ]] && echo "允许" || echo "禁止")"
  echo

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y; apt-get install -y nftables iproute2

  write_files_install "$ssh_ports" "$allow_ping" "$allow_procs_str" "${allow_lines[@]}"

  systemctl daemon-reload; systemctl enable --now nftables; nft -f "$NFT_CONF"
  systemctl enable nftables-port-sync.service; systemctl start nftables-port-sync.service || true

  echo; echo " 安装完成。检查命令："
  echo "  nft list ruleset"
  echo "  systemctl status nftables --no-pager"
  echo "  systemctl status nftables-port-sync.service --no-pager"
  echo
}

uninstall_fw(){
  echo "========== 卸载 =========="
  echo " 卸载将："
  echo "  - 删除本脚本安装的 service / defaults / portsync 脚本"
  echo "  - 写回默认 nftables.conf 模板"
  echo "  - 关闭 nftables 服务并取消自启"
  echo

  read -r -e -p "确认卸载？输入 YES 继续：" confirm || true
  confirm="$(trim "${confirm:-}")"; [[ "$confirm" != "YES" ]] && { echo " 已取消卸载。"; return 0; }

  systemctl stop nftables-port-sync.service 2>/dev/null || true
  systemctl disable nftables-port-sync.service 2>/dev/null || true

  rm -f "$SVC_FILE" "$DEFAULTS_FILE" "$PORTSYNC_SCRIPT" 2>/dev/null || true

  restore_or_remove_nft_conf
  nft -f "$NFT_CONF" 2>/dev/null || true

  systemctl disable --now nftables 2>/dev/null || true
  systemctl daemon-reload || true

  echo; echo " 卸载完成。"
}

show_menu(){
  clear_screen
  echo
  echo "=============================="
  echo "   NFTables 防火墙管理菜单"
  echo "=============================="
  echo "1) 安装"
  echo "2) 卸载"
  echo "0) 退出"
  echo "------------------------------"
}

main(){
  while true; do
    show_menu
    read -r -e -p "请选择 [0-2]：" choice || true
    choice="$(trim "${choice:-}")"
    case "$choice" in
      1) install_fw; pause ;;
      2) uninstall_fw; pause ;;
      0) echo "退出。"; exit 0 ;;
      *) echo " 请输入 0/1/2"; pause ;;
    esac
  done
}

main
