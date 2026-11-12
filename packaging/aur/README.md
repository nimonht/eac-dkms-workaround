# AUR packaging

| Directory | AUR package | Source |
|---|---|---|
| `eac-dkms-workaround/` | `eac-dkms-workaround` | git tag `v$pkgver` |
| `eac-dkms-workaround-git/` | `eac-dkms-workaround-git` | latest `main` |

Each directory is the content of one AUR git repository: `PKGBUILD`, `.SRCINFO` and `eac-dkms-workaround.install`. The two `.install` files must stay identical; `make check` verifies this.

## Publishing a release

1. Set `pkgver=X.Y.Z` and `pkgrel=1` in `eac-dkms-workaround/PKGBUILD`.
2. From the repository root, run `make check srcinfo` to regenerate both `.SRCINFO` files.
3. Add the release to `CHANGELOG.md`, then commit, tag and push, and create the GitHub release:
   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin main --follow-tags
   gh release create vX.Y.Z --title vX.Y.Z --notes "$(awk '/^## /{p = ($2 == "X.Y.Z"); next} p' CHANGELOG.md)"
   ```
4. Test the build from GitHub:
   ```sh
   cd packaging/aur/eac-dkms-workaround
   makepkg -sf
   namcap PKGBUILD ./*.pkg.tar.zst   # optional
   ```
5. Push to the AUR. This needs your SSH key added to your aur.archlinux.org account.
   ```sh
   git clone ssh://aur@aur.archlinux.org/eac-dkms-workaround.git /tmp/aur-eac
   cp PKGBUILD .SRCINFO eac-dkms-workaround.install /tmp/aur-eac/
   cd /tmp/aur-eac && git add -A && git commit -m "Update to X.Y.Z" && git push
   ```
   Do the same for `eac-dkms-workaround-git`. It only needs a push when its `PKGBUILD` changes.

The first push to a new AUR package name creates that package.

## namcap

namcap reports nothing for the PKGBUILDs. On the built package it prints `Dependency included, but may not be needed` for every runtime dependency. Those warnings are false positives: namcap only detects dependencies through linked libraries, and this package is a shell script that calls `dkms`, `pacman`, `modinfo` (kmod), `bsdtar` (libarchive), `flock` (util-linux) and coreutils.
