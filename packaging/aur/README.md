# AUR packaging

| Directory | AUR package | Source |
|---|---|---|
| `eac-dkms-workaround/` | `eac-dkms-workaround` | git tag `v$pkgver` |
| `eac-dkms-workaround-git/` | `eac-dkms-workaround-git` | latest `main` |

Each directory is the content of one AUR git repository: `PKGBUILD`, `.SRCINFO` and `eac-dkms-workaround.install`. The two `.install` files must stay identical; `make check` verifies this.

## Publishing a release

1. Set `pkgver=X.Y.Z` and `pkgrel=1` in `eac-dkms-workaround/PKGBUILD`.
2. From the repository root, run `make check srcinfo` to regenerate both `.SRCINFO` files.
3. Commit, tag and push:
   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin main --follow-tags
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
