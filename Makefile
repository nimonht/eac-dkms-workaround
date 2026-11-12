# Packaging install: make DESTDIR="$pkgdir" install
# (for a manual install use: sudo ./eac-dkms-workaround install)

NAME    := eac-dkms-workaround
HOOK    := 80-$(NAME).hook
PREFIX  ?= /usr
BINDIR  ?= $(PREFIX)/bin
HOOKDIR ?= $(PREFIX)/share/libalpm/hooks
DOCDIR  ?= $(PREFIX)/share/doc/$(NAME)
AURDIR  := packaging/aur

all: $(HOOK)

$(HOOK): $(NAME)
	bash ./$(NAME) print-hook $(BINDIR)/$(NAME) >$@

check:
	bash -n $(NAME)
	@if command -v shellcheck >/dev/null; then shellcheck $(NAME); else echo "shellcheck not installed, skipped"; fi
	@cmp -s $(AURDIR)/$(NAME)/$(NAME).install $(AURDIR)/$(NAME)-git/$(NAME).install \
	    || { echo "the two $(NAME).install files differ"; exit 1; }

install: all
	install -Dm755 $(NAME) $(DESTDIR)$(BINDIR)/$(NAME)
	install -Dm644 $(HOOK) $(DESTDIR)$(HOOKDIR)/$(HOOK)
	install -Dm644 README.md $(DESTDIR)$(DOCDIR)/README.md

# Regenerate .SRCINFO for both AUR packages after editing a PKGBUILD.
srcinfo:
	cd $(AURDIR)/$(NAME) && makepkg --printsrcinfo >.SRCINFO
	cd $(AURDIR)/$(NAME)-git && makepkg --printsrcinfo >.SRCINFO

clean:
	rm -f $(HOOK)

.PHONY: all check install srcinfo clean
