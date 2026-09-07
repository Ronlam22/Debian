#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${TCP_BRUTAL_REPO:-https://github.com/HyNetworks/tcp-brutal.git}"
REF="${TCP_BRUTAL_REF:-exp/xan-fix}"
PINNED_COMMIT="${TCP_BRUTAL_COMMIT:-faf8ac5bc4b94a6c142d60e7f91c3bebd492874d}"

KERNEL="$(uname -r)"
WORKDIR=""
TARGET_VERSION=""
SRC_DIR=""
KERNEL_FLAVOR="unknown"
API_MODE="unknown"

log()  { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die "请使用 root 运行此脚本。"
command -v apt-get >/dev/null 2>&1 || die "当前脚本仅支持 Debian/Ubuntu（需要 apt-get）。"

log "Kernel: ${KERNEL}"

FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
log "Root filesystem free space: ${FREE_MB} MB"

if (( FREE_MB < 250 )); then
    warn "根分区可用空间低于 250 MB。先执行一次安全的 APT 缓存清理。"
    apt-get clean || true
    FREE_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
    log "Free space after apt clean: ${FREE_MB} MB"
fi

if (( FREE_MB < 250 )); then
    die "可用空间仍少于 250 MB。请先扩容或清理空间后再安装，避免 dpkg 再次中断。"
fi

if dpkg --audit 2>/dev/null | grep -q .; then
    warn "检测到未完成的软件包状态，先运行 dpkg --configure -a。"
    dpkg --configure -a || die "dpkg 修复失败。请先修复软件包状态后重试。"
fi

need_pkgs=()
command -v git  >/dev/null 2>&1 || need_pkgs+=(git)
command -v make >/dev/null 2>&1 || need_pkgs+=(make)
command -v dkms >/dev/null 2>&1 || need_pkgs+=(dkms)
command -v cc   >/dev/null 2>&1 || need_pkgs+=(build-essential)

dpkg -s libc6-dev >/dev/null 2>&1 || need_pkgs+=(libc6-dev)
dpkg -s libelf-dev >/dev/null 2>&1 || need_pkgs+=(libelf-dev)

if [[ ! -e "/lib/modules/${KERNEL}/build/Makefile" ]]; then
    need_pkgs+=("linux-headers-${KERNEL}")
fi

if ((${#need_pkgs[@]})); then
    log "Installing missing packages: ${need_pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${need_pkgs[@]}"
fi

[[ -e "/lib/modules/${KERNEL}/build/Makefile" ]] || \
    die "未找到当前内核 headers: /lib/modules/${KERNEL}/build"

TCP_H="/lib/modules/${KERNEL}/build/include/net/tcp.h"

if [[ "${KERNEL,,}" == *xanmod* ]]; then
    KERNEL_FLAVOR="XanMod"
else
    KERNEL_FLAVOR="Standard/Other"
fi

if [[ -r "$TCP_H" ]] && \
   grep -Eq '\(\*tso_segs\)\(struct sock \*sk, unsigned int mss_now\)' "$TCP_H"; then
    API_MODE="BBRv3 tso_segs"
else
    API_MODE="standard min_tso_segs"
fi

log "Detected kernel family: ${KERNEL_FLAVOR}"
log "Detected Brutal build API: ${API_MODE}"

WORKDIR="$(mktemp -d /tmp/tcp-brutal-v2.XXXXXX)"
log "Cloning upstream ${REF}..."
git clone --quiet --branch "$REF" --single-branch "$REPO_URL" "$WORKDIR/repo"
cd "$WORKDIR/repo"

git checkout --quiet "$PINNED_COMMIT"
ACTUAL_COMMIT="$(git rev-parse HEAD)"
[[ "$ACTUAL_COMMIT" == "$PINNED_COMMIT" ]] || \
    die "源码 commit 校验失败：expected=${PINNED_COMMIT}, actual=${ACTUAL_COMMIT}"

grep -q 'BRUTAL_HAVE_TSO_SEGS' Makefile || \
    die "源码缺少 BRUTAL_HAVE_TSO_SEGS 自动检测逻辑。"
grep -q '\.tso_segs = brutal_tso_segs' brutal_cc.c || \
    die "源码缺少 BBRv3/XanMod tso_segs 兼容实现。"
grep -q '\.min_tso_segs = brutal_min_tso_segs' brutal_cc.c || \
    die "源码缺少标准内核 min_tso_segs 兼容实现。"

TARGET_VERSION="$(
    ./scripts/mkdkmsconf.sh |
    sed -n 's/^PACKAGE_VERSION="\([^"]*\)".*/\1/p' |
    head -n1
)"
[[ -n "$TARGET_VERSION" ]] || die "无法生成 DKMS 版本号。"

log "Upstream commit: ${ACTUAL_COMMIT}"
log "Target DKMS version: ${TARGET_VERSION}"

SRC_DIR="/usr/src/tcp-brutal-${TARGET_VERSION}"

if dkms status 2>/dev/null | grep -q "^tcp-brutal/${TARGET_VERSION}"; then
    warn "发现同版本 DKMS 残留，先清理目标版本后重新构建。"
    dkms remove -m tcp-brutal -v "$TARGET_VERSION" --all || true
fi

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
git archive HEAD | tar -x -C "$SRC_DIR"
cd "$SRC_DIR"
PACKAGE_VERSION="$TARGET_VERSION" ./scripts/mkdkmsconf.sh > dkms.conf

log "Adding new DKMS source..."
dkms add -m tcp-brutal -v "$TARGET_VERSION"

log "Building new version for ${KERNEL} before removing the old one..."
if ! dkms build -m tcp-brutal -v "$TARGET_VERSION" -k "$KERNEL"; then
    dkms remove -m tcp-brutal -v "$TARGET_VERSION" --all || true
    die "TCP Brutal v2 编译失败。旧版本尚未被删除。"
fi

if command -v brutalctl >/dev/null 2>&1; then
    brutalctl flush >/dev/null 2>&1 || true
fi

if lsmod | awk '{print $1}' | grep -qx brutal; then
    log "Unloading currently loaded brutal module..."
    if ! modprobe -r brutal 2>/dev/null; then
        die "brutal 模块正在被连接使用，无法卸载。请先停止使用 Brutal 的代理/连接后重试。新 v2 已成功 build，但尚未替换旧模块。"
    fi
fi

mapfile -t old_versions < <(
    dkms status 2>/dev/null |
    sed -n 's/^tcp-brutal\/\([^,: ]*\).*/\1/p' |
    sort -u
)

for v in "${old_versions[@]:-}"; do
    [[ -n "$v" ]] || continue
    [[ "$v" == "$TARGET_VERSION" ]] && continue
    log "Removing old tcp-brutal DKMS version: $v"
    dkms remove -m tcp-brutal -v "$v" --all || true
    rm -rf "/usr/src/tcp-brutal-${v}" || true
done

rm -rf /usr/src/tcp-brutal-1.0.3 /usr/src/tcp-brutal-2.0.0

log "Installing new DKMS version..."
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
printf '  Kernel type:   %s\n' "$KERNEL_FLAVOR"
printf '  API mode:      %s\n' "$API_MODE"
printf '  Commit:        %s\n' "$ACTUAL_COMMIT"
printf '  DKMS version:  %s\n' "$TARGET_VERSION"
printf '  Module:        %s\n' "$MODULE_PATH"
printf '  Vermagic:      %s\n' "$MODULE_VERMAGIC"
printf '  TCP CC:        %s\n' "$AVAILABLE_CC"
printf '  Free space:    %s MB\n' "$(df -Pm / | awk 'NR==2 {print $4}')"
printf '\n'
dkms status | grep '^tcp-brutal/' || true
printf '\n'
brutalctl list || true

cat <<'EOF'

说明：
1. 标准 Debian/Ubuntu 内核会自动使用 min_tso_segs 路径。
2. XanMod/BBRv3 内核会根据当前 headers 自动使用 tso_segs(sk, mss_now) 路径。
3. 脚本不再无条件安装 clang/llvm，适合小磁盘 VPS。
4. 只有新 v2 DKMS build 成功后才删除旧的 TCP Brutal 1.0.3/其他旧版本。
5. 不要把 brutal 设置成系统全局默认 TCP 拥塞控制。
6. brutalctl destination rules 默认不会跨重启保存。
EOF
