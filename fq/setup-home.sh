#!/usr/bin/env bash

# 安装 vim、tmux，并配置当前用户的常用终端环境。
# 支持 Debian、Ubuntu 和 macOS；macOS 使用 ~/.zshrc，Linux 使用 ~/.bashrc。

set -euo pipefail

platform=""
shell_rc=""

check_system() {
    case "$(uname -s)" in
        Darwin)
            platform="macos"
            shell_rc="$HOME/.zshrc"
            echo "✅ 检测到系统: macOS，Shell 配置文件: $shell_rc"
            ;;
        Linux)
            if [ ! -f /etc/os-release ]; then
                echo "❌ 错误：无法检测 Linux 发行版（未找到 /etc/os-release）。"
                exit 1
            fi

            # shellcheck disable=SC1091
            . /etc/os-release
            case "$ID" in
                debian|ubuntu)
                    platform="linux"
                    shell_rc="$HOME/.bashrc"
                    echo "✅ 检测到系统: $PRETTY_NAME，Shell 配置文件: $shell_rc"
                    ;;
                *)
                    echo "❌ 错误：不支持的 Linux 发行版: $PRETTY_NAME ($ID)。"
                    echo "本脚本仅支持 Debian、Ubuntu 和 macOS。"
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "❌ 错误：不支持的操作系统: $(uname -s)。"
            echo "本脚本仅支持 Debian、Ubuntu 和 macOS。"
            exit 1
            ;;
    esac
}

install_packages() {
    echo "---"
    echo "正在安装 vim 和 tmux..."

    case "$platform" in
        linux)
            sudo apt-get update
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y vim tmux
            ;;
        macos)
            if ! command -v brew >/dev/null 2>&1; then
                echo "❌ 未找到 Homebrew。请先安装 Homebrew: https://brew.sh/"
                return 1
            fi
            brew install vim tmux
            ;;
    esac
}

configure_shell() {
    if grep -q "ss_port" "$shell_rc" 2>/dev/null; then
        echo "✅ $shell_rc 环境似乎已配置过，跳过写入。"
        return
    fi

    echo "正在配置 $shell_rc..."
    cat <<'EOF' >> "$shell_rc"
alias ll='ls -l'
alias t='tmux a -t 0'
alias tailf='tail -f'

if command -v systemctl >/dev/null 2>&1; then
    export SYSTEMD_EDITOR=vim
fi

ss_port() {
    if [ -z "$1" ]; then
        echo "错误：请传入一个端口号。"
        return 1
    fi

    if ! [[ "$1" =~ ^[0-9]+$ ]]; then
        echo "错误：'$1' 不是一个有效的数字。"
        return 1
    fi

    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        echo "错误：端口号 '$1' 必须在1到65535之间。"
        return 1
    fi

    if command -v ss >/dev/null 2>&1; then
        sudo ss -ltnp "sport = :$1"
    elif command -v lsof >/dev/null 2>&1; then
        sudo lsof -nP -iTCP:"$1" -sTCP:LISTEN
    else
        echo "错误：未找到 ss 或 lsof，无法查询端口。"
        return 1
    fi
}
EOF
}

ensure_home_bin_path() {
    local path_line='export PATH="$HOME/bin:$PATH"'

    if grep -Fqx "$path_line" "$shell_rc" 2>/dev/null; then
        echo "✅ ~/bin 已在 $shell_rc 的 PATH 中。"
        return
    fi

    printf '\n%s\n' "$path_line" >> "$shell_rc"
    echo "✅ 已将 ~/bin 添加到 $shell_rc 的 PATH。"
}

configure_inputrc() {
    cat > "$HOME/.inputrc" <<'EOF'
"\e[A":history-search-backward
"\e[B":history-search-forward
EOF
}

configure_vim() {
    cat > "$HOME/.vimrc" <<'EOF'
"call plug#begin('~/.vim/plug')
"Plug 'NLKNguyen/papercolor-theme'
"Plug 'altercation/vim-colors-solarized'
"Plug 'Yggdroot/LeaderF', { 'do': ':LeaderfInstallCExtension'}
"Plug 'preservim/nerdtree'
"call plug#end()

"let g:Lf_WindowPosition = 'popup'
"let g:Lf_ShortcutF = '<c-p>'
"let g:Lf_ShortcutB = '<c-b>'
"noremap <c-n> :LeaderfMru<cr>
"noremap <m-p> :LeaderfFunction!<cr>
"noremap <c-b> :LeaderfBuffer<cr>
"noremap <m-m> :LeaderfTag<cr>
"noremap <c-f> :LeaderfFile<cr>
"let g:Lf_StlSeparator = { 'left': '', 'right': '', 'font': '' }
"let g:Lf_RootMarkers = ['.project', '.root', '.svn', '.git']
"let g:Lf_WorkingDirectoryMode = 'Ac'
"let g:Lf_WindowHeight = 0.30
"let g:Lf_CacheDirectory = expand('~/.vim/cache')
"let g:Lf_ShowRelativePath = 0
"let g:Lf_HideHelp = 1
"let g:Lf_StlColorscheme = 'powerline'
"let g:Lf_PreviewResult = {'Function':0, 'BufTag':0}

" === System & Environment ===
language messages en_US.UTF-8
set history=500
set tm=500
set noerrorbells
set novisualbell
set t_vb=
set mouse=a
set laststatus=2
set wildmode=longest,list,full

" === Directories (auto-create if missing) ===
let s:vim_tmp = expand('~/tmp/vim')
if !isdirectory(s:vim_tmp)
  call mkdir(s:vim_tmp, 'p')
endif
set backup
set backupdir=~/tmp/vim
set directory=~/tmp/vim

" === Encoding ===
set encoding=utf-8

" === File Type Detection ===
filetype plugin on
filetype indent on

" === Appearance ===
syntax enable
syntax sync minlines=256 maxlines=1000

if has('termguicolors')
  set termguicolors
endif

function! s:DetectBg() abort
  if $TERM_PROGRAM ==# 'iTerm.app'
    return 'dark'
  endif
  let l:cfg = expand('~/.config/ghostty/config')
  if $TERM_PROGRAM !=# 'ghostty' || !filereadable(l:cfg)
    return &background
  endif
  let l:theme = get(filter(readfile(l:cfg), 'v:val =~# "^\\s*theme\\s*="'), 0, '')
  return l:theme =~? '\<light\>\|latte' ? 'light' : 'dark'
endfunction
let &background = s:DetectBg()

let g:solarized_termtrans=1
colo solarized

" === Editing Behavior ===
set backspace=eol,start,indent
set expandtab
set smarttab
set shiftwidth=4
set tabstop=4
set ai
set si

" === Search & Highlight ===
set hlsearch
set incsearch
set showmatch

" === Display ===
set nu
set cursorline
set scrolloff=5

" === Status Line ===
set statusline=%#LineNr#\ %f%m\%=%#CursorColumn#\ %y\ %{&fileencoding?&fileencoding:&encoding}\ [%{&fileformat}\]\ %l/%L:%c\

" === Cursor Shape (xterm-compatible terminals only) ===
if &term =~? 'xterm\|alacritty\|kitty\|ghostty\|iTerm\|vte\|gnome'
  let &t_SI = "\e[6 q"    " Insert mode: 竖线
  let &t_SR = "\e[4 q"    " Replace mode: 下划线
  let &t_EI = "\e[2 q"    " Normal mode: 方块
endif

" === Key Mappings ===
nmap 0 ^
nmap <space> <C-D>
set clipboard+=unnamed

" === Auto Commands ===
augroup AutoCd
  autocmd!
  autocmd BufEnter * silent! lcd %:p:h
augroup END

augroup RestoreCursor
  autocmd!
  autocmd BufReadPost * if line("'\"") > 0 && line("'\"") <= line("$") | exe "normal! g`\"" | endif
augroup END

augroup DisplayUpdate
  autocmd!
  autocmd WinEnter * setlocal cursorline
  autocmd WinLeave * setlocal nocursorline
augroup END
EOF
}

configure_tmux() {
    cat > "$HOME/.tmux.conf" <<'EOF'
set-option -g display-time 1000		# msg display time, 1000 ms

set-option -g prefix C-j
unbind-key C-b
bind-key C-j send-prefix

bind r source-file ~/.tmux.conf \; display "Reloaded!"	    # reload config file

bind c new-window -c "#{pane_current_path}"
bind | split-window -h -c "#{pane_current_path}"    # horizontal
bind - split-window -v -c "#{pane_current_path}"    # vertical
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -r H resize-pane -L 5  # if want to expand large space, press H several times
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

set -g default-terminal "screen-256color"
set -g status-fg white
set -g status-bg black

set -g status-style bright

# default window title colors
set-window-option -g window-status-style fg=cyan
set-window-option -g window-status-style bg=default
set-window-option -g window-status-style dim

# active window title colors
set-window-option -g window-status-current-style fg=white
set-window-option -g window-status-current-style bg=red
set-window-option -g window-status-current-style bright

# Highlight active window
set-window-option -g window-status-current-style bg=red

#setw -g window-status-fg cyan
#setw -g window-status-bg default
#setw -g window-status-attr dim
#setw -g window-status-current-fg white
#setw -g window-status-current-bg red
#setw -g window-status-current-attr bright
#setw -g mode-mouse on
#set -g mouse-select-pane on
#set -g mouse-select-window on
#set -g mouse-resize-pane on
set -g status-left "#[fg=green][#S]"
set -g status-right "#[fg=cyan]#H %d-%b %R"
set -g status-interval 60   # update time every 60 sec

set -s extended-keys always
set -s extended-keys-format csi-u
set -as terminal-features ',xterm*:extkeys'
EOF
}

main() {
    check_system

    case "${1:-}" in
        --ensure-bin-path)
            ensure_home_bin_path
            return
            ;;
        "")
            ;;
        *)
            echo "用法: $0 [--ensure-bin-path]"
            return 1
            ;;
    esac

    install_packages
    configure_shell
    configure_inputrc
    configure_vim
    configure_tmux
    echo "✅ Home 环境配置完成。"
}

main "$@"
