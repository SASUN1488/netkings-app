#!/bin/sh
# NetKings VPN for Linux: installs into ~/.local/opt/netkings (no root; the VPN core asks for the admin
# password once, on the first connect, to get the network capability).
set -e
D="$HOME/.local/opt/netkings"
SRC=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$D" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/512x512/apps"
cp -a "$SRC/bundle/." "$D/"
cp "$SRC/netkings.png" "$HOME/.local/share/icons/hicolor/512x512/apps/netkings.png"
cat > "$HOME/.local/share/applications/netkings.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=NetKings VPN
Exec=$D/netkings
Icon=netkings
Categories=Network;
Terminal=false
DESK
echo "Готово: NetKings VPN есть в меню приложений (или запусти $D/netkings)"
