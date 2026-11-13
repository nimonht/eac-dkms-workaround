# eac-dkms-workaround

Run CachyOS's Easy Anti-Cheat kernel (`linux-cachyos-eac`) with its prebuilt NVIDIA module, and keep DKMS-built NVIDIA modules for your other kernels on the same system, such as `linux`, `linux-lts`, `linux-zen`, `linux-hardened` or an AUR kernel. Everything keeps working through normal `pacman -Syu` updates. Removing the workaround removes everything it added, once CachyOS fixes the package conflict.

## The problem

- The EAC module packages, `linux-cachyos-eac-nvidia-580xx` and `linux-cachyos-eac-nvidia-open`, provide `NVIDIA-MODULE`.
- The DKMS packages, `nvidia-580xx-dkms` and `nvidia-open-dkms`, declare `Conflicts = NVIDIA-MODULE`. So installing the EAC module removes DKMS, and every kernel without a prebuilt module is left without an NVIDIA module.
- CachyOS kernels have prebuilt modules (`linux-cachyos-nvidia-*`) that can be installed next to the EAC one. Arch's own kernels have no prebuilt module you can rely on:
  - Arch's `nvidia-open` is built for Arch's `nvidia-utils` version, not CachyOS's.
  - The CachyOS rebuild of it lags behind Arch kernel releases.
- A kernel with no NVIDIA module boots without the NVIDIA driver. If the initramfs also contains nvidia (`MODULES+=(nvidia …)` in your mkinitcpio config, or in `/etc/mkinitcpio.conf.d/10-chwd.conf` from older chwd versions), it gets worse: mkinitcpio fails and `limine-mkinitcpio` skips that kernel. Its boot entry keeps the old vmlinuz and initramfs, so after a kernel update that entry boots with no loadable modules. Current chwd leaves nvidia out of the initramfs; its `10-chwd-kms.conf` only drops the `kms` hook.
- `eac-setup` picks the EAC NVIDIA module by looking for an installed package whose name contains `nvidia-580xx` or `nvidia-open`. On the `nvidia-utils` line, `nvidia-open-dkms` is often the only such package. Once this package replaces it, `eac-setup` installs the EAC kernel without its NVIDIA module, so install that yourself (see [Install](#install)). `sync` tells you when this applies.

## How it works

- **The DKMS package is never installed.** `sync` downloads it with pacman itself and then:
  - extracts only `/usr/src/nvidia-<ver>/`,
  - appends a `BUILD_EXCLUSIVE_KERNEL` block (see below),
  - writes a marker file and registers the tree with DKMS.
- **Downloads go through pacman.** It uses a throwaway `--dbpath`, so it has its own lock. pacman checks the signature and falls back to other mirrors on failure.
- **Which kernels get a DKMS build:** every installed kernel that has headers and no prebuilt `nvidia` module in `extramodules/`, except the EAC kernel. The EAC kernel only loads its CachyOS-signed prebuilt module.
- **Kernel updates:** `BUILD_EXCLUSIVE_KERNEL` holds one version-independent pattern per kernel flavor, for example `-[0-9]+-lts` or `-zen[0-9]+-[0-9]+-zen`. So the official DKMS hook rebuilds for new kernel versions on its own. It never builds for kernels that have prebuilt modules.
- **The pacman hook `80-eac-dkms-workaround.hook`** runs `sync --hook` when:
  - the NVIDIA driver is updated, this package is installed, or the official DKMS package is removed;
  - kernel headers are added or removed, so installing `linux-zen-headers` builds for zen;
  - a prebuilt module is added or removed. Installing `linux-cachyos-nvidia-*` drops the DKMS build that would otherwise shadow it;
  - a kernel is installed, upgraded or removed. Installing `linux-cachyos-eac` without its NVIDIA module prints a warning with the package to install.

  The hook sets `NetworkAccess = allowed`, because pacman ≥ 7.1 runs hooks without network.
- **The initramfs is only regenerated when needed.** After a module changed, `sync` runs `limine-mkinitcpio` for that kernel if both of these hold:
  - nvidia is in the initramfs. `sync` reads `MODULES` from `/etc/mkinitcpio.conf` and its drop-ins, as mkinitcpio does. If it can't tell, it regenerates.
  - mkinitcpio's own pacman hook (`90-mkinitcpio-install`) doesn't rebuild that initramfs later in the same transaction anyway. It does when the NVIDIA utils firmware changes, the official DKMS package is removed, the kernel itself is installed, or its prebuilt module changes.
- **Failures don't make things worse.** The new version is downloaded and built before the old one is removed, so a failed download or build leaves the working module in place. In hook mode, `sync` always exits 0 and prints a retry command. A failed run still reports kernels that have no module.
- **The script only touches what it created:** trees with its marker file that no package owns.

## Supported driver lines

The driver line is picked from the installed userspace package.

| Userspace package | DKMS source used | EAC module | GPUs | Tested |
|---|---|---|---|---|
| `nvidia-580xx-utils` | `nvidia-580xx-dkms` | `linux-cachyos-eac-nvidia-580xx` | Maxwell, Pascal, Volta (GTX 9xx/10xx) | yes |
| `nvidia-utils` | `nvidia-open-dkms` | `linux-cachyos-eac-nvidia-open` | Turing and newer (GTX 16xx, RTX) | yes |

## Requirements

- Arch Linux with the CachyOS repositories, `linux-cachyos-eac` and the matching EAC NVIDIA module.
- The headers package for each kernel that should get a DKMS build: `linux-headers`, `linux-lts-headers`, `linux-zen-headers`, and so on.
- pacman ≥ 7.1 and `dkms`. The package pulls in `dkms`.
- Limine with `limine-mkinitcpio-hook`. On other boot setups, regenerate the initramfs yourself after `sync` if nvidia is in it; `sync` says when.
- Don't install `linux-cachyos-eac-headers`. The EAC kernel must only use its prebuilt, CachyOS-signed module.
- CachyOS kernels work like any other: with their headers installed (e.g. `linux-cachyos-headers`), DKMS builds for them from the same source. Their prebuilt `linux-cachyos-nvidia-*` packages are optional. They skip the compile on updates and use about half the disk space, since DKMS keeps its own copy of every build. If you install one, DKMS leaves that kernel alone, so there is never more than one module per kernel.

## Install

### From the AUR (not published to the AUR yet)

```sh
paru -S eac-dkms-workaround        # or eac-dkms-workaround-git, or yay -S …
eac-dkms-workaround status
```

The package's hook runs `sync` at the end of the install transaction. `sync` downloads the DKMS source, builds the module for each kernel that needs it and regenerates their initramfs if nvidia is in it.

Then install the EAC kernel's NVIDIA module yourself, best before `sudo eac-setup`. Once `nvidia-open-dkms` is gone, `eac-setup` doesn't detect it (see [The problem](#the-problem)). At install, `sync` prints the command when `eac-setup` would miss the module on your system, and later it warns whenever the EAC kernel has none:

```sh
sudo pacman -S --needed linux-cachyos-eac-nvidia-open     # Turing and newer, with nvidia-utils
sudo pacman -S --needed linux-cachyos-eac-nvidia-580xx    # Maxwell, Pascal, Volta, with nvidia-580xx-utils
```

On the `nvidia-utils` line, `sudo chwd -a` installs it too, but only if chwd's NVIDIA profile isn't installed yet. Installing that profile adds `<kernel>-nvidia-open` for every `linux-cachyos*` kernel, so it also switches `linux-cachyos` to its prebuilt module. The hook then drops the DKMS build for that kernel.

### From this repository with makepkg

```sh
cd packaging/aur/eac-dkms-workaround-git
makepkg -si
```

### Manually, without a package

```sh
sudo pacman -S --needed --asexplicit dkms linux-headers   # plus the headers of your other kernels
sudo ./eac-dkms-workaround install     # → /usr/local/bin + /etc/pacman.d/hooks
```

Run `install` again after updating the script. It also rewrites the hook, whose triggers can change between versions; `status` reports a hook from another version.

## Commands

| Command | What it does |
|---|---|
| `eac-dkms-workaround status` | Show the managed trees, the kernel pattern, `dkms status`, and the module each kernel uses. Flags missing or duplicate modules (with the package to install or the command to run), version mismatches, an outdated manual-install hook, and whether the official fix has landed |
| `sudo eac-dkms-workaround sync` | Make the DKMS source match the installed driver and the installed kernels; does nothing if already current |
| `sudo eac-dkms-workaround clean` | Remove the managed source trees and their DKMS entries |
| `sudo eac-dkms-workaround fetch-test` | Only download and signature-check the DKMS package, then clean up (diagnostic) |
| `sudo eac-dkms-workaround install` / `uninstall` | Manual install / removal (not used with the package) |

## Removal, and when CachyOS fixes the conflict

`status` reports `LIKELY LANDED` once the DKMS package no longer conflicts with anything installed. Remove the workaround **first**, because the extracted files would collide with the official package's. Then install the official package:

```sh
sudo pacman -R eac-dkms-workaround           # package: pre_remove runs `clean`
# or, for a manual install: sudo eac-dkms-workaround uninstall
sudo pacman -S nvidia-580xx-dkms             # or nvidia-open-dkms
```

With the official DKMS package installed, DKMS builds for every kernel that has headers. If `linux-cachyos-headers` is installed, that DKMS copy overrides the prebuilt `linux-cachyos-nvidia-*` module, so remove one of the two.

## Switching to a newer GPU

Install the new driver line's packages (`nvidia-utils`, `linux-cachyos-eac-nvidia-open`, and optionally `linux-cachyos-nvidia-open`). The hook fires on `nvidia-utils`, builds `nvidia-open-dkms` for your kernels, and removes the old 580xx tree.

## Limits

- If an NVIDIA driver fails to compile against a new kernel, that kernel has no NVIDIA module. If nvidia is in the initramfs, its initramfs build also fails and Limine keeps its old entry. `status` shows the kernel as `MISSING`. The official DKMS package has the same risk.
- A kernel with neither headers nor a prebuilt module gets no NVIDIA module. `sync` and `status` warn about it and name the headers package to install.

## Testing

`make check test` runs the offline suite. It needs no root, no network and no NVIDIA hardware.
- `make check` runs `bash -n` and shellcheck over the script, the tests and the `.install` file.
- `make test` runs `tests/run.sh`: 157 tests that replace pacman, dkms, modinfo and limine-mkinitcpio with stubs and use fixture directories.
- The unit tests cover version handling, kernel flavor patterns and which kernels qualify, driver detection, the hook's content, the `dkms.conf` block, which source trees count as managed, `dkms status` parsing, extracting the source from a package, the hints for kernels without a module, `status`, whether nvidia is in the initramfs, and when the initramfs is regenerated.
- The end-to-end tests run `sync` and `clean` through a whole setup: installing over `nvidia-open-dkms`, `eac-setup` adding the EAC kernel, prebuilt modules arriving, a failed download, a failed build, a driver update and new kernel headers.

The PKGBUILDs run the same targets in `check()`. CI (`.github/workflows/ci.yml`) also runs namcap, `make srcinfo-check` and a full `makepkg` build in an Arch container.

## Notes

- **The conflict:** `nvidia-580xx-dkms` and `nvidia-open-dkms` have `conflicts=(NVIDIA-MODULE …)`, and `linux-cachyos-eac-nvidia-580xx` / `-open` provide `NVIDIA-MODULE`. So once the EAC kernel's module is installed, no DKMS NVIDIA module can be used for kernels CachyOS doesn't prebuild modules for, such as `linux`, `linux-lts`, `linux-zen` or a custom kernel.
- **Why the conflict is there:** a DKMS build would shadow a prebuilt module, because depmod searches `updates` before `extramodules`. This package avoids that by limiting DKMS (`BUILD_EXCLUSIVE_KERNEL`) to kernels without a prebuilt module.
- **What it changes on the system:** apart from its own packaged files, only marked, package-unowned trees under `/usr/src/nvidia-*` and their DKMS entries. Package-owned files are never modified.
- **When it becomes unnecessary:** once a DKMS package can be installed alongside the EAC module, this package isn't needed. `status` detects that case, and removing the package cleans up first.

## Packaging

`make DESTDIR=… install` installs the script to `/usr/bin` and the hook to `/usr/share/libalpm/hooks`.

The AUR packages are in [`packaging/aur/`](packaging/aur/). See [its README](packaging/aur/README.md) for how to publish a release.

## License

MIT, see [LICENSE](LICENSE).
