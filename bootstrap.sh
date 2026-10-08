#!/usr/bin/env bash
# =============================================================================
#  pfshell — bootstrap d'environnement terminal (zsh + oh-my-zsh + starship)
#  Usage :
#    ./bootstrap.sh               installe tout (paquets système si sudo) + config
#    ./bootstrap.sh --no-install  ne télécharge rien : dotfiles uniquement
#    ./bootstrap.sh --uninstall   retire tout et restaure les sauvegardes
#
#  Fichiers gérés (sauvegardés avant d'être remplacés) :
#    ~/.zshrc  ~/.tmux.conf  ~/.vimrc  ~/.config/starship.toml  (+ 3 lignes dans ~/.bashrc)
#  Config commune bash/zsh : ~/.config/pfshell/shell.sh
#  Ajouts propres à une machine : ~/.config/pfshell/local.sh (jamais touché)
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------- RÉGLAGES ---
# Paquets système (noms Debian ; traduits pour les autres distros)
PACKAGES=(zsh git curl wget vim tmux htop tree jq unzip fzf ripgrep bat fastfetch net-tools dnsutils)
# Plugins zsh clonés dans oh-my-zsh (l'ordre compte : syntax-highlighting en dernier)
ZSH_PLUGINS=(zsh-autosuggestions zsh-syntax-highlighting)
# Ton repo dotfiles : on y récupère starship.toml quand le script est lancé seul (via curl)
REPO_RAW="https://raw.githubusercontent.com/pfdemai/dotfiles/main"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
PFSHELL_DIR="$CFG/pfshell"
STATE_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/pfshell/installed.list"
BACKUP_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/pfshell/backups"
BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
MARK_BEGIN="# >>> pfshell >>>"
MARK_END="# <<< pfshell <<<"
MANAGED_FILES=("$HOME/.zshrc" "$HOME/.tmux.conf" "$HOME/.vimrc" "$CFG/starship.toml")

# ---------------------------------------------------------------- AFFICHAGE --
c_red=$'\e[38;5;196m'; c_dim=$'\e[38;5;245m'; c_ok=$'\e[32m'; c_rst=$'\e[0m'
info() { printf '%s::%s %s\n' "$c_red" "$c_rst" "$*"; }
ok()   { printf '%s ✔%s %s\n' "$c_ok" "$c_rst" "$*"; }
warn() { printf '%s !%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
usage() { sed -n '3,12p' "$0" | sed 's/^#  \{0,1\}//'; exit 0; }

DO_INSTALL=1; DO_UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-install) DO_INSTALL=0 ;;
    --uninstall)  DO_UNINSTALL=1 ;;
    -h|--help)    usage ;;
    *) warn "Option inconnue : $arg"; usage ;;
  esac
done

# On note ce qu'on installe nous-mêmes, pour que --uninstall ne retire que ça
record() { mkdir -p "$(dirname "$STATE_FILE")"; echo "$1" >> "$STATE_FILE"; }

# ------------------------------------------------------- PAQUETS SYSTÈME ----
detect_pm() {
  for pm in apt-get dnf pacman zypper apk; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
  done
  echo none
}

pkg_name() {
  case "$1:$2" in
    dnf:dnsutils|zypper:dnsutils) echo bind-utils ;;
    pacman:dnsutils)              echo bind ;;
    apk:dnsutils)                 echo bind-tools ;;
    *)                            echo "$2" ;;
  esac
}

install_packages() {
  local pm sudo="" failed=() name
  pm=$(detect_pm)
  [ "$pm" = none ] && { warn "Gestionnaire de paquets non reconnu : paquets système ignorés."; return; }
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then sudo="sudo"
    else warn "Ni root ni sudo : paquets système ignorés (le reste s'installe dans ton home)."; return; fi
  fi

  info "Paquets système ($pm)…"
  case "$pm" in
    apt-get) $sudo apt-get update -qq ;;
    pacman)  $sudo pacman -Sy --noconfirm >/dev/null ;;
    apk)     $sudo apk update -q ;;
  esac
  # Un paquet à la fois : un nom absent d'un dépôt (ex. fastfetch sur une vieille distro) ne bloque pas les autres
  for p in "${PACKAGES[@]}"; do
    name=$(pkg_name "$pm" "$p")
    case "$pm" in
      apt-get) $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$name" >/dev/null 2>&1 ;;
      dnf)     $sudo dnf install -y -q "$name" >/dev/null 2>&1 ;;
      pacman)  $sudo pacman -S --needed --noconfirm "$name" >/dev/null 2>&1 ;;
      zypper)  $sudo zypper -q install -y "$name" >/dev/null 2>&1 ;;
      apk)     $sudo apk add -q "$name" >/dev/null 2>&1 ;;
    esac || failed+=("$name")
  done
  if [ ${#failed[@]} -eq 0 ]; then ok "Paquets système installés"
  else warn "Non installés : ${failed[*]}"; fi
}

# ------------------------------------- OUTILS DANS TON HOME (sans root) -----
install_ohmyzsh() {
  command -v git >/dev/null 2>&1 || { warn "git absent : oh-my-zsh ignoré"; return; }
  local omz="$HOME/.oh-my-zsh"
  # git clone plutôt que le script officiel : celui-ci réécrirait ~/.zshrc et lancerait chsh tout seul
  if [ ! -d "$omz" ]; then
    if git clone -q --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$omz"; then record omz; ok "oh-my-zsh installé"
    else warn "Échec du clone oh-my-zsh"; return; fi
  fi
  for p in "${ZSH_PLUGINS[@]}"; do
    [ -d "$omz/custom/plugins/$p" ] && continue
    if git clone -q --depth=1 "https://github.com/zsh-users/$p.git" "$omz/custom/plugins/$p"; then ok "Plugin $p installé"
    else warn "Échec du clone $p"; fi
  done
}

install_starship() {
  if command -v starship >/dev/null 2>&1 || [ -x "$HOME/.local/bin/starship" ]; then return 0; fi
  local arch tmp url
  case "$(uname -m)" in
    x86_64)        arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) warn "starship : architecture $(uname -m) non gérée"; return ;;
  esac
  # Binaire statique (musl) = marche sur toutes les distros, sans root, sans exécuter de script distant
  url="https://github.com/starship/starship/releases/latest/download/starship-${arch}-unknown-linux-musl.tar.gz"
  tmp=$(mktemp -d)
  if curl -fsSLo "$tmp/s.tgz" "$url" && curl -fsSLo "$tmp/s.sha256" "$url.sha256" \
     && [ "$(sha256sum "$tmp/s.tgz" | cut -d' ' -f1)" = "$(cut -d' ' -f1 < "$tmp/s.sha256" | tr -d '[:space:]')" ]; then
    mkdir -p "$HOME/.local/bin" && tar xzf "$tmp/s.tgz" -C "$HOME/.local/bin" starship \
      && record starship && ok "starship installé dans ~/.local/bin (empreinte SHA-256 vérifiée)"
  else
    warn "starship : téléchargement ou vérification d'empreinte échoué — prompt de secours utilisé"
  fi
  rm -rf "$tmp"
}

set_default_shell() {
  local z current
  z=$(command -v zsh) || return 0
  current=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
  case "$current" in */zsh) return 0 ;; esac
  if [ ! -t 0 ]; then info "Pour passer zsh par défaut : chsh -s $z"; return; fi
  printf '%s::%s Passer zsh comme shell par défaut ? [O/n] ' "$c_red" "$c_rst"; read -r r
  case "$r" in n|N) return ;; esac
  if chsh -s "$z"; then record "shell:${current:-/bin/bash}"; ok "zsh est ton shell par défaut (effectif à la prochaine connexion)"
  else warn "chsh a échoué — lance toi-même : chsh -s $z"; fi
}

# ------------------------------------------------------------ SAUVEGARDES ---
backup() {
  local f=$1
  [ -f "$f" ] || return 0
  head -n1 "$f" | grep -q "pfshell-managed" && return 0   # déjà le nôtre : rien à sauver
  mkdir -p "$BACKUP_DIR" && cp -a "$f" "$BACKUP_DIR/" && info "Sauvegarde : ${f/#$HOME/\~} → ${BACKUP_DIR/#$HOME/\~}/"
}

# ---------------------------------------------- CONFIG COMMUNE BASH/ZSH -----
write_shell_config() {
  mkdir -p "$PFSHELL_DIR"
  cat > "$PFSHELL_DIR/shell.sh" <<'EOF'
# pfshell-managed — régénéré par bootstrap.sh, ne pas éditer.
# Tes ajouts propres à une machine : ~/.config/pfshell/local.sh (jamais écrasé)

case $- in *i*) ;; *) return ;; esac   # shell non interactif (scp, cron…) : on ne touche à rien

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
export EDITOR=vim VISUAL=vim LESS=-R
command -v dircolors >/dev/null 2>&1 && eval "$(dircolors -b ~/.dircolors 2>/dev/null || dircolors -b)"

# ---- Historique
HISTSIZE=50000
if [ -n "${BASH_VERSION:-}" ]; then
  HISTFILESIZE=100000
  HISTCONTROL=ignoreboth:erasedups
  HISTTIMEFORMAT='%F %T  '
  shopt -s histappend checkwinsize cdspell autocd 2>/dev/null
  bind 'set completion-ignore-case on'
  bind 'set show-all-if-ambiguous on'
  bind 'set colored-stats on'
  bind '"\e[A": history-search-backward'    # ↑ = historique filtré par ce qui est déjà tapé
  bind '"\e[B": history-search-forward'
  case "${PROMPT_COMMAND:-}" in *"history -a"*) ;; *) PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;; esac
elif [ -n "${ZSH_VERSION:-}" ]; then
  SAVEHIST=100000; HISTFILE=${HISTFILE:-$HOME/.zsh_history}
  setopt hist_ignore_dups hist_save_no_dups share_history extended_history
  zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
  autoload -U up-line-or-beginning-search down-line-or-beginning-search
  zle -N up-line-or-beginning-search; zle -N down-line-or-beginning-search
  bindkey '^[[A' up-line-or-beginning-search; bindkey '^[[B' down-line-or-beginning-search
fi

# ---- sudo seulement si on n'est pas déjà root (évite l'erreur sur un conteneur sans sudo)
__pf_sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }
[ "$(id -u)" -eq 0 ] && __s="" || __s="sudo "

# ---- Tes alias de paquets, adaptés à la distro
if command -v apt-get >/dev/null 2>&1; then
  alias update="${__s}apt update" listupgrade="apt list --upgradable" upgrade="${__s}apt upgrade" \
        full-upgrade="${__s}apt full-upgrade -y" install="${__s}apt install" autoremove="${__s}apt autoremove -y"
elif command -v dnf >/dev/null 2>&1; then
  alias update="${__s}dnf check-update" listupgrade="dnf list --upgrades" upgrade="${__s}dnf upgrade" \
        full-upgrade="${__s}dnf upgrade -y" install="${__s}dnf install" autoremove="${__s}dnf autoremove -y"
elif command -v pacman >/dev/null 2>&1; then
  alias update="${__s}pacman -Syu" listupgrade="pacman -Qu" upgrade="${__s}pacman -Syu" \
        full-upgrade="${__s}pacman -Syu --noconfirm" install="${__s}pacman -S"
fi
unset __s

# ---- reboot / shutdown : en SSH, il faut taper le nom de la machine pour confirmer
__pf_confirm() {
  [ -n "${SSH_CONNECTION:-}" ] || return 0
  local h; h=$(uname -n)
  printf '\e[38;5;196m⚠  %s de %s (session SSH).\e[0m Tape le nom de la machine pour confirmer : ' "$1" "$h"
  read -r __pf_r; [ "$__pf_r" = "$h" ] || { echo "Annulé."; return 1; }
}
unalias reboot shutdown 2>/dev/null
reboot()   { __pf_confirm "Redémarrage" && __pf_sudo shutdown -r now; }
shutdown() { if [ $# -gt 0 ]; then __pf_sudo command shutdown "$@"; else __pf_confirm "Extinction" && __pf_sudo command shutdown -h now; fi; }

# ---- Tes alias habituels
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
command -v fastfetch >/dev/null 2>&1 && alias clear='clear && fastfetch'
alias zshrefresh='exec zsh'          # relance un zsh propre (plus fiable que re-sourcer oh-my-zsh)

# ---- Ajouts
alias ..='cd ..' ...='cd ../..'
alias grep='grep --color=auto'
alias df='df -h' du='du -h' free='free -h'
ip -color=auto addr >/dev/null 2>&1 && alias ip='ip -color=auto'
alias ports='ss -tulpn'                      # qui écoute sur quoi
alias myip='curl -s https://ifconfig.me; echo'
alias please='sudo $(fc -ln -1)'             # relance la dernière commande en sudo
command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1 && alias bat='batcat'
command -v fdfind >/dev/null 2>&1 && ! command -v fd  >/dev/null 2>&1 && alias fd='fdfind'

mkcd() { mkdir -p -- "$1" && cd -- "$1"; }
bak()  { local d; d="$1.bak.$(date +%Y%m%d-%H%M%S)"; cp -a -- "$1" "$d" && echo "→ $d"; }   # avant d'éditer une conf
extract() {
  [ -f "$1" ] || { echo "extract: '$1' introuvable"; return 1; }
  case "$1" in
    *.tar.gz|*.tgz)   tar xzf "$1" ;;
    *.tar.bz2|*.tbz2) tar xjf "$1" ;;
    *.tar.xz)         tar xJf "$1" ;;
    *.tar)            tar xf  "$1" ;;
    *.zip)            unzip   "$1" ;;
    *.gz)             gunzip  "$1" ;;
    *.bz2)            bunzip2 "$1" ;;
    *.7z)             7z x    "$1" ;;
    *) echo "extract: format non géré : $1"; return 1 ;;
  esac
}

# ---- Prompt : starship s'il est là, sinon prompt de secours rouge/noir
if command -v starship >/dev/null 2>&1; then
  if [ -n "${BASH_VERSION:-}" ]; then eval "$(starship init bash)"; else eval "$(starship init zsh)"; fi
else
  __pf_git() {
    local b
    b=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) && printf ' (%s)' "$b"
  }
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *UTF-8*|*utf8*) __PF_SYM='❯' ;; *) __PF_SYM='>' ;; esac
  [ -n "${SSH_CONNECTION:-}" ] && __PF_SSH=' [ssh]' || __PF_SSH=''
  if [ -n "${BASH_VERSION:-}" ]; then
    __pf_prompt() {
      local ec=$?    # doit rester la 1re ligne
      local R='\[\e[38;5;196m\]' D='\[\e[38;5;88m\]' G='\[\e[38;5;245m\]' W='\[\e[97m\]' X='\[\e[0m\]'
      local st="" u="$D" sym="$__PF_SYM"
      [ "$ec" -ne 0 ] && st="${R}✘ ${ec} "
      [ "$EUID" -eq 0 ] && { u='\[\e[1;38;5;196m\]'; sym='#'; }
      PS1="${st}${u}\u${G}@${R}\h${G}${__PF_SSH} ${W}\w${D}$(__pf_git)${X}\n${R}${sym}${X} "
    }
    case "${PROMPT_COMMAND:-}" in *__pf_prompt*) ;; *) PROMPT_COMMAND="__pf_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;; esac
  else
    setopt PROMPT_SUBST
    __pf_precmd() { __PF_GIT=$(__pf_git); }
    (( ${precmd_functions[(I)__pf_precmd]} )) || precmd_functions+=(__pf_precmd)
    PROMPT='%(?..%F{196}✘ %? )%(#.%B%F{196}.%F{88})%n%b%F{245}@%F{196}%m%F{245}${__PF_SSH} %F{white}%~%F{88}${__PF_GIT}%f
%F{196}%(#.#.${__PF_SYM})%f '
  fi
fi

# ---- fzf : Ctrl-R = recherche floue dans l'historique, Ctrl-T = fichiers
# fzf récent sait générer ses raccourcis (--bash/--zsh) ; sinon on cherche les fichiers de la distro
if command -v fzf >/dev/null 2>&1; then
  __pf_sh=bash; [ -n "${ZSH_VERSION:-}" ] && __pf_sh=zsh
  if __pf_fzf=$(fzf --$__pf_sh 2>/dev/null); then
    eval "$__pf_fzf"
  else
    for f in /usr/share/doc/fzf/examples/key-bindings.$__pf_sh /usr/share/fzf/key-bindings.$__pf_sh /usr/share/fzf/shell/key-bindings.$__pf_sh; do
      [ -f "$f" ] && { . "$f"; break; }
    done
  fi
  unset __pf_sh __pf_fzf
fi

# ---- Surcharges locales, puis fastfetch à l'ouverture
if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/pfshell/local.sh" ]; then
  . "${XDG_CONFIG_HOME:-$HOME/.config}/pfshell/local.sh"
fi
command -v fastfetch >/dev/null 2>&1 && fastfetch
true   # le 1er prompt ne doit pas afficher une fausse erreur
EOF
  ok "Config commune écrite : ~/.config/pfshell/shell.sh"
}

# ---------------------------------------------------------------- ZSHRC -----
write_zshrc() {
  backup "$HOME/.zshrc"
  cat > "$HOME/.zshrc" <<'EOF'
# pfshell-managed — généré par bootstrap.sh (ton ancien .zshrc est sauvegardé).
# Ajouts propres à cette machine : ~/.config/pfshell/local.sh

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""                     # le prompt est géré par starship
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=242"

# Plugins chargés seulement s'ils sont présents (pas d'erreur sur une machine incomplète)
plugins=(git)
for p in zsh-autosuggestions zsh-syntax-highlighting; do   # syntax-highlighting doit rester le dernier
  [ -d "$ZSH/custom/plugins/$p" ] && plugins+=("$p")
done

if [ -f "$ZSH/oh-my-zsh.sh" ]; then
  source "$ZSH/oh-my-zsh.sh"
  __pf_omz=1
fi

[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/pfshell/shell.sh" ] && source "${XDG_CONFIG_HOME:-$HOME/.config}/pfshell/shell.sh"

# Sans oh-my-zsh : complétion + plugins fournis par la distro, s'ils existent
if [ -z "${__pf_omz:-}" ]; then
  autoload -Uz compinit && compinit
  for f in /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
           /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
    [ -f "$f" ] && source "$f"
  done
fi
true
EOF
  ok "~/.zshrc écrit"
}

hook_bashrc() {
  local rc="$HOME/.bashrc"
  [ -f "$rc" ] && sed -i "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$rc"
  cat >> "$rc" <<EOF
$MARK_BEGIN
[ -f "$PFSHELL_DIR/shell.sh" ] && . "$PFSHELL_DIR/shell.sh"
$MARK_END
EOF
  ok "Bash branché aussi (au cas où zsh manque sur une machine)"
}

# ---------------------------------------------------------------- STARSHIP --
write_starship() {
  local dest="$CFG/starship.toml"
  mkdir -p "$CFG"
  backup "$dest"
  # Ordre de priorité : 1) fichier à côté du script (repo cloné)  2) fichier téléchargé depuis le repo
  #                      3) thème rouge/noir intégré (hors ligne ou --no-install)
  local tmp; tmp=$(mktemp)
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/starship.toml" ]; then
    { echo "# pfshell-managed"; cat "$SCRIPT_DIR/starship.toml"; } > "$dest"
    rm -f "$tmp"; ok "starship.toml copié depuis le repo local"; return
  elif [ "$DO_INSTALL" -eq 1 ] && command -v curl >/dev/null 2>&1 && curl -fsSLo "$tmp" "$REPO_RAW/starship.toml"; then
    { echo "# pfshell-managed"; cat "$tmp"; } > "$dest"
    rm -f "$tmp"; ok "starship.toml téléchargé depuis ton repo"; return
  fi
  rm -f "$tmp"
  [ "$DO_INSTALL" -eq 1 ] && info "starship.toml introuvable dans le repo : thème par défaut utilisé"
  cat > "$dest" <<'EOF'
# pfshell-managed — thème rouge/noir néon par défaut
add_newline = false
format = "$username$hostname$directory$git_branch$git_status$python$cmd_duration$line_break$status$character"

[username]
show_always = true
style_user = "#a00000"
style_root = "bold #ff1744"
format = "[$user]($style)"

[hostname]
ssh_only = false
ssh_symbol = ' \[ssh\]'   # crochets échappés : en starship, [ ] = syntaxe de mise en forme
style = "#ff1744"
format = "[@](#8a8a8a)[$hostname$ssh_symbol]($style) "

[directory]
style = "bold white"
truncation_length = 4

[git_branch]
style = "#a00000"
format = '[\($branch\)]($style) '

[git_status]
style = "#ff1744"

[cmd_duration]
min_time = 3000
style = "#8a8a8a"
format = "[⏱ $duration]($style) "

[status]
disabled = false
style = "#ff1744"
format = "[✘ $status]($style) "

[character]
success_symbol = "[❯](#ff1744)"
error_symbol = "[❯](bold #ff1744)"
EOF
  ok "starship.toml (thème rouge/noir) écrit"
}

# ------------------------------------------------------------ TMUX & VIM ----
write_tmux() {
  backup "$HOME/.tmux.conf"
  cat > "$HOME/.tmux.conf" <<'EOF'
# pfshell-managed
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 10
set -g default-terminal "screen-256color"
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"
bind r source-file ~/.tmux.conf \; display "config rechargée"
set -g status-style "bg=black,fg=colour196"
set -g status-left "#[bold] #S "
set -g status-right "#[fg=colour245]#H #[fg=colour196]%H:%M "
setw -g window-status-current-style "fg=black,bg=colour196,bold"
set -g pane-border-style "fg=colour88"
set -g pane-active-border-style "fg=colour196"
EOF
  ok "~/.tmux.conf écrit"
}

write_vim() {
  backup "$HOME/.vimrc"
  cat > "$HOME/.vimrc" <<'EOF'
" pfshell-managed
set nocompatible encoding=utf-8
syntax on
filetype plugin indent on
set number ruler showcmd laststatus=2
set tabstop=4 shiftwidth=4 expandtab autoindent
set incsearch hlsearch ignorecase smartcase
set backspace=indent,eol,start
set scrolloff=5
EOF
  ok "~/.vimrc écrit"
}

# ------------------------------------------------------- DÉSINSTALLATION ----
uninstall() {
  local rc="$HOME/.bashrc"
  [ -f "$rc" ] && sed -i "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$rc" && ok "Bloc retiré de ~/.bashrc"

  # Chaque fichier est restauré depuis la sauvegarde la plus récente qui le contient
  for f in "${MANAGED_FILES[@]}"; do
    [ -f "$f" ] && head -n1 "$f" | grep -q "pfshell-managed" || continue
    rm -f "$f"
    local src=""
    for d in $(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort -r); do
      [ -f "$d$(basename "$f")" ] && { src="$d$(basename "$f")"; break; }
    done
    if [ -n "$src" ]; then cp -a "$src" "$f" && ok "${f/#$HOME/\~} restauré"
    else ok "${f/#$HOME/\~} supprimé (il n'existait pas avant)"; fi
  done

  # On ne retire que ce que pfshell a lui-même installé
  if [ -f "$STATE_FILE" ]; then
    grep -qx omz "$STATE_FILE"      && rm -rf "$HOME/.oh-my-zsh"         && ok "oh-my-zsh retiré"
    grep -qx starship "$STATE_FILE" && rm -f "$HOME/.local/bin/starship" && ok "starship retiré"
    local old; old=$(grep '^shell:' "$STATE_FILE" | head -n1 | cut -d: -f2-)
    [ -n "$old" ] && info "Shell par défaut d'origine : $old → pour revenir : chsh -s $old"
    rm -f "$STATE_FILE"
  fi
  rm -rf "$PFSHELL_DIR"
  ok "Désinstallé. Sauvegardes conservées dans ${BACKUP_ROOT/#$HOME/\~} (paquets système laissés en place)"
}

# ------------------------------------------------------------------ MAIN ----
if [ "$DO_UNINSTALL" -eq 1 ]; then uninstall; exit 0; fi

info "pfshell — configuration de $(id -un)@$(uname -n)"
if [ "$DO_INSTALL" -eq 1 ]; then
  install_packages
  install_ohmyzsh
  install_starship
else
  info "--no-install : rien n'est téléchargé, seuls les dotfiles sont posés"
fi
write_shell_config
write_zshrc
hook_bashrc
write_starship
write_tmux
write_vim
[ "$DO_INSTALL" -eq 1 ] && set_default_shell

printf '\n%sTerminé.%s Ouvre un nouveau terminal, ou : %sexec zsh%s\n' "$c_red" "$c_rst" "$c_dim" "$c_rst"
