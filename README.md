# Creating Debian packages in container

## Overview

Container engines, in particular docker and podman, can be used for Debian
packaging. Building inside a container avoids installing build dependencies on
the host, ensures a clean and reproducible environment, and in case of podman
allows to perform the build as unprivileged user.

Fork of [docker-deb-builder](https://github.com/tsaarni/docker-deb-builder),
created by Tero Saarni.

## Create build environment

The build environment is setup in advance by creating a container image to
speed up builds. It only contains essential build dependencies, like gcc, thus
one can be used to build different Debian packages. For each distribution a
separate build environment needs to be created.

In this example the target is Ubuntu 22.04 and Debian sid, other distributions
can be created by their respective Dockerfile:

    docker build -t container-deb-builder:22.04 -f Dockerfile-ubuntu-22.04 .
    podman build -t container-deb-builder:sid -f Dockerfile-Debian-sid-unstable .

The image name (`container-deb-builder:22.04`) is later used while building a
Debian package.

## Building packages

First download or git clone the source code of the package to build:

    git clone ... ~/my-package-source

The source code should contain subdirectory called `debian` with at
least a minimum set of packaging files: `control`, `copyright`,
`changelog` and `rules`.

Run the build script to see its usage:

    $ ./build -h
    usage: build [options...] SOURCEDIR
    Options:
      -i IMAGE     Name of the docker image (including tag) to use as package build environment.
      -c PROGRAM   Use a custom container engine.
      -o DIR       Destination directory to store packages to.
      -d DIR       Directory that contains other deb packages that need to be installed before build.
      -p profiles  Specify the profiles to build (e.g. nocheck). Takes a comma separated list.
      -C           Use ccache to cache compiled objects.
      -L           Run Lintian after a successful build.
      -B           Run blhc after a successful build.
      -t           Reset file modification timestamps to changelog entry.

To build Debian packages run following commands:

    # create destination directory to store the build results
    mkdir output

    # build package from source directory
    ./build -i container-deb-builder:22.04 -o output ~/my-package-source

After a successful build the build results will be copied from the container
into the `output` directory. The container itself is discarded.

Sometimes builds might require dependencies that cannot be installed with
`apt-get build-dep`, e.g. when the required version of the dependency is not
yet available.  Those can be installed into the build environment by passing
the option `-d DIR`, where *DIR* is a directory with `*.deb` files in it.

    ./build -i container-deb-builder:22.04 -o output -d dependencies ~/my-package-source

### Native builds for foreign architectures

By default all packages are built for the architecture the host is running on.
Docker and Podman however support running containers under a foreign
architecture via QEMU. This emulation is quite slower than standard cross-
compiling but enables native builds, which for example includes running tests.

First install the required system packages:

    apt install binfmt-support qemu-user-static

Distinct images needs to be build for each architecture via the flag
`--platform`, e.g. for arm64:

    podman build -t container-deb-builder-arm64:sid -f Dockerfile-Debian-bookworm-12 --platform arm64 .

---
**Note**:

Podman remembers the last architecture used for a local image, so be sure to
specify the correct platform for further usage (especially if the name of the
image is used multiple times).

---

Building packages then works just by using the particular images.

## Maintenance

The data for apt archives and ccache is stored in volumes. These volumes have
the naming scheme `cdebb__${ImageName}__(apt|ccache)` and can be removed if
the respective image does no longer exists or the disk space is needed.
