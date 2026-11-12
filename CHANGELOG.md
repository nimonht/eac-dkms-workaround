# Changelog

## Unreleased

- Warn when the EAC kernel has no NVIDIA module, and name the package to install (`linux-cachyos-eac-nvidia-open` or `-580xx`). `eac-setup` looks for an installed package named `*nvidia-open*`, so once this package replaces `nvidia-open-dkms` it installs the EAC kernel without its module. `sync` warns about it, `status` names the package, and the hook also runs when a kernel is installed, upgraded or removed, so the warning shows up in `eac-setup`'s own transaction.
- The post-install message says how to install the EAC module.
- Initramfs messages no longer assume chwd puts nvidia into the initramfs. Current chwd (`10-chwd-kms.conf`) doesn't.

## 0.1.0

First release.

- Keeps DKMS-built NVIDIA modules for every kernel that has headers and no prebuilt module (`linux`, `linux-lts`, `linux-zen`, `linux-hardened`, AUR kernels), next to CachyOS's prebuilt EAC kernel module, which conflicts with the DKMS packages.
- Never installs the DKMS package: pacman downloads it into a throwaway database (signature checked, mirror failover). Only `/usr/src/nvidia-<ver>/` is extracted, and DKMS is limited to the right kernels with a `BUILD_EXCLUSIVE_KERNEL` pattern per kernel flavor, so official DKMS kernel updates keep working.
- A pacman hook syncs on NVIDIA driver updates, on its own install, and when kernel headers or prebuilt modules are added or removed.
- Driver lines: `nvidia-580xx-utils` → `nvidia-580xx-dkms` and `nvidia-utils` → `nvidia-open-dkms`.
- Safe updates: the new version is downloaded and built before the old one is removed, so a failed download or build keeps the working module.
- Commands: `status`, `sync`, `clean`, `fetch-test`, `print-hook`, plus `install` / `uninstall` for manual installs.
- AUR packaging (`eac-dkms-workaround`, `eac-dkms-workaround-git`), 72 offline tests, CI with shellcheck, namcap and a makepkg build.
