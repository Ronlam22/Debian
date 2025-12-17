#!/usr/bin/env bash
set -euo pipefail

KEEP_KERNELS=1
SCRIPT_PATH="${SCRIPT_PATH:-/root/auto-update.sh}"
TAG="# auto-apt-postreboot"
log(){ echo "$*"; }

clean_kernels(){
  log "开始清理旧内核（保留至少 ${KEEP_KERNELS} 个）"
  local running latest; running="$(uname -r)"
  mapfile -t images < <(dpkg-query -W -f='${Package}\t${Status}\n' 'linux-image-*' | awk '$2=="install" && $3=="ok" && $4=="installed"{print $1}' | grep -E '^linux-image-[0-9]')
  if [ "${#images[@]}" -le 1 ]; then log "仅检测到一个内核，跳过清理"; return 0; fi
  mapfile -t versions < <(printf '%s\n' "${images[@]}" | sed -E 's/^linux-image-//' | sort -V); latest="${versions[-1]}"
  declare -A keep=([$running]=1 [$latest]=1)
  to_purge=(); for v in "${versions[@]}"; do [[ -n "${keep[$v]:-}" ]] || to_purge+=("$v"); done
  if [ "${#versions[@]}" -le "$KEEP_KERNELS" ]; then log "内核总数 (${#versions[@]}) <= ${KEEP_KERNELS}，不清理"; return 0; fi
  if [ "${#to_purge[@]}" -eq 0 ]; then log "没有可清理的旧内核"; return 0; fi
  log "准备清理旧内核版本：${to_purge[*]}"
  pkgs=()
  for v in "${to_purge[@]}"; do for p in linux-image-$v linux-headers-$v linux-modules-$v; do dpkg -l | awk '$1=="ii"{print $2}' | grep -qx "$p" && pkgs+=("$p"); done; done
  [ "${#pkgs[@]}" -gt 0 ] && apt-get purge -y "${pkgs[@]}" || log "未匹配到内核包"
  apt-get autoremove -y --purge || true; apt-get clean || true; command -v update-grub >/dev/null 2>&1 && update-grub || true
}

if [[ "${1:-}" == "--postreboot" ]]; then log "重启后进入清理阶段"; clean_kernels; (crontab -l 2>/dev/null | grep -v "$TAG" || true) | crontab - || true; log "清理完成（已移除临时 @reboot 条目）✅"; exit 0; fi

log "开始 apt update / full-upgrade"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confnew" full-upgrade -yq
sync && sleep 2
dpkg --configure -a || true

running="$(uname -r)"
latest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n1 || true)"
if [ -z "$latest" ]; then latest="$(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '$1=="ii"{print $2}' | sed -E 's/^linux-image-//' | sort -V | tail -n1 || true)"; fi

if [ -n "${latest:-}" ] && [ "$latest" != "$running" ]; then log "检测到新内核：$latest（当前运行：$running）"; (crontab -l 2>/dev/null || true; echo "@reboot /bin/bash -lc '$SCRIPT_PATH --postreboot' $TAG") | crontab -; log "准备重启........"; sleep 3; systemctl reboot || reboot; exit 0; fi

log "未检测到新内核，执行安全清理"
clean_kernels
log "自动更新任务完成"
