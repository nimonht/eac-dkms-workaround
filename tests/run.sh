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
STUB_MODINFO=()     # "kernel path version": what modinfo knows about nvidia
STUB_DOWNLOAD_FAIL= # non-empty: `pacman -Sddw` fails
STUB_BUILD_FAIL=    # kernel release for which `dkms build` fails

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
        -Qq)
            if (( $# == 1 )); then
                for e in "${STUB_INSTALLED[@]}"; do printf '%s\n' "${e%% *}"; done
                return 0
            fi
            e=$(stub_lookup "$2") && printf '%s\n' "${e%% *}" ;;
        -Qqdt | -Si | -T) return 1 ;;
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
        -Sddw) # the download: copy the fixture packages into --cachedir
            [[ -z $STUB_DOWNLOAD_FAIL ]] || return 1
            while (( $# )); do
                [[ $1 == --cachedir ]] && e=$2
                shift
            done
            cp -- "$FIX/repo/$last"-*.pkg.tar.zst "$e/" ;;
        *) echo "unexpected: pacman $*" >&2; return 99 ;;
    esac
}

# Replace, or without a state drop, the entry of <version> <kernel> in
# $FIX/dkms.state. Its lines are "<version> <kernel> <state>", with the kernel
# "-" for a version that is only added.
stub_dkms_set() {
    local v k st out=''
    while read -r v k st; do
        [[ $v == "$1" && ( $k == "$2" || $2 == '*' ) ]] || out+="$v $k $st"$'\n'
    done <"$FIX/dkms.state"
    [[ -z ${3:-} ]] || out+="$1 $2 $3"$'\n'
    printf '%s' "$out" >"$FIX/dkms.state"
}

# `dkms status` prints STUB_DKMS_STATUS if set. Otherwise dkms keeps its state
# in $FIX/dkms.state, so add, build, install and remove work as in real life.
dkms() {
    local cmd=$1 ver='' kernel='' all=0 v k st found
    shift
    while (( $# )); do
        case $1 in
            -m) shift ;;
            -v) ver=$2; shift ;;
            -k) kernel=$2; shift ;;
            --all) all=1 ;;
            */*) ver=${1#*/} ;;
        esac
        shift
    done
    touch "$FIX/dkms.state"
    case $cmd in
        status)
            if [[ -n $STUB_DKMS_STATUS ]]; then
                printf '%s\n' "$STUB_DKMS_STATUS"
                return 0
            fi
            found=0
            while read -r v k st; do
                [[ -z $ver || $v == "$ver" ]] || continue
                [[ $k != - && ( -z $kernel || $k == "$kernel" ) ]] || continue
                printf 'nvidia/%s, %s, x86_64: %s\n' "$v" "$k" "$st"
                found=1
            done <"$FIX/dkms.state"
            # Like dkms: "added" only for a version without any build.
            if (( ! found )) && grep -q "^$ver - " "$FIX/dkms.state"; then
                printf 'nvidia/%s: added\n' "$ver"
            fi ;;
        add) stub_dkms_set "$ver" - added ;;
        build)
            [[ $kernel != "$STUB_BUILD_FAIL" ]] || return 1
            stub_dkms_set "$ver" "$kernel" built ;;
        install) stub_dkms_set "$ver" "$kernel" installed ;;
        remove)
            if (( all )); then stub_dkms_set "$ver" '*'; else stub_dkms_set "$ver" "$kernel"; fi ;;
        *) echo "unexpected: dkms $cmd" >&2; return 99 ;;
    esac
    return 0
}

modinfo() { # modinfo -k <kernel> -n|-F version nvidia
    local e k path ver
    for e in "${STUB_MODINFO[@]}"; do
        read -r k path ver <<<"$e"
        [[ $k == "$2" ]] || continue
        if [[ $3 == -n ]]; then printf '%s\n' "$path"; else printf '%s\n' "$ver"; fi
        return 0
    done
    return 1
}

limine-mkinitcpio() {
    printf '%s\n' "$*" >>"$FIX/limine.calls"
    printf '%s\n' "${STUB_LIMINE_OUTPUT:-==> Initcpio image generation successful}"
}

reset_stubs() {
    STUB_INSTALLED=() STUB_PROVIDES=() STUB_OWNED=() STUB_REPO=() STUB_DKMS_STATUS='' STUB_MODINFO=()
    STUB_DOWNLOAD_FAIL='' STUB_BUILD_FAIL=''
    : >"$FIX/dkms.state"
    UTILS_PKG='' DKMS_PKG='' PREBUILT_SUFFIX='' HOOK_MODE=0 HOOK_TARGETS=() INSTALLING=0 NOTES_ON_FAIL=0
    rm -f "$FIX/limine.calls"
}
has_line() { grep -qxF -- "$1" <<<"$2"; }
has_text() { grep -qF -- "$1" <<<"$2"; }

# No mkinitcpio config unless a test creates one: initramfs_has_nvidia says unknown.
MKINITCPIO_CONF=$FIX/etc/mkinitcpio.conf
MKINITCPIO_PRESETS=$FIX/etc/mkinitcpio.d

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
t_eq "detect: 580xx prebuilt module suffix" "$PREBUILT_SUFFIX" nvidia-580xx

reset_stubs
STUB_INSTALLED=("nvidia-utils 620.70.06-2")
detect_driver
t_eq "detect: current (RTX) line" "$UTILS_PKG -> $DKMS_PKG" "nvidia-utils -> nvidia-open-dkms"
t_eq "detect: current prebuilt module suffix" "$PREBUILT_SUFFIX" nvidia-open

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
# Per [Trigger] section: "<type> <operations> : <targets>"
hook_triggers=$(awk '
    function flush() { if (type != "") print type, ops ":" targets; type = ops = targets = "" }
    /^\[/ { flush() }
    /^Type = / { type = $3 }
    /^Operation = / { ops = ops " " $3 }
    /^Target = / { targets = targets " " $3 }
    END { flush() }' <<<"$hook")
t_true "hook: nvidia-utils and this package trigger on install and upgrade only" has_line \
    "Package  Install Upgrade: nvidia-580xx-utils nvidia-utils eac-dkms-workaround eac-dkms-workaround-git" "$hook_triggers"
t_true "hook: only the DKMS packages trigger on package removal" has_line \
    "Package  Remove: nvidia-580xx-dkms nvidia-open-dkms" "$hook_triggers"
t_eq "hook: three triggers" "$(wc -l <<<"$hook_triggers")" 3
print_hook "$SELF_DEST" >"$FIX/current.hook"
t_true "hook_is_current: the hook this version writes" hook_is_current "$FIX/current.hook"
grep -v 'vmlinuz' "$FIX/current.hook" >"$FIX/old.hook"
t_false "hook_is_current: a hook without the vmlinuz trigger" hook_is_current "$FIX/old.hook"
t_false "hook_is_current: no hook file" hook_is_current "$FIX/missing.hook"

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

# ---- kernels without a module --------------------------------------------
# An EAC kernel is uncovered without its prebuilt module, with or without headers.
mkkernel 7.3.4-1-cachyos-eac headers
echo linux-cachyos-eac >"$MOD_ROOT/7.3.4-1-cachyos-eac/pkgbase"
mkkernel 7.9.9-1-custom-eac
t_eq "uncovered: EAC kernels without their prebuilt module" \
    "$(uncovered_kernels | LC_ALL=C sort | paste -sd' ')" \
    "6.17.8-hardened1-1-hardened 7.3.4-1-cachyos-eac 7.9.9-1-custom-eac"
t_false "eligible: never an EAC kernel, even with headers" has_line 7.3.4-1-cachyos-eac "$(eligible_kernels)"

reset_stubs
t_eq "hint: EAC kernel, no driver detected" "$(missing_module_hint 7.3.4-1-cachyos-eac)" \
    "install its prebuilt NVIDIA module package (linux-cachyos-eac-nvidia-*)"
t_eq "hint: no headers, unknown pkgbase" "$(missing_module_hint 6.17.8-hardened1-1-hardened)" \
    "install its headers package so DKMS can build for it"
t_eq "hint: headers but no module yet" "$(missing_module_hint 6.17.8-zen1-1-zen)" "run sudo eac-dkms-workaround sync"
echo linux-hardened >"$MOD_ROOT/6.17.8-hardened1-1-hardened/pkgbase"
t_eq "hint: no headers, known pkgbase" "$(missing_module_hint 6.17.8-hardened1-1-hardened)" \
    "install linux-hardened-headers so DKMS can build for it"

STUB_INSTALLED=("nvidia-utils 620.70.06-2")
detect_driver
t_eq "hint: EAC kernel on the nvidia-utils line" "$(missing_module_hint 7.3.4-1-cachyos-eac)" \
    "sudo pacman -S --needed linux-cachyos-eac-nvidia-open"
echo linux-custom-eac >"$MOD_ROOT/7.9.9-1-custom-eac/pkgbase"
t_eq "hint: the package follows the EAC kernel's pkgbase" "$(missing_module_hint 7.9.9-1-custom-eac)" \
    "sudo pacman -S --needed linux-custom-eac-nvidia-open"
rm -f "$MOD_ROOT/7.9.9-1-custom-eac/pkgbase"

reset_stubs
STUB_INSTALLED=("nvidia-580xx-utils 580.196.07-2")
STUB_PROVIDES=("nvidia-utils nvidia-580xx-utils")
detect_driver
t_eq "hint: EAC kernel with an unknown pkgbase" "$(missing_module_hint 7.9.9-1-custom-eac)" \
    "install its prebuilt NVIDIA module package (<kernel package>-nvidia-580xx)"
rm -rf "$MOD_ROOT/7.9.9-1-custom-eac"
t_eq "hint: EAC kernel on the 580xx line" "$(missing_module_hint 7.3.4-1-cachyos-eac)" \
    "sudo pacman -S --needed linux-cachyos-eac-nvidia-580xx"
warnings=$(warn_uncovered 2>&1)
t_true "warn_uncovered: EAC kernel, 580xx line" has_line \
    "==> WARNING: EAC kernel 7.3.4-1-cachyos-eac has no nvidia module: sudo pacman -S --needed linux-cachyos-eac-nvidia-580xx" "$warnings"
t_true "warn_uncovered: names the headers package" has_line \
    "==> WARNING: kernel 6.17.8-hardened1-1-hardened has no nvidia module: install linux-hardened-headers so DKMS can build for it" "$warnings"
t_eq "warn_uncovered: one line per uncovered kernel" "$(wc -l <<<"$warnings")" 2

# A sync that fails still reports them (fail exits, so run it in a subshell).
out=$( (HOOK_MODE=1 NOTES_ON_FAIL=1; fail "download failed") 2>&1)
t_eq "fail: exits 0 in hook mode" $? 0
t_true "fail: prints the error" has_line "==> ERROR: download failed" "$out"
t_true "fail: still warns about the EAC kernel" has_text "EAC kernel 7.3.4-1-cachyos-eac has no nvidia module" "$out"
out=$( (NOTES_ON_FAIL=0; fail "no driver") 2>&1)
t_eq "fail: exits 1 outside a hook" $? 1
t_false "fail: no notes before the driver line is known" has_text "has no nvidia module" "$out"

# ---- status ----------------------------------------------------------------
STUB_INSTALLED+=("dkms 3.1-1")
STUB_MODINFO=("6.17.8-zen1-1-zen $MOD_ROOT/6.17.8-zen1-1-zen/updates/dkms/nvidia.ko.zst 580.196.07")
saved_src=$SRC_ROOT
SRC_ROOT=$FIX/src-empty
mkdir -p "$SRC_ROOT"
out=$(cmd_status 2>&1)
t_false "status: fails when a kernel has no module" test $? -eq 0
t_true "status: EAC kernel names its module package" has_text \
    "7.3.4-1-cachyos-eac      linux-cachyos-eac    MISSING: sudo pacman -S --needed linux-cachyos-eac-nvidia-580xx" "$out"
t_true "status: names the headers package" has_text \
    "MISSING: install linux-hardened-headers so DKMS can build for it" "$out"
t_true "status: a kernel with a DKMS module" has_text "6.17.8-zen1-1-zen        ?                    dkms (580.196.07)" "$out"
t_false "status: no mkinitcpio remark when it is unknown whether nvidia is in the initramfs" has_text "mkinitcpio fails" "$out"
SRC_ROOT=$saved_src
rm -rf "$MOD_ROOT/7.3.4-1-cachyos-eac" "$MOD_ROOT/6.17.8-hardened1-1-hardened/pkgbase"

# ---- the eac-setup note ---------------------------------------------------
# eac-setup greps the installed package names for nvidia-580xx / nvidia-open.
reset_stubs
STUB_INSTALLED=("nvidia-utils 620.70.06-2" "nvidia-settings 620.70.06-1")
detect_driver
rm -rf "$MOD_ROOT/7.3.3-2-cachyos-eac"
t_eq "eac_setup_note: silent outside an install" "$(eac_setup_note 2>&1)" ''
INSTALLING=1
note=$(eac_setup_note 2>&1)
t_true "eac_setup_note: nvidia-utils line without a *nvidia-open* package" has_line \
    "==>   sudo pacman -S --needed linux-cachyos-eac-nvidia-open" "$note"
STUB_INSTALLED+=("linux-cachyos-nvidia-open 7.3.3-1")
t_eq "eac_setup_note: silent when eac-setup will find a *nvidia-open* package" "$(eac_setup_note 2>&1)" ''
STUB_INSTALLED=("nvidia-utils 620.70.06-2")
mkkernel 7.3.3-2-cachyos-eac '' prebuilt
t_eq "eac_setup_note: silent once an EAC kernel is installed" "$(eac_setup_note 2>&1)" ''
rm -rf "$MOD_ROOT/7.3.3-2-cachyos-eac"
reset_stubs
STUB_INSTALLED=("nvidia-580xx-utils 580.196.07-2")
STUB_PROVIDES=("nvidia-utils nvidia-580xx-utils")
detect_driver
INSTALLING=1
t_eq "eac_setup_note: silent on the 580xx line, which eac-setup detects" "$(eac_setup_note 2>&1)" ''
mkkernel 7.3.3-2-cachyos-eac '' prebuilt
reset_stubs
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

# ---- is nvidia in the initramfs -------------------------------------------
t_eq "initramfs_has_nvidia: unknown without a mkinitcpio config" "$(initramfs_has_nvidia)" unknown
mkdir -p "$FIX/etc/mkinitcpio.conf.d" "$FIX/etc/mkinitcpio.d"
printf 'MODULES=()\nHOOKS=(base udev autodetect kms block filesystems)\n' >"$MKINITCPIO_CONF"
t_eq "initramfs_has_nvidia: no" "$(initramfs_has_nvidia)" no
# What current chwd writes: it only drops the kms hook.
# shellcheck disable=SC2016  # literal config text
printf 'HOOKS=(${HOOKS[@]/kms/})\n' >"$FIX/etc/mkinitcpio.conf.d/10-chwd-kms.conf"
t_eq "initramfs_has_nvidia: no with chwd's 10-chwd-kms.conf" "$(initramfs_has_nvidia)" no
printf 'MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' >"$FIX/etc/mkinitcpio.conf.d/10-chwd.conf"
t_eq "initramfs_has_nvidia: yes with a drop-in that adds it" "$(initramfs_has_nvidia)" yes
printf 'MODULES=(btrfs)\n' >"$FIX/etc/mkinitcpio.conf.d/9-reset.conf"
t_eq "initramfs_has_nvidia: drop-ins apply in version order (9 before 10)" "$(initramfs_has_nvidia)" yes
reset_stubs
SRC_ROOT=$FIX/src-empty
t_true "status: says that mkinitcpio fails when nvidia is in the initramfs" has_text \
    "(nvidia is in the initramfs, so mkinitcpio fails for this kernel)" "$(cmd_status 2>&1)"
SRC_ROOT=$saved_src
mv "$FIX/etc/mkinitcpio.conf.d/9-reset.conf" "$FIX/etc/mkinitcpio.conf.d/20-reset.conf"
t_eq "initramfs_has_nvidia: a later drop-in can remove it again" "$(initramfs_has_nvidia)" no
rm -f "$FIX/etc/mkinitcpio.conf.d/20-reset.conf"
printf '#ALL_config="/etc/mkinitcpio.conf"\nPRESETS=(default)\n' >"$FIX/etc/mkinitcpio.d/linux.preset"
t_eq "initramfs_has_nvidia: a commented preset config changes nothing" "$(initramfs_has_nvidia)" yes
printf 'default_config="/etc/mkinitcpio-custom.conf"\n' >>"$FIX/etc/mkinitcpio.d/linux.preset"
t_eq "initramfs_has_nvidia: unknown when a preset has its own config" "$(initramfs_has_nvidia)" unknown
rm -f "$FIX/etc/mkinitcpio.d/linux.preset"
printf 'MODULES=(\n' >"$FIX/etc/mkinitcpio.conf.d/30-broken.conf"
t_eq "initramfs_has_nvidia: unknown when the config can't be read" "$(initramfs_has_nvidia)" unknown
rm -f "$FIX/etc/mkinitcpio.conf.d/30-broken.conf"

# ---- initramfs regeneration decision -------------------------------------
# nvidia is in the initramfs here (10-chwd.conf above).
limine_calls() { cat "$FIX/limine.calls" 2>/dev/null; rm -f "$FIX/limine.calls"; }
echo linux-zen >"$MOD_ROOT/6.17.8-zen1-1-zen/pkgbase"
reset_stubs
UTILS_PKG=nvidia-580xx-utils
utils_ships_firmware() { return 0; }
HOOK_MODE=1
HOOK_TARGETS=(nvidia-580xx-utils)
regen_initramfs 7.2.15-arch1-1 2>/dev/null
t_eq "regen: skipped when the utils firmware change triggers mkinitcpio" "$(limine_calls)" ''

HOOK_TARGETS=(eac-dkms-workaround)
regen_initramfs 7.2.15-arch1-1 2>/dev/null
t_eq "regen: runs for the kernel's package when triggered by the package itself" "$(limine_calls)" linux

HOOK_TARGETS=(eac-dkms-workaround-git nvidia-open-dkms)
regen_initramfs 7.2.15-arch1-1 2>/dev/null
t_eq "regen: skipped when the removed DKMS package triggers mkinitcpio" "$(limine_calls)" ''

HOOK_TARGETS=(usr/lib/modules/7.2.15-arch1-1/vmlinuz usr/lib/modules/7.2.15-arch1-1/build/include/)
regen_initramfs 7.2.15-arch1-1 6.17.8-zen1-1-zen 2>/dev/null
t_eq "regen: skips a kernel that is installed in the same transaction" "$(limine_calls)" linux-zen

HOOK_TARGETS=(usr/lib/modules/6.17.8-zen1-1-zen/extramodules/nvidia.ko.zst)
regen_initramfs 7.2.15-arch1-1 6.17.8-zen1-1-zen 2>/dev/null
t_eq "regen: skips a kernel whose prebuilt module changes in the same transaction" "$(limine_calls)" linux

HOOK_MODE=0
regen_initramfs 7.2.15-arch1-1 2>/dev/null
t_eq "regen: a manual sync ignores leftover hook targets" "$(limine_calls)" linux
HOOK_TARGETS=()

STUB_LIMINE_OUTPUT="==> ERROR: module not found: 'nvidia'"
t_false "regen: reports mkinitcpio errors" regen_initramfs 7.2.15-arch1-1 2>/dev/null
unset STUB_LIMINE_OUTPUT
rm -f "$FIX/limine.calls"

rm -f "$FIX/etc/mkinitcpio.conf.d/10-chwd.conf"
out=$(regen_initramfs 7.2.15-arch1-1 2>&1)
t_eq "regen: nothing to do when nvidia is not in the initramfs" "$(limine_calls)" ''
t_true "regen: says why it did nothing" has_text "mkinitcpio does not put nvidia into it" "$out"

rm -f "$MKINITCPIO_CONF"
regen_initramfs 7.2.15-arch1-1 2>/dev/null
t_eq "regen: runs when it is unknown whether nvidia is in the initramfs" "$(limine_calls)" linux

# ---- sync, end to end ------------------------------------------------------
# The steps of a real setup (install over nvidia-open-dkms, eac-setup, chwd, a
# driver update), with pacman and dkms replaced by the stubs above. Every sync
# runs in a subshell, because it takes a lock and may exit.
need_root() { :; }
reset_stubs
SRC_ROOT=$FIX/sync-src
MOD_ROOT=$FIX/sync-modules
PACMAN_SYNC_DB=$FIX/sync-db
mkdir -p "$SRC_ROOT" "$PACMAN_SYNC_DB" "$FIX/repo"
make_fake_pkg "$FIX/repo/nvidia-open-dkms-620.70.06-2-x86_64.pkg.tar.zst" 620.70.06 620.70.06
mkkernel 7.2.15-zen1-1-zen headers
echo linux-zen >"$MOD_ROOT/7.2.15-zen1-1-zen/pkgbase"
mkkernel 7.3.3-1-cachyos headers
echo linux-cachyos >"$MOD_ROOT/7.3.3-1-cachyos/pkgbase"
STUB_INSTALLED=("nvidia-utils 620.70.06-2" "dkms 3.1-1" "eac-dkms-workaround-git 0.1.0-1")
STUB_PROVIDES=("eac-dkms-workaround eac-dkms-workaround-git")
STUB_REPO=("nvidia-open-dkms 620.70.06-2")
# nvidia is in the initramfs, as with the 10-chwd.conf of older chwd versions.
printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' >"$MKINITCPIO_CONF"
sync_hook() { printf '%s\n' "$@" | (cmd_sync --hook) 2>&1; }
tree=$SRC_ROOT/nvidia-620.70.06
staging_before=$(compgen -G '/var/tmp/eac-dkms.*' | wc -l)

# 1. The package is installed and replaces nvidia-open-dkms.
out=$(sync_hook eac-dkms-workaround-git nvidia-open-dkms)
t_eq "sync: extracts the tree with its marker" "$(cat "$tree/$MARKER" 2>/dev/null)" 620.70.06-2
t_eq "sync: DKMS pattern for both kernels" "$(current_exclusive "$tree/dkms.conf")" \
    '^[0-9]+(\.[0-9]+)*(-[0-9]+-cachyos|-zen[0-9]+-[0-9]+-zen)$'
t_eq "sync: installed for both kernels" "$(dkms_kernels 620.70.06 | paste -sd' ')" "7.2.15-zen1-1-zen 7.3.3-1-cachyos"
t_eq "sync: leaves the initramfs to mkinitcpio's hook, which the removed DKMS package triggers" "$(limine_calls)" ''
t_true "sync: at install, says that eac-setup will miss the EAC module" has_line \
    "==>   sudo pacman -S --needed linux-cachyos-eac-nvidia-open" "$out"
t_eq "sync: leaves no staging directory" "$(compgen -G '/var/tmp/eac-dkms.*' | wc -l)" "$staging_before"

# 2. eac-setup installs linux-cachyos-eac without its NVIDIA module.
mkkernel 7.3.3-2-cachyos-eac
echo linux-cachyos-eac >"$MOD_ROOT/7.3.3-2-cachyos-eac/pkgbase"
out=$(sync_hook usr/lib/modules/7.3.3-2-cachyos-eac/vmlinuz)
t_true "sync: nothing to build when the EAC kernel arrives" has_line \
    "==> nvidia-open-dkms 620.70.06-2 is up to date for: 7.2.15-zen1-1-zen 7.3.3-1-cachyos" "$out"
t_true "sync: warns that the EAC kernel has no module" has_line \
    "==> WARNING: EAC kernel 7.3.3-2-cachyos-eac has no nvidia module: sudo pacman -S --needed linux-cachyos-eac-nvidia-open" "$out"
t_false "sync: the eac-setup note is for installs only" has_text "eac-setup will not" "$out"

# 3. Prebuilt modules arrive for linux-cachyos and the EAC kernel.
mkkernel 7.3.3-1-cachyos headers prebuilt
mkkernel 7.3.3-2-cachyos-eac '' prebuilt
STUB_INSTALLED+=("linux-cachyos-nvidia-open 7.3.3-1" "linux-cachyos-eac-nvidia-open 7.3.3-2")
out=$(sync_hook usr/lib/modules/7.3.3-1-cachyos/extramodules/nvidia.ko.zst \
    usr/lib/modules/7.3.3-2-cachyos-eac/extramodules/nvidia.ko.zst)
t_eq "sync: drops the DKMS build of a kernel that got a prebuilt module" "$(dkms_kernels 620.70.06)" 7.2.15-zen1-1-zen
t_eq "sync: narrows the DKMS pattern" "$(current_exclusive "$tree/dkms.conf")" '^[0-9]+(\.[0-9]+)*(-zen[0-9]+-[0-9]+-zen)$'
t_eq "sync: leaves that kernel's initramfs to mkinitcpio's hook" "$(limine_calls)" ''
t_false "sync: no warning once every kernel has a module" has_text WARNING "$out"

# 4. A manual sync has nothing to do.
out=$( (cmd_sync) 2>&1)
t_eq "sync: up to date" "$out" "==> nvidia-open-dkms 620.70.06-2 is up to date for: 7.2.15-zen1-1-zen"

# 5. A sync that fails keeps the working module, and still reports an EAC
#    kernel without a module.
rm -rf "$MOD_ROOT/7.3.3-2-cachyos-eac/extramodules"
STUB_INSTALLED[0]="nvidia-utils 621.0-1"
out=$(sync_hook nvidia-utils)
t_eq "sync: a failed hook run exits 0" $? 0
t_true "sync: fails when the repo has no DKMS package for the driver" has_text \
    "==> ERROR: nvidia-utils 621.0-1 needs nvidia-open-dkms 621.0, but the repo has 620.70.06-2" "$out"
t_true "sync: a failed run still warns about the EAC kernel" has_text \
    "EAC kernel 7.3.3-2-cachyos-eac has no nvidia module" "$out"

make_fake_pkg "$FIX/repo/nvidia-open-dkms-621.0-1-x86_64.pkg.tar.zst" 621.0 621.0
STUB_REPO=("nvidia-open-dkms 621.0-1")
STUB_DOWNLOAD_FAIL=1
out=$( (cmd_sync) 2>&1)
t_eq "sync: a failed manual run exits 1" $? 1
t_true "sync: reports the failed download" has_line "==> ERROR: download of nvidia-open-dkms 621.0-1 failed" "$out"
t_true "sync: a failed download still warns about the EAC kernel" has_text \
    "EAC kernel 7.3.3-2-cachyos-eac has no nvidia module" "$out"
STUB_DOWNLOAD_FAIL=''

STUB_BUILD_FAIL=7.2.15-zen1-1-zen
out=$(sync_hook nvidia-utils)
t_true "sync: reports the failed build" has_line "==> ERROR: dkms build of nvidia/621.0 failed" "$out"
t_false "sync: removes the tree that did not build" test -e "$SRC_ROOT/nvidia-621.0"
t_eq "sync: the old module survives failed runs" "$(dkms_kernels 620.70.06)" 7.2.15-zen1-1-zen
t_true "sync: the old tree survives failed runs" test -f "$tree/$MARKER"
t_eq "sync: failed runs leave no staging directory" "$(compgen -G '/var/tmp/eac-dkms.*' | wc -l)" "$staging_before"
STUB_BUILD_FAIL=''
mkkernel 7.3.3-2-cachyos-eac '' prebuilt

# 6. The driver update goes through.
out=$(sync_hook nvidia-utils)
t_eq "sync: builds the new driver" "$(dkms_kernels 621.0)" 7.2.15-zen1-1-zen
t_false "sync: removes the old tree" test -e "$tree"
t_eq "sync: removes the old DKMS entry" "$(dkms status -m nvidia -v 620.70.06)" ''
t_eq "sync: leaves the initramfs to mkinitcpio's hook after a driver update" "$(limine_calls)" ''

# 7. Headers of a new kernel flavor, installed on their own.
mkkernel 6.12.58-1-lts headers
echo linux-lts >"$MOD_ROOT/6.12.58-1-lts/pkgbase"
out=$(sync_hook usr/lib/modules/6.12.58-1-lts/build/include/)
t_eq "sync: builds for a kernel that got headers" "$(dkms_kernels 621.0 | paste -sd' ')" "7.2.15-zen1-1-zen 6.12.58-1-lts"
t_eq "sync: regenerates the initramfs of that kernel only" "$(limine_calls)" linux-lts

# 8. clean removes everything sync created.
out=$( (cmd_clean) 2>&1)
t_eq "clean: removes the managed tree" "$(managed_trees)" ''
t_eq "clean: removes the DKMS entries" "$(cat "$FIX/dkms.state")" ''

# ---- summary --------------------------------------------------------------
printf '1..%d\n' "$ntest"
printf '# %d passed, %d failed\n' "$npass" "$nfail"
(( nfail == 0 ))
