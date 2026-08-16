APP_ID   ?= io.github.rulin132.ChatGPT
MANIFEST := $(APP_ID).yaml
REPO     ?= repo
BUILDDIR ?= build
LOCAL_REMOTE ?= $(APP_ID)-local
# --exceptions is required; --user-exceptions alone is silently inert.
LINT_EXCEPTIONS := flatpak-builder-lint-exceptions.json
GPG_KEY  ?=
GPG_ARGS := $(if $(GPG_KEY),--gpg-sign=$(GPG_KEY),)

# Derived from APP_ID, not the literal OWNER, so rename works from any state.
# Once the scaffold has been renamed once there is no OWNER left to match, and
# matching it would make the target a silent no-op for the next forker.
CURRENT_USER := $(word 3,$(subst ., ,$(APP_ID)))

# The distros this exists for cannot layer flatpak-builder.
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
	@# One shell: `exit` in a make recipe only ends its own line, so an early
	@# return has to be an if/else rather than a guard clause.
	@if [ "$(GH_USER)" = "$(CURRENT_USER)" ]; then \
	  echo "already io.github.$(CURRENT_USER).ChatGPT, nothing to do"; \
	else \
	  for f in $$(grep -rl '$(CURRENT_USER)' --exclude-dir=.git --exclude-dir=build \
	      --exclude-dir=repo --exclude-dir=.cache --exclude-dir=oci \
	      --exclude-dir=.flatpak-builder .); do \
	    sed -i "s/io\.github\.$(CURRENT_USER)/io.github.$(GH_USER)/g; \
	            s|github\.com/$(CURRENT_USER)|github.com/$(GH_USER)|g; \
	            s|$(CURRENT_USER)\.github\.io|$(GH_USER).github.io|g; \
	            s|ghcr\.io/$(CURRENT_USER)|ghcr.io/$(GH_USER)|g" "$$f"; \
	  done; \
	  for f in $$(find . -name '*$(CURRENT_USER)*' -not -path './.git/*' \
	      -not -path './build/*' -not -path './repo/*' -not -path './.cache/*' \
	      -not -path './oci/*' -not -path './.flatpak-builder/*'); do \
	    n=$$(echo "$$f" | sed 's/$(CURRENT_USER)/$(GH_USER)/'); \
	    git mv "$$f" "$$n" 2>/dev/null || mv "$$f" "$$n"; \
	  done; \
	  echo "renamed to io.github.$(GH_USER).ChatGPT, commit the result"; \
	fi

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
	flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
	  --exceptions --user-exceptions $(LINT_EXCEPTIONS) manifest $(MANIFEST)

build:
	$(FB) --user --install-deps-from=flathub --force-clean \
	  --disable-rofiles-fuse --repo=$(REPO) $(GPG_ARGS) $(BUILDDIR) $(MANIFEST)

# Outside the builder, and via a remote. apply_extra runs under bwrap, which
# cannot nest a user namespace inside the org.flatpak.Builder sandbox. And
# build-bundle reads extra-data only from detached metadata, so its bundle has
# no payload; a repo remote reads it from the commit metadata and works.
# Recreated, not --if-not-exists: that preserves an existing remote, so moving
# the checkout or changing REPO leaves it pointing at the old path and the
# install silently succeeds against a stale build.
install: build
	-flatpak remote-delete --user --force $(LOCAL_REMOTE) 2>/dev/null
	flatpak remote-add --user --no-gpg-verify $(LOCAL_REMOTE) $(CURDIR)/$(REPO)
	flatpak install --user -y --reinstall $(LOCAL_REMOTE) $(APP_ID)

run:
	flatpak run $(APP_ID)

# A tombstone, so the target explains itself instead of "No rule to make target".
bundle:
	@echo "make bundle: removed, build-bundle cannot carry extra-data (flatpak#1334)."
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
