#!/bin/bash

set -euo pipefail

# This script is executed within the container as root.  It assumes
# that source code with debian packaging files can be found at
# /source-ro and that resulting packages are written to /output after
# successful build.  These directories are mounted as docker volumes to
# allow files to be exchanged between the host and the container.

CONTAINER_START_TIME="$EPOCHSECONDS"

if [ -t 0 ] && [ -t 1 ]; then
    Blue='\033[0;34m'
    Reset='\033[0m'
else
    Blue=
    Reset=
fi

function log {
    echo -e "${Blue}[*] $1${Reset}"
}

# Remove directory owned by _apt
trap "rm -rf /var/cache/apt/archives/partial" EXIT

# force colors from dh and dpkg
export DH_COLORS="always"
export DPKG_COLORS="always"

log "Updating container"
apt-get update
apt-get upgrade -y --no-install-recommends
apt-mark minimize-manual -y
apt-get autoremove -y

log "Cleaning apt package cache"
apt-get autoclean

# Install extra dependencies that were provided for the build (if any)
#   Note: dpkg can fail due to dependencies, ignore errors, and use
#   apt-get to install those afterwards
if [ -d /dependencies ]; then
    log "Installing extra dependencies"
    dpkg -i /dependencies/*.deb
    apt-get -f install -y --no-install-recommends
fi

adduser --system --no-create-home build-runner

# Install ccache
if [ -n "${USE_CCACHE+x}" ]; then
    log "Setting up ccache"
    apt-get install -y --no-install-recommends ccache
    export CCACHE_DIR=/ccache_dir
    ccache --zero-stats
    chown -R --preserve-root build-runner: /ccache_dir
fi

# Make read-write copy of source code
log "Copying source directory"
mkdir /build
cp -a /source-ro /build/source
chown -R --preserve-root build-runner: /build

# Reset timestamps
if [ -n "${RESET_TIMESTAMPS+x}" ]; then
    log "Resetting timestamps"
    SOURCE_DATE_RFC2822=$(dpkg-parsechangelog --file /build/source/debian/changelog --show-field Date)
    find /build/source -exec touch -m --no-dereference --date="${SOURCE_DATE_RFC2822}" {} +;
fi

cd /build/source

# Install build dependencies
log "Installing build dependencies"
mk-build-deps -ir -t "apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends"

# dovecot_2.3.20+dfsg1.orig.tar.gz
name="$(dpkg-parsechangelog -S Source)_$(dpkg-parsechangelog -S Version | sed -e 's/-[^-]*$//' | sed -e 's/^[0-9]*://').orig.tar.gz"
tar --create --file "../${name}" --gzip --preserve-permissions --exclude './debian' --exclude './.git' .

# Build packages
log "Building package with DEB_BUILD_OPTIONS set to '${DEB_BUILD_OPTIONS:-}'"
BUILD_START_TIME="$EPOCHSECONDS"
runuser -u build-runner -- debuild --prepend-path /usr/lib/ccache --preserve-envvar CCACHE_DIR --sanitize-env -rfakeroot -b --no-sign -sa | tee /build/build.log
log "Build completed in $((EPOCHSECONDS - BUILD_START_TIME)) seconds"

#runuser -u build-runner -- dpkg-source --before-build .
#runuser -u build-runner -- dpkg-buildpackage --sanitize-env -us -uc -rfakeroot -sa --source-option=--format='3.0 (native)'

if [ -n "${BUILD_TWICE+x}" ]; then
    log "Building package the second time"
    #debuild --prepend-path /usr/lib/ccache --preserve-envvar CCACHE_DIR -b -uc -us --sanitize-env
    runuser -u build-runner -- dpkg-buildpackage --sanitize-env -us -uc -rfakeroot -S
fi

if [ -n "${USE_CCACHE+x}" ]; then
    log "ccache statistics"
    ccache --show-stats --verbose
fi

cd /

# Run Lintian
if [ -n "${RUN_LINTIAN+x}" ]; then
    log "Installing Lintian"
    apt-get install -y --no-install-recommends lintian
    adduser --system --no-create-home lintian-runner
    log "+++ Lintian Report Start +++"
    runuser -u lintian-runner -- lintian --display-experimental --info --display-info --pedantic --tag-display-limit 0 --color always --verbose --fail-on none /build/*.changes | tee /build/lintian.log
    log "+++ Lintian Report End +++"
fi

# Run blhc
if [ -n "${RUN_BLHC+x}" ]; then
    log "Installing blhc"
    apt-get install -y --no-install-recommends blhc
    log "+++ blhc Report Start +++"
    blhc --all --color /build/build.log | tee /build/blhc.log || true
    log "+++ blhc Report End +++"
fi

# Drop color escape sequences from logs
sed -e 's/\x1b\[[0-9;]*[mK]//g' --in-place=.color /build/*.log

# Copy packages to output dir with user's permissions
if [ -n "${USER+x}" ] && [ -n "${GROUP+x}" ]; then
    chown "${USER}:${GROUP}" /build/*.deb /build/*.buildinfo /build/*.changes /build/*.log /build/*.log.color
else
    chown root:root /build/*.deb /build/*.buildinfo /build/*.changes /build/*.log /build/*.log.color
fi
cp -a /build/*.deb /build/*.buildinfo /build/*.changes /build/*.log /build/*.log.color /output/
ls -l --almost-all --color=always --human-readable --ignore={*.log,*.log.color} /output

log "Finished in $((EPOCHSECONDS - CONTAINER_START_TIME)) seconds"
