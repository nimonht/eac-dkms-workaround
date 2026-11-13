# Changelog

## Unreleased

EAC kernel without its NVIDIA module:

- `eac-setup` installs the EAC kernel's NVIDIA module only if the name of an installed package contains `nvidia-580xx` or `nvidia-open`. On the `nvidia-utils` line that is often only `nvidia-open-dkms`, which this package replaces. `sync` now warns when an EAC kernel has no NVIDIA module and prints the command that installs it. A `sync` that fails (download, build, repo out of step) prints the warning too.
- When the workaround is installed and `eac-setup` would miss the module, `sync` says so and names the package. This replaces the unconditional text in the post-install message, which was wrong for the 580xx line.
- The package to install follows the driver line and the kernel's own package name (`<kernel package>-nvidia-open` or `-nvidia-580xx`). `sync` and `status` share one hint for a kernel without a module.
- The EAC module packages are optional dependencies, so pacman lists them.

Hook:

- It also runs when a kernel is installed, upgraded or removed, so the warning shows up in `eac-setup`'s own transaction, and when the official DKMS package is removed.
- `status` reports a manual install whose hook file is from another version. Run `install` again to rewrite it.

Initramfs:

- `sync` regenerates an initramfs only if nvidia is in it. It reads `MODULES` from the mkinitcpio config and its drop-ins. Current chwd (`10-chwd-kms.conf`) leaves nvidia out; older versions (`10-chwd.conf`) put it in.
- In a pacman transaction, `sync` skips what mkinitcpio's own hook rebuilds right after: every kernel when the official DKMS package is removed (the first install built each initramfs twice), and a kernel that is installed or gets a prebuilt module in the same transaction.
- Without `limine-mkinitcpio`, `sync` no longer tells you to run it.

Messages and tests:

- A kernel whose package is unknown gets "install its headers package", not the package name `its-headers`.
- The "no kernel needs a DKMS build" message no longer contradicts the EAC warning after it.
- 157 tests, up from 72: `status`, the hints, the initramfs decisions, and `sync` and `clean` end to end with a stateful fake `dkms`.

## 0.1.0

First release.

- Keeps DKMS-built NVIDIA modules for every kernel that has headers and no prebuilt module (`linux`, `linux-lts`, `linux-zen`, `linux-hardened`, AUR kernels), next to CachyOS's prebuilt EAC kernel module, which conflicts with the DKMS packages.
- Never installs the DKMS package: pacman downloads it into a throwaway database (signature checked, mirror failover). Only `/usr/src/nvidia-<ver>/` is extracted, and DKMS is limited to the right kernels with a `BUILD_EXCLUSIVE_KERNEL` pattern per kernel flavor, so official DKMS kernel updates keep working.
- A pacman hook syncs on NVIDIA driver updates, on its own install, and when kernel headers or prebuilt modules are added or removed.
- Driver lines: `nvidia-580xx-utils` → `nvidia-580xx-dkms` and `nvidia-utils` → `nvidia-open-dkms`.
- Safe updates: the new version is downloaded and built before the old one is removed, so a failed download or build keeps the working module.
- Commands: `status`, `sync`, `clean`, `fetch-test`, `print-hook`, plus `install` / `uninstall` for manual installs.
- AUR packaging (`eac-dkms-workaround`, `eac-dkms-workaround-git`), 72 offline tests, CI with shellcheck, namcap and a makepkg build.
