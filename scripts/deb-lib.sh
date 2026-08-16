# shellcheck shell=bash
# Read a .deb without dpkg-deb, which Silverblue, Aeon, NixOS and Alpine do not
# ship. ar + tar only.

deb_member() {
    local m
    m=$(ar t "$1" | grep "^$2" | head -n1)
    [ -n "$m" ] || { echo "deb-lib: no $2* member in $1" >&2; return 1; }
    echo "$m"
}

# Compression comes from the member extension because GNU tar refuses to detect
# it on a non-seekable stream. Unknown extension is a hard error, not a guess.
deb_cat() {
    case "$2" in
        *.tar.xz)  ar p "$1" "$2" | xz -dc ;;
        *.tar.gz)  ar p "$1" "$2" | gzip -dc ;;
        *.tar.zst) ar p "$1" "$2" | zstd -dc ;;
        *) echo "deb-lib: unhandled compression for member '$2', add it here" >&2
           return 1 ;;
    esac
}

deb_control() {
    deb_cat "$1" "$(deb_member "$1" control.tar)" | tar xO ./control
}

deb_version() {
    deb_control "$1" | sed -n 's/^Version:[[:space:]]*//p'
}
