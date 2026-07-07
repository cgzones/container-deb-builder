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
    printf '%b[*] %s%b\n' "${Blue}" "$1" "${Reset}"
}

# Save a colored copy of each log file, then strip ANSI escapes from the original
function save_color_logs {
    local f
    for f in "$@"; do
        [ -f "$f" ] || continue
        cp "$f" "${f%.log}.color.log"
        sed -E -i 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$f"
    done
}

# Copy build artifacts and logs from the current directory to the output volume,
# owned by the invoking user when their UID/GID were passed in (Docker)
function copy_to_output {
    shopt -s nullglob
    local output_files=(*.deb *.buildinfo *.changes *.log)
    shopt -u nullglob

    [[ ${#output_files[@]} -eq 0 ]] && return 0

    if [ -n "${CDEBB_UID+x}" ] && [ -n "${CDEBB_GID+x}" ]; then
        chown "${CDEBB_UID}:${CDEBB_GID}" -- "${output_files[@]}"
    else
        chown root:root -- "${output_files[@]}"
    fi
    cp -a -- "${output_files[@]}" "${CDEBB_DIR}/output/"
}

CONTAINER_START_TIME="$EPOCHSECONDS"

# Remove directory owned by _apt
trap "rm -rf /var/cache/apt/archives/partial" EXIT

# enable colors from dh and dpkg when attached to a TTY
if [ -t 0 ] && [ -t 1 ]; then
    export DH_COLORS="always"
    export DPKG_COLORS="always"
fi

log "Updating container"
apt-get update
apt-get upgrade -y --no-install-recommends

log "Checking for obsolete packages"
apt-mark minimize-manual -y
apt-get autoremove -y

log "Cleaning apt package cache"
apt-get autoclean

# Install extra dependencies that were provided for the build (if any)
#   Note: dpkg can fail due to unmet dependencies, ignore that specific
#   error and use apt-get to resolve afterwards
if [ -d "${CDEBB_DIR}/dependencies" ]; then
    log "Installing extra dependencies"
    dpkg -i "${CDEBB_DIR}/dependencies"/*.deb || if [[ $? -ne 1 ]]; then exit 1; fi
    apt-get -f install -y --no-install-recommends
fi

useradd --system --user-group --no-create-home --shell /usr/sbin/nologin cdebb-build-runner

# Install ccache
if [ -n "${USE_CCACHE+x}" ]; then
    log "Setting up ccache"
    apt-get install -y --no-install-recommends ccache
    export CCACHE_DIR="${CDEBB_DIR}/ccache_dir"
    ccache --zero-stats
    chown -R cdebb-build-runner: "${CDEBB_DIR}/ccache_dir"
fi

# Make read-write copy of source code
log "Copying source directory"
mkdir "${CDEBB_BUILD_DIR}"
cp -a "${CDEBB_DIR}/source-ro" "${CDEBB_BUILD_DIR}/source"
chown -R cdebb-build-runner: "${CDEBB_BUILD_DIR}"

# Reset timestamps
if [ -n "${RESET_TIMESTAMPS+x}" ]; then
    log "Resetting timestamps"
    SOURCE_DATE_RFC2822=$(dpkg-parsechangelog --file "${CDEBB_BUILD_DIR}/source/debian/changelog" --show-field Date)
    find "${CDEBB_BUILD_DIR}/source" -exec touch -m --no-dereference --date="${SOURCE_DATE_RFC2822}" {} +
fi

cd "${CDEBB_BUILD_DIR}/source"

# Install build dependencies
log "Installing build dependencies"
mk-build-deps -ir -t "apt-get -o Debug::pkgProblemResolver=yes -y --no-install-recommends"

# Build packages
log "Building package (DEB_BUILD_PROFILES='${DEB_BUILD_PROFILES:-}', DEB_BUILD_OPTIONS='${DEB_BUILD_OPTIONS:-}')"
debuild_args=()
# supported since Debian 11 (bullseye)
if dpkg-buildpackage --help 2>&1 | grep -q -- '--sanitize-env'; then
    debuild_args+=(--sanitize-env)
fi

# Prepend ccache to PATH only when enabled
build_path="$PATH"
if [ -n "${USE_CCACHE+x}" ]; then
    build_path="/usr/lib/ccache:$PATH"
fi

# supported since Debian 12 (bookworm)
function run_build {
    if unshare --help 2>&1 | grep -q -- '--map-users'; then
        unshare --user --map-root-user --net --map-users 1,1,1000 --map-users 65534,65534,1 --map-groups 1,1,1000 --map-groups 65534,65534,1 --setuid "$(id -u cdebb-build-runner)" --setgid "$(id -g cdebb-build-runner)" -- env PATH="$build_path" dpkg-buildpackage -rfakeroot -b --no-sign "${debuild_args[@]}" 2>&1 | tee "${CDEBB_BUILD_DIR}/build.log"
    else
        log "unshare(1) does not support --map-users, falling back to runuser(1); build has network access"
        runuser -u cdebb-build-runner -- env PATH="$build_path" dpkg-buildpackage -rfakeroot -b --no-sign "${debuild_args[@]}" 2>&1 | tee "${CDEBB_BUILD_DIR}/build.log"
    fi
}

BUILD_START_TIME="$EPOCHSECONDS"
build_status=0
run_build || build_status=$?
log "Build finished in $((EPOCHSECONDS - BUILD_START_TIME)) seconds"

# On failure, salvage the build log to the output dir before aborting
if [[ $build_status -ne 0 ]]; then
    cd "${CDEBB_BUILD_DIR}"
    log "Build failed with exit status ${build_status}; copying logs to output"
    save_color_logs build.log
    copy_to_output
    exit "$build_status"
fi

cd /

if [ -n "${USE_CCACHE+x}" ]; then
    log "ccache statistics"
    # supported since Debian 12 (bookworm)
    if ccache --help 2>&1 | grep -q -- '--verbose'; then
        ccache --show-stats --verbose
    else
        ccache --show-stats
    fi
fi

# Run Lintian
if [ -n "${RUN_LINTIAN+x}" ]; then
    log "Installing Lintian"
    apt-get install -y --no-install-recommends lintian
    useradd --system --user-group --no-create-home --shell /usr/sbin/nologin cdebb-lintian-runner
    log "+++ Lintian Report Start +++"
    # supported since Debian 11 (bullseye)
    if lintian --help 2>&1 | grep -q -- '--fail-on'; then
        runuser -u cdebb-lintian-runner -- lintian --display-experimental --info --display-info --pedantic --tag-display-limit 0 --color always --verbose --fail-on none "${CDEBB_BUILD_DIR}"/*.changes 2>&1 | tee "${CDEBB_BUILD_DIR}/lintian.log"
    else
        runuser -u cdebb-lintian-runner -- lintian --display-experimental --info --display-info --pedantic --tag-display-limit 0 --color always --verbose "${CDEBB_BUILD_DIR}"/*.changes 2>&1 | tee "${CDEBB_BUILD_DIR}/lintian.log"
    fi
    log "+++ Lintian Report End +++"
fi

# Save colored versions of logs before stripping ANSI escape sequences
cd "${CDEBB_BUILD_DIR}"
save_color_logs ./*.log

# Run blhc
if [ -n "${RUN_BLHC+x}" ]; then
    log "Installing blhc"
    apt-get install -y --no-install-recommends blhc
    log "+++ blhc Report Start +++"
    blhc --all --color "${CDEBB_BUILD_DIR}/build.log" 2>&1 | tee "${CDEBB_BUILD_DIR}/blhc.log" || true
    log "+++ blhc Report End +++"
    save_color_logs "${CDEBB_BUILD_DIR}/blhc.log"
fi

# Copy packages and logs to output dir with user's permissions
copy_to_output

log "Generated files:"
ls -l --almost-all --color=always --human-readable --ignore=*.log "${CDEBB_DIR}/output"

log "Finished in $((EPOCHSECONDS - CONTAINER_START_TIME)) seconds"
