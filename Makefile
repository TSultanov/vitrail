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

LINUX_SYSTEM_BIN_DIR ?= /usr/local/bin
LINUX_USER_BIN_DIR ?= $(HOME)/.local/bin
MACOS_SYSTEM_APP_DIR ?= /Applications
MACOS_USER_APP_DIR ?= $(HOME)/Applications
# Leave these empty to use Program Files and LocalAppData from the Windows
# environment. They can be overridden with forward-slash or native paths.
WINDOWS_SYSTEM_INSTALL_DIR ?=
WINDOWS_USER_INSTALL_DIR ?=

.PHONY: all build install install-user

all: build

build:
	$(ZIG) build -Doptimize=$(OPTIMIZE) --prefix "$(BUILD_PREFIX)"

install: build
ifeq ($(PLATFORM),macos)
	mkdir -p "$(MACOS_SYSTEM_APP_DIR)"
	ditto "$(BUILD_PREFIX)/Vitrail.app" "$(MACOS_SYSTEM_APP_DIR)/Vitrail.app"
else ifeq ($(PLATFORM),linux)
	mkdir -p "$(LINUX_SYSTEM_BIN_DIR)"
	install -m 0755 "$(BUILD_PREFIX)/bin/vitrail" "$(LINUX_SYSTEM_BIN_DIR)/vitrail"
else ifeq ($(PLATFORM),windows)
	powershell.exe -NoProfile -Command "$$override = '$(WINDOWS_SYSTEM_INSTALL_DIR)'; $$dest = if ($$override) { $$override } else { Join-Path $$env:ProgramFiles 'Vitrail' }; New-Item -ItemType Directory -Force -Path $$dest | Out-Null; Copy-Item -Force -LiteralPath '$(abspath $(BUILD_PREFIX)/bin/vitrail.exe)' -Destination (Join-Path $$dest 'vitrail.exe')"
endif

install-user: build
ifeq ($(PLATFORM),macos)
	mkdir -p "$(MACOS_USER_APP_DIR)"
	ditto "$(BUILD_PREFIX)/Vitrail.app" "$(MACOS_USER_APP_DIR)/Vitrail.app"
else ifeq ($(PLATFORM),linux)
	mkdir -p "$(LINUX_USER_BIN_DIR)"
	install -m 0755 "$(BUILD_PREFIX)/bin/vitrail" "$(LINUX_USER_BIN_DIR)/vitrail"
else ifeq ($(PLATFORM),windows)
	powershell.exe -NoProfile -Command "$$override = '$(WINDOWS_USER_INSTALL_DIR)'; $$dest = if ($$override) { $$override } else { Join-Path $$env:LOCALAPPDATA 'Programs\Vitrail' }; New-Item -ItemType Directory -Force -Path $$dest | Out-Null; Copy-Item -Force -LiteralPath '$(abspath $(BUILD_PREFIX)/bin/vitrail.exe)' -Destination (Join-Path $$dest 'vitrail.exe')"
endif
