#!/bin/bash
# Tests for tools/bundle-manifest.sh (used by build.sh for BUILDINFO). Only touches a fresh temporary directory.
set -uo pipefail
cd "$(dirname "$0")/.."
MANIFEST="$(pwd -P)/tools/bundle-manifest.sh"
W=$(cd "$(/usr/bin/mktemp -d /tmp/tailbridge-manifest-test.XXXXXX)" && pwd -P)
trap '/bin/chmod -R u+rwx "$W" 2>/dev/null; /bin/rm -rf "$W"' EXIT

PASS=0 FAIL=0
check() { if eval "$1"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "BŁĄD: $2"; fi; }
run() { "$MANIFEST" "$1" > "$W/out" 2> "$W/err"; echo $? > "$W/rc"; }
rc() { /bin/cat "$W/rc"; }
out() { /bin/cat "$W/out"; }
fixture() {  # <dir>: a small bundle with known modes and contents
    /bin/mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
    printf 'exe\n' > "$1/Contents/MacOS/App"; printf 'plist\n' > "$1/Contents/Info.plist"
    /bin/chmod 755 "$1" "$1/Contents" "$1/Contents/MacOS" "$1/Contents/Resources" "$1/Contents/MacOS/App"
    /bin/chmod 644 "$1/Contents/Info.plist"
}
h() { printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64; }

# Format: computed independently from the documented line format.
fixture "$W/a.app"
expected=$(printf '%s\n' \
    "d 755 ." "d 755 ./Contents" "f 644 $(h $'plist\n') ./Contents/Info.plist" "d 755 ./Contents/MacOS" \
    "f 755 $(h $'exe\n') ./Contents/MacOS/App" "d 755 ./Contents/Resources" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-64)
run "$W/a.app"
check '[ "$(rc)" = 0 ] && [ "$(out)" = "$expected" ]' "manifest zgodny z opisanym formatem"
base=$(out)
/usr/bin/ditto "$W/a.app" "$W/b.app"; run "$W/b.app"
check '[ "$(out)" = "$base" ]' "kopia ma ten sam manifest"

# What is covered changes the digest; what is documented as excluded does not.
/bin/chmod 700 "$W/b.app/Contents/MacOS"; run "$W/b.app"
check '[ "$(rc)" = 0 ] && [ "$(out)" != "$base" ]' "uprawnienia katalogu w zakresie"
/bin/chmod 755 "$W/b.app/Contents/MacOS"; /bin/mkdir "$W/b.app/Contents/Resources/empty"; run "$W/b.app"
check '[ "$(out)" != "$base" ]' "pusty katalog w zakresie"
/bin/rmdir "$W/b.app/Contents/Resources/empty"; printf 'exe2\n' > "$W/b.app/Contents/MacOS/App"; run "$W/b.app"
check '[ "$(out)" != "$base" ]' "treść pliku w zakresie"
printf 'exe\n' > "$W/b.app/Contents/MacOS/App"; /usr/bin/xattr -w com.example.test 1 "$W/b.app/Contents/Info.plist"; run "$W/b.app"
check '[ "$(out)" = "$base" ]' "atrybuty rozszerzone poza zakresem (jak w dokumentacji)"

# Review round 3: an unreadable file used to be silently left out (digest printed, exit 0), so a changed
# unreadable file kept the same manifest. Now: failure, nothing on stdout.
fixture "$W/u.app"; printf 'before\n' > "$W/u.app/Contents/Resources/secret"; /bin/chmod 000 "$W/u.app/Contents/Resources/secret"
run "$W/u.app"
check '[ "$(rc)" = 1 ] && [ ! -s "$W/out" ] && /usr/bin/grep -q "nieczytelny plik" "$W/err"' "nieczytelny plik przerywa manifest bez wyniku"
/bin/chmod 600 "$W/u.app/Contents/Resources/secret"; printf 'after\n' > "$W/u.app/Contents/Resources/secret"; /bin/chmod 000 "$W/u.app/Contents/Resources/secret"
run "$W/u.app"
check '[ "$(rc)" = 1 ] && [ ! -s "$W/out" ]' "zmieniony nieczytelny plik nadal nie daje wyniku"
fixture "$W/d.app"; /bin/mkdir "$W/d.app/Contents/Resources/locked"; /bin/chmod 000 "$W/d.app/Contents/Resources/locked"
run "$W/d.app"
check '[ "$(rc)" = 1 ] && [ ! -s "$W/out" ]' "nieczytelny katalog przerywa manifest bez wyniku"
/bin/chmod 755 "$W/d.app/Contents/Resources/locked"

# Unsupported entries.
fixture "$W/l.app"; /bin/ln -s Info.plist "$W/l.app/Contents/link"; run "$W/l.app"
check '[ "$(rc)" = 1 ] && [ ! -s "$W/out" ]' "dowiązanie odrzucone"
fixture "$W/f.app"; /usr/bin/mkfifo "$W/f.app/Contents/fifo"; run "$W/f.app"
check '[ "$(rc)" = 1 ] && [ ! -s "$W/out" ]' "FIFO odrzucone"
fixture "$W/n.app"; : > "$W/n.app/Contents/a"$'\n'"b"; run "$W/n.app"
check '[ "$(rc)" = 1 ] && [ ! -s "$W/out" ]' "nazwa z nową linią odrzucona"
/bin/ln -s "$W/a.app" "$W/link.app"; run "$W/link.app"
check '[ "$(rc)" = 1 ] && [ ! -s "$W/out" ]' "pakiet jako dowiązanie odrzucony"

# The real build, if present: deterministic and equal to BUILDINFO.
if [ -d build/TailBridge.app ] && [ -f build/BUILDINFO.txt ]; then
    run build/TailBridge.app
    check '[ "$(rc)" = 0 ] && [ "$(out)" = "$(/usr/bin/sed -n "s/^bundle_manifest_sha256=//p" build/BUILDINFO.txt)" ]' "manifest buildu zgodny z BUILDINFO"
fi

echo "Wynik: $PASS OK, $FAIL BŁĘDÓW"
[ $FAIL = 0 ]
