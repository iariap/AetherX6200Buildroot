#!/usr/bin/env bash
#
# Cross-build gate for the patched gdyuldin/X6200Control v0.1.1 library.
#
# Builds the patched library AND the pristine v0.1.1 library with the real
# Buildroot ARM toolchain, then checks:
#   1. both outputs are 32-bit ARM EABI5 ELF shared objects
#   2. the exported dynamic symbol set is IDENTICAL (flow ABI unchanged:
#      x6200_flow_init/read/restart stay exported, no new exports)
#   3. the SONAME is unchanged (libaether_x6200_control.so.0)
#   4. the patched flow.c compiles warning-free with -Wall -Wextra -Werror
#      and even -Wcast-align=strict
#
# Usage:
#   tests/build_arm_library.sh <path-to-X6200Control-v0.1.1> <toolchainfile.cmake>
#
# Example:
#   tests/build_arm_library.sh /home/pablo/desa/x6200/refs/X6200Control \
#     /home/pablo/desa/x6200/rom-build/clone-buildroot/build/host/share/buildroot/toolchainfile.cmake
#
# The build output stays OUTSIDE the repository (mktemp directory) and is
# removed on exit.  No radio, UART, I2C, TX, PTT or ATU access happens.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "$here/.." && pwd)"

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <X6200Control-v0.1.1-source-dir> <buildroot-toolchainfile.cmake>" >&2
    exit 2
fi

src="$1"
toolchainfile="$2"
patch_file="$(ls "$package_dir"/[0-9][0-9][0-9][0-9]-*.patch 2>/dev/null | head -n 1)"

if [ ! -f "$toolchainfile" ]; then
    echo "FAIL: toolchain file not found: $toolchainfile" >&2
    exit 1
fi
if [ -z "$patch_file" ]; then
    echo "FAIL: no 0001-*.patch found in $package_dir" >&2
    exit 1
fi

host_dir="$(cd "$(dirname "$toolchainfile")/../.." && pwd)"
cc="$host_dir/bin/arm-buildroot-linux-gnueabihf-gcc"
nm="$host_dir/bin/arm-buildroot-linux-gnueabihf-nm"
readelf="$host_dir/bin/arm-buildroot-linux-gnueabihf-readelf"
for tool in "$cc" "$nm" "$readelf"; do
    if [ ! -x "$tool" ]; then
        echo "FAIL: missing Buildroot tool: $tool" >&2
        exit 1
    fi
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "toolchain compiler: $("$cc" --version | head -n 1)"
echo "patch: $(sha256sum "$patch_file" | cut -d' ' -f1)  $(basename "$patch_file")"

pristine="$tmpdir/pristine"
patched="$tmpdir/patched"
mkdir -p "$pristine"
git -C "$src" archive HEAD | tar -x -C "$pristine"
cp -a "$pristine/." "$patched/"
echo ""
echo "== applying local patch to v0.1.1 source =="
patch -p1 -t -N --no-backup-if-mismatch -d "$patched" < "$patch_file"
echo "patched flow.c sha256: $(sha256sum "$patched/src/low/flow.c" | cut -d' ' -f1)"

build_lib() {
    local name="$1"
    local tree="$2"

    cmake -S "$tree" -B "$tmpdir/$name-build" \
        -DCMAKE_TOOLCHAIN_FILE="$toolchainfile" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON > "$tmpdir/$name-configure.log" 2>&1
    cmake --build "$tmpdir/$name-build" -j"$(nproc)" > "$tmpdir/$name-build.log" 2>&1
    find "$tmpdir/$name-build" -name "libaether_x6200_control.so.0*" -type f | head -n 1
}

echo ""
echo "== building pristine v0.1.1 (reference ABI) =="
base_lib="$(build_lib base "$pristine")"
echo "== building patched v0.1.1 (subject) =="
patched_lib="$(build_lib patched "$patched")"

echo ""
echo "== artifact checks =="
file "$base_lib" "$patched_lib"
if ! file "$patched_lib" | grep -q 'ELF 32-bit LSB shared object, ARM, EABI5'; then
    echo "FAIL: patched library is not a 32-bit ARM EABI5 ELF shared object" >&2
    exit 1
fi

"$nm" -D --defined-only "$base_lib" | awk '{print $2, $3}' | sort > "$tmpdir/base.syms"
"$nm" -D --defined-only "$patched_lib" | awk '{print $2, $3}' | sort > "$tmpdir/patched.syms"

echo "exported dynamic symbols: base=$(wc -l < "$tmpdir/base.syms") patched=$(wc -l < "$tmpdir/patched.syms")"
if ! diff -u "$tmpdir/base.syms" "$tmpdir/patched.syms"; then
    echo "FAIL: exported dynamic symbol set changed" >&2
    exit 1
fi
echo "ABI_SYMBOLS_IDENTICAL"

base_soname="$("$readelf" -d "$base_lib" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
patched_soname="$("$readelf" -d "$patched_lib" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
echo "soname: base=$base_soname patched=$patched_soname"
if [ "$base_soname" != "$patched_soname" ]; then
    echo "FAIL: SONAME changed" >&2
    exit 1
fi
for required in x6200_flow_init x6200_flow_read x6200_flow_restart; do
    if ! grep -q "T $required\$" "$tmpdir/patched.syms"; then
        echo "FAIL: $required is not exported by the patched library" >&2
        exit 1
    fi
done
echo "FLOW_API_EXPORTED"

echo ""
echo "== warning-clean cross compile of the patched flow.c =="
"$cc" -c "$patched/src/low/flow.c" -I "$patched/include" -O3 \
    -Wall -Wextra -Werror -Wcast-align=strict -o "$tmpdir/flow_warncheck.o"
echo "WARN_CHECK_OK"

echo ""
echo "ARM_LIBRARY_PASS"
