# RX framing patch and host tests for X6200 BASE 1.0.8

Local, reproducible patch on top of the Buildroot package source
`gdyuldin/X6200Control` **v0.1.1** (`0ee1ae3d4d9d74cbac7e349147ebc440eed8fad8`),
which is what `aether-x6200-control.mk` fetches. It adds the SLIP RX decoder
needed for the X6200 **BASE 1.0.8** uplink while keeping the 552-byte RAW
parser of the **X6200Control v0.1.1 contract**. It was prepared for
[`iariap/x6200_gui#377`](https://github.com/iariap/x6200_gui/issues/377)
(Epic [#374](https://github.com/iariap/x6200_gui/issues/374)); the wire
contract comes from the focused RE of
[#376](https://github.com/iariap/x6200_gui/issues/376) / PR
[#380](https://github.com/iariap/x6200_gui/pull/380).

The Buildroot package infrastructure applies every `*.patch` placed in this
package directory automatically (Buildroot 2023.02.11, `package/pkg-generic.mk`
`PATCH_BASE_DIRS = $(PKGDIR)`, `patch -g0 -p1 --no-backup-if-mismatch -t -N`).

## Scope and non-goals

- **RAW 552 B = X6200Control v0.1.1 contract** (`uint8_t samples[512]`,
  `sizeof(x6200_flow_t) == 552`). It is the parser this library keeps for the
  v0.1.1 ABI; it is **not** the wire format of the official BASE 1.0.6 APP.
- **SLIP 552 B = contract reconstructed for BASE 1.0.8** from the vendor APP
  1.0.8 static RE of `iariap/x6200_gui#376` / PR #380 over an
  `UNVERIFIED_VENDOR_PAYLOAD`. It is the target of the FAST-TRACK #377.
- **Physical backward compatibility with the official BASE 1.0.6 is
  `NOT_DEMONSTRATED` / `NOT_SUPPORTED` / `NOT_TESTED`.** The BASE 1.0.6 APP
  investigated by #376 consumed **2088-byte** RAW frames with
  `float samples[512]` (X6200Control v0.1.0 ABI, `sizeof == 2088`); supporting
  that would require the 2088-byte ABI and is **out of scope** for the
  FAST-TRACK #377. This patch does not implement it.
- The host tests labelled "RAW legacy" (`test_raw_legacy_552`,
  `test_raw_prev_hkey_legacy`) use **synthetic 552-byte v0.1.1 fixtures**,
  **not** captures from a BASE 1.0.6 radio.

## Patch

`0001-flow-support-SLIP-RX-framing-for-BASE-1.0.8.patch`

- SHA256 `bc64b21d2d489b2e5bf18437f2fd8b3c8e44874dcf8c1f049801ef778699ca68`
  (documentation-corrected version; the previous hash
  `46b4e7f36e25e3db6b53de057d037a11a72ee198fe5500f2ce126996e193838f`
  built the test image — see "Documentation correction" below).  The
  corrected patch differs from the original only in comments/context lines;
  its application produces `src/low/flow.c` sha256
  `182bf89b7113f929debfb79a69cb7b94df9f90d9ca306af3fb00ba07d8bd2061`.

- Only file changed: `src/low/flow.c`.
- Public header, `x6200_flow_t` layout, ABI (`x6200_flow_init`,
  `x6200_flow_read`, `x6200_flow_restart`), `/dev/ttyS1`, `B1152000`,
  termios flags, CRC table/algorithm and hkey handling are unchanged.
- No changes to `src/low/control.c`, `src/control.c`, I2C, TX, PTT or ATU.

Framing rules implemented (all with fixed buffers, no allocation, no busy
loops, no byte logging):

| Rule | Behaviour |
|---|---|
| SLIP END | `0xC0` closes the frame; an empty END is ignored |
| SLIP escapes | `DB DC` -> `C0`, `DB DD` -> `DB` |
| Illegal/orphan escape | frame discarded up to END, decoder resynchronises |
| Frame size | decoded length must be exactly `sizeof(x6200_flow_t)` = 552 bytes |
| CRC | strict vendor CRC32 over the first 548 bytes; a bad CRC rejects the frame and the payload is never modified to make it validate |
| Magic | SLIP path does **not** compare the magic field (same as the vendor APP 1.0.8) |
| Limits | decoded buffer `sizeof(x6200_flow_t)`, SLIP wire `2*sizeof+1` = 1105 bytes |
| Fragmentation | incremental byte parser, any split across `read()` calls |
| Multiple frames | several frames per `read()` are delivered one at a time, nothing lost |
| Noise / overflow | discarded up to END, next frame parses again |
| RAW 552 B (v0.1.1 contract) | magic `0xAA5555AA` + CRC, same parse as X6200Control v0.1.1 including the previous-hkey retry (kept RAW-only). **Not** the official BASE 1.0.6 2088-byte ABI; physical 1.0.6 compatibility is `NOT_DEMONSTRATED`/`NOT_SUPPORTED`/`NOT_TESTED` |
| Transport selection | fixed by the first complete validated frame (length + CRC, + magic for RAW) and reset by `x6200_flow_restart()`; a stray `C0` never selects SLIP |

One deliberate disambiguation: a first SLIP frame with **no** escaped byte is
byte-identical to a valid RAW packet. The frame is delivered once (both
decodings are the same 552 bytes) and the immediately following wire byte
(`0xC0` END for SLIP, next magic `0xAA...` for RAW) locks the transport. This
keeps BASE 1.0.8 from being mis-locked to RAW when its first frame happens to
carry no escaped byte (~1-2% of restarts) while never activating SLIP from a
lone `C0`.

## Host tests

```
tests/run_host_tests.sh [path-to-X6200Control-v0.1.1-checkout]
```

- Applies the patch to a pristine v0.1.1 tree (`git archive`; without an
  argument it clones the tag and verifies `0ee1ae3`) and compiles the **real**
  patched `src/low/flow.c` against fake `open`/`read`/`close`/termios/`usleep`
  shims (`flow_io_shim.h` + `flow_test_io.c`). No real serial port is opened.
- The parser is driven only through the public API with byte queues, so
  fragmentation, several frames per read, overflow and resync are
  deterministic.
- Two builds are run: optimised GCC `-O2 -Wall -Wextra -Werror`, and a
  sanitised build (ASan/UBSan) with the first compiler on the host whose
  sanitizer runtime works (here `clang-18`; the host GCC sanitizer runtime is
  broken). If no sanitizer runtime is available the script reports
  `SANITIZERS_NOT_RUN` instead of a fake pass.
- Covered: valid SLIP 552 B without magic, #376 fixture 2 (synthetic 552-byte
  flow-layout frame), #376 fixture 1 escape vectors, RAW 552 B under the
  X6200Control v0.1.1 contract (synthetic fixtures, **not** BASE 1.0.6
  captures), consecutive frames, byte-by-byte fragmentation, empty
  ENDs/delimiters, corrupted CRC (SLIP and RAW), wrong decoded length
  (551/553), illegal and orphan escapes, overflow + resync, prefix noise,
  v0.1.1 previous-hkey retry,
  transport lock (SLIP rejects RAW and vice versa), first-frame
  disambiguation, restart resetting buffers/mode, no partial packet and no
  false TX/ATU flags, no allocation during parsing, unchanged device
  parameters (`/dev/ttyS1`, `B1152000`, `O_RDWR|O_NONBLOCK|O_NOCTTY`).
- Fixtures under `tests/fixtures/` are the synthetic fixtures from
  `iariap/x6200_gui#376` / PR #380 (hex only, no vendor binaries). They are
  **not radio captures**:
  - `fixture2-wire.hex` (558 B) sha256
    `025f34b9f894229d13cc8bac5c6737c2d4efa730aeaa04699c5e2c5708873853`
  - `fixture2-payload.hex` (552 B) sha256
    `ad2db4be0a4e9b299db4840d2b4242efed35b881e1b6b8b6d8901c636d2b8593`
  - `fixture1-wire.hex` (14 B) / `fixture1-payload.hex` (9 B): minimal
    escape coverage.

## ARM cross-build / ABI gate

```
tests/build_arm_library.sh <path-to-X6200Control-v0.1.1> <buildroot-toolchainfile.cmake>
```

Builds the pristine and the patched library with the real Buildroot ARM
toolchain (`.../host/bin/arm-buildroot-linux-gnueabihf-gcc` via
`.../host/share/buildroot/toolchainfile.cmake`) in a temporary directory,
outside the repository, and fails unless:

- both outputs are 32-bit ARM EABI5 ELF shared objects;
- the exported dynamic symbol sets are identical (100 symbols, no new/removed
  exports, `x6200_flow_init/read/restart` still exported);
- the SONAME is unchanged (`libaether_x6200_control.so.0`);
- the patched `flow.c` compiles with `-O3 -Wall -Wextra -Werror
  -Wcast-align=strict`.

## Documentation correction (PR #14 review, 2026-10-30T15:37Z)

The coordinator review of PR #14 correctly noted that the first version of the
patch header wrongly stated that "BASE 1.0.6 and older send ... raw contiguous
552-byte packet". Only comments/documentation were corrected (the review asked
not to implement 2088 B and not to change the decoder). Evidence that the
executable code is identical:

| Check | Command | Result |
|---|---|---|
| Old/new patched source differ only in comments | `diff -u old/flow.c new/flow.c` | 37 changed lines, **all comments** (`ALL_CHANGED_LINES_ARE_COMMENTS`, exit 0) |
| Comments stripped, token stream identical | `gcc -E -P ...` both trees | both preprocessed outputs sha256 `29f2c1ff743f5406dfefb96e084eac96f801d20e8618687647286bb3e4b02c56` (`PREPROCESSED_IDENTICAL`) |
| ARM object identical | `arm-buildroot-linux-gnueabihf-gcc -c src/low/flow.c` with the Buildroot CMake CFLAGS (`-D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64 -O3 -g0 -D_FORTIFY_SOURCE=1 -DNDEBUG`) | both `flow.o` sha256 `a25bbd7119aa6a56156dd0bf51edba24904ea4530934e6a98c5d1df0d71c6600` (`OBJECTS_IDENTICAL`) |
| ARM disassembly identical | `arm-buildroot-linux-gnueabihf-objdump -d flow.o` (same object name) | `diff -u` **empty** (`DISASM_DIFF_EMPTY`), sha256 `01535514c898f732efe8d54b4b40e19f5742a2fa2a02d0691a4aa273aa32a5aa` |
| LTO library identical | `cmake ... -DCMAKE_TOOLCHAIN_FILE=<buildroot toolchainfile> -DBUILD_SHARED_LIBS=ON` for both trees | both `libaether_x6200_control.so.0.15.3` sha256 `f2eb4fb1b291c6dd76a0a46a5e326eefd9ad87fe46abe6fe0c1a373fc4dd1138` (`LTO_SO_IDENTICAL`) — **the same unstripped library that was built into the test image** |
| New patch applies to v0.1.1 | `git apply --check` and `patch -g0 -p1 --no-backup-if-mismatch -t -N` on pristine v0.1.1 | exit 0 both; patched `flow.c` sha256 `182bf89b7113f929debfb79a69cb7b94df9f90d9ca306af3fb00ba07d8bd2061` |

**The RX test image (`sdcard.img` sha256 `7ec5d8cc…b5d9`, built with the old
patch `46b4e7f3…`) remains valid without rebuilding:** its library
(`f2eb4fb1…` unstripped) is byte-identical to the one produced by this
documentation-only update, and the host parser tests stay `198 checks, 0
failures` (see below).

## Integration in the owner build tree

The build tree under `rom-build/clone-buildroot` is **not** touched by this
change. To rebuild after copying this package directory into the checkout used
for the image (owner/integration step, with the usual backup of local
modifications):

```sh
cd /home/pablo/desa/x6200/rom-build/clone-buildroot
git fetch origin main
git fetch origin feat/x6200-fw108-slip-compat
git checkout feat/x6200-fw108-slip-compat -- br2_external/package/aether-x6200-control/

cd build
make aether-x6200-control-dirclean    # drops any previous aether-x6200-control-v0.1.x source dir
make aether-x6200-control             # re-fetch v0.1.1, apply the patch, build+install to staging
# verify the patch was applied:
grep -c 'FLOW_MODE_SLIP' build/aether-x6200-control-v0.1.1/src/low/flow.c

make x6200-gui-dirclean               # force the GUI to rebuild against the new staging headers/library
make                                  # complete image
```

`X6200_GUI_VERSION` in `br2_external/package/x6200-gui/x6200_gui.mk` also has
to point at the GUI revision that carries the sample ABI fix for BASE 1.0.8
(GUI PR #381); that is the integration task's scope, not this patch.

## Constraints

No radio, UART, I2C, TX, PTT or ATU access is performed by the patch or by
these tests; no vendor binaries, captures or build artifacts are added to Git.
The only files in this directory are the patch, the tests and hex fixtures.
