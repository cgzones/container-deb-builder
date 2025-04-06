#!/bin/bash

set -euo pipefail

# This script is executed within the container as root.  It assumes
# that source code with debian packaging files can be found at
# /source-ro and that resulting packages are written to /output after
# successful build.  These directories are mounted as docker volumes to
# allow files to be exchanged between the host and the container.

CDEBB_DIR='/opt/cdebb'
CDEBB_BUILD_DIR="${CDEBB_DIR}/build"

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

CONTAINER_START_TIME="$EPOCHSECONDS"

# Remove directory owned by _apt
trap "rm -rf /var/cache/apt/archives/partial" EXIT

# force colors from dh and dpkg
export DH_COLORS="always"
export DPKG_COLORS="always"

log "Updating container"
apt-get update
apt-get upgrade -y --no-install-recommends

log "Checking for obsolete packages"
apt-mark minimize-manual -y
apt-get autoremove -y

log "Cleaning apt package cache"
apt-get autoclean

# Install extra dependencies that were provided for the build (if any)
#   Note: dpkg can fail due to dependencies, ignore errors, and use
#   apt-get to install those afterwards
if [ -d "${CDEBB_DIR}/dependencies" ]; then
    log "Installing extra dependencies"
    dpkg -i "${CDEBB_DIR}/dependencies"/*.deb || true
    apt-get -f install -y --no-install-recommends
fi

useradd --system --user-group --no-create-home --shell /usr/sbin/nologin build-runner

# Install ccache
if [ -n "${USE_CCACHE+x}" ]; then
    log "Setting up ccache"
    apt-get install -y --no-install-recommends ccache
    export CCACHE_DIR="${CDEBB_DIR}/ccache_dir"
    ccache --zero-stats
    chown -R --preserve-root build-runner: "${CDEBB_DIR}/ccache_dir"
fi

# Make read-write copy of source code
log "Copying source directory"
mkdir "${CDEBB_BUILD_DIR}"
cp -a "${CDEBB_DIR}/source-ro" "${CDEBB_BUILD_DIR}/source"
chown -R --preserve-root build-runner: "${CDEBB_BUILD_DIR}"

# Reset timestamps
if [ -n "${RESET_TIMESTAMPS+x}" ]; then
    log "Resetting timestamps"
    SOURCE_DATE_RFC2822=$(dpkg-parsechangelog --file "${CDEBB_BUILD_DIR}/source/debian/changelog" --show-field Date)
    find "${CDEBB_BUILD_DIR}/source" -exec touch -m --no-dereference --date="${SOURCE_DATE_RFC2822}" {} +;
fi

cd "${CDEBB_BUILD_DIR}/source"

# Install build dependencies
log "Installing build dependencies"
mk-build-deps -ir -t "apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends"

# Build packages
log "Building package with DEB_BUILD_OPTIONS set to '${DEB_BUILD_OPTIONS:-}'"
debuild_args=
# supported since Debian 11 (bullseye)
if dpkg-buildpackage --sanitize-env --help &> /dev/null; then
    debuild_args+=' --sanitize-env'
fi

BUILD_START_TIME="$EPOCHSECONDS"
# supported since Debian 12 (bookworm)
if unshare --map-users 1,1,1000 --help &> /dev/null; then
    # shellcheck disable=SC2086
    unshare --user --map-root-user --net --map-users 1,1,1000 --map-users 65534,65534,1 --map-groups 1,1,1000 --map-groups 65534,65534,1 --setuid "$(id -u build-runner)" --setgid "$(id -g build-runner)" -- env PATH="/usr/lib/ccache:$PATH" dpkg-buildpackage -rfakeroot -b --no-sign -sa ${debuild_args} 2>&1 | tee "${CDEBB_BUILD_DIR}/build.log"
else
    log "unshare(1) does not support --map-users, falling back to runuser(1); build has network access"
    # shellcheck disable=SC2086
    runuser -u build-runner -- env PATH="/usr/lib/ccache:$PATH" dpkg-buildpackage -rfakeroot -b --no-sign -sa ${debuild_args} 2>&1 | tee "${CDEBB_BUILD_DIR}/build.log"
fi
log "Build completed in $((EPOCHSECONDS - BUILD_START_TIME)) seconds"

cd /

if [ -n "${USE_CCACHE+x}" ]; then
    log "ccache statistics"
    # supported since Debian 12 (bookworm)
    if ccache --verbose --help &> /dev/null; then
        ccache --show-stats --verbose
    else
        ccache --show-stats
    fi
fi

# Run Lintian
if [ -n "${RUN_LINTIAN+x}" ]; then
    log "Installing Lintian"
    apt-get install -y --no-install-recommends lintian
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin lintian-runner
    log "+++ Lintian Report Start +++"
    # supported since Debian 11 (bullseye)
    if lintian --help | grep -w -- '--fail-on\b' &> /dev/null; then
        runuser -u lintian-runner -- lintian --display-experimental --info --display-info --pedantic --tag-display-limit 0 --color always --verbose --fail-on none "${CDEBB_BUILD_DIR}"/*.changes 2>&1 | tee "${CDEBB_BUILD_DIR}/lintian.log"
    else
        runuser -u lintian-runner -- lintian --display-experimental --info --display-info --pedantic --tag-display-limit 0 --color always --verbose "${CDEBB_BUILD_DIR}"/*.changes 2>&1 | tee "${CDEBB_BUILD_DIR}/lintian.log"
    fi
    log "+++ Lintian Report End +++"
fi

# Drop color escape sequences from logs
cd "${CDEBB_BUILD_DIR}"
sed -E -e 's/\x1b\[[0-9;]+[mK]//g' --in-place=.color -- *.log

# Run blhc
if [ -n "${RUN_BLHC+x}" ]; then
    log "Installing blhc"
    apt-get install -y --no-install-recommends blhc
    log "+++ blhc Report Start +++"
    blhc --all --color "${CDEBB_BUILD_DIR}/build.log" 2>&1 | tee "${CDEBB_BUILD_DIR}/blhc.log" || true
    log "+++ blhc Report End +++"
    sed -E -e 's/\x1b\[[0-9;]+[mK]//g' --in-place=.color "${CDEBB_BUILD_DIR}/blhc.log"
fi

# Copy packages to output dir with user's permissions
if [ -n "${USER+x}" ] && [ -n "${GROUP+x}" ]; then
    chown "${USER}:${GROUP}" -- *.deb *.buildinfo *.changes *.log *.log.color
else
    chown root:root -- *.deb *.buildinfo *.changes *.log *.log.color
fi
cp -a -- *.deb *.buildinfo *.changes *.log *.log.color "${CDEBB_DIR}/output/"

log "Generated files:"
ls -l --almost-all --color=always --human-readable --ignore={*.log,*.log.color} "${CDEBB_DIR}/output"

log "Finished in $((EPOCHSECONDS - CONTAINER_START_TIME)) seconds"
