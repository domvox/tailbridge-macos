#!/bin/bash
# Prints the SHA-256 of a bundle manifest. Read-only. Used by build.sh (BUILDINFO).
#
# Scope (exactly this, nothing more):
#   d <mode> <path>          every directory, including empty ones and the bundle root
#   f <mode> <sha256> <path> every regular file
# sorted by path. Anything else (symlinks, devices, sockets, FIFOs), a name with a control character
# (e.g. a newline), or anything that cannot be read (file or directory) makes it fail: exit 1, nothing on stdout.
# NOT covered: extended attributes (incl. resource forks), ACLs, file flags, owner, group, timestamps.
# Equal manifests therefore mean "same tree, permissions and file contents", not byte-identical bundles.
set -euo pipefail
app=${1:?użycie: bundle-manifest.sh <ścieżka .app>}
[ -d "$app" ] && [ ! -L "$app" ] || { echo "to nie jest katalog pakietu: $app" >&2; exit 1; }
cd "$app"
odd=$(/usr/bin/find . ! -type f ! -type d -print -quit)
[ -z "$odd" ] || { echo "nietypowy plik w pakiecie: $odd" >&2; exit 1; }
ctrl=$(/usr/bin/find . -name '*[[:cntrl:]]*' -print -quit)
[ -z "$ctrl" ] || { echo "nazwa ze znakiem sterującym w pakiecie (nieobsługiwana)" >&2; exit 1; }

# Every step is checked on its own: a failure inside a command substitution used as a printf argument would
# otherwise be lost. The whole list is built first and hashed only if it is complete.
entries() {
    local p mode sum
    while IFS= read -r -d '' p; do
        mode=$(/usr/bin/stat -f '%Lp' "$p") && [[ $mode =~ ^[0-7]{1,4}$ ]] || { echo "nie można odczytać uprawnień: $p" >&2; return 1; }
        if [ -d "$p" ]; then
            [ -r "$p" ] && [ -x "$p" ] || { echo "nieczytelny katalog: $p" >&2; return 1; }
            printf 'd %s %s\n' "$mode" "$p"
        else
            sum=$(/usr/bin/shasum -a 256 < "$p") || { echo "nieczytelny plik: $p" >&2; return 1; }
            sum=${sum%% *}
            [[ $sum =~ ^[0-9a-f]{64}$ ]] || { echo "niepoprawna suma pliku: $p" >&2; return 1; }
            printf 'f %s %s %s\n' "$mode" "$sum" "$p"
        fi
    done
}
list=$(/usr/bin/find . \( -type d -o -type f \) -print0 | LC_ALL=C /usr/bin/sort -z | entries)
[ -n "$list" ] || { echo "pusty manifest" >&2; exit 1; }
digest=$(printf '%s\n' "$list" | /usr/bin/shasum -a 256)
digest=${digest%% *}
[[ $digest =~ ^[0-9a-f]{64}$ ]] || { echo "niepoprawny skrót manifestu" >&2; exit 1; }
echo "$digest"
