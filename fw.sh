#!/usr/bin/env bash
set -euo pipefail

clear_screen(){ command -v tput >/dev/null 2>&1 && tput clear || printf "\033c"; }
pause(){ echo; read -r -e -p "按回车继续..." _ || true; }
trim(){ awk '{$1=$1};1' <<<"${1:-}"; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo " 请用 root 执行：sudo $0"; exit 1; fi
if [[ -t 0 ]]; then stty sane 2>/dev/null || true; stty erase '^?' 2>/dev/null || stty erase '^H' 2>/dev/null || true; fi

NFT_CONF="/etc/nftables.conf"
PORTSYNC_SCRIPT="/usr/local/sbin/nftables-port-sync.sh"
DEFAULTS_FILE="/etc/default/nftables-port-sync"
SVC_FILE="/etc/systemd/system/nftables-port-sync.service"

BL_TCP_SYN_RATE="30/minute"     # TCP SYN 新连接超过此速率拉黑
BL_UDP_NEW_RATE="50/minute"     # UDP 新连接超过此速率拉黑
BL_TCP_TIMEOUT="24h"            # TCP/UDP 拉黑时长
BL_UDP_TIMEOUT="24h"
BL_ICMP_TIMEOUT="1h"            # Ping 拉黑时长

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

ports_union_csv(){ local a="${1:-}" b="${2:-}"; echo "${a},${b}" | tr ',' '\n' | awk 'NF' | sort -n -u | paste -sd, -; }

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
  ports="$(ss -lntpH 2>/dev/null | awk '$1=="LISTEN" && index($0, "users:((\"sshd\"")>0 { addr=$4; if (match(addr, /:([0-9]+)$/, m)) print m[1] }' | sort -n -u | paste -sd, - || true)"
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
  ss -lntupH 2>/dev/null | awk '{ proto=$1; addr=$5; if (!match(addr, /:([0-9]+)$/, m)) next; addr=m[1]; proc="(unknown)"; pos=index($0,"users:((\""); if (pos>0){t=substr($0,pos+9); sub(/".*/,"",t); gsub(/"/,"",t); if(t!="") proc=t} printf "%-4s %-6s %s\n", proto, addr, proc }' | sort -k1,1 -k2,2n -k3,3
  echo
  ss -lntupH 2>/dev/null | awk '{
    proto=$1; addr=$5; if (!match(addr, /:([0-9]+)$/, m)) next; addr=m[1]
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
    addr=$5; if (!match(addr, /:([0-9]+)$/, m)) next; addr=m[1]
    proc="(unknown)"; pos=index($0,"users:((\""); if (pos>0){t=substr($0,pos+9); sub(/".*/,"",t); gsub(/"/,"",t); if(t!="") proc=t}
    print proc "\t" addr
  }' | sort -u | awk -F'\t' '{
    p=$1; port=$2; gsub(/"/,"",p)
    if (p=="" || port=="") next
    ports[p]=ports[p] (ports[p] ? "," : "") port
    procs[p]=1
  } END{ for (p in procs) print p "\t" ports[p] }'
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

table inet filter {
  set ssh_ports  { type inet_service; elements = { ${ssh_ports} } }
EOF
  if [[ -n "${open_ports//[[:space:]]/}" ]]; then echo "  set open_port  { type inet_service; elements = { ${open_ports} } }" >>"$NFT_CONF"; else echo "  set open_port  { type inet_service; }" >>"$NFT_CONF"; fi

  cat >>"$NFT_CONF" <<'EOF'
  set blacklist_v4 { type ipv4_addr; flags dynamic,timeout; }
  set blacklist_v6 { type ipv6_addr; flags dynamic,timeout; }
  set local_ipv4 { type ipv4_addr; flags interval; elements = { 127.0.0.0/8 }; }
  set local_ipv6 { type ipv6_addr; flags interval; elements = { ::1, fe80::/10 }; }
EOF

  local line proc ports p_s setname
  for line in "${lines[@]}"; do
    proc="${line%%$'\t'*}"; ports="${line#*$'\t'}"
    [[ -z "${proc// /}" || -z "${ports// /}" ]] && continue
    p_s="$(sanitize_proc "$proc")"; setname="listen_${p_s}_ports"
    echo "  set ${setname} { type inet_service; elements = { ${ports} } }" >>"$NFT_CONF"
  done

  cat >>"$NFT_CONF" <<EOF

  chain input {
    type filter hook input priority 0;
    policy drop;
    ip  saddr @local_ipv4 accept comment "LOCAL_V4"
    ip6 saddr @local_ipv6 accept comment "LOCAL_V6"
    ip  saddr @blacklist_v4 counter drop comment "BL_DROP_V4"
    ip6 saddr @blacklist_v6 counter drop comment "BL_DROP_V6"
    iif lo accept
    ct state established,related accept
    ip6 nexthdr icmpv6 icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, nd-redirect, packet-too-big, time-exceeded, parameter-problem, destination-unreachable } accept
EOF
  if [[ "$allow_ping" == "yes" ]]; then
    cat >>"$NFT_CONF" <<'EOF'
    icmp type echo-request accept
    icmpv6 type echo-request accept
EOF
  else
    cat >>"$NFT_CONF" <<EOF
    ip saddr != @local_ipv4 icmp  type echo-request counter add @blacklist_v4 { ip  saddr timeout ${BL_ICMP_TIMEOUT} } drop comment "BL_ICMP_V4"
    ip6 saddr != @local_ipv6 icmpv6 type echo-request counter add @blacklist_v6 { ip6 saddr timeout ${BL_ICMP_TIMEOUT} } drop comment "BL_ICMP_V6"
EOF
  fi
  cat >>"$NFT_CONF" <<'EOF'
    tcp dport @ssh_ports ct state new limit rate 20/minute accept
    ip  saddr != @local_ipv4 tcp dport @ssh_ports ct state new limit rate over 20/minute add @blacklist_v4 { ip saddr timeout 24h } drop
    ip6 saddr != @local_ipv6 tcp dport @ssh_ports ct state new limit rate over 20/minute add @blacklist_v6 { ip6 saddr timeout 24h } drop
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
  cat >>"$NFT_CONF" <<EOF
    ip  saddr != @local_ipv4 tcp flags syn ct state new limit rate over ${BL_TCP_SYN_RATE} counter add @blacklist_v4 { ip  saddr timeout ${BL_TCP_TIMEOUT} } comment "BL_SYN_V4"
    ip6 saddr != @local_ipv6 tcp flags syn ct state new limit rate over ${BL_TCP_SYN_RATE} counter add @blacklist_v6 { ip6 saddr timeout ${BL_TCP_TIMEOUT} } comment "BL_SYN_V6"
    ip  saddr != @local_ipv4 meta l4proto udp ct state new limit rate over ${BL_UDP_NEW_RATE} counter add @blacklist_v4 { ip  saddr timeout ${BL_UDP_TIMEOUT} } comment "BL_UDP_V4"
    ip6 saddr != @local_ipv6 meta l4proto udp ct state new limit rate over ${BL_UDP_NEW_RATE} counter add @blacklist_v6 { ip6 saddr timeout ${BL_UDP_TIMEOUT} } comment "BL_UDP_V6"
EOF
  cat >>"$NFT_CONF" <<'EOF'
  }
  chain forward {
    type filter hook forward priority 0;
    policy drop;
    ct state { new, established, related } accept
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

  cat >"$PORTSYNC_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

NFT_CONF="/etc/nftables.conf"
DEFAULTS_FILE="/etc/default/nftables-port-sync"

BL_TCP_SYN_RATE="${BL_TCP_SYN_RATE}"
BL_UDP_NEW_RATE="${BL_UDP_NEW_RATE}"
BL_TCP_TIMEOUT="${BL_TCP_TIMEOUT}"
BL_UDP_TIMEOUT="${BL_UDP_TIMEOUT}"
BL_ICMP_TIMEOUT="${BL_ICMP_TIMEOUT}"

trim(){ awk '{\$1=\$1};1' <<<"\${1:-}"; }

sanitize_proc() {
  local s="\${1:-}"
  s="\$(echo "\$s" | tr '[:upper:]' '[:lower:]')"
  s="\$(echo "\$s" | sed 's/[^a-z0-9_]/_/g; s/__*/_/g; s/^_//; s/_$//')"
  [[ -z "\$s" ]] && s="unknown"
  echo "\$s"
}

guess_ssh_ports() {
  local ports=""
  ports="\$(ss -lntpH 2>/dev/null | awk '/sshd/ {addr=\$4; if (match(addr, /:([0-9]+)$/, m)) print m[1]}'     | sort -n -u | paste -sd, - || true)"
  [[ -z "\$ports" && -f /etc/ssh/sshd_config ]] && ports="\$(awk 'BEGIN{IGNORECASE=1} \$1=="port"{print \$2}' /etc/ssh/sshd_config 2>/dev/null     | sort -n -u | paste -sd, - || true)"
  [[ -z "\$ports" ]] && ports="22"
  echo "\$ports"
}

scan_proc_ports_tab() {
  ss -lntupH 2>/dev/null | awk '{
    addr=\$5; if (!match(addr, /:([0-9]+)$/, m)) next; addr=m[1]
    proc="(unknown)"; pos=index(\$0,"users:((\\""); if (pos>0){t=substr(\$0,pos+9); sub(/".*/,"",t); gsub(/"/,"",t); if(t!="") proc=t}
    print proc "\\t" addr
  }' | sort -u | awk -F'\\t' '{
    p=\$1; port=\$2; gsub(/"/,"",p)
    if (p=="" || port=="") next
    ports[p]=ports[p] (ports[p] ? "," : "") port
    procs[p]=1
  } END{
    for (p in procs) print p "\\t" ports[p]
  }'
}

export_blacklist_cmds() {
  local out="\$1"
  : > "\$out"
  local dump4 dump6
  dump4="\$(nft list set inet filter blacklist_v4 2>/dev/null || true)"
  dump6="\$(nft list set inet filter blacklist_v6 2>/dev/null || true)"

  if [[ -n "\$dump4" ]]; then
    echo "\$dump4" | sed -n '/elements = {/,/}/p' | sed '1d;\$d' | tr -d ',' | while read -r line; do
      line="\$(trim "\$line")"; [[ -z "\$line" ]] && continue
      if [[ "\$line" =~ ^([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)([[:space:]]+timeout[[:space:]]+([^[:space:]]+))? ]]; then
        ip="\${BASH_REMATCH[1]}"
        t="\${BASH_REMATCH[3]:-}"
        if [[ -n "\$t" ]]; then
          echo "add element inet filter blacklist_v4 { \$ip timeout \$t }" >>"\$out"
        else
          echo "add element inet filter blacklist_v4 { \$ip }" >>"\$out"
        fi
      fi
    done
  fi

  if [[ -n "\$dump6" ]]; then
    echo "\$dump6" | sed -n '/elements = {/,/}/p' | sed '1d;\$d' | tr -d ',' | while read -r line; do
      line="\$(trim "\$line")"; [[ -z "\$line" ]] && continue
      if [[ "\$line" =~ ^([0-9a-fA-F:]+)([[:space:]]+timeout[[:space:]]+([^[:space:]]+))? ]]; then
        ip="\${BASH_REMATCH[1]}"
        t="\${BASH_REMATCH[3]:-}"
        if [[ -n "\$t" ]]; then
          echo "add element inet filter blacklist_v6 { \$ip timeout \$t }" >>"\$out"
        else
          echo "add element inet filter blacklist_v6 { \$ip }" >>"\$out"
        fi
      fi
    done
  fi
}

SSH_PORTS_OVERRIDE=""
ALLOW_PING="yes"
ALLOW_PROCS=""
OPEN_PORTS=""
[[ -f "\$DEFAULTS_FILE" ]] && source "\$DEFAULTS_FILE" || true
ALLOW_PING="\${ALLOW_PING:-yes}"
OPEN_PORTS="\$(trim "\${OPEN_PORTS:-}")"

ssh_ports=""
if [[ -n "\${SSH_PORTS_OVERRIDE:-}" ]]; then ssh_ports="\$(trim "\${SSH_PORTS_OVERRIDE:-}")"; else ssh_ports="\$(guess_ssh_ports)"; fi
ssh_ports="\$(trim "\$ssh_ports")"; [[ -z "\$ssh_ports" ]] && exit 0

declare -A MAP=()
while IFS=\$'\\t' read -r p csv; do p="\$(trim "\${p//\\"/}")"; [[ -z "\$p" ]] && continue; MAP["\$p"]="\$csv"; done < <(scan_proc_ports_tab)

allow_lines=()
for p in \${ALLOW_PROCS:-}; do csv="\${MAP[\$p]:-}"; [[ -z "\${csv// /}" ]] && continue; allow_lines+=("\$p"\$'\\t'"\$csv"); done

tmp="\$(mktemp /tmp/nftables.conf.XXXXXX)"
bl_cmds="\$(mktemp /tmp/nftables.blacklist.XXXXXX)"
export_blacklist_cmds "\$bl_cmds"

cat >"\$tmp" <<EOF2
#!/usr/sbin/nft -f

table inet filter {
  set ssh_ports { type inet_service; elements = { \${ssh_ports} } }
EOF2

if [[ -n "\${OPEN_PORTS:-}" && -n "\${OPEN_PORTS//[[:space:]]/}" ]]; then
  echo "  set open_port { type inet_service; elements = { \${OPEN_PORTS} } }" >>"\$tmp"
else
  echo "  set open_port { type inet_service; }" >>"\$tmp"
fi

cat >>"\$tmp" <<'EOF2'
  set blacklist_v4 { type ipv4_addr; flags dynamic,timeout; }
  set blacklist_v6 { type ipv6_addr; flags dynamic,timeout; }
  set local_ipv4 { type ipv4_addr; flags interval; elements = { 127.0.0.0/8 }; }
  set local_ipv6 { type ipv6_addr; flags interval; elements = { ::1, fe80::/10 }; }
EOF2

for line in "\${allow_lines[@]}"; do
  proc="\${line%%\$'\\t'*}"
  ports="\${line#*\$'\\t'}"
  [[ -z "\${proc// /}" || -z "\${ports// /}" ]] && continue
  p_s="\$(sanitize_proc "\$proc")"
  setname="listen_\${p_s}_ports"
  echo "  set \${setname} { type inet_service; elements = { \${ports} } }" >>"\$tmp"
done

cat >>"\$tmp" <<EOF2

  chain input {
    type filter hook input priority 0;
    policy drop;
    ip  saddr @local_ipv4 accept comment "LOCAL_V4"
    ip6 saddr @local_ipv6 accept comment "LOCAL_V6"
    ip  saddr @blacklist_v4 counter drop comment "BL_DROP_V4"
    ip6 saddr @blacklist_v6 counter drop comment "BL_DROP_V6"
    iif lo accept
    ct state established,related accept
    ip6 nexthdr icmpv6 icmpv6 type { nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, nd-redirect, packet-too-big, time-exceeded, parameter-problem, destination-unreachable } accept
EOF2
if [[ "\$ALLOW_PING" == "yes" ]]; then
  cat >>"\$tmp" <<'EOF2'
    icmp type echo-request accept
    icmpv6 type echo-request accept
EOF2
else
  cat >>"\$tmp" <<EOF2
    ip saddr != @local_ipv4 icmp  type echo-request add @blacklist_v4 { ip  saddr timeout ${BL_ICMP_TIMEOUT} } drop
    ip6 saddr != @local_ipv6 icmpv6 type echo-request add @blacklist_v6 { ip6 saddr timeout ${BL_ICMP_TIMEOUT} } drop
EOF2
fi
cat >>"\$tmp" <<'EOF2'
    tcp dport @ssh_ports ct state new limit rate 20/minute accept
    ip  saddr != @local_ipv4 tcp dport @ssh_ports ct state new limit rate over 20/minute add @blacklist_v4 { ip saddr timeout 24h } drop
    ip6 saddr != @local_ipv6 tcp dport @ssh_ports ct state new limit rate over 20/minute add @blacklist_v6 { ip6 saddr timeout 24h } drop
    tcp dport @ssh_ports drop
    meta l4proto { tcp, udp, sctp, dccp } th dport @open_port accept
EOF2
for line in "\${allow_lines[@]}"; do
  proc="\${line%%\$'\\t'*}"
  ports="\${line#*\$'\\t'}"
  [[ -z "\${proc// /}" || -z "\${ports// /}" ]] && continue
  p_s="\$(sanitize_proc "\$proc")"
  setname="listen_\${p_s}_ports"
  cat >>"\$tmp" <<EOF2
    meta l4proto { tcp, udp, sctp, dccp } th dport @\${setname} accept
EOF2
done
cat >>"\$tmp" <<EOF2
    ip saddr != @local_ipv4 tcp flags syn ct state new limit rate over ${BL_TCP_SYN_RATE} add @blacklist_v4 { ip saddr timeout ${BL_TCP_TIMEOUT} }
    ip6 saddr != @local_ipv6 tcp flags syn ct state new limit rate over ${BL_TCP_SYN_RATE} add @blacklist_v6 { ip6 saddr timeout ${BL_TCP_TIMEOUT} }
    ip saddr != @local_ipv4 meta l4proto udp ct state new limit rate over ${BL_UDP_NEW_RATE} add @blacklist_v4 { ip saddr timeout ${BL_UDP_TIMEOUT} }
    ip6 saddr != @local_ipv6 meta l4proto udp ct state new limit rate over ${BL_UDP_NEW_RATE} add @blacklist_v6 { ip6 saddr timeout ${BL_UDP_TIMEOUT} }
EOF2
cat >>"\$tmp" <<'EOF2'
  }
  chain forward {
    type filter hook forward priority 0;
    policy drop;
    ct state { new, established, related } accept
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

nft -c -f "\$tmp"
install -m 0644 "\$tmp" "\$NFT_CONF"
rm -f "\$tmp"

nft delete table inet filter 2>/dev/null || true
nft -f "\$NFT_CONF"

if [[ -s "\$bl_cmds" ]]; then
  nft -f "\$bl_cmds" 2>/dev/null || true
fi
rm -f "\$bl_cmds"
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
ExecStartPre=/bin/sleep 10
ExecStart=/usr/local/sbin/nftables-port-sync.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

apply_portsync_now(){
  if [[ ! -x "$PORTSYNC_SCRIPT" ]]; then echo " 未检测到 $PORTSYNC_SCRIPT（请先运行“安装/更新”）。"; return 1; fi
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
  in_open="$(trim "${in_open:-}")"; [[ -z "$in_open" ]] && { echo " 已取消。"; return 0; }
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
  in_rm="$(trim "${in_rm:-}")"; [[ -z "$in_rm" ]] && { echo " 已取消。"; return 0; }
  rm_ports="$(normalize_ports "$in_rm")"
  after="$(ports_minus_csv "${OPEN_PORTS}" "${rm_ports}")"
  write_defaults_only_open_ports "$after"
  apply_portsync_now || true
  echo " 已更新放行端口：${after:-<空>}"
}

ports_manage_view(){
  read_defaults_safe
  local ssh_show=""
  if [[ -n "${SSH_PORTS_OVERRIDE:-}" ]]; then ssh_show="$(trim "${SSH_PORTS_OVERRIDE}")"; else ssh_show="$(guess_ssh_ports)"; fi
  ssh_show="$(normalize_ports "$ssh_show" || true)"
  local open_show=""
  open_show="$(trim "${OPEN_PORTS:-}")"; [[ -n "${open_show// /}" ]] && open_show="$(normalize_ports "$open_show" || true)"

  echo
  echo "============= 端口查看 ============="
  echo "SSH 放行端口：${ssh_show:-<空>}"
  echo "自定义放行端口：${open_show:-<空>}"
  echo "ALLOW_PROCS：${ALLOW_PROCS:-<空>}"
  echo

  declare -A MAP=()
  local p csv
  while IFS=$'\t' read -r p csv; do p="$(trim "${p//\"/}")"; [[ -z "$p" ]] && continue; MAP["$p"]="$(normalize_ports "$csv" || true)"; done < <(scan_proc_ports_tab)

  echo "============= 进程端口 ============="
  if [[ -n "${ALLOW_PROCS:-}" ]]; then
    for p in ${ALLOW_PROCS}; do
      if [[ -n "${MAP[$p]:-}" ]]; then echo " - ${p}: ${MAP[$p]}"; else echo " - ${p}: <当前未监听>"; fi
    done
  else
    echo " - <未配置 ALLOW_PROCS>"
  fi
  echo

  local allow_all=""; allow_all="$(ports_union_csv "${ssh_show:-}" "${open_show:-}")"
  if [[ -n "${ALLOW_PROCS:-}" ]]; then
    for p in ${ALLOW_PROCS}; do allow_all="$(ports_union_csv "$allow_all" "${MAP[$p]:-}")"; done
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
    read -r -e -p "请选择 [0-4]：" c || true
    c="$(trim "${c:-}")"
    case "$c" in
      1) ports_manage_add; pause ;;
      2) ports_manage_del; pause ;;
      3) ports_manage_view; pause ;;
      0) return 0 ;;
      *) echo " 请输入 0/1/2/3/4"; pause ;;
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
    case "$proc" in systemd-timesyncd|systemd-resolved|avahi-daemon|dhclient|NetworkManager) continue ;; esac
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
  [[ -n "$in_open" ]] && open_ports="$(normalize_ports "$in_open")"
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

  systemctl daemon-reload; systemctl enable --now nftables
  systemctl enable nftables-port-sync.service; systemctl start nftables-port-sync.service || true

  echo; echo " 安装/更新完成。检查命令："
  echo "  nft list ruleset"
  echo "  systemctl status nftables --no-pager"
  echo "  systemctl status nftables-port-sync.service --no-pager"
  echo "  nft list set inet filter blacklist_v4"
  echo "  nft list set inet filter blacklist_v6"
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

nft_dump_set_elements() {
  local fam="$1" tbl="$2" set="$3"
  nft list set "$fam" "$tbl" "$set" 2>/dev/null | awk '
    BEGIN{inside=0}
    /elements = \{/{
      inside=1
      sub(/.*elements = \{[[:space:]]*/, "")
      if ($0 ~ /\}/) {
        sub(/\}[[:space:]]*.*/, "")
        gsub(/^[[:space:],]+|[[:space:],]+$/, "")
        if (length($0)) {
          n=split($0, a, /,[[:space:]]*/)
          for(i=1;i<=n;i++) if(length(a[i])) print a[i]
        }
        inside=0
      } else {
        gsub(/^[[:space:],]+|[[:space:],]+$/, "")
        if (length($0)) print $0
      }
      next
    }
    inside==1{
      if ($0 ~ /\}/) {
        sub(/\}[[:space:]]*.*/, "")
        gsub(/^[[:space:],]+|[[:space:],]+$/, "")
        if (length($0)) print $0
        inside=0
        next
      }
      gsub(/^[[:space:],]+|[[:space:],]+$/, "")
      if (length($0)) print $0
    }
  '
}

get_counter_by_comment(){
  local tag="${1:-}"
  local line pk
  line="$(nft -a list chain inet filter input 2>/dev/null | grep -F "comment \"${tag}\"" | head -n 1 || true)"
  pk="$(awk '{for(i=1;i<=NF;i++){if($i=="packets"){print $(i+1); exit}}}' <<<"$line")"
  [[ -n "${pk:-}" ]] && echo "$pk" || echo 0
}

show_block_stats(){
  echo
  echo "============ 拦截统计 (nftables) ============"
  if ! command -v nft >/dev/null 2>&1; then
    echo " 未检测到 nft 命令。"
    return 1
  fi

  local v4_lines v6_lines
  v4_lines="$(nft_dump_set_elements inet filter blacklist_v4 || true)"
  v6_lines="$(nft_dump_set_elements inet filter blacklist_v6 || true)"
  v4_lines="$(printf '%s\n' "$v4_lines" | grep -Ev '^(0\.0\.0\.0|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|169\.254\.|22[4-9]\.|23[0-9]\.|24[0-9]\.|25[0-5]\.|2[4-5][0-9]\.|2[6-9][0-9]\.|27[0-9]\.|28[0-9]\.|29[0-9]\.|3[0-9][0-9]\.|4[0-9][0-9]\.|5[0-9][0-9]\.|6[0-9][0-9]\.|7[0-9][0-9]\.|8[0-9][0-9]\.|9[0-9][0-9])' || true)"
  v6_lines="$(printf '%s\n' "$v6_lines" | grep -Eiv '^(::1$|fe80:|fc|fd|::ffff:|64:ff9b:|100:|2001:db8:|2002:)' || true)"
  echo
  echo "---------  IPv4 黑名单（含剩余时间） --------"
  if [[ -n "${v4_lines//[[:space:]]/}" ]]; then
    printf "%-18s %-10s %-20s\n" "IP" "TIMEOUT" "EXPIRES"
    printf '%s\n' "$v4_lines" | sed '/^$/d' | awk '
      { ip=$1; to=""; ex="";
        for(i=2;i<=NF;i++){
          if($i=="timeout" && (i+1)<=NF) to=$(i+1);
          if($i=="expires" && (i+1)<=NF) ex=$(i+1);
        }
        printf "%-18s %-10s %-20s\n", ip, to, ex;
      }'
  fi
  echo
  echo "---------  IPv6 黑名单（含剩余时间） --------"
  if [[ -n "${v6_lines//[[:space:]]/}" ]]; then
    printf "%-40s %-10s %-20s\n" "IP" "TIMEOUT" "EXPIRES"
    printf '%s\n' "$v6_lines" | sed '/^$/d' | awk '
      { ip=$1; to=""; ex="";
        for(i=2;i<=NF;i++){
          if($i=="timeout" && (i+1)<=NF) to=$(i+1);
          if($i=="expires" && (i+1)<=NF) ex=$(i+1);
        }
        printf "%-40s %-10s %-20s\n", ip, to, ex;
      }'
  fi
  echo
  echo "------------- Top 10 被拦截 IP --------------"
  if [[ -n "${v4_lines//[[:space:]]/}" ]]; then
    printf '%s
' "$v4_lines" | sed '/^$/d' | awk '{print $1}' | head -n 10 | nl -w2 -s'. '
  fi
  if [[ -n "${v6_lines//[[:space:]]/}" ]]; then
    printf '%s
' "$v6_lines" | sed '/^$/d' | awk '{print $1}' | head -n 10 | nl -w2 -s'. '
  fi
  echo
  echo "------------------ 触发统计 ------------------"
  local v4_count v6_count
  v4_count="$(printf '%s
  ' "$v4_lines" | sed '/^$/d' | wc -l | tr -d ' ')"
  v6_count="$(printf '%s
  ' "$v6_lines" | sed '/^$/d' | wc -l | tr -d ' ')"
  echo "当前黑名单数量：IPv4=${v4_count:-0}  IPv6=${v6_count:-0}"
  local drop4 drop6 syn4 syn6 udp4 udp6 icmp4 icmp6
  drop4="$(get_counter_by_comment BL_DROP_V4)"
  drop6="$(get_counter_by_comment BL_DROP_V6)"
  syn4="$(get_counter_by_comment BL_SYN_V4)"
  syn6="$(get_counter_by_comment BL_SYN_V6)"
  udp4="$(get_counter_by_comment BL_UDP_V4)"
  udp6="$(get_counter_by_comment BL_UDP_V6)"
  icmp4="$(get_counter_by_comment BL_ICMP_V4)"
  icmp6="$(get_counter_by_comment BL_ICMP_V6)"
  printf "%-10s IPv4=%-6d IPv6=%-6d 合计=%-6d\n" "拦截次数:" "$drop4" "$drop6" "$((drop4+drop6))"
  echo
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
  echo "4) 安全状态"
  echo "0) 退出"
  echo "------------------------------"
}

main(){
  while true; do
    show_menu
    read -r -e -p "请选择 [0-4]：" choice || true
    choice="$(trim "${choice:-}")"
    case "$choice" in
      1) install_fw; pause ;;
      2) ports_manage_menu ;;
      3) uninstall_fw; pause ;;
      4) show_block_stats; pause ;;
      0) echo "退出。"; exit 0 ;;
      *) echo " 请输入 0/1/2/3/4"; pause ;;
    esac
  done
}

main
