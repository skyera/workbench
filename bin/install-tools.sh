#!/usr/bin/env bash
# =============================================================================
# bin/install-tools.sh - Modern CLI & Runtime Toolchain Installer
#
# Automates the installation of essential tools across Linux and macOS.
# Supports three modes:
#   1. --release (Default): Fetch latest static standalone binaries from GitHub
#                           into ~/.local/bin (no root/sudo or compilers required)
#   2. --source:            Compile latest versions via cargo / make
#   3. --pm:                Install using system package manager (pacman/apt/dnf/brew)
# =============================================================================

set -euo pipefail

# Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_CYAN="\033[36m"
C_RED="\033[31m"
C_GRAY="\033[90m"

# Default configuration
ACTION="install"        # "install", "uninstall"
INSTALL_MODE="release"  # "release", "source", "pm"
DEST_DIR=""
DRY_RUN=false
VERBOSE=false
SELECTED_TOOLS=""

# All supported tools
ALL_TOOLS=(
    "rg"
    "fd"
    "bat"
    "eza"
    "delta"
    "fzf"
    "zoxide"
    "starship"
    "yazi"
    "luajit"
    "nvim"
    "sd"
    "btm"
    "dust"
    "tldr"
)

# -----------------------------------------------------------------------------
# OS & Architecture Detection
# -----------------------------------------------------------------------------
detect_environment() {
    OS_TYPE="$(uname -s)"
    ARCH_TYPE="$(uname -m)"

    case "$OS_TYPE" in
        Linux)   TARGET_OS="linux" ;;
        Darwin)  TARGET_OS="darwin" ;;
        MSYS*|MINGW*|CYGWIN*) TARGET_OS="windows" ;;
        *)       TARGET_OS="unknown" ;;
    esac

    case "$ARCH_TYPE" in
        x86_64|amd64)   TARGET_ARCH="x86_64" ;;
        aarch64|arm64)  TARGET_ARCH="aarch64" ;;
        armv7*|armhf)   TARGET_ARCH="armv7" ;;
        *)              TARGET_ARCH="$ARCH_TYPE" ;;
    esac
}

detect_package_manager() {
    if command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v brew >/dev/null 2>&1; then
        echo "brew"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "unknown"
    fi
}

resolve_dest_dir() {
    if [[ -n "$DEST_DIR" ]]; then
        return
    fi
    if [[ -d "$HOME/.local/bin" ]] || [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
        DEST_DIR="$HOME/.local/bin"
    elif [[ -d "$HOME/bin" ]] || [[ ":$PATH:" == *":$HOME/bin:"* ]]; then
        DEST_DIR="$HOME/bin"
    else
        DEST_DIR="$HOME/.local/bin"
    fi
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log_info()    { echo -e "${C_CYAN}${C_BOLD}[INFO]${C_RESET} $*"; }
log_ok()      { echo -e "${C_GREEN}${C_BOLD}[  OK  ]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}${C_BOLD}[WARN]${C_RESET} $*"; }
log_error()   { echo -e "${C_RED}${C_BOLD}[FAIL]${C_RESET} $*"; }
log_step()    { echo -e "\n${C_BLUE}${C_BOLD}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }

get_download_cmd() {
    if command -v curl >/dev/null 2>&1; then
        echo "curl -fL"
    elif command -v wget >/dev/null 2>&1; then
        echo "wget -qO-"
    else
        log_error "Neither curl nor wget is available. Please install one of them."
        exit 1
    fi
}

get_github_latest_tag() {
    local repo="$1"
    local tag=""
    if command -v curl >/dev/null 2>&1; then
        tag=$(curl -sSL -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    if [[ -z "$tag" ]] && command -v git >/dev/null 2>&1; then
        tag=$(git ls-remote --tags --refs "https://github.com/${repo}.git" 2>/dev/null | tail -n 1 | awk -F/ '{print $NF}')
    fi
    echo "$tag"
}

# -----------------------------------------------------------------------------
# Tool Version and Path Checker
# -----------------------------------------------------------------------------
get_tool_info() {
    local bin="$1"
    local path
    path=$(command -v "$bin" 2>/dev/null || true)
    if [[ -z "$path" && "$bin" == "bat" ]]; then
        path=$(command -v "batcat" 2>/dev/null || true)
    elif [[ -z "$path" && "$bin" == "fd" ]]; then
        path=$(command -v "fdfind" 2>/dev/null || true)
    fi

    if [[ -n "$path" ]]; then
        local ver=""
        case "$bin" in
            rg)       ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            fd)       ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            bat)      ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            eza)      ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            delta)    ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            fzf)      ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $1}') ;;
            zoxide)   ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            starship) ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            yazi)     ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            luajit)   ver=$("$path" -v 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            nvim)     ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            sd)       ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            btm)      ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            dust)     ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            tldr)     ver=$("$path" --version 2>/dev/null | head -n 1 | awk '{print $2}') ;;
            *)        ver=$("$path" --version 2>/dev/null | head -n 1 || echo "installed") ;;
        esac
        echo "${path}|${ver:-unknown}"
    else
        echo "missing|"
    fi
}

cmd_list() {
    detect_environment
    resolve_dest_dir

    echo -e "${C_CYAN}${C_BOLD}=== Workbench CLI Toolchain Status ===${C_RESET}"
    echo -e "OS: ${C_BOLD}${TARGET_OS}${C_RESET} (${TARGET_ARCH}) | Default Install Path: ${C_BOLD}${DEST_DIR}${C_RESET}\n"
    printf "${C_BOLD}%-10s %-12s %-10s %-40s${C_RESET}\n" "TOOL" "STATUS" "VERSION" "LOCATION"
    echo "────────────────────────────────────────────────────────────────────────────"

    for tool in "${ALL_TOOLS[@]}"; do
        local info
        info=$(get_tool_info "$tool")
        local loc="${info%%|*}"
        local ver="${info##*|}"

        if [[ "$loc" == "missing" ]]; then
            printf "%-10s ${C_RED}%-12s${C_RESET} %-10s ${C_GRAY}%-40s${C_RESET}\n" "$tool" "MISSING" "-" "-"
        else
            printf "%-10s ${C_GREEN}%-12s${C_RESET} %-10s %-40s\n" "$tool" "INSTALLED" "$ver" "$loc"
        fi
    done
    echo ""
}

# -----------------------------------------------------------------------------
# GitHub Release Binary Installer (--release)
# -----------------------------------------------------------------------------
install_release_asset() {
    local tool="$1"
    local repo="$2"
    local url="$3"
    local archive_type="$4"  # "tar.gz", "tar.xz", "zip", "raw"
    local bin_subpath="$5"   # Path inside archive or empty

    log_step "Installing ${tool} from GitHub Releases (${repo})..."

    if $DRY_RUN; then
        echo "  [Dry Run] Would download: $url"
        echo "  [Dry Run] Target location: $DEST_DIR/$tool"
        return 0
    fi

    mkdir -p "$DEST_DIR"
    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/wb-install-${tool}.XXXXXX")

    local dl_file="$tmp_dir/download.$archive_type"
    log_info "Downloading $url ..."
    if command -v curl >/dev/null 2>&1; then
        if ! curl -sSL -f -o "$dl_file" "$url"; then
            log_error "Failed to download $url"
            rm -rf "$tmp_dir"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q -O "$dl_file" "$url"; then
            log_error "Failed to download $url"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    log_info "Extracting and installing to $DEST_DIR/$tool ..."
    case "$archive_type" in
        tar.gz|tgz)
            tar -xzf "$dl_file" -C "$tmp_dir"
            ;;
        tar.xz)
            tar -xJf "$dl_file" -C "$tmp_dir"
            ;;
        zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -q "$dl_file" -d "$tmp_dir"
            else
                log_error "unzip command is required to extract $tool. Please install unzip."
                rm -rf "$tmp_dir"
                return 1
            fi
            ;;
        raw)
            mv "$dl_file" "$tmp_dir/$tool"
            ;;
    esac

    # Find the executable file inside extracted contents
    local found_bin=""
    if [[ -n "$bin_subpath" && -f "$tmp_dir/$bin_subpath" ]]; then
        found_bin="$tmp_dir/$bin_subpath"
    else
        found_bin=$(find "$tmp_dir" -type f -name "$tool" -perm /111 2>/dev/null | head -n 1 || true)
        if [[ -z "$found_bin" ]]; then
            found_bin=$(find "$tmp_dir" -type f -name "$tool" 2>/dev/null | head -n 1 || true)
        fi
    fi

    if [[ -n "$found_bin" && -f "$found_bin" ]]; then
        chmod +x "$found_bin"
        cp -f "$found_bin" "$DEST_DIR/$tool"
        log_ok "${tool} successfully installed to $DEST_DIR/$tool"
        rm -rf "$tmp_dir"
        return 0
    else
        log_error "Could not locate executable '${tool}' inside downloaded archive."
        rm -rf "$tmp_dir"
        return 1
    fi
}

install_release_tool() {
    local tool="$1"
    local tag=""

    case "$tool" in
        rg)
            tag=$(get_github_latest_tag "BurntSushi/ripgrep")
            tag="${tag:-14.1.0}"
            local clean_ver="${tag#v}"
            local asset="ripgrep-${clean_ver}-${TARGET_ARCH}-unknown-linux-musl.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="ripgrep-${clean_ver}-${TARGET_ARCH}-apple-darwin.tar.gz"
            install_release_asset "rg" "BurntSushi/ripgrep" \
                "https://github.com/BurntSushi/ripgrep/releases/download/${tag}/${asset}" "tar.gz" "ripgrep-${clean_ver}-${TARGET_ARCH}-unknown-linux-musl/rg"
            ;;

        fd)
            tag=$(get_github_latest_tag "sharkdp/fd")
            tag="${tag:-v10.2.0}"
            local clean_ver="${tag#v}"
            local asset="fd-${tag}-${TARGET_ARCH}-unknown-linux-musl.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="fd-${tag}-${TARGET_ARCH}-apple-darwin.tar.gz"
            install_release_asset "fd" "sharkdp/fd" \
                "https://github.com/sharkdp/fd/releases/download/${tag}/${asset}" "tar.gz" "fd-${tag}-${TARGET_ARCH}-unknown-linux-musl/fd"
            ;;

        bat)
            tag=$(get_github_latest_tag "sharkdp/bat")
            tag="${tag:-v0.24.0}"
            local asset="bat-${tag}-${TARGET_ARCH}-unknown-linux-musl.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="bat-${tag}-${TARGET_ARCH}-apple-darwin.tar.gz"
            install_release_asset "bat" "sharkdp/bat" \
                "https://github.com/sharkdp/bat/releases/download/${tag}/${asset}" "tar.gz" "bat-${tag}-${TARGET_ARCH}-unknown-linux-musl/bat"
            ;;

        eza)
            tag=$(get_github_latest_tag "eza-community/eza")
            tag="${tag:-v0.20.19}"
            local asset="eza_${TARGET_ARCH}-unknown-linux-musl.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="eza_${TARGET_ARCH}-apple-darwin.tar.gz"
            install_release_asset "eza" "eza-community/eza" \
                "https://github.com/eza-community/eza/releases/download/${tag}/${asset}" "tar.gz" "eza"
            ;;

        delta)
            tag=$(get_github_latest_tag "dandavison/delta")
            tag="${tag:-0.18.2}"
            local clean_ver="${tag#v}"
            local asset="delta-${clean_ver}-${TARGET_ARCH}-unknown-linux-musl.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="delta-${clean_ver}-${TARGET_ARCH}-apple-darwin.tar.gz"
            install_release_asset "delta" "dandavison/delta" \
                "https://github.com/dandavison/delta/releases/download/${clean_ver}/${asset}" "tar.gz" "delta-${clean_ver}-${TARGET_ARCH}-unknown-linux-musl/delta"
            ;;

        fzf)
            log_step "Installing fzf via official git release..."
            if $DRY_RUN; then
                echo "  [Dry Run] Would clone and install fzf into ~/.fzf and symlink to $DEST_DIR/fzf"
                return 0
            fi
            if [[ ! -d "$HOME/.fzf" ]]; then
                git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
            else
                git -C "$HOME/.fzf" pull --quiet || true
            fi
            "$HOME/.fzf/install" --bin --no-key-bindings --no-completion --no-update-rc
            mkdir -p "$DEST_DIR"
            cp -f "$HOME/.fzf/bin/fzf" "$DEST_DIR/fzf"
            log_ok "fzf installed to $DEST_DIR/fzf"
            ;;

        zoxide)
            log_step "Installing zoxide via official installer..."
            if $DRY_RUN; then
                echo "  [Dry Run] Would run: curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash"
                return 0
            fi
            curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
            log_ok "zoxide installed."
            ;;

        starship)
            log_step "Installing starship prompt..."
            if $DRY_RUN; then
                echo "  [Dry Run] Would run: curl -sS https://starship.rs/install.sh | sh -s -- --yes -b $DEST_DIR"
                return 0
            fi
            mkdir -p "$DEST_DIR"
            curl -sS https://starship.rs/install.sh | sh -s -- --yes -b "$DEST_DIR"
            log_ok "starship installed to $DEST_DIR/starship"
            ;;

        yazi)
            tag=$(get_github_latest_tag "sxyazi/yazi")
            tag="${tag:-v25.3.2}"
            local asset="yazi-${TARGET_ARCH}-unknown-linux-musl.zip"
            [[ "$TARGET_OS" == "darwin" ]] && asset="yazi-${TARGET_ARCH}-apple-darwin.zip"
            install_release_asset "yazi" "sxyazi/yazi" \
                "https://github.com/sxyazi/yazi/releases/download/${tag}/${asset}" "zip" ""
            ;;

        nvim)
            log_step "Installing Neovim from GitHub Releases..."
            tag=$(get_github_latest_tag "neovim/neovim")
            tag="${tag:-stable}"
            local asset="nvim-linux-x86_64.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="nvim-macos-x86_64.tar.gz"
            [[ "$TARGET_OS" == "darwin" && "$TARGET_ARCH" == "aarch64" ]] && asset="nvim-macos-arm64.tar.gz"

            local url="https://github.com/neovim/neovim/releases/download/${tag}/${asset}"
            install_release_asset "nvim" "neovim/neovim" "$url" "tar.gz" ""
            ;;

        luajit)
            log_step "Installing LuaJIT from source / official repo..."
            if $DRY_RUN; then
                echo "  [Dry Run] Would clone and build LuaJIT to $HOME/.local"
                return 0
            fi
            local tmp_lua
            tmp_lua=$(mktemp -d "/tmp/wb-luajit.XXXXXX")
            git clone --depth 1 https://github.com/LuaJIT/LuaJIT.git "$tmp_lua"
            make -C "$tmp_lua" -j"$(nproc 2>/dev/null || echo 2)"
            make -C "$tmp_lua" install PREFIX="$HOME/.local"
            rm -rf "$tmp_lua"
            mkdir -p "$DEST_DIR"
            # Ensure luajit symlink exists in DEST_DIR
            if [[ -f "$HOME/.local/bin/luajit" && ! -f "$DEST_DIR/luajit" ]]; then
                ln -sf "$HOME/.local/bin/luajit" "$DEST_DIR/luajit"
            fi
            log_ok "luajit installed to $HOME/.local/bin/luajit"
            ;;

        sd)
            tag=$(get_github_latest_tag "chmln/sd")
            tag="${tag:-v1.0.0}"
            local asset="sd-${tag}-${TARGET_ARCH}-unknown-linux-musl.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="sd-${tag}-${TARGET_ARCH}-apple-darwin.tar.gz"
            install_release_asset "sd" "chmln/sd" \
                "https://github.com/chmln/sd/releases/download/${tag}/${asset}" "tar.gz" ""
            ;;

        btm)
            tag=$(get_github_latest_tag "ClementTsang/bottom")
            tag="${tag:-0.10.2}"
            local clean_ver="${tag#v}"
            local asset="bottom_${TARGET_ARCH}-unknown-linux-musl.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="bottom_${TARGET_ARCH}-apple-darwin.tar.gz"
            install_release_asset "btm" "ClementTsang/bottom" \
                "https://github.com/ClementTsang/bottom/releases/download/${clean_ver}/${asset}" "tar.gz" "btm"
            ;;

        dust)
            tag=$(get_github_latest_tag "bootandy/dust")
            tag="${tag:-v1.1.1}"
            local asset="dust-${tag}-${TARGET_ARCH}-unknown-linux-musl.tar.gz"
            [[ "$TARGET_OS" == "darwin" ]] && asset="dust-${tag}-${TARGET_ARCH}-apple-darwin.tar.gz"
            install_release_asset "dust" "bootandy/dust" \
                "https://github.com/bootandy/dust/releases/download/${tag}/${asset}" "tar.gz" ""
            ;;

        tldr)
            tag=$(get_github_latest_tag "dbrgn/tealdeer")
            tag="${tag:-v1.7.1}"
            local asset="tealdeer-linux-${TARGET_ARCH}-musl"
            [[ "$TARGET_OS" == "darwin" ]] && asset="tealdeer-macos-${TARGET_ARCH}"
            install_release_asset "tldr" "dbrgn/tealdeer" \
                "https://github.com/dbrgn/tealdeer/releases/download/${tag}/${asset}" "raw" ""
            ;;

        *)
            log_warn "Unknown release target: $tool"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Source Build Installer (--source via cargo/make)
# -----------------------------------------------------------------------------
install_source_tool() {
    local tool="$1"
    log_step "Compiling ${tool} from source..."

    if [[ "$tool" == "luajit" ]]; then
        install_release_tool "luajit"
        return $?
    fi

    if [[ "$tool" == "fzf" ]]; then
        install_release_tool "fzf"
        return $?
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        log_error "Cargo (Rust toolchain) is not installed. Run 'curl https://sh.rustup.rs -sSf | sh' first or use --release."
        return 1
    fi

    if $DRY_RUN; then
        echo "  [Dry Run] Would run: cargo install <crate> --locked"
        return 0
    fi

    case "$tool" in
        rg)       cargo install ripgrep --locked ;;
        fd)       cargo install fd-find --locked ;;
        bat)      cargo install bat --locked ;;
        eza)      cargo install eza --locked ;;
        delta)    cargo install git-delta --locked ;;
        zoxide)   cargo install zoxide --locked ;;
        starship) cargo install starship --locked ;;
        yazi)     cargo install --locked yazi-fm yazi-cli ;;
        sd)       cargo install sd --locked ;;
        btm)      cargo install bottom --locked ;;
        dust)     cargo install du-dust --locked ;;
        tldr)     cargo install tealdeer --locked ;;
        nvim)
            log_step "Building Neovim from git source..."
            local tmp_nvim
            tmp_nvim=$(mktemp -d "/tmp/wb-nvim.XXXXXX")
            git clone --depth 1 https://github.com/neovim/neovim.git "$tmp_nvim"
            make -C "$tmp_nvim" CMAKE_BUILD_TYPE=RelWithDebInfo
            make -C "$tmp_nvim" install PREFIX="$HOME/.local"
            rm -rf "$tmp_nvim"
            ;;
        *)
            log_warn "No source build recipe for $tool."
            return 1
            ;;
    esac
    log_ok "$tool successfully compiled and installed via Cargo/Make."
}

# -----------------------------------------------------------------------------
# System Package Manager Installer (--pm)
# -----------------------------------------------------------------------------
install_pm_tools() {
    local pm
    pm=$(detect_package_manager)
    log_step "Installing tools using system package manager (${pm})..."

    if $DRY_RUN; then
        echo "  [Dry Run] Would use package manager: $pm"
        return 0
    fi

    case "$pm" in
        pacman)
            local pkgs=(ripgrep fd bat eza git-delta fzf zoxide starship yazi luajit neovim sd bottom dust tealdeer entr)
            echo "Running: sudo pacman -S --needed ${pkgs[*]}"
            sudo pacman -S --needed "${pkgs[@]}"
            ;;
        apt)
            echo "Updating apt cache and installing available packages..."
            sudo apt-get update -y
            sudo apt-get install -y ripgrep fd-find bat fzf zoxide luajit neovim entr
            mkdir -p "$DEST_DIR"
            # Ubuntu/Debian naming fixes
            command -v fdfind >/dev/null 2>&1 && ln -sf "$(command -v fdfind)" "$DEST_DIR/fd"
            command -v batcat >/dev/null 2>&1 && ln -sf "$(command -v batcat)" "$DEST_DIR/bat"
            log_info "Note: Packages like eza, delta, yazi may require --release on older Ubuntu/Debian versions."
            ;;
        dnf)
            sudo dnf install -y ripgrep fd-find bat eza git-delta fzf zoxide starship luajit neovim
            ;;
        brew)
            brew install ripgrep fd bat eza git-delta fzf zoxide starship yazi luajit neovim sd bottom dust tealdeer entr
            ;;
        *)
            log_error "Unsupported package manager. Please use --release (pre-built binaries) instead."
            return 1
            ;;
    esac
}

uninstall_pm_tools() {
    local pm
    pm=$(detect_package_manager)
    log_step "Uninstalling tools using system package manager (${pm})..."

    if $DRY_RUN; then
        echo -e "  ${C_YELLOW}[Dry Run]${C_RESET} Would use package manager to uninstall: $pm"
        return 0
    fi

    case "$pm" in
        pacman)
            local pkgs=(ripgrep fd bat eza git-delta fzf zoxide starship yazi luajit neovim sd bottom dust tealdeer entr)
            echo "Running: sudo pacman -R ${pkgs[*]}"
            sudo pacman -R "${pkgs[@]}" || true
            ;;
        apt)
            echo "Running: sudo apt-get remove -y ripgrep fd-find bat fzf zoxide luajit neovim entr"
            sudo apt-get remove -y ripgrep fd-find bat fzf zoxide luajit neovim entr || true
            ;;
        dnf)
            echo "Running: sudo dnf remove -y ripgrep fd-find bat eza git-delta fzf zoxide starship luajit neovim"
            sudo dnf remove -y ripgrep fd-find bat eza git-delta fzf zoxide starship luajit neovim || true
            ;;
        brew)
            brew uninstall ripgrep fd bat eza git-delta fzf zoxide starship yazi luajit neovim sd bottom dust tealdeer entr || true
            ;;
        *)
            log_error "Unsupported package manager for uninstallation."
            return 1
            ;;
    esac
}

uninstall_tools() {
    log_step "Uninstalling tools from ${DEST_DIR}..."
    local removed_cnt=0

    for tool in "${TARGET_LIST[@]}"; do
        local target_bin="$DEST_DIR/$tool"
        local found=false

        if [[ -f "$target_bin" || -L "$target_bin" ]]; then
            found=true
            if $DRY_RUN; then
                echo -e "  ${C_YELLOW}[Dry Run]${C_RESET} Would remove: $target_bin"
                removed_cnt=$((removed_cnt + 1))
            else
                rm -f "$target_bin"
                log_ok "Removed $target_bin"
                removed_cnt=$((removed_cnt + 1))
            fi
        fi

        # Special companions (e.g. fdfind/batcat symlinks, ~/.fzf)
        if [[ "$tool" == "fd" && (-f "$DEST_DIR/fdfind" || -L "$DEST_DIR/fdfind") ]]; then
            if $DRY_RUN; then
                echo -e "  ${C_YELLOW}[Dry Run]${C_RESET} Would remove: $DEST_DIR/fdfind"
            else
                rm -f "$DEST_DIR/fdfind"
                log_ok "Removed $DEST_DIR/fdfind"
            fi
        fi
        if [[ "$tool" == "bat" && (-f "$DEST_DIR/batcat" || -L "$DEST_DIR/batcat") ]]; then
            if $DRY_RUN; then
                echo -e "  ${C_YELLOW}[Dry Run]${C_RESET} Would remove: $DEST_DIR/batcat"
            else
                rm -f "$DEST_DIR/batcat"
                log_ok "Removed $DEST_DIR/batcat"
            fi
        fi
        if [[ "$tool" == "fzf" && -d "$HOME/.fzf" ]]; then
            if $DRY_RUN; then
                echo -e "  ${C_YELLOW}[Dry Run]${C_RESET} Would remove: $HOME/.fzf"
            else
                rm -rf "$HOME/.fzf"
                log_ok "Removed $HOME/.fzf"
            fi
        fi

        if ! $found; then
            if $VERBOSE; then
                echo -e "  ${C_GRAY}[SKIP]   ${tool} not found in ${DEST_DIR}${C_RESET}"
            fi
        fi
    done

    echo ""
    if $DRY_RUN; then
        log_info "Dry run complete: ${removed_cnt} tools would be removed."
    else
        log_ok "Uninstallation complete: ${removed_cnt} tools removed."
    fi
}

# -----------------------------------------------------------------------------
# Main & CLI Parser
# -----------------------------------------------------------------------------
show_help() {
    cat << EOF
Workbench CLI Toolchain Installer & Uninstaller (bin/install-tools.sh)

Usage:
  ./bin/install-tools.sh [OPTIONS]

Options:
  -r, --release         Install latest pre-built static binaries from GitHub Releases (Default)
  -s, --source          Build from source using Cargo & Make
  -p, --pm, --package   Install using system package manager (pacman, apt, dnf, brew)
  -u, --uninstall       Uninstall tools from destination directory (or via package manager)
  -t, --tools <LIST>    Comma-separated list of tools to process (default: all)
  -d, --dir <DIR>       Destination directory for binaries (default: ~/.local/bin or ~/bin)
  -l, --list            Inspect and list status of all tools without installing
  -n, --dry-run         Print actions without downloading, installing, or removing
  -v, --verbose         Verbose diagnostic logging
  -h, --help            Show this help message

Available Tools:
  Core:         rg, fd, bat, eza, delta, fzf, zoxide, starship, yazi, luajit, nvim
  Productivity: sd, btm, dust, tldr

Examples:
  ./bin/install-tools.sh --list
  ./bin/install-tools.sh --release
  ./bin/install-tools.sh --release --tools "rg,fd,bat,eza,delta,zoxide,yazi"
  ./bin/install-tools.sh --source --tools "yazi,eza"
  ./bin/install-tools.sh --uninstall --tools "dust,sd,btm"
  ./bin/install-tools.sh --uninstall --dry-run
  ./bin/install-tools.sh --dir ~/bin
EOF
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -l|--list)
            cmd_list
            exit 0
            ;;
        -u|--uninstall)
            ACTION="uninstall"
            shift
            ;;
        -r|--release)
            INSTALL_MODE="release"
            shift
            ;;
        -s|--source)
            INSTALL_MODE="source"
            shift
            ;;
        -p|--pm|--package)
            INSTALL_MODE="pm"
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -d|--dir)
            DEST_DIR="$2"
            shift 2
            ;;
        -t|--tools)
            SELECTED_TOOLS="$2"
            shift 2
            ;;
        *)
            echo -e "${C_RED}Error: Unknown argument: $1${C_RESET}"
            show_help
            exit 1
            ;;
    esac
done

detect_environment
resolve_dest_dir

log_info "Detected OS: ${TARGET_OS} (${TARGET_ARCH})"
log_info "Action: ${ACTION}"
log_info "Installation mode: ${INSTALL_MODE}"
log_info "Destination directory: ${DEST_DIR}"

# Determine tool list
TARGET_LIST=()
if [[ -n "$SELECTED_TOOLS" ]]; then
    IFS=',' read -ra ADDR <<< "$SELECTED_TOOLS"
    for t in "${ADDR[@]}"; do
        # trim whitespace
        t=$(echo "$t" | xargs)
        [[ -n "$t" ]] && TARGET_LIST+=("$t")
    done
else
    TARGET_LIST=("${ALL_TOOLS[@]}")
fi

if [[ "$ACTION" == "uninstall" ]]; then
    if [[ "$INSTALL_MODE" == "pm" ]]; then
        uninstall_pm_tools
    else
        uninstall_tools
    fi
    exit 0
fi

if [[ "$INSTALL_MODE" == "pm" ]]; then
    install_pm_tools
    exit 0
fi

log_info "Tools to process: ${TARGET_LIST[*]}"

for tool in "${TARGET_LIST[@]}"; do
    if [[ "$INSTALL_MODE" == "release" ]]; then
        install_release_tool "$tool" || log_warn "Failed to install $tool via release mode."
    elif [[ "$INSTALL_MODE" == "source" ]]; then
        install_source_tool "$tool" || log_warn "Failed to install $tool via source mode."
    fi
done

echo ""
log_ok "Installation process complete!"
echo -e "${C_CYAN}Run '${C_BOLD}$0 --list${C_RESET}${C_CYAN}' to verify your installed tools.${C_RESET}"
