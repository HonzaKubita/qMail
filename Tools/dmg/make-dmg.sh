#!/bin/sh
# Packages a notarized qMail.app as the release disk image, with the background and layout in Tools/dmg:
#   Tools/dmg/make-dmg.sh build/release/notarized/qMail.app build/release/qMail-<version>.dmg
# Uses dmgbuild (it writes the Finder layout without scripting Finder), installed into build/dmg-venv on first use.
set -e
[ $# -eq 2 ] || { echo "usage: $0 <qMail.app> <output.dmg>" >&2; exit 1; }
app=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
venv=$root/build/dmg-venv
[ -x "$venv/bin/dmgbuild" ] || { python3 -m venv "$venv" && "$venv/bin/pip" install -q dmgbuild; }
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
rm -f "$out"
"$venv/bin/dmgbuild" -s "$here/settings.py" -D app="$app" -D settings="$here/settings.py" "qMail $version" "$out" >/dev/null
echo "Built $out"
