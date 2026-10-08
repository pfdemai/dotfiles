# dotfiles

Configuration de mon terminal, déployable en une commande sur n'importe quelle machine Linux :
zsh + oh-my-zsh + starship, plugins autosuggestions et syntax-highlighting, alias, tmux, vim.

## Installation

```bash
curl -fsSLo bootstrap.sh https://raw.githubusercontent.com/pfdemai/dotfiles/main/bootstrap.sh
less bootstrap.sh     # relire avant d'exécuter
bash bootstrap.sh
```

| Option | Effet |
|---|---|
| *(aucune)* | Installe les paquets (si sudo dispo), oh-my-zsh, starship, puis la config |
| `--no-install` | Ne télécharge rien : pose seulement les fichiers de config |
| `--uninstall` | Retire tout et restaure les fichiers d'origine |

## Principes

- **Idempotent** : relançable à volonté, sans doublon.
- **Réversible** : chaque fichier remplacé est sauvegardé, `--uninstall` les restaure.
  Seul ce que le script a lui-même installé est retiré.
- **Sans root si besoin** : oh-my-zsh et starship s'installent dans le home.
- **Multi-distro** : apt, dnf, pacman, zypper, apk. Bash est aussi configuré, au cas où zsh manque.
- **Starship vérifié** : binaire statique, empreinte SHA-256 contrôlée, pas de `curl | sh`.
- **Garde-fou SSH** : `reboot` et `shutdown` demandent le nom de la machine en session distante.

## Contenu

| Fichier | Rôle |
|---|---|
| `bootstrap.sh` | Script d'installation |
| `starship.toml` | Thème du prompt (optionnel, sinon thème par défaut du script) |
| `local.sh.example` | Modèle de config propre à une machine |

## Config locale

Ce qui est propre à une machine (alias vers des IP, proxy, dossiers de travail) va dans
`~/.config/pfshell/local.sh`, jamais dans ce repo :

```bash
cp local.sh.example ~/.config/pfshell/local.sh
```
