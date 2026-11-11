# gmklabs — consolidated installer for the Gomoku laboratory.
#
# Builds the tools from clean, pinned checkouts and installs them into
# a prefix on PATH (default ~/.local). The source repositories stay
# clean: all fetching and building happens under build/ here.
#
# Targets:
#   make install    fetch, build, install binaries + scripts + config
#   make doctor     verify the installed environment
#   make uninstall  remove installed binaries and scripts
#   make clean      remove the build area
#
# Common overrides:
#   make install PREFIX=/opt/lab            install elsewhere
#   make install GOMOKU_HOME=/tmp/gomoku    redirect the config dir
#     (used by the test suite of this repository; normally not needed)

SHELL := /bin/zsh

PREFIX      ?= $(HOME)/.local
GOMOKU_HOME ?= $(HOME)/.gomoku
BUILD_DIR   ?= $(CURDIR)/build

# One shared target directory for all three cargo installs: the Burn
# dependency stack is compiled once, not three times.
export CARGO_TARGET_DIR := $(BUILD_DIR)/target

BINDIR     := $(PREFIX)/bin
GUI_SRC    := $(BUILD_DIR)/gomoku-gui
RUSTML_SRC := $(BUILD_DIR)/rust-ml

GUI_URL    := https://github.com/Project-Ellie/gomoku-gui
RUSTML_URL := https://github.com/Project-Ellie/rust-ml

GUI_REV := $(shell sed -n 's/^rev *= *"\(.*\)"/\1/p' gmklabs.toml)

BINARIES := nettrain gomoku gomoku-gui
SCRIPTS  := nettrain-wgpu

.PHONY: install dirs fetch-gui fetch-rustml bins scripts config report \
        doctor uninstall clean

install: dirs fetch-gui fetch-rustml bins scripts config report

dirs:
	@mkdir -p $(BUILD_DIR) $(BINDIR) $(GOMOKU_HOME)

fetch-gui: dirs
	@if [ -d $(GUI_SRC)/.git ]; then \
	  git -C $(GUI_SRC) fetch -q origin && git -C $(GUI_SRC) checkout -q $(GUI_REV); \
	else \
	  git clone -q $(GUI_URL) $(GUI_SRC) && git -C $(GUI_SRC) checkout -q $(GUI_REV); \
	fi
	@echo "gomoku-gui @ $(GUI_REV)"

fetch-rustml: fetch-gui
	@rev=$$(sed -n 's/^engine = { git = "[^"]*", rev = "\([^"]*\)".*/\1/p' $(GUI_SRC)/Cargo.toml); \
	if [ -z "$$rev" ]; then \
	  echo "error: cannot read rust-ml rev from $(GUI_SRC)/Cargo.toml" >&2; exit 1; \
	fi; \
	if [ -d $(RUSTML_SRC)/.git ]; then \
	  git -C $(RUSTML_SRC) fetch -q origin && git -C $(RUSTML_SRC) checkout -q $$rev; \
	else \
	  git clone -q $(RUSTML_URL) $(RUSTML_SRC) && git -C $(RUSTML_SRC) checkout -q $$rev; \
	fi; \
	echo "rust-ml @ $$rev (pinned by gomoku-gui/Cargo.toml)"

bins: fetch-rustml
	cargo install --locked --force --features gpu \
	  --path $(RUSTML_SRC)/gomoku/crates/net --root $(PREFIX)
	cargo install --locked --force \
	  --path $(RUSTML_SRC)/gomoku/crates/cli --root $(PREFIX)
	@rm -f $(BINDIR)/historydemo   # demo binary; not part of the lab
	cargo install --locked --force \
	  --path $(GUI_SRC)/crates/gui --root $(PREFIX)

scripts: dirs
	install -m 755 $(CURDIR)/scripts/nettrain-wgpu $(BINDIR)/

config: dirs
	@if [ ! -f $(GOMOKU_HOME)/config.json ]; then \
	  printf '{\n  "version": 1,\n  "bin_dir": "%s",\n  "default_lab": null\n}\n' \
	    $(BINDIR) > $(GOMOKU_HOME)/config.json; \
	  echo "wrote $(GOMOKU_HOME)/config.json"; \
	else \
	  echo "kept existing $(GOMOKU_HOME)/config.json"; \
	fi

report: dirs
	@echo ""
	@echo "installed into $(BINDIR): $(BINARIES) $(SCRIPTS)"
	@case ":$$PATH:" in \
	  *":$(BINDIR):"*) ;; \
	  *) echo "note: $(BINDIR) is not on your PATH yet" ;; \
	esac

doctor:
	@ok=1; \
	for b in $(BINARIES) $(SCRIPTS); do \
	  if [ -x $(BINDIR)/$$b ]; then echo "ok    $$b"; \
	  else echo "MISS  $$b"; ok=0; fi; \
	done; \
	case ":$$PATH:" in \
	  *":$(BINDIR):"*) echo "ok    PATH" ;; \
	  *) echo "WARN  $(BINDIR) not on PATH" ;; \
	esac; \
	if python3 -m json.tool $(GOMOKU_HOME)/config.json >/dev/null 2>&1; then \
	  echo "ok    config.json"; \
	else echo "WARN  $(GOMOKU_HOME)/config.json missing or invalid"; fi; \
	[ $$ok = 1 ]

uninstall:
	rm -f $(addprefix $(BINDIR)/,$(BINARIES) $(SCRIPTS))
	@echo "removed binaries and scripts from $(BINDIR)"
	@echo "kept $(GOMOKU_HOME)/config.json (remove by hand if unwanted)"

clean:
	rm -rf $(BUILD_DIR)
