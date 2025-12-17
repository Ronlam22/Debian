#!/usr/bin/env bash

set -euo pipefail

clear_screen() {
    if command -v tput >/dev/null 2>&1; then
        tput clear
    else
        printf "\033c"
    fi
}

read_line() {
    local prompt="$1"
    local default="$2"
    local char
    local buf=""

    printf "%s" "$prompt"

    while IFS= read -r -s -n1 char; do
        if [[ -z "$char" || "$char" == $'\n' || "$char" == $'\r' ]]; then
            printf "\n"
            break
        fi

        if [[ "$char" == $'\177' || "$char" == $'\010' ]]; then
            if [[ -n "$buf" ]]; then
                buf=${buf%?}
                printf '\b \b'
            fi
        else
            buf+="$char"
            printf "%s" "$char"
        fi
    done

    if [[ -z "$buf" && -n "$default" ]]; then
        REPLY="$default"
    else
        REPLY="$buf"
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请用 root 运行此脚本（sudo $0）" >&2
        exit 1
    fi
}

install_base_limits() {
    # 1) /etc/security/limits.d
    mkdir -p /etc/security/limits.d

    cat >/etc/security/limits.d/99-limits.conf <<EOF
* soft     nproc    1048576
* hard     nproc    1048576
* soft     nofile   1048576
* hard     nofile   1048576

root soft  nproc    1048576
root hard  nproc    1048576
root soft  nofile   1048576
root hard  nofile   1048576
EOF

    # 2) 确保 pam_limits 启用（有就不加，没有才追加）
    for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [ -f "$f" ] && \
           ! grep -qE '^[[:space:]]*session[[:space:]]+required[[:space:]]+pam_limits\.so' "$f" 2>/dev/null; then
            echo "session required pam_limits.so" >> "$f"
        fi
    done

    # 3) systemd 默认 limits
    mkdir -p /etc/systemd/system.conf.d

    cat >/etc/systemd/system.conf.d/99-system.conf <<EOF
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reexec
    fi
}

install_vps_limits() {
    # 1) /etc/security/limits.d
    mkdir -p /etc/security/limits.d

    cat >/etc/security/limits.d/99-limits.conf <<EOF
* soft     nproc    524288
* hard     nproc    524288
* soft     nofile   524288
* hard     nofile   524288

root soft  nproc    524288
root hard  nproc    524288
root soft  nofile   524288
root hard  nofile   524288
EOF

    # 2) pam_limits 启用
    for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [ -f "$f" ] && \
           ! grep -qE '^[[:space:]]*session[[:space:]]+required[[:space:]]+pam_limits\.so' "$f" 2>/dev/null; then
            echo "session required pam_limits.so" >> "$f"
        fi
    done

    # 3) systemd 默认 limits
    mkdir -p /etc/systemd/system.conf.d

    cat >/etc/systemd/system.conf.d/99-system.conf <<EOF
[Manager]
DefaultLimitNOFILE=524288
DefaultLimitNPROC=524288
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reexec
    fi
}

ensure_ethtool() {
    if command -v ethtool >/dev/null 2>&1; then
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    if ! apt-get install -y ethtool >/dev/null 2>&1; then
        echo "ERROR: ethtool 安装失败，请检查 apt 源。" >&2
        exit 1
    fi
    echo "ethtool 已安装。"
}

detect_ifaces() {
    ls /sys/class/net \
        | grep -vE '^(lo|docker.*|virbr.*|veth.*|tap.*|tun.*)$'
}

install_nic_tuning_service() {
    local OFFLOAD_OPTS="$1"
    local SERVICE_FILE="/etc/systemd/system/nic-tuning.service"

    ensure_ethtool

    local ifaces
    mapfile -t ifaces < <(detect_ifaces)

    if [ "${#ifaces[@]}" -eq 0 ]; then
        echo "没有检测到需要优化的网卡，跳过网卡优化。"
        return 0
    fi

    local ethtool_bin
    ethtool_bin="$(command -v ethtool)"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=NIC Offload Tuning (ethtool)
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
EOF

    for iface in "${ifaces[@]}"; do
        echo "ExecStart=$ethtool_bin -K $iface $OFFLOAD_OPTS" >> "$SERVICE_FILE"
    done

    cat >> "$SERVICE_FILE" <<EOF

RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable --now nic-tuning.service >/dev/null 2>&1 || true

    echo "执行网卡优化..."
    systemctl restart nic-tuning.service >/dev/null 2>&1 || true

    echo "网卡调优完成（$OFFLOAD_OPTS）。"
}

ask_reboot() {
    echo
    read_line "当前优化已完成，是否立即重启使内核参数完全生效？[y/N]: " ""
    ans="$REPLY"
    case "${ans:-}" in
        y|Y)
            echo "即将重启..."
            sleep 1
            reboot
            ;;
        *)
            echo "已跳过自动重启，你可以稍后手动 reboot。"
            ;;
    esac
}

# ------------------------------------------------------------
# Mosdns_sysctl（本地 MOSDNS VM 用）  
# ------------------------------------------------------------

install_mosdns_sysctl() {
    local CONF_DIR="/etc/sysctl.d"
    local CONF_FILE="${CONF_DIR}/99-sysctl.conf"

    echo "[MOSDNS] 写入 ${CONF_FILE} ..."
    install -d "${CONF_DIR}"
    cat > "${CONF_FILE}" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
kernel.panic = 5
kernel.sysrq = 1
kernel.printk = 3 4 1 3
kernel.sched_autogroup_enabled = 0
kernel.timer_migration = 0
kernel.watchdog = 1
kernel.hardlockup_panic = 0
kernel.task_delayacct = 0
kernel.split_lock_mitigate = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_low_latency = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rmem = 4096 65536 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
net.core.optmem_max = 131072
net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 2
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.udp_early_demux = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_orphans = 16384
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_limit_output_bytes = 3145728
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.core.netdev_max_backlog = 8192
net.core.netdev_budget_usecs = 8000
net.core.netdev_budget = 600
net.core.dev_weight = 64
net.core.dev_weight_rx_bias = 1
net.core.dev_weight_tx_bias = 1
net.core.somaxconn = 16384
net.ipv4.route.gc_timeout = 300
vm.dirty_background_ratio = 3
vm.dirty_ratio = 20
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 200
vm.swappiness = 0
vm.page-cluster = 0
vm.compaction_proactiveness = 0
vm.vfs_cache_pressure = 50
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 100
vm.min_free_kbytes = 16384
EOF

    sed -i 's/\r$//' "${CONF_FILE}"

    echo "[MOSDNS] 加载内核模块 tcp_bbr / sch_fq ..."
    modprobe tcp_bbr || true
    modprobe sch_fq || true
    echo -e "tcp_bbr\nsch_fq" > /etc/modules-load.d/bbr-fq.conf

    echo "[MOSDNS] 备份并删除 /etc/sysctl.conf..."
    if [[ -f /etc/sysctl.conf ]]; then
        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak-${ts}"
        rm -f /etc/sysctl.conf
        echo "  已备份到 /etc/sysctl.conf.bak-${ts} 并删除原文件。"
    fi

    echo "[MOSDNS] 应用 sysctl ..."
    sysctl --system

    echo "[MOSDNS] 当前拥塞算法："
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc || true
    lsmod | grep -E 'tcp_bbr|sch_fq' || true
}

# ------------------------------------------------------------
# Singbox_sysctl（本地 Sing-box VM 用）
# ------------------------------------------------------------

install_singbox_sysctl() {
    local CONF_DIR="/etc/sysctl.d"
    local CONF_FILE="${CONF_DIR}/99-sysctl.conf"

    echo "[SINGBOX] 写入 ${CONF_FILE} ..."
    install -d "${CONF_DIR}"
    cat > "${CONF_FILE}" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 1000000
fs.nr_open = 2000000
fs.inotify.max_user_instances = 4096
fs.inotify.max_user_watches = 524288
fs.aio-max-nr = 1048576
kernel.core_uses_pid = 1
kernel.pid_max = 65535
kernel.panic = 5
kernel.sysrq = 1
kernel.printk = 3 4 1 3
kernel.sched_autogroup_enabled = 0
kernel.timer_migration = 0
kernel.watchdog = 1
kernel.hardlockup_panic = 0
kernel.task_delayacct = 0
kernel.split_lock_mitigate = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_low_latency = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
net.core.optmem_max = 524288
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 2
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.udp_early_demux = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_limit_output_bytes = 3145728
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 32768
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.core.netdev_max_backlog = 32768
net.core.netdev_budget_usecs = 8000
net.core.netdev_budget = 800
net.core.dev_weight = 96
net.core.dev_weight_rx_bias = 1
net.core.dev_weight_tx_bias = 1
net.core.somaxconn = 65535
net.ipv4.route.gc_timeout = 300
net.core.rps_sock_flow_entries = 32768
vm.dirty_background_ratio = 3
vm.dirty_ratio = 20
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 200
vm.swappiness = 0
vm.page-cluster = 0
vm.compaction_proactiveness = 0
vm.vfs_cache_pressure = 50
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 200
vm.min_free_kbytes = 32768
EOF

    sed -i 's/\r$//' "${CONF_FILE}"

    echo "[SINGBOX] 加载内核模块 tcp_bbr / sch_fq ..."
    modprobe tcp_bbr || true
    modprobe sch_fq || true
    echo -e "tcp_bbr\nsch_fq" > /etc/modules-load.d/bbr-fq.conf

    echo "[SINGBOX] 备份并删除 /etc/sysctl.conf..."
    if [[ -f /etc/sysctl.conf ]]; then
        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak-${ts}"
        rm -f /etc/sysctl.conf
        echo "  已备份到 /etc/sysctl.conf.bak-${ts} 并删除原文件。"
    fi

    echo "[SINGBOX] 应用 sysctl ..."
    sysctl --system

    echo "[SINGBOX] 当前拥塞算法："
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc || true
    lsmod | grep -E 'tcp_bbr|sch_fq' || true
}

# ------------------------------------------------------------
# VPS_sysctl（远端 VPS VM 用）
# ------------------------------------------------------------

# 默认最大窗口
TCP_WIN_MAX_DEFAULT=16777216
TCP_WIN_MAX="${TCP_WIN_MAX_DEFAULT}"

calc_tcp_window() {
  echo "=================================================="
  echo " TCP 窗口大小计算器（基于带宽 × RTT 的 BDP）"
  echo "=================================================="
  echo "说明："
  echo "  - 带宽：Mbps（整数），RTT：ms（整数）"
  echo "  - BDP(bytes) = 带宽(Mbps) × 125 × RTT(ms)"
  echo "  - 建议窗口 ≈ 1.5 × BDP，限制在 [4MB, 64MB]"
  echo

  read_line "请输入 VPS 带宽 (Mbps，例如 100 或 1000)： " ""
  bw_mbps="$REPLY"
  read_line "请输入估算 RTT (ms，例如 20 或 80)： " ""
  rtt_ms="$REPLY"

  if ! [[ "${bw_mbps:-}" =~ ^[0-9]+$ ]] || ! [[ "${rtt_ms:-}" =~ ^[0-9]+$ ]]; then
    echo "输入不是整数，跳过计算，继续使用默认值 ${TCP_WIN_MAX_DEFAULT} 字节。"
    TCP_WIN_MAX="${TCP_WIN_MAX_DEFAULT}"
    return
  fi

  if [[ "${bw_mbps}" -le 0 || "${rtt_ms}" -le 0 ]]; then
    echo "带宽与 RTT 必须大于 0，跳过计算，继续使用默认值 ${TCP_WIN_MAX_DEFAULT} 字节。"
    TCP_WIN_MAX="${TCP_WIN_MAX_DEFAULT}"
    return
  fi

  local bdp_bytes=$(( bw_mbps * 125 * rtt_ms ))
  local win_bytes=$(( bdp_bytes * 3 / 2 ))

  local min_win=4194304      # 4MB
  local max_win=67108864     # 64MB

  if (( win_bytes < min_win )); then
    win_bytes=${min_win}
  elif (( win_bytes > max_win )); then
    win_bytes=${max_win}
  fi

  local bdp_kb=$(( (bdp_bytes + 1023) / 1024 ))
  local win_kb=$(( (win_bytes + 1023) / 1024 ))

  echo
  echo "=== 计算结果 ==="
  echo "  带宽：${bw_mbps} Mbps"
  echo "  RTT ：${rtt_ms} ms"
  echo "  BDP  ≈ ${bdp_bytes} bytes（约 ${bdp_kb} KB）"
  echo "  建议 TCP 窗口上限（max）：${win_bytes} bytes（约 ${win_kb} KB）"
  echo
  echo "示例："
  echo "  net.ipv4.tcp_rmem = 4096 262144 ${win_bytes}"
  echo "  net.ipv4.tcp_wmem = 4096 262144 ${win_bytes}"
  echo

  read_line "是否使用上述 ${win_bytes} 作为本次脚本写入的 tcp_rmem/tcp_wmem 上限？[y/N]: " ""
  use_it="$REPLY"

  case "${use_it:-}" in
    y|Y)
      TCP_WIN_MAX="${win_bytes}"
      echo "已选择使用 ${TCP_WIN_MAX} 作为 tcp_rmem/tcp_wmem 的 max。"
      ;;
    *)
      TCP_WIN_MAX="${TCP_WIN_MAX_DEFAULT}"
      echo "继续使用默认 max = ${TCP_WIN_MAX}。"
      ;;
  esac

  echo "=================================================="
  echo
}

install_vps_sysctl() {
    local CONF_DIR="/etc/sysctl.d"
    local CONF_FILE="${CONF_DIR}/99-sysctl.conf"

    calc_tcp_window

    echo "[VPS] 写入 ${CONF_FILE} ..."
    install -d "${CONF_DIR}"
    cat > "${CONF_FILE}" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 1000000
fs.nr_open = 2000000
fs.inotify.max_user_instances = 4096
fs.inotify.max_user_watches = 524288
fs.aio-max-nr = 1048576
kernel.core_uses_pid = 1
kernel.pid_max = 65535
kernel.panic = 5
kernel.sysrq = 1
kernel.printk = 3 4 1 3
kernel.sched_autogroup_enabled = 0
kernel.timer_migration = 0
kernel.watchdog = 1
kernel.hardlockup_panic = 0
kernel.task_delayacct = 0
kernel.split_lock_mitigate = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_low_latency = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rmem = 4096 262144 ${TCP_WIN_MAX}
net.ipv4.tcp_wmem = 4096 262144 ${TCP_WIN_MAX}
net.core.optmem_max = 524288
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = ${TCP_WIN_MAX}
net.core.wmem_max = ${TCP_WIN_MAX}
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 2
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.udp_early_demux = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_limit_output_bytes = 3145728
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 32768
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.core.netdev_max_backlog = 32768
net.core.netdev_budget_usecs = 8000
net.core.netdev_budget = 800
net.core.dev_weight = 96
net.core.dev_weight_rx_bias = 1
net.core.dev_weight_tx_bias = 1
net.core.somaxconn = 65535
net.ipv4.route.gc_timeout = 300
net.core.rps_sock_flow_entries = 32768
vm.dirty_background_ratio = 3
vm.dirty_ratio = 20
vm.dirty_expire_centisecs = 1500
vm.dirty_writeback_centisecs = 200
vm.swappiness = 0
vm.page-cluster = 0
vm.compaction_proactiveness = 0
vm.vfs_cache_pressure = 50
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 200
vm.min_free_kbytes = 16384
EOF

    sed -i 's/\r$//' "${CONF_FILE}"

    echo "[VPS] 加载内核模块 tcp_bbr / sch_fq ..."
    modprobe tcp_bbr || true
    modprobe sch_fq || true
    echo -e "tcp_bbr\nsch_fq" > /etc/modules-load.d/bbr-fq.conf

    echo "[VPS] 备份并删除 /etc/sysctl.conf..."
    if [[ -f /etc/sysctl.conf ]]; then
        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak-${ts}"
        rm -f /etc/sysctl.conf
        echo "  已备份到 /etc/sysctl.conf.bak-${ts} 并删除原文件。"
    fi

    echo "[VPS] 应用 sysctl ..."
    sysctl --system

    echo "[VPS] 当前拥塞算法："
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc || true
    lsmod | grep -E 'tcp_bbr|sch_fq' || true
}

# ------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------

main_menu() {
    while true; do
        clear_screen
        echo "==========================="
        echo "  网络优化菜单脚本"
        echo "==========================="
        echo " 1) 本地 MOSDNS 虚拟机优化"
        echo " 2) 本地 SINGBOX 虚拟机优化"
        echo " 3) VPS 虚拟机优化"
        echo " 0) 退出"
        echo

        read_line "请选择 [0-3]: " ""
        choice="$REPLY"
        case "${choice:-}" in
            1)
                clear_screen
                echo "[操作] 本地 MOSDNS 虚拟机优化 ..."
                install_base_limits
                install_mosdns_sysctl
                # MOSDNS VM:
                install_nic_tuning_service "tso off gso off gro off rx-gro-hw off lro off"
                ask_reboot
                break
                ;;
            2)
                clear_screen
                echo "[操作] 本地 SINGBOX 虚拟机优化 ..."
                install_base_limits
                install_singbox_sysctl
                # Sing-box VM:
                install_nic_tuning_service "tso on gso on gro on rx-gro-hw off lro off"
                ask_reboot
                break
                ;;
            3)
                clear_screen
                echo "[操作] VPS 虚拟机优化 ..."
                install_vps_limits
                install_vps_sysctl
                # VPS VM:
                install_nic_tuning_service "tso on gso on gro on rx-gro-hw off lro off"
                ask_reboot
                break
                ;;
            0)
                echo "已退出。"
                break
                ;;
            *)
                echo "无效选择：${choice} ，请按 0-3 重新输入。"
                sleep 1
                ;;
        esac
    done
}

require_root
main_menu
