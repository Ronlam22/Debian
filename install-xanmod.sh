#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info(){ echo -e "${GREEN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){  echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    warn "需要 root 权限，自动用 sudo 重新执行……"
    exec sudo -E bash "$0" "$@"
  else
    err  "当前不是 root，且未安装 sudo。请先用 root 运行：apt update && apt install -y sudo"
    exit 1
  fi
fi

map_pkg() {
  case "$1" in
    gpg)          echo "gnupg" ;;       
    lsb_release)  echo "lsb-release" ;; 
    sudo)         echo "sudo" ;;
    clang)        echo "clang" ;;
    lld)          echo "lld" ;;
    llvm)         echo "llvm" ;;
    *)            echo "${1//_/-}" ;;
  esac
}

need_cmds=( bash curl wget gpg gawk lsb_release sudo )

pkg_checks=( ca-certificates bash-completion build-essential dkms libdw-dev clang lld llvm )

missing_pkgs=()

for c in "${need_cmds[@]}"; do
  if ! command -v "$c" >/dev/null 2>&1; then
    missing_pkgs+=( "$(map_pkg "$c")" )
  fi
done

for p in "${pkg_checks[@]}"; do
  if ! dpkg -s "$p" >/dev/null 2>&1; then
    missing_pkgs+=( "$p" )
  fi
done

if [ ${#missing_pkgs[@]} -gt 0 ]; then
  IFS=$'\n' read -r -d '' -a missing_pkgs_unique < <(printf "%s\n" "${missing_pkgs[@]}" | awk '!seen[$0]++' && printf '\0')
  info "将安装缺失依赖：${missing_pkgs_unique[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_pkgs_unique[@]}"
else
  info "所需命令/包已齐全。"
fi

SUPPORTED=( bookworm trixie sid noble oracular plucky questing faye wilma xia )
DISTRO=$(lsb_release -sc)
if [[ ! " ${SUPPORTED[*]} " =~ " ${DISTRO} " ]]; then
  err "当前发行版 '${DISTRO}' 不在 XanMod 官方 APT 支持列表：${SUPPORTED[*]}"
  exit 1
fi
info "发行版：${DISTRO} ✓"

info "执行 psABI 检测……"
ABI_STR=$(gawk 'BEGIN {
  while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
  if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
  if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
  if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
  if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
  if (level > 0) { print "CPU supports x86-64-v" level; exit level + 1 }
  exit 1
}' || true)

if [[ -z "${ABI_STR}" ]]; then
  err "无法获取 CPU psABI 信息。"
  exit 1
fi

ABI_VER=$(grep -oP 'x86-64-v\K\d' <<<"$ABI_STR" || true)
if [[ -z "${ABI_VER}" ]]; then
  err "无法解析 psABI 等级（输出：$ABI_STR）"
  exit 1
fi
info "CPU 支持：x86-64-v${ABI_VER}"

case "$ABI_VER" in
  3|4)
    XAN_PKG="linux-xanmod-x64v3"
    ;;
  2)
    XAN_PKG="linux-xanmod-x64v2"
    ;;
  1)
    err "检测到 x86-64-v1：该 CPU 不支持 XanMod 的 x64v2/x64v3 优化内核。"
    err "建议继续使用系统默认内核，或自行编译通用（non-v2/v3）内核版本。"
    exit 1
    ;;
  *)
    err "未知或不受支持的 psABI 等级：x86-64-v${ABI_VER}"
    err "建议中止安装，或手动指定兼容的内核版本。"
    exit 1
    ;;
esac

info "将安装：${XAN_PKG}"

install -d -m 0755 /etc/apt/keyrings
KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"

info "导入 XanMod 仓库公钥到 ${KEYRING} ……"
if wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o "$KEYRING"; then
  info "GPG 密钥导入成功。"
else
  err "GPG 密钥导入失败。"
  exit 1
fi

SRC_LIST="/etc/apt/sources.list.d/xanmod-release.list"
echo "deb [signed-by=${KEYRING}] http://deb.xanmod.org ${DISTRO} main" > "$SRC_LIST" || {
  err "写入 APT 源失败：$SRC_LIST"
  exit 1
}
info "APT 源写入：$SRC_LIST ✓"

info "更新 APT 索引……"
if ! apt-get update; then
  err "apt-get update 失败，请检查网络或源配置。"
  exit 1
fi

info "安装内核包 ${XAN_PKG} ……（可能需要几分钟）"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$XAN_PKG"; then
  err "安装 ${XAN_PKG} 失败。"
  exit 1
fi

echo
echo "XanMod 内核 (${XAN_PKG}) 安装完成，请重启系统！"
echo
