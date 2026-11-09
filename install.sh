#!/usr/bin/env bash
#
# Dev Environment Setup - Symlink Installer
# 
# This script creates symlinks from standard config locations
# to the configs in this project directory.
#
# Usage:
#   ./install.sh           # Install all configs (with backups)
#   ./install.sh --dry-run # Preview what would be done
#   ./install.sh --force   # Skip backup prompts
#

set -euo pipefail

# ============================================
# Configuration
# ============================================

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGS_DIR="$PROJECT_DIR/configs"
ICLOUD_AGENT_DIR="${ICLOUD_AGENT_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/agent}"
AGENT_CONTEXT_FILE="${AGENT_CONTEXT_FILE:-$ICLOUD_AGENT_DIR/AGENTS.md}"
SKILLS_DIR="${SKILLS_DIR:-$ICLOUD_AGENT_DIR/skills}"
BACKUP_DIR="$HOME/.config-backup-$(date +%Y%m%d_%H%M%S)"
DRY_RUN=false
FORCE=false
IS_MACOS=false

# Detect OS
if [[ "$(uname)" == "Darwin" ]]; then
    IS_MACOS=true
fi

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ============================================
# Helper Functions
# ============================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================
# Dependency Checks
# ============================================

check_dependencies() {
    echo ""
    echo "--- Dependency Check ---"
    
    local missing_deps=()
    local optional_deps=()
    
    # Required dependencies
    if ! command_exists zsh; then
        missing_deps+=("zsh")
    fi
    
    if ! command_exists git; then
        missing_deps+=("git")
    fi
    
    # Optional but recommended
    if ! command_exists tmux; then
        optional_deps+=("tmux")
    fi
    
    if ! command_exists nvim && ! command_exists vim; then
        optional_deps+=("neovim")
    fi
    
    if ! command_exists rg; then
        optional_deps+=("ripgrep")
    fi
    
    # macOS-only tools
    if [[ "$IS_MACOS" == "true" ]]; then
        if [[ ! -d "/Applications/Hammerspoon.app" ]]; then
            optional_deps+=("Hammerspoon (install from hammerspoon.org)")
        fi
        
        if [[ ! -d "/Applications/Ghostty.app" ]] && ! command_exists ghostty; then
            optional_deps+=("Ghostty (install from ghostty.org)")
        fi
        
        if ! command_exists brew; then
            optional_deps+=("Homebrew (install from brew.sh)")
        fi
    fi
    
    # Report status
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Install them before continuing:"
        echo ""
        if [[ "$IS_MACOS" == "true" ]]; then
            echo "  brew install ${missing_deps[*]}"
        else
            echo "  sudo apt install ${missing_deps[*]}  # Debian/Ubuntu"
            echo "  sudo yum install ${missing_deps[*]}  # RHEL/CentOS"
        fi
        echo ""
        exit 1
    else
        log_success "All required dependencies present"
    fi
    
    if [[ ${#optional_deps[@]} -gt 0 ]]; then
        log_warn "Optional dependencies not found (configs will still be installed):"
        for dep in "${optional_deps[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Some features may not work without these tools."
    fi
}

backup_if_exists() {
    local target="$1"
    if [[ -e "$target" || -L "$target" ]]; then
        mkdir -p "$BACKUP_DIR"
        local rel_path="${target#$HOME/}"
        local backup_path="$BACKUP_DIR/${rel_path//\//_}"
        log_warn "Backing up existing: $target -> $backup_path"
        if [[ "$DRY_RUN" == "false" ]]; then
            mv "$target" "$backup_path"
        fi
    fi
}

create_symlink() {
    local source="$1"
    local target="$2"
    local description="$3"
    
    log_info "Setting up: $description"
    echo "  Source: $source"
    echo "  Target: $target"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] Would create symlink"
        return
    fi

    if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
        log_success "Symlink already correct: $target -> $source"
        return
    fi
    
    # Backup existing
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ "$FORCE" == "false" ]]; then
            backup_if_exists "$target"
        else
            rm -rf "$target"
        fi
    fi
    
    # Create parent directory if needed
    local parent_dir="$(dirname "$target")"
    if [[ ! -d "$parent_dir" ]]; then
        mkdir -p "$parent_dir"
    fi
    
    # Create symlink
    ln -sf "$source" "$target"
    log_success "Symlink created: $target -> $source"
}

# ============================================
# Main Installation
# ============================================

echo ""
echo "=========================================="
echo "  Dev Environment Setup - Symlink Installer"
echo "=========================================="
echo ""
echo "Project Dir: $PROJECT_DIR"
echo "Configs Dir: $CONFIGS_DIR"
echo "OS: $(uname) $(uname -m)"
echo ""

# Check dependencies first
check_dependencies

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN MODE - No changes will be made"
    echo ""
fi

# ----------------------------------------
# 1. ZSH Configuration
# ----------------------------------------
echo ""
echo "--- ZSH Configuration ---"

create_symlink "$CONFIGS_DIR/zsh/zshrc" "$HOME/.zshrc" "Zsh main config"
create_symlink "$CONFIGS_DIR/zsh/zshenv" "$HOME/.zshenv" "Zsh environment"
create_symlink "$CONFIGS_DIR/zsh/custom_alias.zsh" "$HOME/custom_alias.zsh" "Custom aliases"
create_symlink "$CONFIGS_DIR/zsh/custom_function.zsh" "$HOME/custom_function.zsh" "Custom functions"

# ----------------------------------------
# 2. Neovim Configuration
# ----------------------------------------
echo ""
echo "--- Neovim Configuration ---"

create_symlink "$CONFIGS_DIR/nvim/vim_runtime" "$HOME/.config/nvim" "Neovim config directory"
create_symlink "$CONFIGS_DIR/nvim/vimrc" "$HOME/.vimrc" "Vim runtime config"

# Optional: LazyVim config (alternative neovim setup)
if [[ -d "$CONFIGS_DIR/nvim/LazyVim" ]]; then
    log_info "LazyVim config found at $CONFIGS_DIR/nvim/LazyVim"
    log_info "To use LazyVim, update the nvim symlink or use NVIM_APPNAME=LazyVim"
fi

# ----------------------------------------
# 3. Hammerspoon Configuration
# ----------------------------------------
echo ""
echo "--- Hammerspoon Configuration ---"

create_symlink "$CONFIGS_DIR/hammerspoon" "$HOME/.hammerspoon" "Hammerspoon config directory"

# ----------------------------------------
# 4. Ghostty Configuration
# ----------------------------------------
echo ""
echo "--- Ghostty Configuration ---"

create_symlink "$CONFIGS_DIR/ghostty/config" "$HOME/.config/ghostty/config" "Ghostty config"

# ----------------------------------------
# 5. Tmux Configuration
# ----------------------------------------
echo ""
echo "--- Tmux Configuration ---"

create_symlink "$CONFIGS_DIR/tmux/tmux.conf" "$HOME/.tmux.conf" "Tmux main config"

# Install TPM (Tmux Plugin Manager) if not present
if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
    log_info "Installing Tmux Plugin Manager (TPM)..."
    if [[ "$DRY_RUN" == "false" ]]; then
        git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
        log_success "TPM installed"
    else
        echo "  [DRY RUN] Would clone TPM"
    fi
else
    log_success "TPM already installed"
fi

# ----------------------------------------
# 6. Ripgrep Configuration
# ----------------------------------------
echo ""
echo "--- Ripgrep Configuration ---"

create_symlink "$CONFIGS_DIR/ripgreprc" "$HOME/.ripgreprc" "Ripgrep config"

# ----------------------------------------
# 7. Doom Emacs Configuration (DOOMDIR)
# ----------------------------------------
echo ""
echo "--- Doom Emacs Configuration ---"

# Requires Doom Emacs (github.com/doomemacs/core) cloned to ~/.emacs.d; the
# modules repo is fetched by 'doom install' into ~/.emacs.d/sources/doom+.
create_symlink "$CONFIGS_DIR/doom" "$HOME/.doom.d" "Doom Emacs private config (DOOMDIR)"

if [[ -x "$HOME/.emacs.d/bin/doom" ]]; then
    log_info "After changing init.el/packages.el, run: ~/.emacs.d/bin/doom sync"
else
    log_warn "Doom Emacs not found at ~/.emacs.d; install it before starting Emacs"
fi

# ----------------------------------------
# 8. Karabiner Elements Rules (macOS only)
# ----------------------------------------
echo ""
echo "--- Karabiner Elements Rules ---"

# Karabiner reads a single karabiner.json and cannot include files, so the
# shared complex-modification rules are merged in instead of symlinked
# (machine-local devices/simple_modifications are preserved).
if [[ "$(uname)" == "Darwin" ]] && [[ -f "$HOME/.config/karabiner/karabiner.json" ]]; then
    if command_exists python3; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [DRY RUN] Would run: python3 $CONFIGS_DIR/karabiner/apply.py --dry-run"
        else
            python3 "$CONFIGS_DIR/karabiner/apply.py" || log_warn "Karabiner rules not applied"
        fi
    else
        log_warn "python3 not found; skipping Karabiner rules"
    fi
else
    log_info "Karabiner Elements config not found; skipping"
fi

# ----------------------------------------
# 9. Agent Context and Skills (external iCloud files)
# ----------------------------------------
echo ""
echo "--- Agent Context and Skills ---"

if [[ -f "$AGENT_CONTEXT_FILE" ]]; then
    create_symlink "$AGENT_CONTEXT_FILE" "$HOME/.pi/agent/AGENTS.md" "Agent context file"
else
    log_warn "Agent context file not found; skipping: $AGENT_CONTEXT_FILE"
fi

if [[ -d "$SKILLS_DIR" ]]; then
    create_symlink "$SKILLS_DIR" "$HOME/.agents/skills" "Agent skills directory"
else
    log_warn "Agent skills directory not found; skipping: $SKILLS_DIR"
fi

# ----------------------------------------
# 10. Install Zinit (Zsh Plugin Manager)
# ----------------------------------------
echo ""
echo "--- Zsh Plugin Manager (Zinit) ---"

if [[ ! -d "$HOME/.local/share/zinit/zinit.git" ]]; then
    log_info "Installing Zinit (Zsh plugin manager)..."
    if [[ "$DRY_RUN" == "false" ]]; then
        mkdir -p "$HOME/.local/share/zinit"
        git clone https://github.com/zdharma-continuum/zinit.git "$HOME/.local/share/zinit/zinit.git"
        log_success "Zinit installed"
    else
        echo "  [DRY RUN] Would clone Zinit"
    fi
else
    log_success "Zinit already installed"
fi

# ----------------------------------------
# 11. Ensure required directories exist
# ----------------------------------------
echo ""
echo "--- Creating Required Directories ---"

REQUIRED_DIRS=(
    "$HOME/zsh_history"
    "$HOME/.config/ghostty"
    "$HOME/.tmux/plugins"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        log_info "Creating directory: $dir"
        if [[ "$DRY_RUN" == "false" ]]; then
            mkdir -p "$dir"
        fi
    else
        log_success "Directory exists: $dir"
    fi
done

# ----------------------------------------
# 12. Post-install instructions
# ----------------------------------------
echo ""
echo "=========================================="
echo "  Installation Complete!"
echo "=========================================="
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo "This was a DRY RUN. No changes were made."
    echo "Run without --dry-run to apply changes."
else
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "Backups saved to: $BACKUP_DIR"
    fi
    
    echo ""
    echo "=== Next Steps ==="
    echo ""
    echo "1. Restart your shell:"
    echo "   exec zsh"
    echo ""
    echo "2. Install Tmux plugins (inside tmux):"
    echo "   Ctrl-a + I  (prefix + capital I)"
    echo ""
    echo "3. Hammerspoon setup (macOS only):"
    echo "   - Launch Hammerspoon"
    echo "   - Press Cmd+Alt+Ctrl+R to reload config"
    echo "   - Grant Accessibility permissions when prompted"
    echo ""
    echo "4. Ghostty setup (macOS only):"
    echo "   - Launch Ghostty - config is already linked"
    echo "   - Install Iosevka Nerd Font if not already installed"
    echo ""
    echo "5. Neovim setup:"
    echo "   - Open nvim - plugins will auto-install"
    echo "   - Or run: :Lazy sync"
    echo ""
    echo "=== Machine-Specific Adjustments ==="
    echo ""
    echo "The following configs may need path adjustments for this machine:"
    echo ""
    echo "  Zsh (~/.zshrc):"
    echo "    - Android SDK (ANDROID_HOME)"
    echo "    - Java (JAVA_HOME)"
    echo "    - Homebrew paths"
    echo "    - NVM/Node paths"
    echo "    - Custom tool paths (~/code/agent_tools, ~/kit/, etc.)"
    echo ""
    echo "  Hammerspoon (~/.hammerspoon/init.lua):"
    echo "    - App bundle IDs (may differ per machine)"
    echo ""
    echo "  Tmux (~/.tmux.conf):"
    echo "    - Shell path"
    echo ""
    echo "  Ghostty (~/.config/ghostty/config):"
    echo "    - Font family"
    echo "    - Theme"
    echo ""
fi
