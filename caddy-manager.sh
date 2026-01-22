#!/usr/bin/env bash
set -euo pipefail

clear_screen(){ command -v tput >/dev/null 2>&1 && tput clear || printf "\033c"; }
pause(){ echo; read -r -e -p "按回车继续..." _ || true; }
trim(){ awk '{$1=$1};1' <<<"${1:-}"; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo " 请用 root 执行：sudo bash $0"; exit 1; fi
if [[ -t 0 ]]; then stty sane 2>/dev/null || true; stty erase '^?' 2>/dev/null || stty erase '^H' 2>/dev/null || true; fi

KEYRING_PATH="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
LIST_PATH="/etc/apt/sources.list.d/caddy-stable.list"
GPG_URL="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
REPO_URL="https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"

install_caddy(){
  echo "安装 Caddy"
  apt-get update
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -fsSL --proto '=https' --tlsv1.2 "$GPG_URL" | gpg --dearmor -o "$KEYRING_PATH"
  chmod o+r "$KEYRING_PATH"
  curl -fsSL --proto '=https' --tlsv1.2 "$REPO_URL" | tee "$LIST_PATH" >/dev/null
  chmod o+r "$LIST_PATH"
  apt-get update
  apt-get install -y caddy
  systemctl enable --now caddy
  echo "完成：Caddy 已安装"
  caddy version || true
}

uninstall_caddy(){
  echo "卸载 Caddy"
  systemctl stop caddy 2>/dev/null || true
  systemctl disable caddy 2>/dev/null || true
  apt-get purge -y caddy 2>/dev/null || true
  apt-get autoremove -y --purge || true
  rm -rf /etc/systemd/system/caddy.service.d
  rm -f  /etc/systemd/system/caddy.service /lib/systemd/system/caddy.service /usr/lib/systemd/system/caddy.service
  rm -rf /etc/caddy /var/lib/caddy /var/log/caddy /var/cache/caddy
  rm -f  /etc/default/caddy /etc/logrotate.d/caddy
  rm -f  /usr/local/bin/caddy /usr/local/bin/xcaddy /usr/bin/caddy
  systemctl daemon-reload
  id caddy &>/dev/null && userdel -r caddy || true
  getent group caddy &>/dev/null && groupdel caddy || true
  rm -f "$LIST_PATH" "$KEYRING_PATH"
  apt-get update
  FAILED=0
  command -v caddy &>/dev/null && FAILED=1
  dpkg -l | grep -qi '^ii\s\+caddy' && FAILED=1
  systemctl list-unit-files | grep -q '^caddy\.service' && FAILED=1
  [[ -e "$LIST_PATH" || -e "$KEYRING_PATH" ]] && FAILED=1
  echo
  [[ "$FAILED" -eq 0 ]] && echo "完成：Caddy 已彻底卸载" || echo "警告：存在残留"
}

show_menu(){
  clear_screen
  echo
  echo "=============================="
  echo "        Caddy 管理菜单        "
  echo "=============================="
  echo "1) 安装 Caddy"
  echo "2) 卸载 Caddy"
  echo "0) 退出"
  echo "------------------------------"
}

main(){
  while true; do
    show_menu
    read -r -e -p "请选择 [0-2]：" choice || true
    choice="$(trim "${choice:-}")"
    case "$choice" in
      1) install_caddy; pause ;;
      2) uninstall_caddy; pause ;;
      0) echo "退出。"; exit 0 ;;
      *) echo " 请输入 0/1/2"; pause ;;
    esac
  done
}

main
