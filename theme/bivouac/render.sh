#!/usr/bin/env bash
set -euo pipefail

THEME_DIR="$(cd "$(dirname "$0")" && pwd)"
set -a; source "$THEME_DIR/palette.env"; set +a

# Liste explicite des variables : sans elle, envsubst effacerait aussi
# les variables propres à Sway ($bg, $accent…) présentes dans les modèles.
VARS=$(grep -oE '^[A-Z0-9_]+' "$THEME_DIR/palette.env" | sed 's/^/$/' | tr '\n' ' ')

render() {
    mkdir -p "$(dirname "$2")"
    envsubst "$VARS" < "$THEME_DIR/templates/$1" > "$2"
    echo "généré : $2"
}

# Variante pour foot, qui attend des couleurs hex sans le '#'
render_bare() {
    mkdir -p "$(dirname "$2")"
    envsubst "$VARS" < "$THEME_DIR/templates/$1" | sed 's/#\([0-9a-fA-F]\{6\}\)/\1/g' > "$2"
    echo "généré : $2"
}

render sway-colors.tmpl "$HOME/.config/sway/colors-bivouac"
render waybar-colors.css.tmpl "$HOME/.config/waybar/colors-bivouac.css"
render_bare foot-colors.ini.tmpl "$HOME/.config/foot/colors-bivouac.ini"
render starship.toml.tmpl "$HOME/.config/starship.toml"
render fastfetch.jsonc.tmpl "$HOME/.config/fastfetch/config.jsonc"
render rofi-colors.rasi.tmpl "$HOME/.config/rofi/colors-bivouac.rasi"
render mako.tmpl "$HOME/.config/mako/config"
render gtklock.css.tmpl "$HOME/.config/gtklock/style.css"
