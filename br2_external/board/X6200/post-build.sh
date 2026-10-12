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

# pulseaudio arranca en modo sistema (S50pulseaudio lo llama con --system) y en modo
# sistema necesita el usuario `pulse`: sin él el log dice "Failed to find user 'pulse'",
# el daemon no arranca y la GUI se quedaba esperando un contexto que nunca llegaba a
# READY (ver src/audio.c). Se crea acá, con un uid libre.
if ! grep -q '^pulse:' "${TARGET_DIR}/etc/passwd" 2>/dev/null; then
    PUID=1000
    while grep -q ":${PUID}:" "${TARGET_DIR}/etc/passwd" 2>/dev/null; do
        PUID=$((PUID + 1))
    done
    echo "pulse:x:${PUID}:${PUID}:PulseAudio system daemon:/var/run/pulse:/bin/false" >> "${TARGET_DIR}/etc/passwd"
    echo "pulse:x:${PUID}:" >> "${TARGET_DIR}/etc/group"
    if [ -f "${TARGET_DIR}/etc/shadow" ]; then
        echo "pulse:!:19000:0:99999:7:::" >> "${TARGET_DIR}/etc/shadow"
    fi
    echo "post-build: usuario pulse creado (uid ${PUID}) para el pulseaudio en modo sistema"
fi

exit 0
