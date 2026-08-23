ZIG ?= zig
OPTIMIZE ?= ReleaseSafe
BUILD_PREFIX ?= zig-out/make-install

ifeq ($(OS),Windows_NT)
PLATFORM := windows
else
UNAME_S := $(shell uname -s 2>/dev/null)
ifeq ($(UNAME_S),Darwin)
PLATFORM := macos
else ifeq ($(UNAME_S),Linux)
PLATFORM := linux
else
$(error Unsupported host platform: OS=$(OS) uname=$(UNAME_S))
endif
endif

ifeq ($(PLATFORM),linux)
ifeq ($(shell id -u),0)
SUDO ?=
else
SUDO ?= sudo
endif
endif

LINUX_SYSTEM_BIN_DIR ?= /usr/local/bin
LINUX_USER_BIN_DIR ?= $(HOME)/.local/bin
MACOS_SYSTEM_APP_DIR ?= /Applications
MACOS_USER_APP_DIR ?= $(HOME)/Applications
# Standard macOS admin accounts can write to /Applications without elevation.
# Set MACOS_SUDO=sudo on managed or non-admin systems that require it.
MACOS_SUDO ?=
# A stable signing identity is required for macOS to recognize rebuilt bundles
# as updates of the same app and retain Accessibility permission. By default,
# use the first valid code-signing identity in the user's keychain.
MACOS_CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"/ { print $$2; exit }')
# Leave these empty to use Program Files and LocalAppData from the Windows
# environment. They can be overridden with forward-slash or native paths.
WINDOWS_SYSTEM_INSTALL_DIR ?=
WINDOWS_USER_INSTALL_DIR ?=

.PHONY: all build prepare-install install install-user

all: build

build:
	$(ZIG) build -Doptimize=$(OPTIMIZE) --prefix "$(BUILD_PREFIX)"

prepare-install: build
ifeq ($(PLATFORM),macos)
	@test -n "$(MACOS_CODESIGN_IDENTITY)" || { echo "No macOS code-signing identity found. Configure one in Xcode or set MACOS_CODESIGN_IDENTITY explicitly." >&2; exit 1; }
	codesign --force --sign "$(MACOS_CODESIGN_IDENTITY)" --options runtime "$(BUILD_PREFIX)/Vitrail.app"
	codesign --verify --deep --strict "$(BUILD_PREFIX)/Vitrail.app"
endif

install: prepare-install
ifeq ($(PLATFORM),macos)
	@killall -TERM -u "$${SUDO_USER:-$${USER}}" vitrail 2>/dev/null || true
	$(MACOS_SUDO) mkdir -p "$(MACOS_SYSTEM_APP_DIR)"
	$(MACOS_SUDO) ditto "$(BUILD_PREFIX)/Vitrail.app" "$(MACOS_SYSTEM_APP_DIR)/Vitrail.app"
else ifeq ($(PLATFORM),linux)
	$(SUDO) mkdir -p "$(LINUX_SYSTEM_BIN_DIR)"
	$(SUDO) install -m 0755 "$(BUILD_PREFIX)/bin/vitrail" "$(LINUX_SYSTEM_BIN_DIR)/vitrail"
else ifeq ($(PLATFORM),windows)
	powershell.exe -NoProfile -Command "$$override = '$(WINDOWS_SYSTEM_INSTALL_DIR)'; $$dest = if ($$override) { $$override } else { Join-Path $$env:ProgramFiles 'Vitrail' }; New-Item -ItemType Directory -Force -Path $$dest | Out-Null; Copy-Item -Force -LiteralPath '$(abspath $(BUILD_PREFIX)/bin/vitrail.exe)' -Destination (Join-Path $$dest 'vitrail.exe')"
endif

install-user: prepare-install
ifeq ($(PLATFORM),macos)
	@killall -TERM -u "$${SUDO_USER:-$${USER}}" vitrail 2>/dev/null || true
	mkdir -p "$(MACOS_USER_APP_DIR)"
	ditto "$(BUILD_PREFIX)/Vitrail.app" "$(MACOS_USER_APP_DIR)/Vitrail.app"
else ifeq ($(PLATFORM),linux)
	mkdir -p "$(LINUX_USER_BIN_DIR)"
	install -m 0755 "$(BUILD_PREFIX)/bin/vitrail" "$(LINUX_USER_BIN_DIR)/vitrail"
else ifeq ($(PLATFORM),windows)
	powershell.exe -NoProfile -Command "$$override = '$(WINDOWS_USER_INSTALL_DIR)'; $$dest = if ($$override) { $$override } else { Join-Path $$env:LOCALAPPDATA 'Programs\Vitrail' }; New-Item -ItemType Directory -Force -Path $$dest | Out-Null; Copy-Item -Force -LiteralPath '$(abspath $(BUILD_PREFIX)/bin/vitrail.exe)' -Destination (Join-Path $$dest 'vitrail.exe')"
endif
