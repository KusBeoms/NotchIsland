#!/bin/bash
# ./install.sh              build, install to ~/Applications and start NotchIsland at every login
# ./install.sh --stop       stop it for now (it starts again at the next login)
# ./install.sh --uninstall  stop it and remove the app and the login item
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.kusbeoms.notchisland
DEST="$HOME/Applications/NotchIsland.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

stop() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    pkill -x NotchIsland 2>/dev/null || true
    sleep 0.5
}

case "${1:-install}" in
    --stop)
        stop; echo "stopped" ;;
    --uninstall)
        stop; rm -f "$PLIST"; rm -rf "$DEST"; echo "removed $DEST and $PLIST" ;;
    install)
        ./build.sh
        stop
        mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
        rm -rf "$DEST"
        cp -R build/NotchIsland.app "$DEST"
        cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/NotchIsland</string></array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
        plutil -lint "$PLIST"
        launchctl bootstrap "$DOMAIN" "$PLIST"
        echo "installed $DEST; it starts now and at every login" ;;
    *)
        echo "usage: $0 [--stop | --uninstall]"; exit 2 ;;
esac
