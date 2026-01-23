#!/usr/bin/env bash
set -euo pipefail

SERVER_SERVICE="komari"
AGENT_SERVICE="komari-agent"

PURGE_DIRS=(
  "/opt/komari"
  "/etc/komari"
  "/var/lib/komari"
  "/var/log/komari"
  "/var/cache/komari"
  "/run/komari"
  "/usr/local/komari"
)

clear_screen(){ command -v tput >/dev/null 2>&1 && tput clear || printf "\033c"; }
trim(){ awk '{$1=$1};1' <<<"${1:-}"; }

echo "==============================================="
echo "        Komari 卸载（Server + Agent）"
echo " 删除：服务 / 进程 / 二进制 / 配置 / 数据 / 日志"
echo "==============================================="
echo

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo "[错误] 请使用 root 运行：sudo bash $0"; exit 1; fi

echo
echo "[0/10] 系统信息快照"
date || true
uname -a || true
echo

stop_disable_units_by_prefix(){
  command -v systemctl >/dev/null 2>&1 || return 0
  local units=""
  units="$(systemctl list-units --type=service --all 2>/dev/null \
    | awk '{print $1}' \
    | grep -Ei '^komari.*\.service$' || true)"

  [[ -z "${units//[[:space:]]/}" ]] && { echo "  - 未发现 komari*.service"; return 0; }

  while read -r s; do
    [[ -z "${s:-}" ]] && continue
    echo "  - 停止并禁用：$s"
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
  done <<<"$units"
}

remove_unit_files(){
  rm -f  /etc/systemd/system/komari*.service 2>/dev/null || true
  rm -rf /etc/systemd/system/komari*.service.d 2>/dev/null || true
  rm -f  /lib/systemd/system/komari*.service 2>/dev/null || true
  rm -f  /usr/lib/systemd/system/komari*.service 2>/dev/null || true
  rm -f  /etc/default/komari* /etc/sysconfig/komari* 2>/dev/null || true
}

kill_komari_processes_safe(){
  echo "  - 扫描并结束 komari 相关进程"
  local me="$$"
  local pids=""
  pids="$(pgrep -af 'komari' 2>/dev/null | awk -v ME="$me" '$1!=ME {print $1}' | tr '\n' ' ' || true)"
  pids="$(trim "${pids:-}")"
  if [[ -n "${pids// /}" ]]; then
    echo "    将终止 PID：$pids"
    kill $pids 2>/dev/null || true
    sleep 0.5
    kill -9 $pids 2>/dev/null || true
  else
    echo "未发现 komari 相关进程"
  fi
}

remove_binaries(){
  rm -f /usr/local/bin/komari* 2>/dev/null || true
  rm -f /usr/bin/komari* 2>/dev/null || true
  rm -f /bin/komari* 2>/dev/null || true
  rm -f /sbin/komari* 2>/dev/null || true
  rm -f /usr/sbin/komari* 2>/dev/null || true
}

remove_misc(){
  rm -f /etc/profile.d/komari* 2>/dev/null || true
  rm -f /etc/cron.d/komari* 2>/dev/null || true
  rm -f /etc/cron.daily/komari* 2>/dev/null || true
  rm -f /etc/logrotate.d/komari* 2>/dev/null || true
  rm -rf /tmp/komari* 2>/dev/null || true
}

docker_podman_cleanup(){
  if command -v docker >/dev/null 2>&1; then
    echo "  - 清理 Docker（容器/镜像/卷）"
    docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' | grep -i komari | awk '{print $1}' | while read -r id; do docker rm -f "$id" 2>/dev/null || true; done
    docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -i komari | awk '{print $2}' | while read -r id; do docker rmi -f "$id" 2>/dev/null || true; done
    docker volume ls --format '{{.Name}}' | grep -i komari | while read -r v; do docker volume rm -f "$v" 2>/dev/null || true; done
  fi
  if command -v podman >/dev/null 2>&1; then
    echo "  - 清理 Podman（容器）"
    podman ps -a --format '{{.ID}} {{.Names}} {{.Image}}' | grep -i komari | awk '{print $1}' | while read -r id; do podman rm -f "$id" 2>/dev/null || true; done
  fi
}

remove_user_group(){
  id komari >/dev/null 2>&1 && userdel -r komari 2>/dev/null || true
  getent group komari >/dev/null 2>&1 && groupdel komari 2>/dev/null || true
}

echo "[1/10] 停止并禁用 systemd 中的 Komari 服务（komari*.service）"
stop_disable_units_by_prefix

echo "[2/10] 删除 systemd 服务文件与环境配置"
remove_unit_files
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

echo "[3/10] 删除 OpenRC / upstart / rc 残留（兼容项）"
rm -f /etc/init.d/komari* 2>/dev/null || true
rm -f /etc/init/komari*.conf 2>/dev/null || true
rm -f /etc/rc*.d/*komari* 2>/dev/null || true

echo "[4/10] 强制终止 Komari 相关进程"
kill_komari_processes_safe

echo "[5/10] 删除 Komari 可执行文件（更宽范围）"
remove_binaries

echo "[6/10] 删除 Komari 相关目录（程序/配置/数据/日志/缓存/运行时）"
for d in "${PURGE_DIRS[@]}"; do
  if [[ -e "$d" ]]; then echo "  - 删除：$d"; rm -rf "$d" 2>/dev/null || true; fi
done
rm -rf /tmp/komari* 2>/dev/null || true

echo "[7/10] 删除 profile / cron / logrotate 等残留"
remove_misc

echo "[8/10] 清理 Docker / Podman 资源（如存在）"
docker_podman_cleanup

echo "[9/10] 删除 komari 用户与用户组（如存在）"
remove_user_group

echo "[10/10] 卸载验收（Caddy 风格：FAILED=0/1）"
FAILED=0

echo
echo "- 检查 komari 相关进程（排除当前脚本 PID=$$）"
if ps -eo pid,args | grep -i komari | grep -v grep | awk -v ME="$$" '$1!=ME' | grep -q .; then
  echo "仍存在 komari 进程："
  ps -eo pid,args | grep -i komari | grep -v grep | awk -v ME="$$" '$1!=ME' || true
  FAILED=1
else
  echo "未发现 komari 进程"
fi

echo "- 检查 systemd unit-files"
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -qi '^komari'; then
  echo "仍存在 komari unit-files："
  systemctl list-unit-files 2>/dev/null | grep -i komari || true
  FAILED=1
else
  echo "systemd 中无 komari unit-files"
fi

echo "- 检查监听端口（关键字 komari）"
if ss -lntup 2>/dev/null | grep -qi komari; then
  echo "仍有端口监听命中 komari："
  ss -lntup 2>/dev/null | grep -i komari || true
  FAILED=1
else
  echo "未发现 komari 端口监听"
fi

echo "- 检查关键目录是否残留"
for d in /opt/komari /etc/komari /var/lib/komari /var/log/komari /var/cache/komari /run/komari; do
  if [[ -e "$d" ]]; then echo "仍存在：$d"; FAILED=1; else echo "已清理：$d"; fi
done

echo "- 检查二进制是否残留（PATH）"
if command -v komari >/dev/null 2>&1; then
  echo "仍存在：$(command -v komari)"
  FAILED=1
else
  echo "komari 命令不存在"
fi

echo "- 快速扫描残留（/etc /var /opt /usr/local）"
FOUND="$(find /etc /var /opt /usr/local -maxdepth 6 -iname '*komari*' 2>/dev/null || true)"
if [[ -n "${FOUND:-}" ]]; then
  echo "仍发现 komari 相关文件："
  echo "$FOUND"
  FAILED=1
else
  echo "未发现 komari 文件残留"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "完成：Komari 已彻底卸载"
  exit 0
else
  echo "警告：检测到残留，请按上方输出逐项处理"
  exit 1
fi
