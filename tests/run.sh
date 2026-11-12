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
    UTILS_PKG='' DKMS_PKG='' HOOK_MODE=0 HOOK_TARGETS=()
    rm -f "$FIX/limine.calls"
}

# ---- version handling ----------------------------------------------------
t_eq "upstream_version strips pkgrel" "$(upstream_version 580.196.07-2)" 580.196.07
t_eq "upstream_version strips epoch and pkgrel" "$(upstream_version 1:2.0-3)" 2.0

# ---- kernel allowlist ----------------------------------------------------
allowed() { [[ $1 =~ $KERNEL_ALLOW ]]; }
t_true "allowlist: stock Arch kernel" allowed 7.2.15-arch1-1
t_true "allowlist: stock Arch kernel, two-digit rel" allowed 6.12.10-arch12-3
t_false "allowlist: linux-cachyos" allowed 7.3.3-1-cachyos
t_false "allowlist: linux-cachyos-eac" allowed 7.3.3-2-cachyos-eac
t_false "allowlist: linux-lts" allowed 6.12.5-1-lts
t_false "allowlist: linux-zen" allowed 6.18.1-zen1-1-zen

# ---- driver detection ----------------------------------------------------
reset_stubs
STUB_INSTALLED=("nvidia-580xx-utils 580.196.07-2")
STUB_PROVIDES=("nvidia-utils nvidia-580xx-utils")
detect_driver
t_eq "detect: 580xx line, despite it providing nvidia-utils" "$UTILS_PKG -> $DKMS_PKG" "nvidia-580xx-utils -> nvidia-580xx-dkms"

reset_stubs
STUB_INSTALLED=("nvidia-utils 620.70.06-2")
detect_driver
t_eq "detect: current (RTX) line" "$UTILS_PKG -> $DKMS_PKG" "nvidia-utils -> nvidia-open-dkms"

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
    'NeedsTargets' 'NetworkAccess = allowed'; do
    t_true "hook has: $line" grep -qxF -- "$line" <<<"$hook"
done
t_false "hook has no Remove trigger" grep -q 'Operation = Remove' <<<"$hook"

# ---- managed source trees ------------------------------------------------
reset_stubs
SRC_ROOT=$FIX/src
mkdir -p "$SRC_ROOT"/{nvidia-1.0,nvidia-2.0,nvidia-3.0,other-1.0}
touch "$SRC_ROOT"/nvidia-{1.0,2.0,3.0}/dkms.conf "$SRC_ROOT"/other-1.0/dkms.conf
touch "$SRC_ROOT"/nvidia-1.0/$MARKER "$SRC_ROOT"/nvidia-3.0/$MARKER "$SRC_ROOT"/other-1.0/$MARKER
STUB_OWNED=("$SRC_ROOT/nvidia-3.0/dkms.conf")
t_eq "managed_trees: only marked, unowned nvidia trees" "$(managed_trees)" "$SRC_ROOT/nvidia-1.0"
t_eq "tree_version" "$(tree_version "$SRC_ROOT/nvidia-580.196.07")" 580.196.07

# ---- eligible kernels ----------------------------------------------------
MOD_ROOT=$FIX/modules
mkdir -p "$MOD_ROOT"/7.2.15-arch1-1/{build/include,kernel} \
    "$MOD_ROOT"/7.3.3-1-cachyos/{build/include,kernel} \
    "$MOD_ROOT"/7.3.3-2-cachyos-eac/kernel \
    "$MOD_ROOT"/7.2.14-arch1-1/kernel
echo linux >"$MOD_ROOT/7.2.15-arch1-1/pkgbase"
t_eq "eligible_kernels: stock kernel with headers only" "$(eligible_kernels)" 7.2.15-arch1-1
t_eq "kernel_pkgbase reads pkgbase" "$(kernel_pkgbase 7.2.15-arch1-1)" linux

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
staged=$(stage_tree "$FIX/good.pkg.tar.zst" 1.2.3 1.2.3-4 2>/dev/null)
t_eq "stage_tree: returns the staged tree" "$staged" "$TMP/root/usr/src/nvidia-1.2.3"
t_eq "stage_tree: marker holds pkgver-pkgrel" "$(cat "$staged/$MARKER" 2>/dev/null)" 1.2.3-4
# shellcheck source=/dev/null  # fixture created at runtime
t_eq "stage_tree: dkms.conf gets the kernel allowlist" \
    "$( (source "$staged/dkms.conf" && printf '%s' "$BUILD_EXCLUSIVE_KERNEL") 2>/dev/null)" "$KERNEL_ALLOW"
# shellcheck source=/dev/null  # fixture created at runtime
t_eq "stage_tree: rest of dkms.conf untouched" \
    "$( (source "$staged/dkms.conf" && printf '%s %s' "$PACKAGE_NAME" "$PACKAGE_VERSION") 2>/dev/null)" "nvidia 1.2.3"
t_false "stage_tree: extracts nothing outside usr/src" test -e "$TMP/root/usr/share"

make_fake_pkg "$FIX/bad.pkg.tar.zst" 1.2.3 9.9.9
TMP=$FIX/stage-bad
mkdir -p "$TMP"
t_false "stage_tree: rejects a PACKAGE_VERSION mismatch" stage_tree "$FIX/bad.pkg.tar.zst" 1.2.3 1.2.3-1 2>/dev/null
TMP=$FIX/stage-missing
mkdir -p "$TMP"
t_false "stage_tree: rejects a package without that version" stage_tree "$FIX/good.pkg.tar.zst" 4.5.6 4.5.6-1 2>/dev/null

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
