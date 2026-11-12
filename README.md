# eac-dkms-workaround

Run CachyOS's Easy Anti-Cheat kernel (`linux-cachyos-eac`) with its prebuilt NVIDIA module, and keep a DKMS-built NVIDIA module for the stock Arch `linux` kernel on the same system. Both keep working through normal `pacman -Syu` updates. One command removes everything once CachyOS fixes the package conflict.

## The problem

- The EAC module packages, `linux-cachyos-eac-nvidia-580xx` and `linux-cachyos-eac-nvidia-open`, provide `NVIDIA-MODULE`.
- The DKMS packages, `nvidia-580xx-dkms` and `nvidia-open-dkms`, declare `Conflicts = NVIDIA-MODULE`. So installing the EAC module removes DKMS, and the stock `linux` kernel is left without an NVIDIA module.
- CachyOS kernels have prebuilt modules (`linux-cachyos-nvidia-*`) that can be installed next to the EAC one. The stock `linux` kernel has no prebuilt module you can rely on:
  - Arch's `nvidia-open` is built for Arch's `nvidia-utils` version, not CachyOS's.
  - The CachyOS rebuild of it lags behind Arch kernel releases.
- chwd adds `MODULES+=(nvidia …)` to every initramfs. On a kernel with no module, mkinitcpio fails and `limine-mkinitcpio` skips that kernel. Its boot entry keeps the old vmlinuz and initramfs, so after a kernel update that entry boots with no loadable modules.

## How it works

- **The DKMS package is never installed.** `sync` downloads it with pacman itself and then:
  - extracts only `/usr/src/nvidia-<ver>/`,
  - appends `BUILD_EXCLUSIVE_KERNEL` so DKMS builds only for stock Arch kernels,
  - writes a marker file and registers the tree with DKMS.
- **Downloads go through pacman.** It uses a throwaway `--dbpath`, so it has its own lock. pacman checks the signature and falls back to other mirrors on failure.
- **Kernel updates:** the official DKMS hook rebuilds every `/usr/src/*/dkms.conf` for the new kernel. Nothing extra is needed.
- **Driver updates:** `80-eac-dkms-workaround.hook` runs `sync --hook` after the NVIDIA userspace package is installed or upgraded.
  - The hook sets `NetworkAccess = allowed`, because pacman ≥ 7.1 runs hooks without network.
  - The utils package ships firmware, so `90-mkinitcpio-install` then rebuilds every initramfs.
- **Failures don't make things worse.** The new version is downloaded and built before the old one is removed, so a failed download or build leaves the working module in place. In hook mode, `sync` always exits 0 and prints a retry command.
- **The script only touches what it created:** trees with its marker file that no package owns.

## Supported driver lines

The driver line is picked from the installed userspace package.

| Userspace package | DKMS source used | EAC module | GPUs | Tested |
|---|---|---|---|---|
| `nvidia-580xx-utils` | `nvidia-580xx-dkms` | `linux-cachyos-eac-nvidia-580xx` | Maxwell, Pascal, Volta (GTX 9xx/10xx) | yes (GTX 1050) |
| `nvidia-utils` | `nvidia-open-dkms` | `linux-cachyos-eac-nvidia-open` | Turing and newer (GTX 16xx, RTX) | detection only; same code path, not run on RTX hardware |

## Requirements

- Arch Linux with the CachyOS repositories, `linux-cachyos-eac` and the matching EAC NVIDIA module.
- `linux` and `linux-headers`.
- `dkms`, marked as explicitly installed so orphan cleanup doesn't remove it.
- Limine with `limine-mkinitcpio-hook`. On other boot setups `sync` asks you to regenerate the initramfs yourself.
- Don't install `linux-cachyos-eac-headers`. The EAC kernel must only use its prebuilt, CachyOS-signed module.

## Install

```sh
sudo snapper -c root create -d "before eac-dkms-workaround"   # optional safety net
sudo pacman -S --needed --asexplicit dkms linux-headers
# if you also use linux-cachyos, give it the prebuilt module for your driver line:
sudo pacman -S --needed linux-cachyos-nvidia-580xx            # or linux-cachyos-nvidia-open
sudo ./eac-dkms-workaround install
eac-dkms-workaround status
```

`install` copies the script to `/usr/local/bin/`, writes the pacman hook, then runs `sync`. `sync` builds the module for every stock Arch kernel and regenerates that kernel's initramfs.

## Commands

| Command | What it does |
|---|---|
| `sudo eac-dkms-workaround install` | Install the script and hook, then `sync` |
| `sudo eac-dkms-workaround sync` | Make the DKMS source match the installed driver and build it; does nothing if already current |
| `eac-dkms-workaround status` | Show the managed trees, `dkms status`, and the module each kernel uses. Flags missing or duplicate modules, version mismatches, and whether the official fix has landed |
| `sudo eac-dkms-workaround uninstall` | Remove the managed trees, their DKMS entries, the hook and the script |
| `sudo eac-dkms-workaround fetch-test` | Only download and signature-check the DKMS package, then clean up (diagnostic) |

## When CachyOS fixes the conflict

`status` reports `LIKELY LANDED` once the DKMS package no longer conflicts with anything installed. Then:

```sh
sudo eac-dkms-workaround uninstall      # first: the extracted files would collide with the package's
sudo pacman -S nvidia-580xx-dkms        # or nvidia-open-dkms
```

With the official DKMS package installed, DKMS builds for every kernel that has headers. If `linux-cachyos-headers` is installed, that DKMS copy overrides the prebuilt `linux-cachyos-nvidia-*` module, so remove one of the two.

## Switching to a newer GPU

Install the new driver line's packages (`nvidia-utils`, `linux-cachyos-eac-nvidia-open`, and optionally `linux-cachyos-nvidia-open`). The hook fires on `nvidia-utils`, builds `nvidia-open-dkms` for the stock kernel, and removes the old 580xx tree.

## Limits

- `KERNEL_ALLOW` (`-arch[0-9]+-[0-9]+$`) matches only the stock `linux` kernel. To cover `linux-lts` or `linux-zen` as well, edit the regex.
- If an NVIDIA driver fails to compile against a new Arch kernel, that kernel's initramfs build fails and Limine keeps its old entry. `status` shows the kernel as `MISSING`. The official DKMS package has the same risk.
