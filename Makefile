APP_ID   ?= io.github.OWNER.ChatGPT
MANIFEST := $(APP_ID).yaml
REPO     ?= repo
BUILDDIR ?= build
GPG_KEY  ?=
GPG_ARGS := $(if $(GPG_KEY),--gpg-sign=$(GPG_KEY),)

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
	@echo "make bundle                 single-file .flatpak for sideloading"
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
	@echo "renamed to io.github.$(GH_USER).ChatGPT — commit the result"

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
	flatpak-builder --user --install-deps-from=flathub --force-clean \
	  --disable-rofiles-fuse --repo=$(REPO) $(GPG_ARGS) $(BUILDDIR) $(MANIFEST)

install:
	flatpak-builder --user --install-deps-from=flathub --force-clean \
	  --disable-rofiles-fuse --install $(BUILDDIR) $(MANIFEST)

run:
	flatpak run $(APP_ID)

bundle: build
	flatpak build-bundle $(GPG_ARGS) \
	  --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
	  $(REPO) $(APP_ID).flatpak $(APP_ID)

repo: build
	flatpak build-update-repo $(GPG_ARGS) --generate-static-deltas --prune $(REPO)

oci: build
	flatpak build-bundle --oci --oci-layer-compress=zstd $(REPO) oci/$(APP_ID) $(APP_ID)

clean:
	rm -rf $(BUILDDIR) .flatpak-builder

distclean: clean
	rm -rf $(REPO) oci *.flatpak
