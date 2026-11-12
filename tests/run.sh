#!/usr/bin/env bash
#
# Offline tests for eac-dkms-workaround. They need no root, network, or real
# pacman/dkms state: those commands are replaced by shell functions, and the
# source/module roots point at a temporary fixture tree.
#
# Usage: bash tests/run.sh   (or: make test)

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# shellcheck source=eac-dkms-workaround
source ./eac-dkms-workaround

npass=0
nfail=0
ntest=0
t_ok() {
    ntest=$((ntest + 1)); npass=$((npass + 1))
    printf 'ok %d - %s\n' "$ntest" "$1"
}
t_notok() {
    ntest=$((ntest + 1)); nfail=$((nfail + 1))
    printf 'not ok %d - %s\n' "$ntest" "$1"
    [[ -n ${2:-} ]] && printf '#   %s\n' "$2"
    return 0
}
t_true() { local d=$1; shift; if "$@"; then t_ok "$d"; else t_notok "$d"; fi; }
t_false() { local d=$1; shift; if "$@"; then t_notok "$d"; else t_ok "$d"; fi; }
t_eq() { if [[ $2 == "$3" ]]; then t_ok "$1"; else t_notok "$1" "got '$2', want '$3'"; fi; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

# ---- stubs ----------------------------------------------------------------
STUB_INSTALLED=()   # "name version"
STUB_PROVIDES=()    # "virtual name": pacman -Q resolves the virtual to name
STUB_OWNED=()       # paths that pacman -Qo reports as owned
STUB_REPO=()        # "name version" in the sync databases
STUB_DKMS_STATUS='' # what `dkms status ...` prints

stub_lookup() {
    local e
    for e in "${STUB_INSTALLED[@]}"; do
        [[ ${e%% *} == "$1" ]] && { printf '%s\n' "$e"; return 0; }
    done
    for e in "${STUB_PROVIDES[@]}"; do
        [[ ${e%% *} == "$1" ]] && { stub_lookup "${e#* }"; return; }
    done
    return 1
}

pacman() {
    local e last=${*: -1}
    case $1 in
        -Q) stub_lookup "$2" ;;
        -Qq) e=$(stub_lookup "$2") && printf '%s\n' "${e%% *}" ;;
        -Qqo)
            for e in "${STUB_OWNED[@]}"; do
                [[ $e == "$2" ]] && { echo owner; return 0; }
            done
            return 1 ;;
        -Sddp)
            for e in "${STUB_REPO[@]}"; do
                [[ ${e%% *} == "$last" ]] && { printf '%s\n' "${e#* }"; return 0; }
            done
            return 1 ;;
        *) echo "unexpected: pacman $*" >&2; return 99 ;;
    esac
}

dkms() {
    [[ $1 == status ]] || { echo "unexpected: dkms $*" >&2; return 99; }
    [[ -n $STUB_DKMS_STATUS ]] && printf '%s\n' "$STUB_DKMS_STATUS"
    return 0
}

limine-mkinitcpio() {
    printf '%s\n' "$*" >>"$FIX/limine.calls"
    printf '%s\n' "${STUB_LIMINE_OUTPUT:-==> Initcpio image generation successful}"
}

reset_stubs() {
    STUB_INSTALLED=() STUB_PROVIDES=() STUB_OWNED=() STUB_REPO=() STUB_DKMS_STATUS=''
    UTILS_PKG='' DKMS_PKG='' EAC_PKG='' HOOK_MODE=0 HOOK_TARGETS=()
    rm -f "$FIX/limine.calls"
}

# ---- version handling ----------------------------------------------------
t_eq "upstream_version strips pkgrel" "$(upstream_version 580.196.07-2)" 580.196.07
t_eq "upstream_version strips epoch and pkgrel" "$(upstream_version 1:2.0-3)" 2.0

# ---- kernel flavors ------------------------------------------------------
t_eq "flavor: stock linux" "$(flavor_suffix 7.2.15-arch1-1)" '-arch[0-9]+-[0-9]+'
t_eq "flavor: linux-lts" "$(flavor_suffix 6.12.58-1-lts)" '-[0-9]+-lts'
t_eq "flavor: linux-zen" "$(flavor_suffix 6.17.8-zen1-1-zen)" '-zen[0-9]+-[0-9]+-zen'
t_eq "flavor: linux-hardened" "$(flavor_suffix 6.17.8-hardened1-1-hardened)" '-hardened[0-9]+-[0-9]+-hardened'
t_eq "flavor: dots are escaped" "$(flavor_suffix 6.1.2-1.1-foo)" '-[0-9]+\.[0-9]+-foo'
t_false "flavor: rejects a release without a suffix" flavor_suffix 6.12.0

# ---- driver detection ----------------------------------------------------
reset_stubs
STUB_INSTALLED=("nvidia-580xx-utils 580.196.07-2")
STUB_PROVIDES=("nvidia-utils nvidia-580xx-utils")
detect_driver
t_eq "detect: 580xx line, despite it providing nvidia-utils" "$UTILS_PKG -> $DKMS_PKG" "nvidia-580xx-utils -> nvidia-580xx-dkms"
t_eq "detect: 580xx EAC module" "$EAC_PKG" linux-cachyos-eac-nvidia-580xx

reset_stubs
STUB_INSTALLED=("nvidia-utils 620.70.06-2")
detect_driver
t_eq "detect: current (RTX) line" "$UTILS_PKG -> $DKMS_PKG" "nvidia-utils -> nvidia-open-dkms"
t_eq "detect: current EAC module" "$EAC_PKG" linux-cachyos-eac-nvidia-open

reset_stubs
t_false "detect: fails with no NVIDIA userspace" detect_driver

reset_stubs
STUB_INSTALLED=("eac-dkms-workaround-git 0.1.0.r1.gabc-1")
STUB_PROVIDES=("eac-dkms-workaround eac-dkms-workaround-git")
t_eq "installed_as_package resolves the -git package" "$(installed_as_package)" eac-dkms-workaround-git

# ---- hook ----------------------------------------------------------------
hook=$(print_hook /opt/bin/eac-dkms-workaround)
for line in '[Trigger]' 'Type = Package' 'Operation = Install' 'Operation = Upgrade' \
    'Target = nvidia-580xx-utils' 'Target = nvidia-utils' \
    'Target = eac-dkms-workaround' 'Target = eac-dkms-workaround-git' \
    '[Action]' 'When = PostTransaction' 'Exec = /opt/bin/eac-dkms-workaround sync --hook' \
    'Type = Path' 'Target = usr/lib/modules/*/vmlinuz' 'Target = usr/lib/modules/*/build/include/' \
    'Target = usr/lib/modules/*/extramodules/nvidia.ko*' \
    'NeedsTargets' 'NetworkAccess = allowed'; do
    t_true "hook has: $line" grep -qxF -- "$line" <<<"$hook"
done
t_eq "hook: Remove only in the path trigger" \
    "$(awk '/^\[/ {sec=$0} /^Type =/ {type=$3} /^Operation = Remove/ {print type}' <<<"$hook")" Path

# ---- managed source trees ------------------------------------------------
reset_stubs
SRC_ROOT=$FIX/src
mkdir -p "$SRC_ROOT"/{nvidia-1.0,nvidia-2.0,nvidia-3.0,other-1.0}
touch "$SRC_ROOT"/nvidia-{1.0,2.0,3.0}/dkms.conf "$SRC_ROOT"/other-1.0/dkms.conf
touch "$SRC_ROOT"/nvidia-1.0/$MARKER "$SRC_ROOT"/nvidia-3.0/$MARKER "$SRC_ROOT"/other-1.0/$MARKER
STUB_OWNED=("$SRC_ROOT/nvidia-3.0/dkms.conf")
t_eq "managed_trees: only marked, unowned nvidia trees" "$(managed_trees)" "$SRC_ROOT/nvidia-1.0"
t_eq "tree_version" "$(tree_version "$SRC_ROOT/nvidia-580.196.07")" 580.196.07

# ---- kernels -------------------------------------------------------------
MOD_ROOT=$FIX/modules
mkkernel() { # <release> [headers] [prebuilt]
    mkdir -p "$MOD_ROOT/$1/kernel"
    [[ ${2:-} == headers ]] && mkdir -p "$MOD_ROOT/$1/build/include"
    if [[ ${3:-} == prebuilt ]]; then
        mkdir -p "$MOD_ROOT/$1/extramodules"
        touch "$MOD_ROOT/$1/extramodules/nvidia.ko.zst"
    fi
    return 0
}
mkkernel 7.2.15-arch1-1 headers
mkkernel 6.12.58-1-lts headers
mkkernel 6.17.8-zen1-1-zen headers
mkkernel 7.3.3-1-cachyos headers prebuilt
mkkernel 7.3.3-2-cachyos-eac '' prebuilt
mkkernel 6.17.8-hardened1-1-hardened
mkdir -p "$MOD_ROOT/7.2.14-arch1-1"  # leftover directory of a removed kernel
echo linux >"$MOD_ROOT/7.2.15-arch1-1/pkgbase"

t_eq "installed_kernels: only directories with a kernel tree" \
    "$(installed_kernels | LC_ALL=C sort | paste -sd' ')" \
    "6.12.58-1-lts 6.17.8-hardened1-1-hardened 6.17.8-zen1-1-zen 7.2.15-arch1-1 7.3.3-1-cachyos 7.3.3-2-cachyos-eac"
t_eq "eligible: headers, no prebuilt module, not EAC" \
    "$(eligible_kernels | LC_ALL=C sort | paste -sd' ')" "6.12.58-1-lts 6.17.8-zen1-1-zen 7.2.15-arch1-1"
t_eq "uncovered: no headers and no prebuilt module" "$(uncovered_kernels)" 6.17.8-hardened1-1-hardened
mkkernel 7.3.4-1-cachyos-eac
t_eq "uncovered: EAC kernel without its prebuilt module" \
    "$(uncovered_kernels | LC_ALL=C sort | paste -sd' ')" "6.17.8-hardened1-1-hardened 7.3.4-1-cachyos-eac"
reset_stubs
STUB_INSTALLED=("nvidia-utils 620.70.06-2")
detect_driver
echo linux-hardened >"$MOD_ROOT/6.17.8-hardened1-1-hardened/pkgbase"
warnings=$(warn_uncovered 2>&1)
t_true "warn_uncovered: names the EAC module package" \
    grep -qxF -- "==> WARNING: EAC kernel 7.3.4-1-cachyos-eac has no nvidia module: sudo pacman -S --needed linux-cachyos-eac-nvidia-open" <<<"$warnings"
t_true "warn_uncovered: names the headers package" \
    grep -qxF -- "==> WARNING: kernel 6.17.8-hardened1-1-hardened has no nvidia module: install linux-hardened-headers so DKMS can build for it" <<<"$warnings"
rm -rf "$MOD_ROOT/7.3.4-1-cachyos-eac" "$MOD_ROOT/6.17.8-hardened1-1-hardened/pkgbase"
t_true "is_eac_kernel: linux-cachyos-eac" is_eac_kernel 7.3.3-2-cachyos-eac
t_false "is_eac_kernel: linux-cachyos" is_eac_kernel 7.3.3-1-cachyos
t_eq "kernel_pkgbase reads pkgbase" "$(kernel_pkgbase 7.2.15-arch1-1)" linux

regex=$(exclusive_regex 7.2.15-arch1-1 6.12.58-1-lts 6.17.8-zen1-1-zen)
t_eq "exclusive_regex: one pattern per flavor" "$regex" '^[0-9]+(\.[0-9]+)*(-[0-9]+-lts|-arch[0-9]+-[0-9]+|-zen[0-9]+-[0-9]+-zen)$'
matches() { [[ $1 =~ $regex ]]; }
t_true "regex: next stock kernel" matches 7.3.1-arch1-1
t_true "regex: next lts" matches 6.12.60-1-lts
t_true "regex: next zen" matches 6.18.2-zen1-1-zen
t_false "regex: linux-cachyos (prebuilt)" matches 7.3.3-1-cachyos
t_false "regex: linux-cachyos-eac" matches 7.3.3-2-cachyos-eac
t_false "regex: linux-cachyos-lts" matches 6.18.60-2-cachyos-lts
t_false "regex: linux-hardened (not eligible)" matches 6.17.8-hardened1-1-hardened
t_eq "exclusive_regex: matches nothing without kernels" "$(exclusive_regex)" '^$'
mkkernel 7.2.9-arch1-1 '' prebuilt
t_eq "exclusive_regex: exact releases when a flavor would hit a kernel with a prebuilt module" \
    "$(exclusive_regex 7.2.15-arch1-1)" '^(7\.2\.15-arch1-1)$'
rm -rf "$MOD_ROOT/7.2.9-arch1-1"

# ---- the block in dkms.conf ----------------------------------------------
conf=$FIX/dkms.conf
printf 'PACKAGE_NAME="nvidia"\nPACKAGE_VERSION="1.0"\n\n\n' >"$conf"
chmod 644 "$conf"
set_exclusive "$conf" '^(a)$'
t_eq "current_exclusive reads the block" "$(current_exclusive "$conf")" '^(a)$'
set_exclusive "$conf" "$regex"
t_eq "set_exclusive replaces the block" "$(current_exclusive "$conf")" "$regex"
t_eq "set_exclusive leaves one assignment" "$(grep -c '^BUILD_EXCLUSIVE_KERNEL=' "$conf")" 1
t_eq "set_exclusive keeps the rest, one blank line before the block" \
    "$(head -n 4 "$conf")" "$(printf 'PACKAGE_NAME="nvidia"\nPACKAGE_VERSION="1.0"\n\n%s' "$BLOCK_BEGIN")"
t_eq "set_exclusive keeps mode 644" "$(stat -c %a "$conf")" 644
# How DKMS reads it: source dkms.conf, match the kernel release.
conf_builds_for() {
    # shellcheck source=/dev/null  # fixture created at runtime
    (source "$1" && [[ $2 =~ $BUILD_EXCLUSIVE_KERNEL ]])
}
t_true "sourced dkms.conf: DKMS builds for the next lts" conf_builds_for "$conf" 6.12.60-1-lts
t_false "sourced dkms.conf: DKMS skips linux-cachyos-eac" conf_builds_for "$conf" 7.3.3-2-cachyos-eac

# ---- dkms status parsing -------------------------------------------------
STUB_DKMS_STATUS='nvidia/580.196.07, 7.2.15-arch1-1, x86_64: installed'
t_eq "dkms_state: installed" "$(dkms_state 580.196.07 7.2.15-arch1-1)" installed
STUB_DKMS_STATUS='nvidia/580.196.07, 7.2.15-arch1-1, x86_64: built'
t_eq "dkms_state: built" "$(dkms_state 580.196.07 7.2.15-arch1-1)" built
STUB_DKMS_STATUS='nvidia/580.196.07: added'
t_eq "dkms_state: added" "$(dkms_state 580.196.07 7.2.15-arch1-1)" added
STUB_DKMS_STATUS=''
t_eq "dkms_state: unknown module" "$(dkms_state 580.196.07 7.2.15-arch1-1)" ''
t_false "dkms_registered: unknown module" dkms_registered 580.196.07
STUB_DKMS_STATUS=$'nvidia/580.196.07, 7.2.15-arch1-1, x86_64: installed\nnvidia/580.196.07, 7.3.3-1-cachyos, x86_64: built\nnvidia/580.196.07: added'
t_eq "dkms_kernels: kernels with a build" "$(dkms_kernels 580.196.07 | paste -sd' ')" "7.2.15-arch1-1 7.3.3-1-cachyos"
STUB_DKMS_STATUS=''

t_eq "show_build_log: silent when DKMS left no log" "$(show_build_log 0.0.0 2>&1)" ''

# ---- staging the source tree from a package ------------------------------
make_fake_pkg() { # <out> <dir version> <PACKAGE_VERSION>
    local root=$FIX/pkgroot-$2-$3
    mkdir -p "$root/usr/src/nvidia-$2" "$root/usr/share/licenses/x"
    printf 'PACKAGE_NAME="nvidia"\nPACKAGE_VERSION="%s"\nAUTOINSTALL="yes"\n' "$3" >"$root/usr/src/nvidia-$2/dkms.conf"
    echo src >"$root/usr/src/nvidia-$2/nv.c"
    echo license >"$root/usr/share/licenses/x/LICENSE"
    bsdtar --zstd -cf "$1" -C "$root" usr
}
make_fake_pkg "$FIX/good.pkg.tar.zst" 1.2.3 1.2.3
TMP=$FIX/stage-good
mkdir -p "$TMP"
staged=$(stage_tree "$FIX/good.pkg.tar.zst" 1.2.3 1.2.3-4 "$regex" 2>/dev/null)
t_eq "stage_tree: returns the staged tree" "$staged" "$TMP/root/usr/src/nvidia-1.2.3"
t_eq "stage_tree: marker holds pkgver-pkgrel" "$(cat "$staged/$MARKER" 2>/dev/null)" 1.2.3-4
# shellcheck source=/dev/null  # fixture created at runtime
t_eq "stage_tree: dkms.conf gets the kernel block" \
    "$( (source "$staged/dkms.conf" && printf '%s' "$BUILD_EXCLUSIVE_KERNEL") 2>/dev/null)" "$regex"
# shellcheck source=/dev/null  # fixture created at runtime
t_eq "stage_tree: rest of dkms.conf untouched" \
    "$( (source "$staged/dkms.conf" && printf '%s %s' "$PACKAGE_NAME" "$PACKAGE_VERSION") 2>/dev/null)" "nvidia 1.2.3"
t_false "stage_tree: extracts nothing outside usr/src" test -e "$TMP/root/usr/share"

make_fake_pkg "$FIX/bad.pkg.tar.zst" 1.2.3 9.9.9
TMP=$FIX/stage-bad
mkdir -p "$TMP"
t_false "stage_tree: rejects a PACKAGE_VERSION mismatch" stage_tree "$FIX/bad.pkg.tar.zst" 1.2.3 1.2.3-1 "$regex" 2>/dev/null
TMP=$FIX/stage-missing
mkdir -p "$TMP"
t_false "stage_tree: rejects a package without that version" stage_tree "$FIX/good.pkg.tar.zst" 4.5.6 4.5.6-1 "$regex" 2>/dev/null

# ---- initramfs regeneration decision -------------------------------------
reset_stubs
UTILS_PKG=nvidia-580xx-utils
utils_ships_firmware() { return 0; }
HOOK_MODE=1
HOOK_TARGETS=(nvidia-580xx-utils)
regen_initramfs 7.2.15-arch1-1 2>/dev/null
t_false "regen: skipped when the utils firmware change triggers mkinitcpio" test -e "$FIX/limine.calls"

HOOK_TARGETS=(eac-dkms-workaround)
regen_initramfs 7.2.15-arch1-1 2>/dev/null
t_eq "regen: runs for the kernel's package when triggered by the package itself" "$(cat "$FIX/limine.calls" 2>/dev/null)" linux

rm -f "$FIX/limine.calls"
HOOK_MODE=0
HOOK_TARGETS=()
regen_initramfs 7.2.15-arch1-1 2>/dev/null
t_eq "regen: runs on a manual sync" "$(cat "$FIX/limine.calls" 2>/dev/null)" linux

STUB_LIMINE_OUTPUT="==> ERROR: module not found: 'nvidia'"
t_false "regen: reports mkinitcpio errors" regen_initramfs 7.2.15-arch1-1 2>/dev/null
unset STUB_LIMINE_OUTPUT

# ---- summary --------------------------------------------------------------
printf '1..%d\n' "$ntest"
printf '# %d passed, %d failed\n' "$npass" "$nfail"
(( nfail == 0 ))
