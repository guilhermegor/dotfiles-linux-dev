# ===========================================
# DOTFILES-DEV - MAKEFILE
# ===========================================
#
# Help is auto-generated from target annotations:
#   target: deps  ## Description  → appears in `make help`
#   no annotation                 → hidden from help (internal)
#   ##@ Section name              → group separator in help
#
# Keep target descriptions in sync with the target itself, not in a separate
# block at the bottom.

.DEFAULT_GOAL := help

##@ Quick Start

.PHONY: run
# Exported so ai_clients/main.sh skips its own restore-env prompt during the run.
run: export DOTFILES_INIT_IN_PROGRESS=1
run: export MAKE_BIN := $(MAKE)
run:  ## Complete initial setup (RECOMMENDED first-time entry point)
	@bash lib/run_chain.sh
	@echo ""
	@echo "╔════════════════════════════════════════════════════════════╗"
	@echo "║                                                            ║"
	@echo "║  🎉 Initial System Setup Complete!                         ║"
	@echo "║                                                            ║"
	@echo "║  ✅ Permissions set for all scripts                        ║"
	@echo "║  ✅ Essential programs installed                           ║"
	@echo "║  ✅ AI clients configured (Claude Code)                    ║"
	@echo "║  ✅ Espanso packages installed                             ║"
	@echo "║  ✅ Coding environment installed                           ║"
	@echo "║  ✅ Bash profile loads ~/.bashrc                           ║"
	@echo "║  ✅ Starship prompt and autocomplete configured            ║"
	@echo "║  ✅ VS Code configured with extensions                     ║"
	@echo "║  ✅ IRPF (Brazilian tax software) downloaded               ║"
	@echo "║  ✅ Custom shortcuts configured                            ║"
	@echo "║  ✅ Ubuntu workspace configured                            ║"
	@echo "║                                                            ║"
	@echo "║  Next steps:                                               ║"
	@echo "║    • make setup_all_drivers  (configure hardware)          ║"
	@echo "║    • make storage_setup      (configure storage)           ║"
	@echo "║    • make vm_setup           (setup virtual machines)      ║"
	@echo "║    • make help               (see all commands)            ║"
	@echo "║                                                            ║"
	@echo "╚════════════════════════════════════════════════════════════╝"
	@echo ""

##@ System Setup

.PHONY: setup_env install_programs rclone_mount install_coding irpf_download set_shortcuts ubuntu_workspace vscode_setup vscode_restore bash_profile starship_setup starship_menu starship_undo_previous starship_undo_original

setup_env:  ## Prompt to create .env from .env.example
	@bash distro_config/setup_env.sh

install_programs:  ## Install desktop apps (browsers, productivity, media, sharing, VM)
	@echo "Installing essential programs..."
	@bash distro_config/install_programs.sh

rclone_mount:  ## Enable + start the rclone mount unit (after install_programs wrote it)
	@bash -c 'source distro_config/install_lib/_common.sh && source distro_config/install_lib/sharing.sh && enable_rclone_mount_unit'

install_coding:  ## Install coding env (languages, editors, databases, AI CLIs)
	@echo "Installing coding environment (languages, editors, databases, AI CLIs)..."
	@bash distro_config/install_coding.sh

vscode_setup:  ## Configure VS Code with extensions and keybindings
	@echo "Configuring VS Code with extensions and shortcuts..."
	@bash code_editors/vscode.sh

vscode_restore:  ## Restore VS Code configuration from a backup
	@echo "Restoring VS Code configurations..."
	@bash code_editors/vscode_restore.sh

irpf_download:  ## Download IRPF (Brazilian tax software)
	@echo "Downloading IRPF (Brazilian tax software)..."
	@bash distro_config/irpf_download.sh

set_shortcuts:  ## Set GNOME custom keyboard shortcuts
	@echo "Setting custom shortcuts..."
	@bash distro_config/set_custom_shortcuts.sh

ubuntu_workspace:  ## Configure GNOME workspace, dock, theme, app folders
	@echo "Configuring Ubuntu workspace..."
	@bash distro_config/ubuntu_workspace.sh

bash_profile:  ## Ensure ~/.bash_profile loads ~/.bashrc
	@echo "Ensuring ~/.bash_profile loads ~/.bashrc..."
	@bash code_editors/bash_profile_snippet.sh

starship_setup:  ## Install Starship prompt + Bash autocomplete
	@echo "Installing Starship, Bash integration, and autocomplete..."
	@bash code_editors/setup_starship_bash.sh all

starship_menu:  ## Interactive Starship / Bash setup menu
	@echo "Opening Starship and Bash setup menu..."
	@bash code_editors/setup_starship_bash.sh

starship_undo_previous:  ## Roll back Starship/Bash setup to the previous backup
	@echo "Rolling back Starship/Bash setup to previous configuration..."
	@bash code_editors/setup_starship_bash.sh undo-previous

starship_undo_original:  ## Roll back Starship/Bash setup to the original config
	@echo "Rolling back Starship/Bash setup to original configuration..."
	@bash code_editors/setup_starship_bash.sh undo-original

##@ Hardware Drivers

.PHONY: setup_bluetooth setup_keyboard setup_mouse setup_wifi setup_yubikey setup_all_drivers

setup_bluetooth:  ## Setup Bluetooth adapter
	@echo "Setting up Bluetooth adapter..."
	@bash drivers/bluetooth_adapter.sh

setup_keyboard:  ## Configure keyboard
	@echo "Configuring keyboard..."
	@bash drivers/setup_keyboard.sh

setup_mouse:  ## Configure mouse (MX Master + xbindkeys workspace buttons)
	@echo "Configuring mouse..."
	@bash drivers/mouse.sh

setup_wifi:  ## Setup TP-Link USB WiFi adapter driver
	@echo "Setting up TP-Link WiFi adapter..."
	@bash drivers/tplink_wifi_adapter.sh

setup_yubikey:  ## Install YubiKey software (ykman, pcscd, Authenticator, GPG/SSH, PAM)
	@echo "Setting up YubiKey software..."
	@bash drivers/yubikey.sh

setup_all_drivers: setup_bluetooth setup_keyboard setup_mouse setup_wifi  ## Setup all hardware drivers
	@echo "All drivers configured successfully!"

##@ Storage Management

.PHONY: check_drive_legitimacy data_recovery format_hard format_neat vault_setup mount_disks

check_drive_legitimacy:  ## Verify drive authenticity and SMART health
	@echo "Checking drive legitimacy and integrity..."
	@bash storage/check_legitimity.sh

data_recovery:  ## Run testdisk / photorec recovery tools
	@echo "Running data recovery tools..."
	@bash storage/data_recovery.sh

format_hard:  ## Full slow format with shred (⚠️  IRREVERSIBLE)
	@echo "⚠️  WARNING: Performing hard format (complete drive formatting)..."
	@echo "This operation is IRREVERSIBLE. Press Ctrl+C to cancel."
	@sleep 3
	@bash storage/format_hard.sh

format_neat:  ## Quick partition + filesystem format
	@echo "Performing neat format (quick and clean)..."
	@bash storage/format_neat.sh

vault_setup:  ## Encrypt a device with VeraCrypt (AES-256 + SHA-512)
	@echo "Setting up secure storage vault..."
	@bash storage/vault.sh

mount_disks:  ## Auto-mount external drives under /mnt/auto/
	@echo "Mounting unmounted non-NTFS partitions..."
	@bash storage/mount_disks.sh

##@ OS Management

.PHONY: manage_isos create_vm launch_vm

manage_isos:  ## Manage ISO files and operating systems
	@echo "Managing ISO files and operating systems..."
	@bash os/isos_os_manager.sh

create_vm:  ## Create a KVM/QEMU virtual machine
	@echo "Creating virtual machine..."
	@bash os/vm_creator.sh

launch_vm:  ## Launch an existing KVM virtual machine
	@echo "Launching virtual machine..."
	@bash os/vm_launcher.sh

##@ Storage Analytics

.PHONY: storage_analysis

storage_analysis:  ## SSD/NVMe slot analysis + theoretical max capacity report
	@echo "Running storage gap analysis..."
	@bash storage/storage_hiato.sh

##@ Batch Operations

.PHONY: full_setup install_espanso_packages hardware_setup storage_setup vm_setup permissions ai_clients restore_env_prompt

full_setup: permissions install_programs install_coding vscode_setup setup_all_drivers  ## Complete system setup (programs + coding + drivers)
	@echo ""
	@echo "════════════════════════════════════════════"
	@echo "  ✅ Full system setup completed!"
	@echo "════════════════════════════════════════════"
	@echo ""

install_espanso_packages:  ## Copy espanso/*/ packages to ~/.config/espanso/packages/
	@echo "Installing Espanso packages from repo..."
	@PACK_DIR="$$HOME/.config/espanso/packages"; \
	mkdir -p "$$PACK_DIR"; \
	for d in espanso/*; do \
		if [ -d "$$d" ]; then \
			name=$$(basename "$$d"); \
			echo " - Installing $$d -> $$PACK_DIR/$$name"; \
			rm -rf "$$PACK_DIR/$$name" 2>/dev/null || true; \
			cp -a "$$d" "$$PACK_DIR/$$name"; \
			find "$$PACK_DIR/$$name" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true; \
		fi; \
	done; \
	echo "Espanso packages installed to $$PACK_DIR"; \
	if command -v espanso >/dev/null 2>&1; then \
		echo "Reloading espanso..."; \
		espanso restart >/dev/null 2>&1 || espanso start >/dev/null 2>&1 || true; \
	fi; \
	for d in espanso/*; do \
		if [ -f "$$d/setup.sh" ]; then \
			echo "Running setup: $$d/setup.sh"; \
			bash "$$d/setup.sh"; \
		fi; \
	done; \
	echo "Note: to use new terminal wrappers in this session, run: source ~/.profile"

hardware_setup: setup_bluetooth setup_keyboard setup_mouse setup_wifi  ## Setup all hardware drivers (alias for setup_all_drivers)
	@echo ""
	@echo "════════════════════════════════════════════"
	@echo "  ✅ Hardware setup completed!"
	@echo "════════════════════════════════════════════"
	@echo ""

storage_setup: check_drive_legitimacy format_neat vault_setup storage_analysis  ## Complete storage setup
	@echo ""
	@echo "════════════════════════════════════════════"
	@echo "  ✅ Storage setup completed!"
	@echo "════════════════════════════════════════════"
	@echo ""

vm_setup: manage_isos create_vm  ## Setup virtual machine environment
	@echo ""
	@echo "════════════════════════════════════════════"
	@echo "  ✅ Virtual machine setup completed!"
	@echo "════════════════════════════════════════════"
	@echo ""

permissions:  ## chmod +x every *.sh in the repo (skips sourced libs — see below)
	@echo "Making all scripts executable..."
	@find distro_config -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
	@find drivers -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
	@find os -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
	@find storage -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
	@find code_editors -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
	@find ai_clients -name "*.sh" -not -path "*/lib/*" -not -path "*/profile_functions.sh" -exec chmod +x {} \; 2>/dev/null || true
	@echo "✅ Permissions updated successfully!"

# Boring path-shaped exclusion, not a shebang/main() sniff (dotfiles-linux-dev#312):
# skip every */lib/* dir under ai_clients/ plus the one top-level exception,
# profile_functions.sh. Some files under */lib/* are legitimately executable
# (already committed 755, e.g. ai_clients/lib/restore_env_prompt.sh is
# dual-mode) — skipping them here is a harmless no-op since chmod would only
# ever confirm a mode they already have. What this exclusion actually fixes
# is the four sourced-only libs (review_thread_gate.sh, profiles.sh,
# shared_agents_md.sh, profile_functions.sh) that git stores 644: without
# it, `chmod +x` flips them to 755 and dirties the tree on every run.

ai_clients:  ## Configure all AI clients (interactive menu: Claude Code, ...)
	@echo "Configuring all AI clients (Claude, ...)..."
	@bash ai_clients/main.sh

restore_env_prompt:  ## Prompt to restore .env files from external backup
	@bash ai_clients/lib/restore_env_prompt.sh || true

##@ Code Editors

.PHONY: editors_setup

editors_setup: vscode_setup ai_clients  ## Setup all code editors + AI clients
	@echo ""
	@echo "════════════════════════════════════════════"
	@echo "  ✅ Code editors setup completed!"
	@echo "════════════════════════════════════════════"
	@echo ""

##@ Utilities

.PHONY: banner check_status list_scripts clean patch_claudestatus git_hooks test lessons_mirror

test:  ## Run the bats unit test suite (tests/) — local parity with CI
	@command -v bats >/dev/null 2>&1 || { echo "bats not found — run 'make install_coding' (bats step) or 'brew install bats-core'"; exit 1; }
	@bash tests/bats_negation_gate.sh
	@bats tests/

lessons_mirror:  ## Regenerate this repo's git-ignored lesson mirrors (.specs/_lessons/) from the global stores
	@bash ai_clients/claude/hooks/lib/generate_lesson_mirrors.sh "$(CURDIR)"

git_hooks:  ## Enable this repo's local git hooks (gitlint commit-msg lint)
	@command -v gitlint >/dev/null 2>&1 || { echo "Installing gitlint..."; pipx install gitlint-core 2>/dev/null || python3 -m pip install --user gitlint-core; }
	@git config core.hooksPath .githooks
	@find .githooks -type f -exec chmod +x {} \;
	@echo "✅ Local git hooks enabled (core.hooksPath → .githooks; gitlint lints commit messages before push)"

patch_claudestatus:  ## Patch @howells/claudestatus billing table (re-run after npm updates)
	@bash ai_clients/claude/lib/patch_claudestatus.sh

banner:  ## Print the DOTFILES-DEV ASCII banner
	@bash lib/banner.sh

check_status:  ## Show distribution info and executable scripts
	@echo "Checking system status..."
	@echo ""
	@echo "=== Distribution Info ==="
	@lsb_release -a 2>/dev/null || cat /etc/os-release
	@echo ""
	@echo "=== Available Scripts ==="
	@find distro_config drivers os storage code_editors -name "*.sh" -type f 2>/dev/null | sort
	@echo ""
	@echo "=== Executable Scripts ==="
	@find distro_config drivers os storage code_editors -name "*.sh" -type f -executable 2>/dev/null | sort
	@echo ""
	@echo "=== AI Clients Modules ==="
	@find ai_clients -name "*.sh" -type f 2>/dev/null | sort

list_scripts:  ## List every *.sh script in the repo, grouped by directory
	@echo "Available bash scripts:"
	@echo ""
	@echo "Distro Config scripts:"
	@ls -1 distro_config/*.sh 2>/dev/null || echo "  No distro config scripts found"
	@echo ""
	@echo "Driver scripts:"
	@ls -1 drivers/*.sh 2>/dev/null || echo "  No driver scripts found"
	@echo ""
	@echo "Storage scripts:"
	@ls -1 storage/*.sh 2>/dev/null || echo "  No storage scripts found"
	@echo ""
	@echo "OS scripts:"
	@ls -1 os/*.sh 2>/dev/null || echo "  No OS scripts found"
	@echo ""
	@echo "Code Editor scripts:"
	@ls -1 code_editors/*.sh 2>/dev/null || echo "  No code editor scripts found"
	@echo ""
	@echo "AI Clients modules:"
	@find ai_clients -name "*.sh" -type f 2>/dev/null | sort || echo "  No agent setup scripts found"

clean:  ## Remove *.log, *.tmp, *~ files under config/driver/os/storage/editor dirs
	@echo "Cleaning temporary files..."
	@find distro_config drivers os storage code_editors -name "*.log" -type f -delete 2>/dev/null || true
	@find distro_config drivers os storage code_editors -name "*.tmp" -type f -delete 2>/dev/null || true
	@find distro_config drivers os storage code_editors -name "*~" -type f -delete 2>/dev/null || true
	@echo "✅ Cleanup completed!"

##@ Help

.PHONY: help

# Auto-generated from `## description` annotations on each target and `##@ Name`
# section headers. To add a new target to the help output, append `  ## …` to
# its declaration line.
help:  ## Show this help message
	@bash lib/banner.sh
	@awk 'BEGIN { \
		FS = ":.*?## "; \
		printf "\n\033[1mDOTFILES-DEV — Make targets\033[0m\n\n"; \
		printf "Usage:\n  make \033[36m<target>\033[0m\n"; \
	} \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	/^[a-zA-Z_][a-zA-Z_-]*:.*?## / { printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2 }' \
	$(MAKEFILE_LIST)
	@echo ""
	@echo "💡 Common flows:"
	@echo "  make run             — first-time setup"
	@echo "  make full_setup      — complete system setup"
	@echo "  make help            — this message"
	@echo ""
	@echo "⚠️  format_hard is IRREVERSIBLE — use with caution."
	@echo ""
