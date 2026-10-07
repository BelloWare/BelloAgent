#!/usr/bin/env bash
# Explicit operator launch only. Never invoke this during preparation/headless QA.
set -euo pipefail
root=${1:?Usage: launch_skills_gui.sh FIXTURE_ROOT FROZEN_BINARY BUILD_ENV}
binary=${2:?Supply the sealed debug synthetic-authority binary}
build_env=${3:?Supply the existing build-environment directory}
root=$(realpath "$root")
binary=$(realpath "$binary")
fixture_script=$(realpath "$(dirname "$0")/skills_workflow_fixture.py")
[[ -f "$root/fixture.json" && -x "$binary" && -f "$root/evidence/sealed-build.json" ]]
# Verify the recorded exact binary before creating any GUI process.
python3 - "$root" "$binary" <<'PY'
import hashlib,json,pathlib,sys
root,binary=map(pathlib.Path,sys.argv[1:])
manifest=json.loads((root/'evidence/sealed-build.json').read_text())
assert binary == pathlib.Path(manifest['binary']), 'Use the sealed binary path'
assert hashlib.sha256(binary.read_bytes()).hexdigest() == manifest['binary_sha256'], 'Binary changed after sealing'
PY
if [[ ${BELLO_SKILLS_DBUS_CHILD:-0} != 1 ]]; then
    export BELLO_SKILLS_DBUS_CHILD=1
    exec dbus-run-session -- bash "$0" "$root" "$binary" "$build_env"
fi
# Use only already provisioned dependencies. This script installs nothing.
source "$build_env/gui-env.sh"
export HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache"
export XDG_CURRENT_DESKTOP=XFCE GTK_USE_PORTAL=0
export XDG_DESKTOP_PORTAL_DIR="$root/portals"
export XDG_DATA_DIRS="$build_env/portal-sysroot/usr/share:/usr/local/share:/usr/share"
export BELLO_TEST_APPEARANCE=${BELLO_TEST_APPEARANCE:-light}
export BELLO_TEST_WINDOW_SIZE=${BELLO_TEST_WINDOW_SIZE:-1180x840}
: "${DISPLAY:?Set DISPLAY only after the desktop lane is assigned}"
unset WAYLAND_DISPLAY
children=()
cleanup() { for pid in "${children[@]}"; do kill "$pid" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT INT TERM
portal="$build_env/portal-sysroot/usr/libexec"
for name in xdg-permission-store xdg-desktop-portal-gtk xdg-desktop-portal; do
    [[ -x "$portal/$name" ]] || { echo "Missing already-provisioned $name" >&2; exit 2; }
    "$portal/$name" > "$root/evidence/$name.log" 2>&1 & children+=("$!")
done
# A bounded availability probe, never a GUI acceptance assertion.
deadline=$((SECONDS + 8))
until dbus-send --session --dest=org.freedesktop.portal.Desktop --type=method_call --print-reply /org/freedesktop/portal/desktop org.freedesktop.DBus.Properties.Get string:org.freedesktop.portal.FileChooser string:version > "$root/evidence/portal-probe.log" 2>&1; do
    ((SECONDS < deadline)) || { echo 'File chooser portal did not become ready' >&2; exit 2; }
    sleep .1
done
# The operator starts the numeric-loopback gateway separately to preserve request
# numbering/control state across app restart. No automatic trust/selection/send.
python3 - "$root" <<'PY'
import http.client,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); marker=json.loads((root/'fixture.json').read_text())
connection=http.client.HTTPConnection("127.0.0.1",marker["port"],timeout=2)
connection.request("GET","/status")
response=connection.getresponse()
assert response.status==200 and json.loads(response.read())["fixture_id"]==marker["id"], "Different fixture gateway"
connection.close()
PY
"$binary" --synthetic-connections --synthetic-attachment-fixture "$root/profile.json" --project "$root/project" --session "$root/state/session.json" > "$root/evidence/app.log" 2>&1
python3 "$fixture_script" inspect --root "$root"
