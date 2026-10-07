#!/usr/bin/env bash
set -euo pipefail
root=/workspace/shared/agent-shell-held-gui-fixture
base=/workspace/scratch/8b6fda578834/build-environment
if [[ ${BELLO_BASH_DBUS_CHILD:-0} != 1 ]]; then
 export BELLO_BASH_DBUS_CHILD=1
 exec dbus-run-session -- bash "$0"
fi
source "$base/gui-env.sh"
export HOME="$root/home" TMPDIR="$root/tmp" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache"
export XDG_CURRENT_DESKTOP=XFCE GTK_USE_PORTAL=0 XDG_DESKTOP_PORTAL_DIR="$root/portals"
export XDG_DATA_DIRS="$base/portal-sysroot/usr/share:/usr/local/share:/usr/share"
: "${DISPLAY:?Assigned desktop required}"
children=()
cleanup(){ for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM
portal="$base/portal-sysroot/usr/libexec"
for name in xdg-permission-store xdg-desktop-portal-gtk xdg-desktop-portal; do
 "$portal/$name" > "$root/evidence/$name.log" 2>&1 & children+=("$!")
done
deadline=$((SECONDS + 8))
until dbus-send --session --dest=org.freedesktop.portal.Desktop --type=method_call --print-reply /org/freedesktop/portal/desktop org.freedesktop.DBus.Properties.Get string:org.freedesktop.portal.FileChooser string:version > "$root/evidence/portal-probe.log" 2>&1; do
 ((SECONDS < deadline)) || exit 2
 sleep .1
done
python3 -B /workspace/shared/agent-shell-held-gui-fixture/held_provider.py serve --root "$root" > "$root/evidence/gateway.log" 2>&1 & children+=("$!")
python3 - "$root" <<'PY'
import http.client,time,json,pathlib,sys
r=pathlib.Path(sys.argv[1]);m=json.loads((r/'fixture.json').read_text());deadline=time.monotonic()+5
while True:
 try:
  c=http.client.HTTPConnection('127.0.0.1',m['port'],timeout=1);c.request('GET','/status');v=json.loads(c.getresponse().read());assert v['fixture_id']==m['id'];c.close();break
 except OSError:
  if time.monotonic()>=deadline: raise
  time.sleep(.05)
PY
export BELLO_TEST_APPEARANCE=light BELLO_TEST_WINDOW_SIZE=1180x840
unset WAYLAND_DISPLAY
python3 -B "$root/observe_app.py"
