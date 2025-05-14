#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

# Enable the multilib repository
cat <<EOM >>/etc/pacman.conf
[multilib]
Include = /etc/pacman.d/mirrorlist
[archlinuxcn]
Server = https://repo.archlinuxcn.org/x86_64
EOM

pacman-key --init
pacman-key --lsign-key "farseerfc@archlinux.org"
pacman -Sy --noconfirm && pacman -S --noconfirm archlinuxcn-keyring
pacman -Syu --noconfirm archlinux-keyring
pacman -Syu --noconfirm --needed yay

# Makepkg does not allow running as root
# Create a new user `builder`
# `builder` needs to have a home directory because some PKGBUILDs will try to
# write to it (e.g. for cache)
useradd builder -m
# When installing dependencies, makepkg will use sudo
# Give user `builder` passwordless sudo access
echo "builder ALL=(ALL) NOPASSWD: ALL" >>/etc/sudoers

# Give all users (particularly builder) full access to these files
chmod -R a+rw .

BASEDIR="$PWD"
echo "BASEDIR: $BASEDIR"
cd "build-nonaur-action/${INPUT_PKGDIR:-.}"

# Just generate .SRCINFO
if ! [ -f .SRCINFO ]; then
    sudo -u builder makepkg --printsrcinfo >.SRCINFO
fi

function recursive_build() {
    for d in *; do
        if [ -d "$d" ]; then
            (cd -- "$d" && recursive_build)
        fi
    done

    sudo -u builder makepkg --printsrcinfo >.SRCINFO
    mapfile -t OTHERPKGDEPS < \
        <(sed -n -e 's/^[[:space:]]*\(make\)\?depends\(_x86_64\)\? = \([[:alnum:][:punct:]]*\)[[:space:]]*$/\3/p' .SRCINFO)
    sudo -H -u builder yay --sync --noconfirm --needed --builddir="$BASEDIR" "${OTHERPKGDEPS[@]}"

    sudo -H -u builder makepkg --install --noconfirm
    [ -d "$BASEDIR/local/" ] || mkdir "$BASEDIR/local/"
    cp ./*.pkg.tar.zst "$BASEDIR/local/"
}

# Optionally install dependencies from AUR
if [ -n "${INPUT_AURDEPS:-}" ]; then
    # Extract dependencies from .SRCINFO (depends or depends_x86_64) and install
    mapfile -t PKGDEPS < \
        <(sed -n -e 's/^[[:space:]]*\(make\)\?depends\(_x86_64\)\? = \([[:alnum:][:punct:]]*\)[[:space:]]*$/\3/p' .SRCINFO)

    # If package have dependencies from AUR and we want to use our PKGBUILD of these dependencies
    CURDIR="$PWD"
    for d in *; do
        if [ -d "$d" ]; then
            (cd -- "$d" && recursive_build)
        fi
    done
    cd "$CURDIR"

    sudo -H -u builder yay --sync --noconfirm --needed --builddir="$BASEDIR" "${PKGDEPS[@]}"
fi

# Build packages
# INPUT_MAKEPKGARGS is intentionally unquoted to allow arg splitting
# shellcheck disable=SC2086
sudo -H -u builder makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}

# Get array of packages to be built
mapfile -t PKGFILES < <(sudo -u builder makepkg --packagelist)
echo "Package(s): ${PKGFILES[*]}"

# Report built package archives
i=0
for PKGFILE in "${PKGFILES[@]}"; do
    # makepkg reports absolute paths, must be relative for use by other actions
    RELPKGFILE="$(realpath --relative-base="$BASEDIR" "$PKGFILE")"
    # Caller arguments to makepkg may mean the pacakge is not built
    if [ -f "$PKGFILE" ]; then
        echo "pkgfile$i=$RELPKGFILE" >>$GITHUB_OUTPUT
    else
        echo "Archive $RELPKGFILE not built"
    fi
    ((++i))
done

function prepend() {
    # Prepend the argument to each input line
    while read -r line; do
        echo "$1$line"
    done
}

python3 $BASEDIR/build-nonaur-action/encode_name.py
