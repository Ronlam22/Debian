#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${TCP_BRUTAL_REPO:-https://github.com/HyNetworks/tcp-brutal.git}"
REF="${TCP_BRUTAL_REF:-exp/xan-fix}"
PINNED_COMMIT="${TCP_BRUTAL_COMMIT:-faf8ac5bc4b94a6c142d60e7f91c3bebd492874d}"

KERNEL="$(uname -r)"
WORKDIR=""
TARGET_VERSION=""
SRC_DIR=""

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 运行此脚本。"
fi

log "Kernel: ${KERNEL}"

need_pkgs=()

command -v git  >/dev/null 2>&1 || need_pkgs+=(git)
command -v make >/dev/null 2>&1 || need_pkgs+=(make)
command -v dkms >/dev/null 2>&1 || need_pkgs+=(dkms)
command -v cc   >/dev/null 2>&1 || need_pkgs+=(build-essential)
command -v clang >/dev/null 2>&1 || need_pkgs+=(clang llvm)

if [[ ! -e "/lib/modules/${KERNEL}/build/Makefile" ]]; then
    need_pkgs+=("linux-headers-${KERNEL}")
fi

dpkg -s libc6-dev >/dev/null 2>&1 || need_pkgs+=(libc6-dev)
dpkg -s libelf-dev >/dev/null 2>&1 || need_pkgs+=(libelf-dev)

if ((${#need_pkgs[@]})); then
    command -v apt-get >/dev/null 2>&1 || die "缺少依赖且系统没有 apt-get：${need_pkgs[*]}"
    log "Installing missing packages: ${need_pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${need_pkgs[@]}"
fi

[[ -e "/lib/modules/${KERNEL}/build/Makefile" ]] || \
    die "未找到当前内核 headers: /lib/modules/${KERNEL}/build"

if command -v brutalctl >/dev/null 2>&1; then
    brutalctl flush >/dev/null 2>&1 || true
fi

if lsmod | awk '{print $1}' | grep -qx brutal; then
    log "Unloading currently loaded brutal module..."
    if ! modprobe -r brutal 2>/dev/null; then
        die "brutal 模块正在被连接使用，无法卸载。请先停止正在使用 Brutal 的 TCP 连接/代理服务后重试。"
    fi
fi

if command -v dkms >/dev/null 2>&1; then
    mapfile -t old_versions < <(
        dkms status 2>/dev/null |
        sed -n 's/^tcp-brutal\/\([^,: ]*\).*/\1/p' |
        sort -u
    )

    if ((${#old_versions[@]})); then
        log "Removing existing tcp-brutal DKMS versions: ${old_versions[*]}"
        for v in "${old_versions[@]}"; do
            dkms remove -m tcp-brutal -v "$v" --all || true
        done
    else
        log "No existing tcp-brutal DKMS registration found."
    fi
fi

rm -rf /usr/src/tcp-brutal-1.0.3 \
       /usr/src/tcp-brutal-2.0.0

depmod -a "$KERNEL" 2>/dev/null || true

WORKDIR="$(mktemp -d /tmp/tcp-brutal-v2.XXXXXX)"
log "Cloning upstream ${REF}..."
git clone --quiet --branch "$REF" --single-branch "$REPO_URL" "$WORKDIR/repo"
cd "$WORKDIR/repo"

git checkout --quiet "$PINNED_COMMIT"
ACTUAL_COMMIT="$(git rev-parse HEAD)"

[[ "$ACTUAL_COMMIT" == "$PINNED_COMMIT" ]] || \
    die "源码 commit 校验失败：expected=${PINNED_COMMIT}, actual=${ACTUAL_COMMIT}"

grep -q 'BRUTAL_HAVE_TSO_SEGS' Makefile || \
    die "该源码没有检测到 BRUTAL_HAVE_TSO_SEGS 兼容逻辑，停止安装。"
grep -q '\.tso_segs = brutal_tso_segs' brutal_cc.c || \
    die "该源码没有检测到 XanMod/BBRv3 tso_segs 实现，停止安装。"

TARGET_VERSION="$(
    ./scripts/mkdkmsconf.sh |
    sed -n 's/^PACKAGE_VERSION="\([^"]*\)".*/\1/p' |
    head -n1
)"
[[ -n "$TARGET_VERSION" ]] || die "无法从上游源码生成 DKMS 版本号。"

log "Upstream commit: ${ACTUAL_COMMIT}"
log "DKMS version: ${TARGET_VERSION}"

SRC_DIR="/usr/src/tcp-brutal-${TARGET_VERSION}"

if dkms status 2>/dev/null | grep -q "^tcp-brutal/${TARGET_VERSION}"; then
    dkms remove -m tcp-brutal -v "$TARGET_VERSION" --all || true
fi

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
git archive HEAD | tar -x -C "$SRC_DIR"

cd "$SRC_DIR"
PACKAGE_VERSION="$TARGET_VERSION" ./scripts/mkdkmsconf.sh > dkms.conf

log "Adding DKMS source..."
dkms add -m tcp-brutal -v "$TARGET_VERSION"

log "Building for ${KERNEL}..."
dkms build -m tcp-brutal -v "$TARGET_VERSION" -k "$KERNEL"

log "Installing for ${KERNEL}..."
dkms install -m tcp-brutal -v "$TARGET_VERSION" -k "$KERNEL"

log "Building brutalctl..."
make -C tools clean >/dev/null 2>&1 || true
make -C tools
install -m 0755 tools/brutalctl /usr/local/bin/brutalctl

printf 'brutal\n' > /etc/modules-load.d/brutal.conf

if [[ -f /etc/modules-load.d/tcp-brutal.conf ]] && \
   [[ "$(tr -d '[:space:]' < /etc/modules-load.d/tcp-brutal.conf)" == "brutal" ]]; then
    rm -f /etc/modules-load.d/tcp-brutal.conf
fi

depmod -a "$KERNEL"
log "Loading DKMS-installed module..."
modprobe brutal

MODULE_PATH="$(modinfo -F filename brutal)"
MODULE_VERMAGIC="$(modinfo -F vermagic brutal)"
AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control)"

[[ "$MODULE_PATH" == *"/updates/dkms/brutal.ko"* ]] || \
    die "加载的 brutal 不是 DKMS 模块：${MODULE_PATH}"

grep -qw brutal <<<"$AVAILABLE_CC" || \
    die "brutal 未出现在 tcp_available_congestion_control 中。"

[[ -e /proc/net/tcp_brutal/rules ]] || \
    die "/proc/net/tcp_brutal/rules 不存在，v2 rules 接口初始化失败。"

log "Installation successful."
printf '\n'
printf '  Kernel:        %s\n' "$KERNEL"
printf '  Commit:        %s\n' "$ACTUAL_COMMIT"
printf '  DKMS version:  %s\n' "$TARGET_VERSION"
printf '  Module:        %s\n' "$MODULE_PATH"
printf '  Vermagic:      %s\n' "$MODULE_VERMAGIC"
printf '  TCP CC:        %s\n' "$AVAILABLE_CC"
printf '\n'
dkms status | grep '^tcp-brutal/' || true
printf '\n'
brutalctl list || true

cat <<'EOF'

注意：
1. 不要把 brutal 设置成系统全局默认 TCP 拥塞控制。
2. brutalctl 的 destination rules 默认不会跨重启保存。
3. 该脚本固定使用已经验证过的官方 exp/xan-fix commit，
   用于兼容带 BBRv3 tso_segs 接口的 XanMod。
EOF
