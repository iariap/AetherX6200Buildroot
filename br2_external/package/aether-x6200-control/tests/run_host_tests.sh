#!/usr/bin/env bash
#
# Host tests for the RX framing decoder of src/low/flow.c
# (gdyuldin/X6200Control v0.1.1 + local SLIP patch for X6200 BASE 1.0.8).
#
# The script applies the package patch to a pristine v0.1.1 source tree,
# compiles the REAL patched flow.c together with fake open/read/termios
# shims (tests/flow_io_shim.h + tests/flow_test_io.c) and runs the host
# test binary.  No radio, UART, I2C, TX, PTT or ATU access happens.
#
# Usage:
#   tests/run_host_tests.sh [path-to-X6200Control-v0.1.1-checkout]
#
# The source tree can also be passed with AETHER_X6200_CONTROL_SRC.  When it
# is omitted, v0.1.1 is cloned from github.com/gdyuldin/X6200Control and the
# tag commit is verified (network required).
#
# Result: exit 0 = all checks passed; non-zero = test/build failure.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "$here/.." && pwd)"

expected_commit="0ee1ae3d4d9d74cbac7e349147ebc440eed8fad8"
patch_file="$(ls "$package_dir"/[0-9][0-9][0-9][0-9]-*.patch 2>/dev/null | head -n 1)"

if [ -z "${patch_file}" ]; then
    echo "FAIL: no 0001-*.patch found in $package_dir" >&2
    exit 1
fi

src="${1:-${AETHER_X6200_CONTROL_SRC:-}}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if [ -z "$src" ]; then
    echo "== cloning gdyuldin/X6200Control v0.1.1 =="
    git clone --quiet --branch v0.1.1 --depth 1 https://github.com/gdyuldin/X6200Control "$tmpdir/source"
    src="$tmpdir/source"
fi

if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    src_commit="$(git -C "$src" rev-parse HEAD)"
    echo "source: $src (git $src_commit)"
    if [ "$src_commit" != "$expected_commit" ]; then
        echo "WARNING: source commit is not v0.1.1 ($expected_commit); patch applicability is the real gate" >&2
    fi
    mkdir -p "$tmpdir/tree"
    git -C "$src" archive HEAD | tar -x -C "$tmpdir/tree"
else
    echo "source: $src (not a git checkout)"
    mkdir -p "$tmpdir/tree"
    cp -a "$src"/. "$tmpdir/tree"/
fi

tree="$tmpdir/tree"

echo "== applying $(basename "$patch_file") to pristine v0.1.1 =="
sha256sum "$patch_file"
patch -p1 -t -N --no-backup-if-mismatch -d "$tree" < "$patch_file"
echo "patched flow.c: $(sha256sum "$tree/src/low/flow.c" | cut -d' ' -f1)"

include_flags=(-I "$tree/include")

build_variant() {
    local name="$1"
    shift
    local cc="${CC_VARIANT:-gcc}"
    local outdir="$tmpdir/$name"
    mkdir -p "$outdir"

    echo ""
    echo "== building host tests ($name, $cc) =="
    "$cc" -c "$tree/src/low/flow.c" -o "$outdir/flow.o" \
        "${include_flags[@]}" -I "$here" \
        -include "$here/flow_io_shim.h" "$@"
    "$cc" -c "$here/flow_test_io.c" -o "$outdir/flow_test_io.o" \
        -I "$here" "$@"
    "$cc" -c "$here/flow_host_test.c" -o "$outdir/flow_host_test.o" \
        "${include_flags[@]}" -I "$here" "$@"
    "$cc" "$outdir/flow.o" "$outdir/flow_test_io.o" "$outdir/flow_host_test.o" \
        -o "$outdir/flow_host_test" "$@"

    echo "running $name tests"
    "$outdir/flow_host_test" "$here/fixtures"
    echo "exit code ($name): 0"
}

# Portable build: optimised, all warnings as errors.
build_variant release -O2 -g0 -Wall -Wextra -Werror

# Sanitised build: catches out-of-bounds/UB in the incremental parser.
# Pick an available compiler whose ASan/UBSan runtime actually works on this
# host (the distro gcc can ship a broken sanitizer runtime; probe it first).
san_cc=""
san_flags=(-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all)
cat > "$tmpdir/san_probe.c" <<'EOF'
int main(void) { int a[2] = {1, 2}; return a[0] + a[1] - 3; }
EOF
for candidate in clang-18 clang gcc; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
        continue
    fi
    if "$candidate" "${san_flags[@]}" "$tmpdir/san_probe.c" -o "$tmpdir/san_probe" >/dev/null 2>&1 &&
        "$tmpdir/san_probe" >/dev/null 2>&1; then
        san_cc="$candidate"
        break
    fi
done

if [ -n "$san_cc" ]; then
    echo ""
    echo "sanitizer compiler: $san_cc"
    CC_VARIANT="$san_cc" build_variant sanitized "${san_flags[@]}"
else
    echo "SANITIZERS_NOT_RUN: no compiler with a working ASan/UBSan runtime on this host" >&2
fi

echo ""
echo "HOST_TESTS_PASS"
