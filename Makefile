# Packaging install: make DESTDIR="$pkgdir" install
# (for a manual install use: sudo ./eac-dkms-workaround install)

NAME    := eac-dkms-workaround
HOOK    := 80-$(NAME).hook
PREFIX  ?= /usr
BINDIR  ?= $(PREFIX)/bin
HOOKDIR ?= $(PREFIX)/share/libalpm/hooks
DOCDIR  ?= $(PREFIX)/share/doc/$(NAME)
AURDIR  := packaging/aur
INSTALL_SCRIPTS := $(AURDIR)/$(NAME)/$(NAME).install $(AURDIR)/$(NAME)-git/$(NAME).install

all: $(HOOK)

$(HOOK): $(NAME)
	bash ./$(NAME) print-hook $(BINDIR)/$(NAME) >$@

# Static checks. shellcheck is skipped when missing (CI always runs it).
check:
	@for f in $(NAME) tests/run.sh $(INSTALL_SCRIPTS); do bash -n $$f || exit 1; done
	@if command -v shellcheck >/dev/null; then \
	    shellcheck -x $(NAME) tests/run.sh && shellcheck -s bash $(INSTALL_SCRIPTS); \
	else echo "shellcheck not installed, skipped"; fi
	@cmp -s $(INSTALL_SCRIPTS) || { echo "the two $(NAME).install files differ"; exit 1; }

# Offline unit tests: no root, network or pacman state needed.
test:
	bash tests/run.sh

install: all
	install -Dm755 $(NAME) $(DESTDIR)$(BINDIR)/$(NAME)
	install -Dm644 $(HOOK) $(DESTDIR)$(HOOKDIR)/$(HOOK)
	install -Dm644 README.md $(DESTDIR)$(DOCDIR)/README.md

# Regenerate .SRCINFO for both AUR packages after editing a PKGBUILD.
srcinfo:
	cd $(AURDIR)/$(NAME) && makepkg --printsrcinfo >.SRCINFO
	cd $(AURDIR)/$(NAME)-git && makepkg --printsrcinfo >.SRCINFO

# Fail when a .SRCINFO no longer matches its PKGBUILD.
srcinfo-check:
	@for d in $(AURDIR)/$(NAME) $(AURDIR)/$(NAME)-git; do \
	    (cd $$d && makepkg --printsrcinfo | diff -u .SRCINFO -) \
	        || { echo "$$d/.SRCINFO is stale: run make srcinfo"; exit 1; }; \
	done

clean:
	rm -f $(HOOK)

.PHONY: all check test install srcinfo srcinfo-check clean
