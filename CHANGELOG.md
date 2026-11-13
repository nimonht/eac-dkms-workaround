# Changelog

## 0.2.0

- Warns when the EAC kernel has no NVIDIA module and prints the command that installs it, also when `sync` itself fails. `eac-setup` only installs that module if an installed package is named `*nvidia-open*` or `*nvidia-580xx*`, and on the `nvidia-utils` line that is often only `nvidia-open-dkms`, which this package replaces. At install, `sync` says when this applies.
- The EAC module packages are optional dependencies, so pacman lists them.
- The hook also runs when a kernel is installed, upgraded or removed, and when the official DKMS package is removed.
- The initramfs is regenerated only if nvidia is in it (`MODULES` in the mkinitcpio config and its drop-ins), and not when mkinitcpio's own pacman hook rebuilds it later in the same transaction. The first install no longer builds every initramfs twice.
- `status` names the package or command that fixes a kernel without a module, and reports a manual install whose hook file is from another version.
- Without `limine-mkinitcpio`, `sync` no longer tells you to run it.
- 157 tests, up from 72, including `sync` and `clean` end to end.

## 0.1.0

First release.

- Keeps DKMS-built NVIDIA modules for every kernel that has headers and no prebuilt module (`linux`, `linux-lts`, `linux-zen`, `linux-hardened`, AUR kernels), next to CachyOS's prebuilt EAC kernel module, which conflicts with the DKMS packages.
- Never installs the DKMS package: pacman downloads it into a throwaway database (signature checked, mirror failover). Only `/usr/src/nvidia-<ver>/` is extracted, and DKMS is limited to the right kernels with a `BUILD_EXCLUSIVE_KERNEL` pattern per kernel flavor, so official DKMS kernel updates keep working.
- A pacman hook syncs on NVIDIA driver updates, on its own install, and when kernel headers or prebuilt modules are added or removed.
- Driver lines: `nvidia-580xx-utils` → `nvidia-580xx-dkms` and `nvidia-utils` → `nvidia-open-dkms`.
- Safe updates: the new version is downloaded and built before the old one is removed, so a failed download or build keeps the working module.
- Commands: `status`, `sync`, `clean`, `fetch-test`, `print-hook`, plus `install` / `uninstall` for manual installs.
- AUR packaging (`eac-dkms-workaround`, `eac-dkms-workaround-git`), 72 offline tests, CI with shellcheck, namcap and a makepkg build.
