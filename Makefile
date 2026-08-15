APP_ID   ?= io.github.rulin132.ChatGPT
MANIFEST := $(APP_ID).yaml
REPO     ?= repo
BUILDDIR ?= build
LOCAL_REMOTE ?= $(APP_ID)-local
GPG_KEY  ?=
GPG_ARGS := $(if $(GPG_KEY),--gpg-sign=$(GPG_KEY),)

# The distros this package exists for cannot layer flatpak-builder, so fall
# back to the org.flatpak.Builder flatpak that `make deps` installs.
FB := $(shell command -v flatpak-builder 2>/dev/null || echo 'flatpak run org.flatpak.Builder')

.PHONY: help rename deps hashes icons inspect lint build install run bundle repo oci clean distclean

help:
	@echo "make rename GH_USER=<you>   set the app-id namespace across the repo (do this first)"
	@echo "make deps                   install flatpak runtimes/SDK/BaseApp from Flathub"
	@echo "make hashes                 fetch upstream .deb, pin sha256+size, sync version"
	@echo "make icons                  extract real icons from the .deb (replaces placeholders)"
	@echo "make inspect                dump the upstream .deb layout (debugging apply_extra)"
	@echo "make lint                   flatpak-builder-lint the manifest"
	@echo "make build                  build into $(REPO)"
	@echo "make install                build + install --user"
	@echo "make run                    run the installed app"
	@echo "make repo GPG_KEY=<id>      sign + generate static deltas + prune"
	@echo "make oci                    OCI image for a container registry"

rename:
	@test -n "$(GH_USER)" || { echo "usage: make rename GH_USER=<your-github-username>"; exit 1; }
	@for f in $$(grep -rl 'OWNER' --exclude-dir=.git --exclude-dir=build --exclude-dir=repo .); do \
	  sed -i "s/io\.github\.OWNER/io.github.$(GH_USER)/g; s|github\.com/OWNER|github.com/$(GH_USER)|g" "$$f"; \
	done
	@for f in $$(find . -name '*OWNER*' -not -path './.git/*'); do \
	  git mv "$$f" "$${f//OWNER/$(GH_USER)}" 2>/dev/null || mv "$$f" "$${f//OWNER/$(GH_USER)}"; \
	done
	@echo "renamed to io.github.$(GH_USER).ChatGPT, commit the result"

deps:
	flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
	flatpak install --user -y flathub \
	  org.freedesktop.Platform//25.08 org.freedesktop.Sdk//25.08 \
	  org.electronjs.Electron2.BaseApp//25.08
	flatpak install --user -y flathub org.flatpak.Builder

hashes:
	scripts/refresh-source.sh $(MANIFEST)

icons:
	scripts/extract-icons.sh

inspect:
	scripts/inspect-deb.sh

lint:
	flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest $(MANIFEST)

build:
	$(FB) --user --install-deps-from=flathub --force-clean \
	  --disable-rofiles-fuse --repo=$(REPO) $(GPG_ARGS) $(BUILDDIR) $(MANIFEST)

# Installing must happen outside the builder: apply_extra runs under bwrap, and
# bwrap cannot create a nested user namespace from inside the org.flatpak.Builder
# sandbox ("No permissions to create a new namespace").
#
# It also has to go through a remote rather than `build-bundle`. flatpak-builder
# records the extra-data source in the commit metadata, but `flatpak build-bundle`
# only copies it from *detached* metadata, so the bundle comes out with no
# vendor payload at all and installing it dies with "Extra data missing in
# detached metadata". Pulling from a repo reads the commit metadata and works.
install: build
	flatpak remote-add --user --if-not-exists --no-gpg-verify $(LOCAL_REMOTE) $(CURDIR)/$(REPO)
	flatpak install --user -y --reinstall $(LOCAL_REMOTE) $(APP_ID)

run:
	flatpak run $(APP_ID)

# Kept as a tombstone so `make bundle` explains itself instead of failing with
# "No rule to make target", and so nobody re-adds it from muscle memory.
bundle:
	@echo "make bundle: removed. flatpak build-bundle cannot carry an extra-data"
	@echo "source (flatpak#1334), so the .flatpak has no application payload and"
	@echo "installs to 'Extra data missing in detached metadata'."
	@echo "Use 'make install' locally, or the repo remote to distribute."
	@exit 1

repo: build
	flatpak build-update-repo $(GPG_ARGS) --generate-static-deltas --prune $(REPO)

oci: build
	flatpak build-bundle --oci --oci-layer-compress=zstd $(REPO) oci/$(APP_ID) $(APP_ID)

clean:
	rm -rf $(BUILDDIR) .flatpak-builder

distclean: clean
	rm -rf $(REPO) oci *.flatpak
