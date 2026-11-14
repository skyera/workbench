#!/bin/bash
# deploy.sh - Copy configuration files to $HOME

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
    echo "Usage: ./deploy.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help      Show this help message"
    echo "  -v, --vim       Use myvimrc as init.vim (Vimscript style)"
    echo "  -l, --lua       Use .config/nvim as Neovim config (Lua style, default)"
    echo ""
    echo "By default, Neovim Lua configuration is deployed."
}

# Default choice
NVIM_CHOICE="lua"

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -v|--vim) NVIM_CHOICE="vim"; shift ;;
        -l|--lua) NVIM_CHOICE="lua"; shift ;;
        *) echo "Unknown parameter passed: $1"; show_help; exit 1 ;;
    esac
done

# 1. Ensure bin exists (for scripts)
mkdir -p ~/bin

# 2. Helper function to copy
deploy_file() {
    local src="$1"
    local dest="$2"
    
    if [ ! -f "$src" ]; then
        echo "Warning: Source $src does not exist. Skipping."
        return
    fi

    # Create destination directory if it doesn't exist
    mkdir -p "$(dirname "$dest")"

    if [ -f "$dest" ]; then
        if cmp -s "$src" "$dest"; then
            echo "Skipping $dest (already up to date)"
            return
        fi
        echo "Backing up existing $dest to ${dest}.bak"
        cp "$dest" "${dest}.bak"
    fi
    
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
        cp "$src" "$dest"
    else
        # Strip Windows carriage returns (CRLF to LF) when deploying on Linux/macOS
        tr -d '\r' < "$src" > "$dest"
    fi
    echo "Deployed $dest"
}

# 3. Deploy files
echo "Deploying dotfiles..."

# Handle .bashrc sourcing instead of overwriting
deploy_file "$REPO_DIR/mybashrc" "$HOME/.mybashrc"
BASHRC_LINE="[ -f ~/.mybashrc ] && . ~/.mybashrc"
if ! grep -Fxq "$BASHRC_LINE" "$HOME/.bashrc" 2>/dev/null; then
    echo "Adding sourcing line to ~/.bashrc"
    echo -e "\n# Source personal aliases and functions\n$BASHRC_LINE" >> "$HOME/.bashrc"
fi

# Also add to .zshrc on macOS (default shell since Catalina)
if [ "$(uname)" = "Darwin" ]; then
    if ! grep -Fxq "$BASHRC_LINE" "$HOME/.zshrc" 2>/dev/null; then
        echo "Adding sourcing line to ~/.zshrc"
        echo -e "\n# Source personal aliases and functions\n$BASHRC_LINE" >> "$HOME/.zshrc"
    fi
fi

deploy_file "$REPO_DIR/myvimrc"    "$HOME/.vimrc"
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    deploy_file "$REPO_DIR/.config/nvim/syntax/computesanitizer.vim" "$HOME/vimfiles/syntax/computesanitizer.vim"
    deploy_file "$REPO_DIR/.config/nvim/syntax/terra.vim"            "$HOME/vimfiles/syntax/terra.vim"
    deploy_file "$REPO_DIR/.config/nvim/indent/terra.vim"            "$HOME/vimfiles/indent/terra.vim"
else
    deploy_file "$REPO_DIR/.config/nvim/syntax/computesanitizer.vim" "$HOME/.vim/syntax/computesanitizer.vim"
    deploy_file "$REPO_DIR/.config/nvim/syntax/terra.vim"            "$HOME/.vim/syntax/terra.vim"
    deploy_file "$REPO_DIR/.config/nvim/indent/terra.vim"            "$HOME/.vim/indent/terra.vim"
fi

# Neovim configuration
if [ "$NVIM_CHOICE" == "lua" ]; then
    if [ -d "$REPO_DIR/.config/nvim" ]; then
        echo "Deploying Neovim Lua configuration..."
        mkdir -p "$HOME/.config/nvim"
        [ -f "$HOME/.config/nvim/init.vim" ] && rm "$HOME/.config/nvim/init.vim"
        cp -r "$REPO_DIR/.config/nvim/." "$HOME/.config/nvim/"
        echo "Deployed Neovim configuration to $HOME/.config/nvim"
    fi
else
    echo "Deploying Neovim Vimscript configuration..."
    # Remove Lua config directory if it exists to avoid conflicts
    [ -d "$HOME/.config/nvim/lua" ] && rm -rf "$HOME/.config/nvim/lua"
    [ -f "$HOME/.config/nvim/init.lua" ] && rm "$HOME/.config/nvim/init.lua"
    deploy_file "$REPO_DIR/myvimrc" "$HOME/.config/nvim/init.vim"
    deploy_file "$REPO_DIR/.config/nvim/syntax/computesanitizer.vim" "$HOME/.config/nvim/syntax/computesanitizer.vim"
    deploy_file "$REPO_DIR/.config/nvim/syntax/terra.vim"            "$HOME/.config/nvim/syntax/terra.vim"
    deploy_file "$REPO_DIR/.config/nvim/indent/terra.vim"            "$HOME/.config/nvim/indent/terra.vim"
fi

deploy_file "$REPO_DIR/.tigrc"      "$HOME/.tigrc"
deploy_file "$REPO_DIR/.vifm/vifmrc" "$HOME/.vifm/vifmrc"
deploy_file "$REPO_DIR/.tmux.conf" "$HOME/.tmux.conf"
deploy_file "$REPO_DIR/.ripgreprc" "$HOME/.ripgreprc"
deploy_file "$REPO_DIR/.gdbinit"    "$HOME/.gdbinit"
deploy_file "$REPO_DIR/.cgdb/cgdbrc" "$HOME/.cgdb/cgdbrc"
deploy_file "$REPO_DIR/.gitconfig" "$HOME/.gitconfig"

# Config directories
deploy_file "$REPO_DIR/.config/ranger/rc.conf"      "$HOME/.config/ranger/rc.conf"
deploy_file "$REPO_DIR/.config/ranger/commands.py"  "$HOME/.config/ranger/commands.py"
deploy_file "$REPO_DIR/.config/ranger/scope.sh"     "$HOME/.config/ranger/scope.sh"
if [ -d "$REPO_DIR/.config/ranger/colorschemes" ]; then
    mkdir -p "$HOME/.config/ranger/colorschemes"
    cp -r "$REPO_DIR/.config/ranger/colorschemes/"* "$HOME/.config/ranger/colorschemes/"
fi
chmod +x "$HOME/.config/ranger/scope.sh" 2>/dev/null
deploy_file "$REPO_DIR/.config/lf/lfrc"             "$HOME/.config/lf/lfrc"
deploy_file "$REPO_DIR/.config/lf/icons"            "$HOME/.config/lf/icons"
deploy_file "$REPO_DIR/.config/lf/colors"           "$HOME/.config/lf/colors"
deploy_file "$REPO_DIR/.config/git/ignore"          "$HOME/.config/git/ignore"
deploy_file "$REPO_DIR/.config/fd/ignore"           "$HOME/.config/fd/ignore"

# Starship configuration
deploy_file "$REPO_DIR/.config/starship.toml"        "$HOME/.config/starship.toml"

# Alacritty configuration
deploy_file "$REPO_DIR/.config/alacritty/alacritty.toml" "$HOME/.config/alacritty/alacritty.toml"
deploy_file "$REPO_DIR/.config/alacritty/theme.toml"     "$HOME/.config/alacritty/theme.toml"
if [ -f "$REPO_DIR/.config/alacritty/shell.toml" ]; then
    if grep -qi '\.exe"' "$REPO_DIR/.config/alacritty/shell.toml" 2>/dev/null; then
        echo "Notice: Repository shell.toml targets Windows. Deploying default shell config for Linux."
        mkdir -p "$HOME/.config/alacritty"
        cat << 'EOF' > "$HOME/.config/alacritty/shell.toml"
# Default shell configuration for Alacritty
# Automatically uses native $SHELL (/usr/bin/bash, fish, zsh, etc.)
EOF
    else
        deploy_file "$REPO_DIR/.config/alacritty/shell.toml" "$HOME/.config/alacritty/shell.toml"
    fi
fi
if [ -d "$REPO_DIR/.config/alacritty/themes" ]; then
    mkdir -p "$HOME/.config/alacritty/themes"
    cp -r "$REPO_DIR/.config/alacritty/themes/"* "$HOME/.config/alacritty/themes/" 2>/dev/null || true
fi

# MPV configuration
deploy_file "$REPO_DIR/.config/mpv/mpv.conf" "$HOME/.config/mpv/mpv.conf"

# w3m configuration
deploy_file "$REPO_DIR/.w3m/config" "$HOME/.w3m/config"
deploy_file "$REPO_DIR/.w3m/keymap" "$HOME/.w3m/keymap"

# Yazi configuration
echo "Deploying Yazi configuration..."
deploy_file "$REPO_DIR/.config/yazi/theme.toml"             "$HOME/.config/yazi/theme.toml"
deploy_file "$REPO_DIR/.config/yazi/keymap.toml"            "$HOME/.config/yazi/keymap.toml"
# Note: yazi_windows.toml is present but usually yazi expects yazi.toml on Linux
if [ -f "$REPO_DIR/.config/yazi/yazi.toml" ]; then
    deploy_file "$REPO_DIR/.config/yazi/yazi.toml"          "$HOME/.config/yazi/yazi.toml"
fi

# SSH base configuration
echo "Deploying SSH base configuration..."
mkdir -p "$HOME/.ssh/sockets" "$HOME/.ssh/conf.d"
chmod 700 "$HOME/.ssh" "$HOME/.ssh/sockets" 2>/dev/null
deploy_file "$REPO_DIR/.config/ssh/config.base" "$HOME/.ssh/config.base"
chmod 600 "$HOME/.ssh/config.base" 2>/dev/null

if [ ! -f "$HOME/.ssh/config" ]; then
    echo "Include ~/.ssh/config.base" > "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config" 2>/dev/null
elif ! grep -q "config.base" "$HOME/.ssh/config" 2>/dev/null; then
    _tmp_ssh_cfg=$(mktemp)
    echo "Include ~/.ssh/config.base" > "$_tmp_ssh_cfg"
    cat "$HOME/.ssh/config" >> "$_tmp_ssh_cfg"
    mv "$_tmp_ssh_cfg" "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config" 2>/dev/null
fi

# Binaries

echo "Deploying binaries to ~/bin/..."
for f in "$REPO_DIR/bin/"*; do
    if [ -f "$f" ]; then
        deploy_file "$f" "$HOME/bin/$(basename "$f")"
        chmod +x "$HOME/bin/$(basename "$f")"
    fi
done

# Check sshfs availability
if ! command -v sshfs >/dev/null 2>&1; then
    echo "Tip: 'sshfs' is not installed. Install it via package manager (e.g. sudo apt install sshfs) to use rmount.sh."
fi

# 3b. Ensure ~/.gitconfig.local holds the Git commit identity.
# Name and email come from GIT_USER_NAME / GIT_USER_EMAIL, or from a prompt
# when stdin is a terminal. An identity that already exists is never changed.
ensure_git_identity() {
    local local_config="$HOME/.gitconfig.local"
    local user_name="${GIT_USER_NAME:-}"
    local user_email="${GIT_USER_EMAIL:-}"

    if ! command -v git >/dev/null 2>&1; then
        return 0
    fi

    if [ -f "$local_config" ] \
        && git config --file "$local_config" user.name >/dev/null 2>&1 \
        && git config --file "$local_config" user.email >/dev/null 2>&1; then
        echo "Git identity already set in $local_config"
        return 0
    fi

    if [ -z "$user_name" ] || [ -z "$user_email" ]; then
        if [ ! -t 0 ]; then
            echo "Warning: Git identity not set and no terminal to ask on." >&2
            echo "  Set GIT_USER_NAME and GIT_USER_EMAIL, then re-run ./deploy.sh," >&2
            echo "  or run: git config --file ~/.gitconfig.local user.name 'Your Name'" >&2
            return 0
        fi

        echo "Git identity not set in $local_config"
        read -r -p "  Name:  " user_name
        read -r -p "  Email: " user_email
    fi

    if [ -z "$user_name" ] || [ -z "$user_email" ]; then
        echo "Warning: empty name or email; Git identity not saved." >&2
        return 0
    fi

    if ! git config --file "$local_config" user.name "$user_name" \
        || ! git config --file "$local_config" user.email "$user_email"; then
        echo "Error: could not write Git identity to $local_config" >&2
        return 1
    fi

    echo "Saved Git identity to $local_config"
}

ensure_git_identity

# 4. Handle legacy Git versions (< 2.35.0) for 'zdiff3' compatibility
if command -v git >/dev/null 2>&1; then
    GIT_VER=$(git --version | awk '{print $3}' | grep -oE '^[0-9]+\.[0-9]+')
    IFS='.' read -r major minor <<< "$GIT_VER"
    
    if [[ -n "$major" && -n "$minor" ]]; then
        if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
            echo "Detected legacy Git version ($GIT_VER < 2.35) which does not support 'zdiff3'."
            
            # Ensure ~/.gitconfig.local has the fallback
            if [ ! -f "$HOME/.gitconfig.local" ] || ! grep -q "conflictstyle" "$HOME/.gitconfig.local" 2>/dev/null; then
                echo -e "\n[merge]\n\tconflictstyle = diff3" >> "$HOME/.gitconfig.local"
                echo "Added legacy 'conflictstyle = diff3' fallback to ~/.gitconfig.local"
            else
                echo "~/.gitconfig.local already configured."
            fi
        fi
    fi
fi

# 5. Install Starship prompt if missing
if ! command -v starship >/dev/null 2>&1; then
    if [[ "$OSTYPE" != "msys" && "$OSTYPE" != "cygwin" && "$OSTYPE" != "win32" ]]; then
        mkdir -p "$HOME/bin"
        curl -sS https://starship.rs/install.sh | sh -s -- --yes -b "$HOME/bin"
    fi
fi

# 6. Install missing plugins and tools (TPM, fonts, fzf-git.sh, forgit, ranger_devicons)
echo "Installing shell plugins and fonts..."
IS_WINDOWS=false
[[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]] && IS_WINDOWS=true

if ! $IS_WINDOWS; then
    # Install vim-plug if missing
    if [ ! -f "$HOME/.vim/autoload/plug.vim" ]; then
        echo "Installing vim-plug for Vim..."
        curl -fLo "$HOME/.vim/autoload/plug.vim" --create-dirs \
            https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    fi

    if [ ! -f "$HOME/.local/share/nvim/site/autoload/plug.vim" ]; then
        echo "Installing vim-plug for Neovim..."
        curl -fLo "$HOME/.local/share/nvim/site/autoload/plug.vim" --create-dirs \
            https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    fi

    # Install TPM (Tmux Plugin Manager) if missing
    if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
        echo "Installing TPM for Tmux..."
        git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
    fi
fi

if $IS_WINDOWS; then
    echo "Creating directory junctions for Git Bash Vim compatibility..."
    mkdir -p "$HOME/.vim"
    if [ ! -d "$HOME/.vim/autoload" ]; then
        cmd //c mklink //J "$(cygpath -w "$HOME/.vim/autoload")" "$(cygpath -w "$HOME/vimfiles/autoload")"
    fi
    if [ ! -d "$HOME/.vim/plugged" ]; then
        cmd //c mklink //J "$(cygpath -w "$HOME/.vim/plugged")" "$(cygpath -w "$HOME/vimfiles/plugged")"
    fi
fi

# Install Hack Nerd Font variations if missing
if [[ "$OSTYPE" == darwin* ]]; then
    if [ ! -f "$HOME/Library/Fonts/HackNerdFont-Regular.ttf" ] && \
       [ ! -f "$HOME/Library/Fonts/Hack Nerd Font Complete.ttf" ]; then
        if command -v brew >/dev/null 2>&1; then
            echo "Installing Hack Nerd Font via Homebrew..."
            brew install --cask font-hack-nerd-font
        fi
    fi
elif [[ "$OSTYPE" == linux* ]]; then
    if [ ! -f "$HOME/.local/share/fonts/HackNerdFont-Regular.ttf" ]; then
        echo "Installing all Hack Nerd Font variations..."
        mkdir -p "$HOME/.local/share/fonts"
        _tmp_font=$(mktemp)
        if curl -sSLo "$_tmp_font" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Hack.tar.xz"; then
            tar -xJf "$_tmp_font" -C "$HOME/.local/share/fonts" --wildcards "*.ttf"
            command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$HOME/.local/share/fonts"
        fi
        rm -f "$_tmp_font"
    fi
fi

PLUGINS_DIR="$HOME/.local/share"
mkdir -p "$PLUGINS_DIR"

install_plugin() {
    local repo=$1
    local name
    name=$(basename "$repo")
    local dir="$PLUGINS_DIR/$name"
    if [ ! -d "$dir" ]; then
        echo "Installing $repo..."
        git clone --depth 1 "https://github.com/$repo.git" "$dir"
    fi
}

install_plugin "junegunn/fzf-git.sh"
install_plugin "wfxr/forgit"

# MPV Plugins (uosc, mpv-cut, thumbfast, autoload, quality-menu)
MPV_DIR="$HOME/.config/mpv"
UOSC_REPO_DIR="$MPV_DIR/uosc"
MPV_CUT_DIR="$MPV_DIR/scripts/mpv-cut"
THUMBFAST_REPO_DIR="$MPV_DIR/thumbfast"
QUALITY_MENU_REPO_DIR="$MPV_DIR/quality-menu"

mkdir -p "$MPV_DIR/scripts" "$MPV_DIR/fonts" "$MPV_DIR/script-opts"

if command -v git >/dev/null 2>&1; then
    # 1. uosc
    if [ ! -d "$UOSC_REPO_DIR" ]; then
        echo "Cloning uosc for mpv..."
        git clone --depth 1 https://github.com/tomasklaen/uosc.git "$UOSC_REPO_DIR"
    fi
    if [ -d "$UOSC_REPO_DIR" ]; then
        echo "Deploying uosc components for mpv..."
        [ -d "$UOSC_REPO_DIR/src/uosc" ] && cp -r "$UOSC_REPO_DIR/src/uosc" "$MPV_DIR/scripts/"
        [ -d "$UOSC_REPO_DIR/src/fonts" ] && cp -r "$UOSC_REPO_DIR/src/fonts/"* "$MPV_DIR/fonts/"
        if [ -f "$UOSC_REPO_DIR/src/uosc.conf" ] && [ ! -f "$MPV_DIR/script-opts/uosc.conf" ]; then
            cp "$UOSC_REPO_DIR/src/uosc.conf" "$MPV_DIR/script-opts/uosc.conf"
        fi
    fi

    # 2. mpv-cut
    if [ ! -d "$MPV_CUT_DIR" ]; then
        echo "Cloning mpv-cut for mpv..."
        git clone -b release --single-branch --depth 1 https://github.com/familyfriendlymikey/mpv-cut.git "$MPV_CUT_DIR" 2>/dev/null || git clone --depth 1 https://github.com/familyfriendlymikey/mpv-cut.git "$MPV_CUT_DIR"
    fi
    if [ -f "$REPO_DIR/.config/mpv-cut/config.lua" ]; then
        deploy_file "$REPO_DIR/.config/mpv-cut/config.lua" "$MPV_CUT_DIR/config.lua"
    fi

    # 3. thumbfast
    if [ ! -d "$THUMBFAST_REPO_DIR" ]; then
        echo "Cloning thumbfast for mpv..."
        git clone --depth 1 https://github.com/po5/thumbfast.git "$THUMBFAST_REPO_DIR"
    fi
    if [ -d "$THUMBFAST_REPO_DIR" ]; then
        echo "Deploying thumbfast for mpv..."
        [ -f "$THUMBFAST_REPO_DIR/thumbfast.lua" ] && cp "$THUMBFAST_REPO_DIR/thumbfast.lua" "$MPV_DIR/scripts/thumbfast.lua"
        if [ -f "$THUMBFAST_REPO_DIR/thumbfast.conf" ] && [ ! -f "$MPV_DIR/script-opts/thumbfast.conf" ]; then
            cp "$THUMBFAST_REPO_DIR/thumbfast.conf" "$MPV_DIR/script-opts/thumbfast.conf"
        fi
    fi

    # 4. quality-menu
    if [ ! -d "$QUALITY_MENU_REPO_DIR" ]; then
        echo "Cloning quality-menu for mpv..."
        git clone --depth 1 https://github.com/christoph-heinrich/mpv-quality-menu.git "$QUALITY_MENU_REPO_DIR"
    fi
    if [ -d "$QUALITY_MENU_REPO_DIR" ]; then
        echo "Deploying quality-menu for mpv..."
        [ -f "$QUALITY_MENU_REPO_DIR/quality-menu.lua" ] && cp "$QUALITY_MENU_REPO_DIR/quality-menu.lua" "$MPV_DIR/scripts/quality-menu.lua"
        if [ -f "$QUALITY_MENU_REPO_DIR/quality-menu.conf" ] && [ ! -f "$MPV_DIR/script-opts/quality-menu.conf" ]; then
            cp "$QUALITY_MENU_REPO_DIR/quality-menu.conf" "$MPV_DIR/script-opts/quality-menu.conf"
        fi
    fi

    # 5. sponsorblock
    SPONSORBLOCK_REPO_DIR="$MPV_DIR/sponsorblock"
    if [ ! -d "$SPONSORBLOCK_REPO_DIR" ]; then
        echo "Cloning sponsorblock for mpv..."
        git clone --depth 1 https://github.com/po5/mpv_sponsorblock.git "$SPONSORBLOCK_REPO_DIR"
    fi
    if [ -d "$SPONSORBLOCK_REPO_DIR" ]; then
        echo "Deploying sponsorblock for mpv..."
        [ -f "$SPONSORBLOCK_REPO_DIR/sponsorblock.lua" ] && cp "$SPONSORBLOCK_REPO_DIR/sponsorblock.lua" "$MPV_DIR/scripts/sponsorblock.lua"
        if [ -d "$SPONSORBLOCK_REPO_DIR/sponsorblock_shared" ]; then
            mkdir -p "$MPV_DIR/scripts/sponsorblock_shared"
            cp -r "$SPONSORBLOCK_REPO_DIR/sponsorblock_shared/"* "$MPV_DIR/scripts/sponsorblock_shared/"
        fi
    fi
fi

# 6. autoload

if [ ! -f "$MPV_DIR/scripts/autoload.lua" ]; then
    echo "Downloading autoload.lua for mpv..."
    if command -v curl >/dev/null 2>&1; then
        curl -sLo "$MPV_DIR/scripts/autoload.lua" https://raw.githubusercontent.com/mpv-player/mpv/master/TOOLS/lua/autoload.lua
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$MPV_DIR/scripts/autoload.lua" https://raw.githubusercontent.com/mpv-player/mpv/master/TOOLS/lua/autoload.lua
    fi
fi

# 7. mpv-webm
if [ ! -f "$MPV_DIR/scripts/webm.lua" ]; then
    echo "Downloading webm.lua for mpv..."
    if command -v curl >/dev/null 2>&1; then
        curl -sLo "$MPV_DIR/scripts/webm.lua" "https://github.com/ekisu/mpv-webm/releases/download/latest/webm.lua"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$MPV_DIR/scripts/webm.lua" "https://github.com/ekisu/mpv-webm/releases/download/latest/webm.lua"
    fi
fi

echo "Deployment complete! Please restart your shell or run 'source ~/.bashrc'."
