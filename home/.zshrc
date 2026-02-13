# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

export ZSH="$HOME/.oh-my-zsh"
# fastfetch

ZSH_THEME="kiwi"

plugins=(
    git
    archlinux
    zsh-autosuggestions
    zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

# Check archlinux plugin commands here
# https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/archlinux

# Display Pokemon-colorscripts
# Project page: https://gitlab.com/phoneybadger/pokemon-colorscripts#on-other-distros-and-macos
#pokemon-colorscripts --no-title -s -r #without fastfetch
pokemon-colorscripts --no-title -s -r | fastfetch -c $HOME/.config/fastfetch/config-pokemon.jsonc --logo-type file-raw --logo-height 10 --logo-width 5 --logo -

# fastfetch. Will be disabled if above colorscript was chosen to install
#fastfetch -c $HOME/.config/fastfetch/config-compact.jsonc

# Set-up icons for files/directories in terminal using lsd
alias ls='lsd'
alias l='ls -l'
alias la='ls -a'
alias lla='ls -la'
alias lt='ls --tree'
alias ff='fastfetch'
alias ai='gemini'
alias files='yazi'
alias 0G='~/Other/run_antigravity.sh'
alias AI='node /home/lee/.gemini/antigravity/scratch/brain-core/bin/index.js'

# Set-up FZF key bindings (CTRL R for fuzzy history finder)
source <(fzf --zsh)

# High Contrast Settings
# ----------------------
# Autosuggestions: Using 'cyan' to ensure it is clearly visible.
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=cyan,bold'

# Syntax Highlighting High Contrast (Visible against dark backgrounds)
typeset -A ZSH_HIGHLIGHT_STYLES
ZSH_HIGHLIGHT_STYLES[comment]='fg=yellow,bold'
ZSH_HIGHLIGHT_STYLES[command]='fg=cyan,bold'
ZSH_HIGHLIGHT_STYLES[alias]='fg=cyan,bold'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=cyan,bold'
ZSH_HIGHLIGHT_STYLES[function]='fg=cyan,bold'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=red,bold'
ZSH_HIGHLIGHT_STYLES[path]='fg=blue,bold'
ZSH_HIGHLIGHT_STYLES[default]='fg=white,bold'
ZSH_HIGHLIGHT_STYLES[argument]='fg=white'
ZSH_HIGHLIGHT_STYLES[option]='fg=green,bold'

HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory
# FORCE OVERRIDE: Set Agnoster prompt text to Pink (200)

# 1. User Context (@lee)
# prompt_context() {
  # arg1=Background (black), arg2=Foreground (200/pink)
  # prompt_segment black 200 "%(!.%{%F{yellow}%}.)$USER@%m"
# }

# 2. Directory (~)
# prompt_dir() {
  # arg1=Background (blue), arg2=Foreground (200/pink)
#   prompt_segment blue 200 '%~'
# }
# 3. Date & Time (Fri 23 Jan - 20:29)
# If your grep result found a different function name (e.g. prompt_time), rename this function below.
# prompt_date() {
  # arg1=Background (blue), arg2=Foreground (200/pink)
#   prompt_segment blue 200 "%D{%a %d %b - %H:%M}"
# }

# --- OSINT & Search Aliases ---
alias q='rg -S'                             # Quick search (Smart Case)
alias qq='rg -S -C 3'                     # Quick search with 3 lines of context
alias rip-hist='history 1 | grep -i'           # Search shell history
alias rip-ip='grep -Eo "([0-9]{1,3}\.){3}[0-9]{1,3}"'
alias rip-url='grep -Eo "https?://[a-zA-Z0-9./?=_-]+"'
alias rip-email='grep -Eo "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"'
alias fix-docker='sudo docker stop $(sudo docker ps -q) 2>/dev/null' # Nuke all running containers
export PATH="$HOME/.npm-global/bin:$PATH"
export PATH="$HOME/.npm-global/bin:$PATH"

# dot-files session helpers
[ -f "$HOME/.config/dotfiles/session_tools.sh" ] && source "$HOME/.config/dotfiles/session_tools.sh"
	
