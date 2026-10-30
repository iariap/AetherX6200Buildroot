# RX framing patch and host tests for X6200 BASE 1.0.8

Local, reproducible patch on top of the Buildroot package source
`gdyuldin/X6200Control` **v0.1.1** (`0ee1ae3d4d9d74cbac7e349147ebc440eed8fad8`),
which is what `aether-x6200-control.mk` fetches. It adds the SLIP RX decoder
needed for the X6200 **BASE 1.0.8** uplink while keeping the legacy RAW path
used by BASE 1.0.6 and older. It was prepared for
[`iariap/x6200_gui#377`](https://github.com/iariap/x6200_gui/issues/377)
(Epic [#374](https://github.com/iariap/x6200_gui/issues/374)); the wire
contract comes from the focused RE of
[#376](https://github.com/iariap/x6200_gui/issues/376) / PR
[#380](https://github.com/iariap/x6200_gui/pull/380).

The Buildroot package infrastructure applies every `*.patch` placed in this
package directory automatically (Buildroot 2023.02.11, `package/pkg-generic.mk`
`PATCH_BASE_DIRS = $(PKGDIR)`, `patch -g0 -p1 --no-backup-if-mismatch -t -N`).

## Patch

`0001-flow-support-SLIP-RX-framing-for-BASE-1.0.8.patch`

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
| RAW legacy | magic `0xAA5555AA` + CRC, same parse as v0.1.1 including the previous-hkey retry (kept RAW-only) |
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
  flow-layout frame), #376 fixture 1 escape vectors, RAW legacy 552 B,
  consecutive frames, byte-by-byte fragmentation, empty ENDs/delimiters,
  corrupted CRC (SLIP and RAW), wrong decoded length (551/553), illegal and
  orphan escapes, overflow + resync, prefix noise, prev-hkey legacy retry,
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
