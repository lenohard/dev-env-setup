# Dev Environment Setup

Portable development environment configuration for Zsh, Neovim, Doom Emacs, Hammerspoon, Ghostty, and Tmux.

## Overview

This project contains your shell/editor/terminal configurations in one portable directory. The `install.sh` script creates **symlinks** from standard config locations to the files in this project, making this the single source of truth. Agent context and skills are kept outside the repository in iCloud and are linked during installation.

## Directory Structure

```
dev-env-setup/
├── README.md
├── install.sh              # Symlink installer script
├── .gitignore
├── configs/
│   ├── zsh/
│   │   ├── zshrc           # Main Zsh configuration
│   │   ├── zshenv          # Zsh environment variables
│   │   ├── custom_alias.zsh    # Custom shell aliases
│   │   └── custom_function.zsh # Custom shell functions
│   ├── nvim/
│   │   ├── vim_runtime/    # Main Neovim config (init.vim, lua/, etc.)
│   │   ├── vimrc           # Vim runtime config
│   │   └── LazyVim/        # Alternative LazyVim configuration
│   ├── hammerspoon/
│   │   ├── init.lua        # Main Hammerspoon config
│   │   ├── utils.lua       # Utility functions
│   │   ├── delete_app.lua  # App deletion helper
│   │   ├── launchApplications.lua
│   │   ├── switchApplications.lua
│   │   ├── x11CopyPaste.lua
│   │   └── Spoons/         # Hammerspoon Spoons
│   ├── ghostty/
│   │   └── config          # Ghostty terminal config
│   ├── tmux/
│   │   ├── tmux.conf       # Main Tmux configuration
│   │   └── tmux.conf.local # Local Tmux overrides
│   ├── karabiner/
│   │   ├── rules.json      # Shared complex-modification rules
│   │   └── apply.py        # Merges the rules into ~/.config/karabiner/karabiner.json
│   ├── ripgreprc           # Ripgrep configuration
│   └── doom/
│       ├── init.el         # Doom module list
│       ├── config.el       # Private config (evil keys, gptel, theme)
│       ├── packages.el     # Extra packages
│       ├── custom.el       # Customize cache
│       ├── body.el         # gptel "agent body" (in-Emacs assistant)
│       └── body-genes.el   # Long-lived body memory
└── docs/
    └── (documentation files)
```

## Installation

### On a New Machine

1. **Copy this entire project** to the new machine:
   ```bash
   # Via git (recommended - set up a private repo)
   git clone <your-repo-url> ~/dev-env-setup
   
   # Or manually copy
   scp -r ~/dev-env-setup new-machine:~/
   ```

2. **Make sure the external agent files are available**:
   ```text
   ~/Library/Mobile Documents/com~apple~CloudDocs/agent/AGENTS.md
   ~/Library/Mobile Documents/com~apple~CloudDocs/agent/skills/
   ```

   These files are not stored in this repository. To use a different location, set `ICLOUD_AGENT_DIR` before running the installer.

3. **Run the installer**:
   ```bash
   cd ~/dev-env-setup
   ./install.sh
   ```

4. **Install dependencies** (if not already present):
   ```bash
   # Homebrew
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   
   # Core tools
   brew install tmux neovim ripgrep zsh fzf
   
   # Tmux plugins will be auto-installed by install.sh (TPM)
   # Zsh plugins will be auto-installed (Zinit)
   ```

4. **Restart your shell**:
   ```bash
   exec zsh
   ```

### Dry Run (Preview Changes)

```bash
./install.sh --dry-run
```

### Force Install (Skip Backups)

```bash
./install.sh --force
```

## Symlinks Created

The installer creates these symlinks:

| Source (in project) | Target (standard location) |
|---|---|
| `configs/zsh/zshrc` | `~/.zshrc` |
| `configs/zsh/zshenv` | `~/.zshenv` |
| `configs/zsh/custom_alias.zsh` | `~/custom_alias.zsh` |
| `configs/zsh/custom_function.zsh` | `~/custom_function.zsh` |
| `configs/nvim/vim_runtime` | `~/.config/nvim` |
| `configs/nvim/vimrc` | `~/.vimrc` |
| `configs/hammerspoon/` | `~/.hammerspoon/` |
| `configs/ghostty/config` | `~/.config/ghostty/config` |
| `configs/tmux/tmux.conf` | `~/.tmux.conf` |
| `configs/ripgreprc` | `~/.ripgreprc` |
| `configs/doom/` | `~/.doom.d` (Doom Emacs DOOMDIR) |

`configs/karabiner/rules.json` is not symlinked (Karabiner reads one file and
cannot include others): `install.sh` runs `configs/karabiner/apply.py`, which
replaces each profile's `complex_modifications.rules` while keeping machine-local
`devices`, `simple_modifications` and `fn_function_keys` untouched. Re-run it
after editing the rules; it is idempotent and backs up the old file.
| `iCloud agent/AGENTS.md` | `~/.pi/agent/AGENTS.md` |
| `iCloud agent/skills/` | `~/.agents/skills` |

The installer uses the actual iCloud filename `AGENTS.md`. If either external source is unavailable, it skips that symlink and prints a warning. Override the sources with `ICLOUD_AGENT_DIR`, `AGENT_CONTEXT_FILE`, or `SKILLS_DIR`.

## Post-Install Steps

### 1. Tmux Plugins

After first tmux launch, install plugins with:
```
Ctrl-a + I  (prefix then capital I)
```

TPM plugins included:
- `tmux-resurrect` - Save/restore sessions
- `tmux-continuum` - Auto-save sessions
- `tmux-yank` - Better copy/paste
- `tmux-copycat` - Enhanced search
- `tmux-pain-control` - Pane navigation
- `tmux-sidebar` - File tree sidebar
- `extrakto` - Fuzzy extract

### 2. Hammerspoon

1. Launch Hammerspoon
2. Press `Cmd+Alt+Ctrl+R` to reload config
3. The config watches for changes automatically

### 3. Neovim

The main config uses `vim_runtime/` with lazy.nvim plugin manager. LazyVim is also available as an alternative config.

### 4. Zsh Plugins

Zinit will auto-install these plugins on first shell start:
- `zsh-completions`
- `fast-syntax-highlighting`
- `zsh-autosuggestions`
- `tumult.plugin.zsh`
- `k` (directory listing)
- `history-search-multi-word`
- `pure` prompt

## Machine-Specific Customization

Some configs reference paths specific to the original machine. When moving to a new machine, update these:

### Zsh (`configs/zsh/zshrc`)
- Android SDK paths (`ANDROID_HOME`)
- Java paths (`JAVA_HOME`)
- Homebrew paths
- NVM/Node paths
- Custom tool paths (e.g., `~/code/agent_tools`, `~/kit/`)

### Hammerspoon (`configs/hammerspoon/init.lua`)
- App bundle IDs (may differ per machine)
- Custom hotkey bindings

### Ghostty (`configs/ghostty/config`)
- Font settings (Iosevka Nerd Font)
- Theme (Kibble)

### Tmux (`configs/tmux/tmux.conf`)
- Shell path
- Plugin settings

## Key Features & Tools

### Zsh
- **Plugin Manager**: Zinit
- **Prompt**: Pure
- **History**: 50k lines, deduplicated, shared across sessions
- **FZF**: File finding, history search, directory navigation
- **Zoxide**: Smart directory jumping
- **Atuin**: Enhanced shell history
- **Pyenv**: Python version management
- **NVM**: Node version management (lazy-loaded)
- **GVM**: Go version management
- **Aliases**: Custom shortcuts and functions

### Neovim
- **Plugin Manager**: lazy.nvim
- **LSP**: Mason for LSP management
- **UI**: lualine statusline, gruvbox colorscheme
- **Fuzzy Finder**: fzf-lua
- **Completion**: CoC (Conquer of Completion)

### Hammerspoon
- App switching hotkeys (Option+Ctrl+key)
- Clipboard operations (strip newlines, prettify JSON)
- Window management
- Config auto-reload on changes
- Image paste handler for Ghostty

### Tmux
- **Prefix**: `Ctrl-a`
- **Plugins**: TPM manager with multiple plugins
- **Navigation**: Vim-style pane movement
- **Mouse**: Full mouse support
- **Copy**: System clipboard integration

### Ghostty
- **Font**: Iosevka Nerd Font, 14pt
- **Theme**: Kibble (dark)
- **Opacity**: 92%
- **Keybindings**: Custom tmux-style navigation

## Usage Tips

### Zsh Keybindings
- `Ctrl+]`: Zoxide fuzzy path finder
- `Ctrl+T`: FZF file widget
- `Ctrl+R`: Atuin history search
- `Alt+C`: FZF cd widget
- `,gg`: FZF git files
- `,cc`: Inline Python calculation
- `,p`: Copy buffer to clipboard
- `,mm`: Output to clipboard
- `Ctrl+O`: Accept autosuggestion

### Tmux Keybindings
- `Ctrl-a |`: Split vertical
- `Ctrl-a -`: Split horizontal
- `Ctrl-a h/j/k/l`: Navigate panes
- `Ctrl-a H/J/K/L`: Resize panes
- `Ctrl-a r`: Reload config
- `Ctrl-a e`: Edit config
- `Alt+h/l/j/k`: Navigate panes (direct)
- `Alt+u/o`: Next/prev window

### Hammerspoon Keybindings
- `Cmd+Alt+Ctrl+R`: Reload config
- `Cmd+Alt+Ctrl+0`: Toggle console
- `Cmd+Alt+Ctrl+B`: Copy frontmost app bundle ID
- `Cmd+Alt+Ctrl+D`: Quick delete app
- `Cmd+Alt+Ctrl+C`: Empty trash
- `Cmd+Alt+Ctrl+P`: Copy Finder selection path
- `Cmd+Alt+Ctrl+F`: Move cursor to focused app
- `Ctrl+/`: Switch to other monitor
- `Option+Ctrl+key`: Toggle various apps

## Backup & Restore

Backups are automatically created before symlinking:
```
~/.config-backup-YYYYMMDD_HHMMSS/
```

To restore a backup:
```bash
# View backups
ls -la ~/.config-backup-*

# Restore specific file
cp ~/.config-backup-20260313_020322/.zshrc ~/.zshrc
```

## Development & Updates

To update configs:
1. Edit files in `~/dev-env-setup/configs/`
2. Changes are immediately active (symlinked)
3. Commit changes to version control

```bash
cd ~/dev-env-setup
git add -A
git commit -m "Update configs"
git push
```

## Notes

- **macOS specific**: Hammerspoon and Ghostty are macOS-only
- **Security**: Never commit `.env` files or secrets
- **Performance**: The zshrc is optimized with lazy-loading for NVM
- **Fonts**: Install Iosevka Nerd Font or adjust Ghostty font setting
- **Homebrew**: Uses Tsinghua mirror for faster downloads in China

## Troubleshooting

### Symlinks not working
```bash
# Check symlink targets
ls -la ~/.zshrc ~/.config/nvim ~/.hammerspoon ~/.tmux.conf

# Re-run installer
cd ~/dev-env-setup && ./install.sh --force
```

### Tmux plugins not loading
```bash
# Inside tmux, press: Ctrl-a + I
# Or manually:
~/.tmux/plugins/tpm/scripts/install_plugins.sh
```

### Zsh plugins not installing
```bash
# Remove Zinit cache and restart
rm -rf ~/.local/share/zinit
exec zsh
```

### Neovim plugins not installing
```bash
# Open nvim and run:
:Lazy sync
```

### Hammerspoon config not loading
- Open Hammerspoon console (Cmd+Alt+Ctrl+0)
- Check for errors
- Reload with Cmd+Alt+Ctrl+R

## License

Personal configuration - use at your own discretion.
