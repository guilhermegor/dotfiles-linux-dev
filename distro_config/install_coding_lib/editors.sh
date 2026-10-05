#!/bin/bash
#
# distro_config/install_coding_lib/editors.sh
#
# Code editors and terminals. Sourced by install_coding.sh.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "editors.sh is meant to be sourced, not executed." >&2
    exit 1
fi

install_vscode() {
    print_status "section" "VISUAL STUDIO CODE"

    if command_exists code; then
        print_status "info" "VS Code already installed"
        return 0
    fi

    case "$PACKAGE_MANAGER" in
        apt)
            cd "$DOWNLOADS_DIR" || return 1
            print_status "info" "Downloading VS Code..."
            run_or_echo wget -O code_amd64.deb "https://go.microsoft.com/fwlink/?LinkID=760868"

            print_status "info" "Installing VS Code..."
            run_or_echo sudo dpkg -i code_amd64.deb
            run_or_echo sudo apt-get install -f -y
            cd - > /dev/null || return 1
            ;;
        dnf|yum)
            print_status "info" "Adding VS Code repository..."
            run_or_echo sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
            sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
            $UPDATE_CMD
            $INSTALL_CMD code
            ;;
        pacman)
            print_status "info" "Installing VS Code from AUR..."
            if command_exists yay; then
                run_or_echo yay -S --noconfirm visual-studio-code-bin
            else
                print_status "warning" "Please install VS Code manually from AUR: visual-studio-code-bin"
                print_status "info" "Or install yay first: sudo pacman -S --needed git base-devel && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
            fi
            ;;
        zypper)
            print_status "info" "Adding VS Code repository..."
            run_or_echo sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
            sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ntype=rpm-md\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/zypp/repos.d/vscode.repo'
            $UPDATE_CMD
            $INSTALL_CMD code
            ;;
    esac

    print_status "success" "VS Code installed"
}

install_cursor() {
    print_status "section" "CURSOR IDE"

    if command_exists cursor; then
        print_status "info" "Cursor IDE already installed"
        return 0
    fi

    cd "$DOWNLOADS_DIR" || return 1

    case "$PACKAGE_MANAGER" in
        apt)
            print_status "info" "Downloading Cursor IDE..."
            print_status "warning" "This may take a few minutes (large file ~150MB)..."

            local cursor_deb_url="https://api2.cursor.sh/updates/download/golden/linux-x64-deb/cursor/2.2"

            print_status "info" "Downloading from official Cursor API..."

            if run_or_echo wget --timeout=120 --tries=3 \
                --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
                -O cursor_latest.deb "$cursor_deb_url" 2>&1 | tee -a "$LOG_FILE"; then

                if [ -f "cursor_latest.deb" ] && [ -s "cursor_latest.deb" ]; then
                    if file cursor_latest.deb | grep -q "Debian"; then
                        print_status "success" "Downloaded Cursor .deb package"

                        print_status "info" "Installing Cursor IDE..."
                        if run_or_echo sudo dpkg -i cursor_latest.deb 2>&1 | tee -a "$LOG_FILE"; then
                            print_status "success" "Cursor installed successfully"
                        else
                            print_status "warning" "dpkg installation had issues, fixing dependencies..."
                            run_or_echo sudo apt-get install -f -y

                            if run_or_echo sudo dpkg -i cursor_latest.deb; then
                                print_status "success" "Cursor installed after fixing dependencies"
                            else
                                print_status "error" "Failed to install Cursor package"
                                cd - > /dev/null || return 1
                                return 1
                            fi
                        fi

                        if command_exists cursor || dpkg -l | grep -q cursor; then
                            print_status "success" "Cursor IDE installation verified"

                            if dpkg -l | grep -q cursor; then
                                local version
                                version=$(dpkg -l | grep cursor | awk '{print $3}')
                                print_status "info" "Installed version: $version"
                                echo "Cursor version: $version" >> "$LOG_FILE"
                            fi

                            cd - > /dev/null || return 1
                            return 0
                        else
                            print_status "error" "Installation verification failed"
                            cd - > /dev/null || return 1
                            return 1
                        fi
                    else
                        print_status "error" "Downloaded file is not a valid .deb package"
                        rm -f cursor_latest.deb
                        cd - > /dev/null || return 1
                        return 1
                    fi
                else
                    print_status "error" "Download failed or file is empty"
                    cd - > /dev/null || return 1
                    return 1
                fi
            else
                print_status "error" "Failed to download Cursor"
                print_status "info" "Manual installation options:"
                print_status "config" "1. Visit https://cursor.com to download directly"
                print_status "config" "2. Or try: sudo snap install cursor"
                print_status "config" "3. Or download with: wget -O cursor.deb https://api2.cursor.sh/updates/download/golden/linux-x64-deb/cursor/2.2"
                cd - > /dev/null || return 1
                return 1
            fi
            ;;
        dnf|yum|zypper)
            print_status "info" "Installing Cursor for RPM-based / openSUSE system..."

            local appimage_url="https://api2.cursor.sh/updates/download/golden/linux-x64-appimage/cursor/2.2"

            print_status "info" "Downloading Cursor AppImage..."

            if run_or_echo wget --timeout=120 --tries=3 \
                --user-agent="Mozilla/5.0" \
                -O cursor.AppImage "$appimage_url" 2>&1 | tee -a "$LOG_FILE"; then

                if [ -f "cursor.AppImage" ] && [ -s "cursor.AppImage" ]; then
                    run_or_echo chmod +x cursor.AppImage
                    run_or_echo mkdir -p ~/.local/bin
                    mv cursor.AppImage ~/.local/bin/cursor

                    if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
                        echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
                        print_status "info" "Added ~/.local/bin to PATH in ~/.bashrc"
                    fi

                    print_status "success" "Cursor AppImage installed in ~/.local/bin/cursor"
                    print_status "info" "Reload shell with: source ~/.bashrc"
                else
                    print_status "error" "Download failed or file is empty"
                    print_status "info" "Please visit https://cursor.com to download manually"
                fi
            else
                print_status "error" "Could not download Cursor AppImage"
                print_status "info" "Please visit https://cursor.com to download manually"
            fi
            ;;
        pacman)
            print_status "info" "Installing Cursor from AUR..."
            if command_exists yay; then
                if yay -S --noconfirm cursor-bin 2>&1 | tee -a "$LOG_FILE"; then
                    print_status "success" "Cursor installed from AUR"
                elif yay -S --noconfirm cursor-appimage 2>&1 | tee -a "$LOG_FILE"; then
                    print_status "success" "Cursor AppImage installed from AUR"
                else
                    print_status "error" "Failed to install Cursor from AUR"
                    print_status "info" "Trying direct AppImage download..."

                    local appimage_url="https://api2.cursor.sh/updates/download/golden/linux-x64-appimage/cursor/2.2"

                    if wget --timeout=120 -O cursor.AppImage "$appimage_url" 2>&1 | tee -a "$LOG_FILE"; then
                        if [ -f "cursor.AppImage" ] && [ -s "cursor.AppImage" ]; then
                            run_or_echo chmod +x cursor.AppImage
                            run_or_echo mkdir -p ~/.local/bin
                            mv cursor.AppImage ~/.local/bin/cursor

                            if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
                                echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
                                print_status "info" "Added ~/.local/bin to PATH in ~/.bashrc"
                            fi

                            print_status "success" "Cursor AppImage installed in ~/.local/bin/cursor"
                        fi
                    fi
                fi
            else
                print_status "warning" "yay not found"
                print_status "info" "Install yay first or download Cursor manually from https://cursor.com"
            fi
            ;;
    esac

    if command_exists cursor; then
        print_status "success" "Cursor IDE is ready to use"
        print_status "info" "Launch with: cursor"
        cursor --version 2>&1 | head -n1 >> "$LOG_FILE" || true
    elif [ -f ~/.local/bin/cursor ]; then
        print_status "success" "Cursor AppImage installed in ~/.local/bin/cursor"
        print_status "info" "Launch with: cursor (after reloading shell)"
        print_status "config" "Or run: export PATH=\"\$HOME/.local/bin:\$PATH\" && cursor"
    else
        print_status "warning" "Cursor installation could not be verified"
        print_status "info" "If you need to install manually:"
        print_status "config" "1. Visit https://cursor.com"
        print_status "config" "2. Or download with: wget -O cursor.deb https://api2.cursor.sh/updates/download/golden/linux-x64-deb/cursor/2.2"
        print_status "config" "3. Then install: sudo dpkg -i cursor.deb"
    fi

    cd - > /dev/null || return 1
}

install_neovim() {
    print_status "section" "NEOVIM INSTALLATION"

    if command_exists nvim; then
        local current_version
        current_version=$(nvim --version | head -n1 | awk '{print $2}')
        print_status "info" "Neovim already installed (version: $current_version)"
        return 0
    fi

    print_status "info" "Installing Neovim..."

    case "$PACKAGE_MANAGER" in
        apt)
            if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
                print_status "info" "Adding Neovim PPA for latest version..."
                run_or_echo sudo add-apt-repository -y ppa:neovim-ppa/unstable
                $UPDATE_CMD
            fi

            if install_package "neovim" "neovim" "neovim" "neovim"; then
                print_status "success" "Neovim installed via system package manager"
            else
                print_status "warning" "System package installation failed, trying alternative methods..."
                install_neovim_alternative
            fi
            ;;
        dnf|yum|pacman|zypper)
            if install_package "neovim" "neovim" "neovim" "neovim"; then
                print_status "success" "Neovim installed via system package manager"
            else
                print_status "warning" "System package installation failed, trying alternative methods..."
                install_neovim_alternative
            fi
            ;;
    esac

    if command_exists nvim; then
        local version
        version=$(nvim --version | head -n1 | awk '{print $2}')
        print_status "success" "Neovim installed successfully (version: $version)"

        install_vim_plug
        setup_neovim_config
    else
        print_status "error" "Neovim installation failed"
        return 1
    fi
}

install_neovim_alternative() {
    print_status "info" "Trying alternative Neovim installation methods..."

    if command_exists brew; then
        print_status "info" "Installing Neovim via Homebrew..."
        run_or_echo brew install neovim
        return $?
    fi

    print_status "info" "Downloading Neovim AppImage..."
    cd "$DOWNLOADS_DIR" || return 1

    local nvim_appimage_url="https://github.com/neovim/neovim/releases/latest/download/nvim.appimage"

    if wget -O nvim.appimage "$nvim_appimage_url"; then
        run_or_echo chmod +x nvim.appimage
        run_or_echo sudo mv nvim.appimage /usr/local/bin/nvim
        print_status "success" "Neovim AppImage installed to /usr/local/bin/nvim"
        cd - > /dev/null || return 1
        return 0
    else
        print_status "error" "Failed to download Neovim AppImage"
        cd - > /dev/null || return 1
        return 1
    fi
}

install_vim_plug() {
    print_status "info" "Installing vim-plug plugin manager..."

    local plug_dir="$HOME/.local/share/nvim/site/autoload"
    local plug_file="$plug_dir/plug.vim"

    run_or_echo mkdir -p "$plug_dir"

    if curl -fLo "$plug_file" --create-dirs \
        https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim; then
        print_status "success" "vim-plug installed successfully"
    else
        print_status "warning" "Failed to install vim-plug"
    fi
}

setup_neovim_config() {
    print_status "info" "Setting up basic Neovim configuration..."

    local nvim_dir="$HOME/.config/nvim"
    local init_file="$nvim_dir/init.vim"

    run_or_echo mkdir -p "$nvim_dir"

    if [ ! -f "$init_file" ]; then
        cat > "$init_file" << 'EOF'
" Basic Neovim Configuration
set number
set relativenumber
set expandtab
set tabstop=4
set shiftwidth=4
set smartindent
set wrap
set smartcase
set noswapfile
set nobackup
set undodir=~/.vim/undodir
set undofile
set incsearch
set termguicolors
set scrolloff=8
set noshowmode
set completeopt=menuone,noinsert,noselect
set signcolumn=yes
set colorcolumn=80

" Plugin configuration
call plug#begin('~/.vim/plugged')

" Theme
Plug 'navarasu/onedark.nvim'

" File explorer
Plug 'preservim/nerdtree'

" Status line
Plug 'vim-airline/vim-airline'

" Git integration
Plug 'tpope/vim-fugitive'
Plug 'airblade/vim-gitgutter'

" Syntax highlighting and language support
Plug 'neoclide/coc.nvim', {'branch': 'release'}

" Fuzzy finder
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'

" Commenting
Plug 'tpope/vim-commentary'

" Auto pairs
Plug 'jiangmiao/auto-pairs'

" Which key
Plug 'folke/which-key.nvim'

call plug#end()

" Color scheme
colorscheme onedark

" Key mappings
let mapleader = " "

" NERDTree
nnoremap <leader>n :NERDTreeFocus<CR>
nnoremap <C-n> :NERDTree<CR>
nnoremap <C-t> :NERDTreeToggle<CR>
nnoremap <C-f> :NERDTreeFind<CR>

" Fuzzy finder
nnoremap <C-p> :Files<CR>
nnoremap <leader>fg :Rg<CR>
nnoremap <leader>fb :Buffers<CR>

" Navigation
nnoremap <leader>h :wincmd h<CR>
nnoremap <leader>j :wincmd j<CR>
nnoremap <leader>k :wincmd k<CR>
nnoremap <leader>l :wincmd l<CR>

" Tab management
nnoremap <leader>to :tabnew<CR>
nnoremap <leader>tc :tabclose<CR>
nnoremap <leader>tn :tabnext<CR>
nnoremap <leader>tp :tabprevious<CR>

" Save and quit
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>
nnoremap <leader>wq :wq<CR>

" Source current file
nnoremap <leader><CR> :so ~/.config/nvim/init.vim<CR>

" Auto commands
autocmd VimEnter * NERDTree | wincmd p

" COC configuration
nmap <silent> gd <Plug>(coc-definition)
nmap <silent> gy <Plug>(coc-type-definition)
nmap <silent> gi <Plug>(coc-implementation)
nmap <silent> gr <Plug>(coc-references)

" Use tab for trigger completion with characters ahead and navigate
inoremap <silent><expr> <TAB>
      \ coc#pum#visible() ? coc#pum#next(1) :
      \ CheckBackspace() ? "\<Tab>" :
      \ coc#refresh()
inoremap <expr><S-TAB> coc#pum#visible() ? coc#pum#prev(1) : "\<C-h>"

function! CheckBackspace() abort
  let col = col('.') - 1
  return !col || getline('.')[col - 1]  =~# '\s'
endfunction

" Make <CR> to accept selected completion item or notify coc.nvim to format
inoremap <silent><expr> <CR> coc#pum#visible() ? coc#pum#confirm() : "\<C-g>u\<CR>\<c-r>=coc#on_enter()\<CR>"
EOF

        print_status "success" "Basic Neovim configuration created at $init_file"
        print_status "info" "After first launch, run :PlugInstall to install plugins"
    else
        print_status "info" "Neovim configuration already exists at $init_file"
    fi
}

install_warp_terminal() {
    print_status "section" "WARP TERMINAL"

    if command_exists warp-terminal; then
        print_status "info" "Warp Terminal already installed"
        return 0
    fi

    cd "$DOWNLOADS_DIR" || return 1
    print_status "info" "Downloading Warp Terminal..."
    run_or_echo wget -O warp-terminal.deb "https://app.warp.dev/download?package=deb"

    print_status "info" "Installing Warp Terminal..."
    run_or_echo sudo apt install -y ./warp-terminal.deb

    print_status "success" "Warp Terminal installed"
    cd - > /dev/null || return 1
}

INSTALL_REGISTRY+=(
    "install_vscode:VS Code::com.microsoft.VSCode.desktop"
    "install_cursor:Cursor IDE:Code:cursor.desktop"
    "install_neovim:Neovim Text Editor::"
    "install_warp_terminal:Warp Terminal:Code:dev.warp.Warp.desktop"
)
