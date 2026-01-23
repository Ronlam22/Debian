#!/usr/bin/env bash
set -euo pipefail

clear_screen(){ command -v tput >/dev/null 2>&1 && tput clear || printf "\033c"; }
pause(){ echo; read -r -e -p "按回车继续..." _ || true; }
trim(){ awk '{$1=$1};1' <<<"${1:-}"; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo " 请使用 root 权限运行：sudo $0"
  exit 1
fi

if [[ -t 0 ]]; then
  stty sane 2>/dev/null || true
  stty erase '^?' 2>/dev/null || stty erase '^H' 2>/dev/null || true
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info(){ echo -e "$1"; }
log_success(){ echo -e "${GREEN}$1${NC}"; }
log_error(){ echo -e "${RED}$1${NC}"; }
log_step(){ echo -e "${YELLOW}$1${NC}"; }

INSTALL_DIR="/opt/komari"
DATA_DIR="/opt/komari"
SERVICE_NAME="komari"
BINARY_PATH="$INSTALL_DIR/komari"
DEFAULT_PORT="25774"
LISTEN_PORT=""

show_banner(){
  clear_screen
  echo "=============================================================="
  echo "               Komari Monitoring System"
  echo "       https://github.com/komari-monitor/komari"
  echo "=============================================================="
  echo
}

check_systemd(){ command -v systemctl >/dev/null 2>&1; }

detect_arch(){
  case "$(uname -m)" in
    x86_64) echo "amd64" ;; 
    aarch64) echo "arm64" ;;
    i386|i686) echo "386" ;;
    riscv64) echo "riscv64" ;;
    *) log_error "不支持的架构"; exit 1 ;;
  esac
}

is_installed(){ [[ -f "$BINARY_PATH" ]]; }

install_dependencies(){
  log_step "检查并安装依赖..."
  if command -v curl >/dev/null 2>&1; then return; fi
  if command -v apt >/dev/null 2>&1; then
    apt update && apt install -y curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl
  elif command -v apk >/dev/null 2>&1; then
    apk add curl
  else
    log_error "未找到支持的包管理器"
    exit 1
  fi
}

create_systemd_service(){
  local port="$1"
  cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Komari Monitor Service
After=network.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} server -l 127.0.0.1:${port}
WorkingDirectory=${DATA_DIR}
Restart=always
User=root
Environment="TZ=Asia/Hong_Kong"

[Install]
WantedBy=multi-user.target
EOF
}

install_binary(){
  show_banner

  if is_installed; then
    log_info "Komari 已安装，如需更新请使用升级功能。"
    pause; return
  fi

  while true; do
    read -r -e -p "请输入监听端口 [默认: ${DEFAULT_PORT}]: " input || true
    input="$(trim "$input")"
    if [[ -z "$input" ]]; then LISTEN_PORT="$DEFAULT_PORT"; break; fi
    [[ "$input" =~ ^[0-9]+$ && $input -ge 1 && $input -le 65535 ]] && { LISTEN_PORT="$input"; break; }
    log_error "端口号无效 (1-65535)"
  done

  install_dependencies

  local arch file url
  arch="$(detect_arch)"
  file="komari-linux-${arch}"
  url="https://github.com/komari-monitor/komari/releases/latest/download/${file}"

  mkdir -p "$INSTALL_DIR" "$DATA_DIR"
  log_step "下载 Komari (${arch})"
  curl -L -o "$BINARY_PATH" "$url"
  chmod +x "$BINARY_PATH"

  if ! check_systemd; then
    log_success "已安装完成（无 systemd）"
    log_info "手动运行：$BINARY_PATH server -l 0.0.0.0:${LISTEN_PORT}"
    pause; return
  fi

  create_systemd_service "$LISTEN_PORT"
  systemctl daemon-reload
  systemctl enable --now ${SERVICE_NAME}.service

  if systemctl is-active --quiet ${SERVICE_NAME}.service; then
    sleep 3
    local pwd
    pwd="$(journalctl -u ${SERVICE_NAME} --since '2 minutes ago' | grep 'admin account created.' | tail -n1 | sed 's/.*created.//')"
    log_success "Komari 服务启动成功"
    echo "访问地址：http://$(hostname -I | awk '{print $1}'):${LISTEN_PORT}"
    [[ -n "$pwd" ]] && echo "初始密码：$pwd"
  else
    log_error "服务启动失败，请查看日志"
  fi
  pause
}

upgrade_komari(){
  show_banner
  is_installed || { log_error "Komari 未安装"; pause; return; }
  check_systemd || { log_error "未检测到 systemd"; pause; return; }

  systemctl stop ${SERVICE_NAME}.service
  cp "$BINARY_PATH" "$BINARY_PATH.bak.$(date +%s)"

  local arch file url
  arch="$(detect_arch)"
  file="komari-linux-${arch}"
  url="https://github.com/komari-monitor/komari/releases/latest/download/${file}"

  curl -L -o "$BINARY_PATH" "$url" || { log_error "下载失败"; pause; return; }
  chmod +x "$BINARY_PATH"
  systemctl start ${SERVICE_NAME}.service

  systemctl is-active --quiet ${SERVICE_NAME}.service \
    && log_success "升级完成" \
    || log_error "升级后服务未启动"
  pause
}

uninstall_komari(){
  show_banner
  is_installed || { log_info "Komari 未安装"; pause; return; }

  read -r -e -p "确认卸载 Komari？输入 YES 继续：" c || true
  [[ "$(trim "$c")" != "YES" ]] && { echo "已取消"; pause; return; }

  if check_systemd; then
    systemctl stop ${SERVICE_NAME}.service 2>/dev/null || true
    systemctl disable ${SERVICE_NAME}.service 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
  fi

  rm -f "$BINARY_PATH"
  rmdir "$INSTALL_DIR" 2>/dev/null || true

  log_success "Komari 已卸载（数据目录保留：$DATA_DIR）"
  pause
}

show_status(){ check_systemd && systemctl status ${SERVICE_NAME}.service --no-pager -l || echo "无 systemd"; pause; }
show_logs(){ check_systemd && journalctl -u ${SERVICE_NAME} -f --no-pager || true; }
restart_service(){ check_systemd && systemctl restart ${SERVICE_NAME}.service; pause; }
stop_service(){ check_systemd && systemctl stop ${SERVICE_NAME}.service; pause; }

show_menu(){
  clear_screen
  echo
  echo "=============================="
  echo "     Komari 管理菜单"
  echo "=============================="
  echo "1) 安装 Komari"
  echo "2) 升级 Komari"
  echo "3) 卸载 Komari"
  echo "4) 查看状态"
  echo "5) 查看日志"
  echo "6) 重启服务"
  echo "7) 停止服务"
  echo "0) 退出"
  echo "------------------------------"
}

main(){
  while true; do
    show_menu
    read -r -e -p "请选择 [0-7]: " c || true
    c="$(trim "$c")"
    case "$c" in
      1) install_binary ;; 
      2) upgrade_komari ;;
      3) uninstall_komari ;;
      4) show_status ;;
      5) show_logs ;;
      6) restart_service ;;
      7) stop_service ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "请输入 0-7"; pause ;;
    esac
  done
}

main
