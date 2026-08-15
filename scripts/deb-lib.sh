# shellcheck shell=bash
# Read a .deb without dpkg-deb.
#
# The distributions this package exists for (Silverblue, Aeon, NixOS, Alpine)
# do not ship dpkg. Every maintainer script here has to work with ar + tar only.
#
# GNU tar refuses to auto-detect compression on a non-seekable stream, so the
# member's own extension picks the decompressor. An extension we do not know is
# a hard error, not a guess: a silently-unread payload is how a maintainer ends
# up publishing a manifest that describes bytes nobody looked at.

# deb_member <deb> <prefix>   -> the ar member starting with <prefix>
deb_member() {
    local m
    m=$(ar t "$1" | grep "^$2" | head -n1)
    [ -n "$m" ] || { echo "deb-lib: no $2* member in $1" >&2; return 1; }
    echo "$m"
}

# deb_cat <deb> <member>      -> that member, decompressed, on stdout
deb_cat() {
    case "$2" in
        *.tar)     ar p "$1" "$2" ;;
        *.tar.xz)  ar p "$1" "$2" | xz -dc ;;
        *.tar.gz)  ar p "$1" "$2" | gzip -dc ;;
        *.tar.zst) ar p "$1" "$2" | zstd -dc ;;
        *.tar.bz2) ar p "$1" "$2" | bzip2 -dc ;;
        *) echo "deb-lib: unhandled compression for member '$2', add it here" >&2
           return 1 ;;
    esac
}

# deb_control <deb>           -> the control file on stdout
deb_control() {
    deb_cat "$1" "$(deb_member "$1" control.tar)" | tar xO ./control
}

# deb_version <deb>           -> the upstream version string
deb_version() {
    deb_control "$1" | sed -n 's/^Version:[[:space:]]*//p'
}

# deb_list <deb>              -> `tar tv` of the data member
deb_list() {
    deb_cat "$1" "$(deb_member "$1" data.tar)" | tar tv
}

# deb_extract <deb> <destdir> [tar args...]
deb_extract() {
    local deb=$1 dest=$2
    shift 2
    mkdir -p "$dest"
    deb_cat "$deb" "$(deb_member "$deb" data.tar)" | tar x -C "$dest" "$@"
}
