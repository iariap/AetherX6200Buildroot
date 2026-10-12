#!/bin/sh
#
# Strip what only the build needs from the target rootfs.
#
# The JS8 engine (js8core) is header-only as far as Boost goes, but Buildroot's
# boost package also installs its headers into the target: 172 MB of C++ headers
# that nothing on the radio ever reads. Drop the development headers.
#
# SPDX-License-Identifier: LGPL-2.1-or-later
#
set -e

TARGET_DIR="$1"

# C/C++ headers: build-time only
rm -rf "${TARGET_DIR}/usr/include"

# pkg-config files and static libraries are build-time only too
find "${TARGET_DIR}/usr/lib" -maxdepth 2 -name "*.la" -delete 2>/dev/null || true

exit 0
