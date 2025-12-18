#!/usr/bin/env bash
set -euo pipefail

clear_screen(){
  command -v tput >/dev/null 2>&1 && tput clear || printf "c"
}

pause(){
  echo
  read -r -e -p "按回车继续..." _ || true
}

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

ports_union_csv(){
  local a="${1:-}" b="${2:-}"
  echo "${a},${b}" | tr ',' '\n' | awk 'NF' | sort -n -u | paste -sd, -
}

ports_minus_csv(){
  local base="${1:-}" rm="${2:-}"
  [[ -z "${base// /}" ]] && { echo ""; return 0; }
  [[ -z "${rm// /}" ]] && { echo "$(echo "$base" | tr ',' '\n' | awk 'NF' | sort -n -u | paste -sd, -)"; return 0; }
  awk -v B="$base" -v R="$rm" '
    BEGIN{
      n=split(R, rr, ","); for(i=1;i<=n;i++){ if(rr[i]!="") del[rr[i]]=1 }
      m=split(B, bb, ","); for(i=1;i<=m;i++){
        if(bb[i]=="" ) continue
        if(!(bb[i] in del)) keep[bb[i]]=1
      }
      for(k in keep) print k
    }
  ' | sort -n -u | paste -sd, -
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
  local ssh_ports="$1" allow_ping="$2" open_ports="$3"; shift 3; local lines=("$@")

  cat >"$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  set ssh_ports  { type inet_service; elements = { ${ssh_ports} } }
EOF

  if [[ -n "${open_ports//[[:space:]]/}" ]]; then
    echo "  set open_port  { type inet_service; elements = { ${open_ports} } }" >>"$NFT_CONF"
  else
    echo "  set open_port  { type inet_service; }" >>"$NFT_CONF"
  fi

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

    tcp dport @ssh_ports ct state new limit rate 20/minute accept
    tcp dport @ssh_ports drop

    meta l4proto { tcp, udp, sctp, dccp } th dport @open_port accept
EOF

  for line in "${lines[@]}"; do
    proc="${line%%$'\t'*}"; ports="${line#*$'\t'}"
    [[ -z "${proc// /}" || -z "${ports// /}" ]] && continue
    p_s="$(sanitize_proc "$proc")"; setname="listen_${p_s}_ports"
    cat >>"$NFT_CONF" <<EOF

    meta l4proto { tcp, udp, sctp, dccp } th dport @${setname} accept
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
    iifname "veth*" accept
    oifname "veth*" accept
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
  local ssh_ports="$1" allow_ping="$2" allow_procs_str="$3" open_ports="$4"; shift 4; local allow_lines=("$@")
  write_nft_conf_dynamic "$ssh_ports" "$allow_ping" "$open_ports" "${allow_lines[@]}"

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
  ports="$(ss -lntpH 2>/dev/null | awk '/sshd/ {addr=$4; gsub(/.*:/,"",addr); if(addr~/^[0-9]+$/) print addr}'     | sort -n -u | paste -sd, - || true)"
  [[ -z "$ports" && -f /etc/ssh/sshd_config ]] && ports="$(awk 'BEGIN{IGNORECASE=1} $1=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null     | sort -n -u | paste -sd, - || true)"
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
OPEN_PORTS=""
[[ -f "$DEFAULTS_FILE" ]] && source "$DEFAULTS_FILE" || true
ALLOW_PING="${ALLOW_PING:-yes}"
OPEN_PORTS="$(trim "${OPEN_PORTS:-}")"

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

if [[ -n "${OPEN_PORTS:-}" && -n "${OPEN_PORTS//[[:space:]]/}" ]]; then
  echo "  set open_port { type inet_service; elements = { ${OPEN_PORTS} } }" >>"$tmp"
else
  echo "  set open_port { type inet_service; }" >>"$tmp"
fi

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

    tcp dport @ssh_ports ct state new limit rate 20/minute accept
    tcp dport @ssh_ports drop

    meta l4proto { tcp, udp, sctp, dccp } th dport @open_port accept
EOF2

for line in "${allow_lines[@]}"; do
  proc="${line%%$'\t'*}"
  ports="${line#*$'\t'}"
  [[ -z "${proc// /}" || -z "${ports// /}" ]] && continue
  p_s="$(sanitize_proc "$proc")"
  setname="listen_${p_s}_ports"
  cat >>"$tmp" <<EOF2

    meta l4proto { tcp, udp, sctp, dccp } th dport @${setname} accept
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
    iifname "veth*" accept
    oifname "veth*" accept
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
OPEN_PORTS="${open_ports}"
EOF
  chmod 0644 "$DEFAULTS_FILE"

  cat >"$SVC_FILE" <<'EOF'
[Unit]
Description=Sync nftables.conf from current listening ports (boot-time safety)
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 20
ExecStart=/usr/local/sbin/nftables-port-sync.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

apply_portsync_now(){
  if [[ ! -x "$PORTSYNC_SCRIPT" ]]; then
    echo " 未检测到 $PORTSYNC_SCRIPT（请先运行“安装/更新”）。"
    return 1
  fi
  "$PORTSYNC_SCRIPT"
}

read_defaults_safe(){
  SSH_PORTS_OVERRIDE=""; ALLOW_PING="yes"; ALLOW_PROCS=""; OPEN_PORTS=""
  [[ -f "$DEFAULTS_FILE" ]] && source "$DEFAULTS_FILE" || true
  SSH_PORTS_OVERRIDE="$(trim "${SSH_PORTS_OVERRIDE:-}")"
  ALLOW_PING="$(trim "${ALLOW_PING:-yes}")"
  ALLOW_PROCS="$(trim "${ALLOW_PROCS:-}")"
  OPEN_PORTS="$(trim "${OPEN_PORTS:-}")"
}

write_defaults_only_open_ports(){
  local new_open="${1:-}"
  read_defaults_safe
  cat >"$DEFAULTS_FILE" <<EOF
SSH_PORTS_OVERRIDE="${SSH_PORTS_OVERRIDE}"
ALLOW_PING="${ALLOW_PING}"
ALLOW_PROCS="${ALLOW_PROCS}"
OPEN_PORTS="${new_open}"
EOF
  chmod 0644 "$DEFAULTS_FILE"
}

ports_manage_add(){
  read_defaults_safe
  echo; echo "当前放行端口：${OPEN_PORTS:-<空>}"
  local in_open add_ports merged
  read -r -e -p "请输入要新增放行的端口（空格/逗号分隔；留空取消）: " in_open || true
  in_open="$(trim "${in_open:-}")"
  [[ -z "$in_open" ]] && { echo " 已取消。"; return 0; }
  add_ports="$(normalize_ports "$in_open")"
  merged="$(ports_union_csv "${OPEN_PORTS}" "${add_ports}")"
  write_defaults_only_open_ports "$merged"
  apply_portsync_now || true
  echo " 已更新放行端口：${merged:-<空>}"
}

ports_manage_del(){
  read_defaults_safe
  echo; echo "当前放行端口：${OPEN_PORTS:-<空>}"
  [[ -z "${OPEN_PORTS// /}" ]] && { echo " 放行端口为空，无需删除。"; return 0; }
  local in_rm rm_ports after
  read -r -e -p "请输入要删除的端口（空格/逗号分隔；留空取消）: " in_rm || true
  in_rm="$(trim "${in_rm:-}")"
  [[ -z "$in_rm" ]] && { echo " 已取消。"; return 0; }
  rm_ports="$(normalize_ports "$in_rm")"
  after="$(ports_minus_csv "${OPEN_PORTS}" "${rm_ports}")"
  write_defaults_only_open_ports "$after"
  apply_portsync_now || true
  echo " 已更新放行端口：${after:-<空>}"
}

ports_manage_view(){
  read_defaults_safe

  local ssh_show=""
  if [[ -n "${SSH_PORTS_OVERRIDE:-}" ]]; then
    ssh_show="$(trim "${SSH_PORTS_OVERRIDE}")"
  else
    ssh_show="$(guess_ssh_ports)"
  fi
  ssh_show="$(normalize_ports "$ssh_show" || true)"

  local open_show=""
  open_show="$(trim "${OPEN_PORTS:-}")"
  [[ -n "${open_show// /}" ]] && open_show="$(normalize_ports "$open_show" || true)"

  echo
  echo "============= 端口查看 ============="
  echo "SSH 放行端口：${ssh_show:-<空>}"
  echo "自定义放行端口：${open_show:-<空>}"
  echo "ALLOW_PROCS：${ALLOW_PROCS:-<空>}"
  echo

  declare -A MAP=()
  local p csv
  while IFS=$'\t' read -r p csv; do
    p="$(trim "${p//\"/}")"
    [[ -z "$p" ]] && continue
    MAP["$p"]="$(normalize_ports "$csv" || true)"
  done < <(scan_proc_ports_tab)

  echo "============= 进程端口 ============="
  if [[ -n "${ALLOW_PROCS:-}" ]]; then
    for p in ${ALLOW_PROCS}; do
      if [[ -n "${MAP[$p]:-}" ]]; then
        echo " - ${p}: ${MAP[$p]}"
      else
        echo " - ${p}: <当前未监听>"
      fi
    done
  else
    echo " - <未配置 ALLOW_PROCS>"
  fi
  echo

  local allow_all=""
  allow_all="$(ports_union_csv "${ssh_show:-}" "${open_show:-}")"
  if [[ -n "${ALLOW_PROCS:-}" ]]; then
    for p in ${ALLOW_PROCS}; do
      allow_all="$(ports_union_csv "$allow_all" "${MAP[$p]:-}")"
    done
  fi

  echo "============= 放行端口总览 ============="
  echo "${allow_all:-<空>}"
  echo
}

ports_manage_menu(){
  while true; do
    clear_screen
    echo
    echo "=============================="
    echo "           端口管理"
    echo "=============================="
    echo "1) 添加端口"
    echo "2) 删除端口"
    echo "3) 查看端口"
    echo "0) 退回上一级"
    echo "------------------------------"
    read -r -e -p "请选择 [0-3]：" c || true
    c="$(trim "${c:-}")"
    case "$c" in
      1) ports_manage_add; pause ;;
      2) ports_manage_del; pause ;;
      3) ports_manage_view; pause ;;
      0) return 0 ;;
      *) echo " 请输入 0/1/2/3"; pause ;;
    esac
  done
}

install_fw(){
  echo
  scan_listen_ports; read -r -e -p "(已显示当前监听端口) 按回车继续进入端口配置..." _ || true; echo

  local default_ssh in_ssh ssh_ports
  default_ssh="$(guess_ssh_ports)"; echo "检测到 SSH 端口：${default_ssh}"
  read -r -e -p "请输入要放行的 SSH 端口 [默认: ${default_ssh}] : " in_ssh || true
  in_ssh="$(trim "${in_ssh:-}")"; [[ -z "$in_ssh" ]] && in_ssh="$default_ssh"
  ssh_ports="$(normalize_ports "$in_ssh")"
  echo

  declare -A PROC_DEF=()
  local proc csv
  while IFS=$'\t' read -r proc csv; do proc="$(trim "${proc//\"/}")"; [[ -z "$proc" ]] && continue; PROC_DEF["$proc"]="$csv"; done < <(scan_proc_ports_tab)
  mapfile -t PROCS < <(printf "%s\n" "${!PROC_DEF[@]}" | sort)

  declare -A ALLOW_MAP=()
  local in ports
  for proc in "${PROCS[@]}"; do
    [[ "$proc" == "sshd" || "$proc" == "(unknown)" ]] && continue
    case "$proc" in
      systemd-timesyncd|systemd-resolved|avahi-daemon|dhclient|NetworkManager) continue ;;
    esac
    csv="${PROC_DEF[$proc]}"; [[ -z "${csv// /}" ]] && continue
    echo "检测到 ${proc} 端口：${csv}"
    read -r -e -p "[默认: ${csv}]  回车继续: " _ || true
ports="$(normalize_ports "$csv")"
[[ -n "${ports// /}" ]] && ALLOW_MAP["$proc"]="$ports"
echo
  done

  local in_open open_ports=""
  read -r -e -p "请输入需要放行的端口（空格/逗号分隔；留空跳过）: " in_open || true
  in_open="$(trim "${in_open:-}")"
  if [[ -n "$in_open" ]]; then open_ports="$(normalize_ports "$in_open")"; fi
  echo

  local in_ping allow_ping="yes"
  read -r -e -p "是否允许 Ping（ICMP echo-request）？[Y/n] : " in_ping || true
  in_ping="$(trim "${in_ping:-}")"
  case "${in_ping,,}" in ""|"y"|"yes") allow_ping="yes" ;; "n"|"no") allow_ping="no" ;; *) echo " 输入无效，默认允许 Ping"; allow_ping="yes" ;; esac

  allow_lines=(); allow_procs_str=""
  for proc in "${!ALLOW_MAP[@]}"; do allow_lines+=("$proc"$'\t'"${ALLOW_MAP[$proc]}"); allow_procs_str+="$proc "; done
  allow_procs_str="$(trim "$allow_procs_str")"

  echo; echo "端口配置汇总："
  echo "  SSH 放行端口 ：${ssh_ports}"
  echo "  自定义放行端口 ：${open_ports:-<空>}"
  if [[ ${#allow_lines[@]} -gt 0 ]]; then
    echo "  动态进程："
    for line in "${allow_lines[@]}"; do echo "    - ${line%%$'\t'*} : ${line#*$'\t'}"; done
    echo "  动态放行策略：端口型协议 tcp/udp/sctp/dccp 全放行"
  else
    echo "  动态进程放行：无"
  fi
  echo "  Ping：$([[ "$allow_ping" == "yes" ]] && echo "允许" || echo "禁止")"
  echo

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y; apt-get install -y nftables iproute2

  write_files_install "$ssh_ports" "$allow_ping" "$allow_procs_str" "$open_ports" "${allow_lines[@]}"

  systemctl daemon-reload; systemctl enable --now nftables; nft -f "$NFT_CONF"
  systemctl enable nftables-port-sync.service; systemctl start nftables-port-sync.service || true

  echo; echo " 安装/更新完成。检查命令："
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
  echo "1) 安装/更新"
  echo "2) 端口管理"
  echo "3) 卸载"
  echo "0) 退出"
  echo "------------------------------"
}

main(){
  while true; do
    show_menu
    read -r -e -p "请选择 [0-3]：" choice || true
    choice="$(trim "${choice:-}")"
    case "$choice" in
      1) install_fw; pause ;;
      2) ports_manage_menu ;;
      3) uninstall_fw; pause ;;
      0) echo "退出。"; exit 0 ;;
      *) echo " 请输入 0/1/2/3"; pause ;;
    esac
  done
}

main
