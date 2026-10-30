/*
 * Host tests for the RX framing decoder of src/low/flow.c.
 *
 * Target: X6200 BASE 1.0.8 (vendor APP 1.0.8) sends the 552-byte
 * x6200_flow_t payload wrapped in SLIP; BASE 1.0.6 and older sent it as a
 * RAW magic-prefixed 552-byte packet.  The real flow.c from gdyuldin/
 * X6200Control v0.1.1 (patched with the RX SLIP decoder) is compiled into
 * this test against fake open/read/termios shims, so the parser and both
 * transport paths are exercised for real.
 *
 * Fixtures: tests/fixtures/fixture2-{wire,payload}.hex are the synthetic
 * 552-byte flow-layout fixtures of iariap/x6200_gui#376 (PR #380), sha256
 * wire 025f34b9f894229d13cc8bac5c6737c2d4efa730aeaa04699c5e2c5708873853,
 * payload ad2db4be0a4e9b299db4840d2b4242efed35b881e1b6b8b6d8901c636d2b8593.
 * They are synthetic (not radio captures) and are used as transport bytes.
 *
 * No radio, UART, I2C, TX, PTT or ATU access happens here.
 */

#include "aether_radio/x6200_control/low/flow.h"
#include "flow_test_io.h"

#include <fcntl.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>

#define PACKET_SIZE ((size_t) sizeof(x6200_flow_t))
#define PACKET_WORDS (sizeof(x6200_flow_t) / sizeof(uint32_t))
#define CRC_WORDS (PACKET_WORDS - 1)
#define CRC_OFFSET offsetof(x6200_flow_t, crc)
#define HKEY_OFFSET offsetof(x6200_flow_t, hkey)
#define SAMPLES_OFFSET offsetof(x6200_flow_t, samples)

#define MAGIC 0xAA5555AAu
#define MAGIC_OTHER 0x5A1234C3u

#define SLIP_END 0xC0u
#define SLIP_ESC 0xDBu
#define SLIP_ESC_END 0xDCu
#define SLIP_ESC_ESC 0xDDu

#define WIRE_CAP (2 * PACKET_SIZE + 1)

/* Format of the fixed buffers used by the tests (aligned for calc_crc32). */
typedef union
{
    uint32_t words[PACKET_WORDS];
    uint8_t bytes[PACKET_SIZE];
} packet_buf_t;

extern uint32_t calc_crc32(const uint32_t *data, uint16_t len);

static int checks;
static int failures;

static void check_mem_eq(const void *expected, const void *actual, size_t length, const char *what, int line)
{
    checks++;
    if (memcmp(expected, actual, length) != 0) {
        size_t i;

        failures++;
        fprintf(stderr, "FAIL flow_host_test.c:%d: %s (%zu bytes) differ at:", line, what, length);
        for (i = 0; i < length; i++) {
            if (((const uint8_t *) expected)[i] != ((const uint8_t *) actual)[i]) {
                fprintf(stderr, " offset %zu expected 0x%02X got 0x%02X", i, ((const uint8_t *) expected)[i],
                        ((const uint8_t *) actual)[i]);
                break;
            }
        }
        fprintf(stderr, "\n");
    }
}

#define RUN(test)                                                                                                      \
    do {                                                                                                               \
        int before_ = failures;                                                                                        \
        printf("== %s\n", #test);                                                                                      \
        fflush(stdout);                                                                                                \
        test;                                                                                                          \
        printf("-- %s: %s\n", #test, failures == before_ ? "ok" : "FAIL");                                            \
        fflush(stdout);                                                                                                \
    } while (0)

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        checks++;                                                                                                      \
        if (!(cond)) {                                                                                                 \
            failures++;                                                                                                \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                            \
        }                                                                                                              \
    } while (0)

#define CHECK_MEM_EQ(expected, actual, length) check_mem_eq((expected), (actual), (length), #expected " == " #actual, __LINE__)

static uint32_t load_u32(const uint8_t *ptr)
{
    uint32_t value;

    memcpy(&value, ptr, sizeof(value));
    return value;
}

static void store_u32(uint8_t *ptr, uint32_t value)
{
    memcpy(ptr, &value, sizeof(value));
}

static void store_u32_at(uint8_t *base, size_t offset, uint32_t value)
{
    store_u32(base + offset, value);
}

static void update_crc(packet_buf_t *packet)
{
    uint32_t crc = calc_crc32((const uint32_t *) packet->words, (uint16_t) CRC_WORDS);

    store_u32(packet->bytes + CRC_OFFSET, crc);
}

/* Deterministic synthetic payload in the legacy x6200_flow_t layout.  The
 * filler contains 0xC0 and 0xDB bytes on purpose, so its SLIP wire uses both
 * escapes. */
static void fill_payload(packet_buf_t *packet, uint32_t magic, uint32_t hkey, unsigned seed)
{
    size_t i;

    for (i = 0; i < PACKET_SIZE; i++)
        packet->bytes[i] = (uint8_t) ((i * 37u + seed * 101u + 11u) & 0xFFu);

    store_u32_at(packet->bytes, 0, magic);

    packet->bytes[0x204] = 0x06; /* flags: synthetic bits */
    packet->bytes[0x205] = 0x00;
    packet->bytes[0x206] = 0x00;
    packet->bytes[0x207] = 0x00;
    packet->bytes[0x208] = 0xB0; /* dbm example */
    packet->bytes[0x209] = 0x05; /* tx_power */
    packet->bytes[0x20A] = 0x0C; /* vswr */
    packet->bytes[0x20B] = 0x03; /* alc */
    packet->bytes[0x20C] = 0x82; /* vext */
    packet->bytes[0x20D] = 0x7D; /* vbat */
    packet->bytes[0x20E] = 0x4D; /* batcap */
    packet->bytes[0x20F] = 0x00; /* reserved */
    store_u32(packet->bytes + 0x210, 0x000A0201u);
    store_u32(packet->bytes + 0x214, 0x11111111u);
    store_u32(packet->bytes + 0x218, 0x22222222u);
    store_u32(packet->bytes + 0x21C, 0x33333333u);
    store_u32(packet->bytes + HKEY_OFFSET, hkey);

    update_crc(packet);
}

/* Payload with a valid CRC and no 0xC0/0xDB byte anywhere: its SLIP wire is
 * byte-identical to the payload plus END, so it is also RAW-valid.  Used to
 * check the one-byte transport disambiguation after the first packet. */
static bool fill_unescaped_raw_valid(packet_buf_t *packet, uint32_t hkey, unsigned seed)
{
    unsigned attempt;

    for (attempt = 0; attempt < 64; attempt++) {
        size_t i;

        for (i = 0; i < PACKET_SIZE; i++)
            packet->bytes[i] = (uint8_t) ((i * 7u + (seed + attempt) * 31u) % 0xB0u);

        store_u32_at(packet->bytes, 0, MAGIC);
        packet->bytes[0x204] = 0x00;
        packet->bytes[0x205] = 0x00;
        packet->bytes[0x206] = 0x00;
        packet->bytes[0x207] = 0x00;
        packet->bytes[0x208] = 0x50;
        packet->bytes[0x209] = 0x05;
        packet->bytes[0x20A] = 0x0C;
        packet->bytes[0x20B] = 0x03;
        packet->bytes[0x20C] = 0x82;
        packet->bytes[0x20D] = 0x7D;
        packet->bytes[0x20E] = 0x4D;
        packet->bytes[0x20F] = 0x00;
        store_u32(packet->bytes + 0x210, 0x000A0201u);
        store_u32(packet->bytes + 0x214, 0x01020304u);
        store_u32(packet->bytes + 0x218, 0x0A0B0C0Du);
        store_u32(packet->bytes + 0x21C, 0x01010101u);
        store_u32(packet->bytes + HKEY_OFFSET, hkey);

        update_crc(packet);

        if (packet->bytes[CRC_OFFSET] != SLIP_END && packet->bytes[CRC_OFFSET] != SLIP_ESC &&
            packet->bytes[CRC_OFFSET + 1] != SLIP_END && packet->bytes[CRC_OFFSET + 1] != SLIP_ESC &&
            packet->bytes[CRC_OFFSET + 2] != SLIP_END && packet->bytes[CRC_OFFSET + 2] != SLIP_ESC &&
            packet->bytes[CRC_OFFSET + 3] != SLIP_END && packet->bytes[CRC_OFFSET + 3] != SLIP_ESC)
            return true;
    }
    return false;
}

static size_t slip_encode(const uint8_t *payload, size_t length, uint8_t *wire)
{
    size_t in;
    size_t out = 0;

    for (in = 0; in < length; in++) {
        if (payload[in] == SLIP_END) {
            wire[out++] = SLIP_ESC;
            wire[out++] = SLIP_ESC_END;
        } else if (payload[in] == SLIP_ESC) {
            wire[out++] = SLIP_ESC;
            wire[out++] = SLIP_ESC_ESC;
        } else {
            wire[out++] = payload[in];
        }
    }
    wire[out++] = SLIP_END;
    return out;
}

static size_t load_hex(const char *dir, const char *name, uint8_t *out, size_t capacity)
{
    char path[512];
    FILE *file;
    int high = -1;
    int chr;
    size_t length = 0;

    snprintf(path, sizeof(path), "%s/%s", dir, name);
    file = fopen(path, "r");
    if (file == NULL) {
        fprintf(stderr, "cannot open fixture %s\n", path);
        return 0;
    }

    while ((chr = fgetc(file)) != EOF) {
        int value;

        if (chr >= '0' && chr <= '9')
            value = chr - '0';
        else if (chr >= 'a' && chr <= 'f')
            value = chr - 'a' + 10;
        else if (chr >= 'A' && chr <= 'F')
            value = chr - 'A' + 10;
        else
            continue;

        if (high < 0) {
            high = value;
        } else {
            if (length >= capacity) {
                fprintf(stderr, "fixture %s does not fit in %zu bytes\n", path, capacity);
                fclose(file);
                return 0;
            }
            out[length++] = (uint8_t) ((high << 4) | value);
            high = -1;
        }
    }
    fclose(file);
    return length;
}

static void reset_case(void)
{
    flow_test_io_reset();
    CHECK(x6200_flow_restart());
}

static void packet_canary(x6200_flow_t *pack)
{
    memset((void *) pack, 0xA5, sizeof(*pack));
}

static bool packet_canary_ok(const x6200_flow_t *pack)
{
    const uint8_t *bytes = (const uint8_t *) pack;
    size_t i;

    for (i = 0; i < sizeof(*pack); i++) {
        if (bytes[i] != 0xA5)
            return false;
    }
    return true;
}

static bool read_frame(x6200_flow_t *pack)
{
    int tries;

    for (tries = 0; tries < 4; tries++) {
        if (x6200_flow_read(pack))
            return true;
    }
    return false;
}

static void expect_no_frame(x6200_flow_t *pack)
{
    packet_canary(pack);
    CHECK(!read_frame(pack));
    CHECK(packet_canary_ok(pack));
}

static void expect_frame(x6200_flow_t *pack, const packet_buf_t *expected)
{
    packet_canary(pack);
    CHECK(read_frame(pack));
    CHECK_MEM_EQ(expected->bytes, (const void *) pack, PACKET_SIZE);
}

/* --- Tests ------------------------------------------------------------------------------------------------------ */

static void test_device_parameters(void)
{
    flow_test_io_reset();

    CHECK(x6200_flow_init());
    CHECK(strcmp(flow_test_io_open_path(), "/dev/ttyS1") == 0);
    CHECK((flow_test_io_open_flags() & O_RDWR) == O_RDWR);
    CHECK((flow_test_io_open_flags() & O_NONBLOCK) == O_NONBLOCK);
    CHECK((flow_test_io_open_flags() & O_NOCTTY) == O_NOCTTY);
    CHECK(flow_test_io_speed() == (int) B1152000);
    CHECK(flow_test_io_malloc_calls() == 0);
}

static void test_slip_fixture2(const char *fixtures_dir)
{
    packet_buf_t payload;
    packet_buf_t expected;
    uint8_t wire[WIRE_CAP];
    size_t wire_length;
    size_t payload_length;
    x6200_flow_t pack;

    wire_length = load_hex(fixtures_dir, "fixture2-wire.hex", wire, sizeof(wire));
    payload_length = load_hex(fixtures_dir, "fixture2-payload.hex", payload.bytes, sizeof(payload.bytes));
    CHECK(wire_length == 558);
    CHECK(payload_length == PACKET_SIZE);
    CHECK(load_u32(payload.bytes) == MAGIC);

    reset_case();
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);
    CHECK(flow_test_io_malloc_calls() == 0);

    /* Consecutive equal frames must both be delivered. */
    reset_case();
    flow_test_io_push(wire, wire_length);
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);
    expect_frame(&pack, &payload);
    expect_no_frame(&pack);

    /* A second frame still parses after the first one (incremental state). */
    reset_case();
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);

    (void) expected;
}

static void test_slip_fixture1_escapes(const char *fixtures_dir)
{
    packet_buf_t expected;
    uint8_t f1_wire[32];
    uint8_t f1_payload[16];
    uint8_t wire[WIRE_CAP];
    size_t f1_wire_length;
    size_t f1_payload_length;
    size_t wire_length;
    size_t i;
    x6200_flow_t pack;

    /* #376 fixture 1: minimal escape coverage, payload 00 01 C0 02 DB 03 DB
     * C0 04.  Embed it at the beginning of a full 552-byte packet and check
     * that the SLIP wire prefix is exactly the fixture wire (escape rules
     * C0 -> DB DC and DB -> DB DD, single trailing END). */
    f1_wire_length = load_hex(fixtures_dir, "fixture1-wire.hex", f1_wire, sizeof(f1_wire));
    f1_payload_length = load_hex(fixtures_dir, "fixture1-payload.hex", f1_payload, sizeof(f1_payload));
    CHECK(f1_wire_length == 14);
    CHECK(f1_payload_length == 9);

    for (i = 0; i < PACKET_SIZE; i++)
        expected.bytes[i] = 0x11;
    memcpy(expected.bytes, f1_payload, f1_payload_length);
    update_crc(&expected);

    wire_length = slip_encode(expected.bytes, PACKET_SIZE, wire);
    CHECK(wire_length == f1_wire_length - 1 + (PACKET_SIZE - f1_payload_length) + 1);
    CHECK(memcmp(wire, f1_wire, f1_wire_length - 1) == 0);

    reset_case();
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &expected);
}

static void test_slip_552_without_magic(void)
{
    packet_buf_t payload;
    uint8_t wire[WIRE_CAP];
    size_t wire_length;
    x6200_flow_t pack;

    /* BASE 1.0.8 must not require the legacy magic: the vendor APP does not
     * compare it either.  The payload uses both SLIP escapes (filler). */
    fill_payload(&payload, MAGIC_OTHER, 0xC1, 3);
    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);

    CHECK(wire_length > PACKET_SIZE + 1);
    reset_case();
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);
    CHECK(load_u32(((const uint8_t *) &pack)) == MAGIC_OTHER);

    /* Payload must be emitted byte for byte, never rewritten. */
    CHECK_MEM_EQ(payload.bytes, (const void *) &pack, PACKET_SIZE);
}

static void test_slip_fragmented_byte_by_byte(void)
{
    packet_buf_t payload;
    uint8_t wire[WIRE_CAP];
    size_t wire_length;
    size_t i;
    int frames = 0;
    x6200_flow_t pack;

    fill_payload(&payload, MAGIC, 0x11223344u, 1);
    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);

    reset_case();
    for (i = 0; i < wire_length; i++) {
        flow_test_io_push_byte(wire[i]);
        if (x6200_flow_read(&pack)) {
            frames++;
            CHECK(i + 1 == wire_length);
        }
    }
    CHECK(frames == 1);
    CHECK_MEM_EQ(payload.bytes, (const void *) &pack, PACKET_SIZE);
}

static void test_slip_multiple_frames_per_read(void)
{
    packet_buf_t payload_a;
    packet_buf_t payload_b;
    uint8_t wire_a[WIRE_CAP];
    uint8_t wire_b[WIRE_CAP];
    size_t wire_length_a;
    size_t wire_length_b;
    x6200_flow_t pack;

    fill_payload(&payload_a, MAGIC, 0x11111111u, 2);
    fill_payload(&payload_b, MAGIC_OTHER, 0x22222222u, 5);
    wire_length_a = slip_encode(payload_a.bytes, PACKET_SIZE, wire_a);
    wire_length_b = slip_encode(payload_b.bytes, PACKET_SIZE, wire_b);

    reset_case();
    flow_test_io_push(wire_a, wire_length_a);
    flow_test_io_push(wire_b, wire_length_b);
    flow_test_io_push(wire_a, wire_length_a);

    expect_frame(&pack, &payload_a);
    expect_frame(&pack, &payload_b);
    expect_frame(&pack, &payload_a);
    expect_no_frame(&pack);
}

static void test_slip_empty_ends_and_delimiters(void)
{
    packet_buf_t payload;
    uint8_t wire[WIRE_CAP];
    size_t wire_length;
    x6200_flow_t pack;

    fill_payload(&payload, MAGIC, 0x01020304u, 7);
    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);

    reset_case();
    flow_test_io_push_byte(SLIP_END);
    flow_test_io_push_byte(SLIP_END);
    flow_test_io_push_byte(SLIP_END);
    expect_no_frame(&pack);

    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);

    flow_test_io_push_byte(SLIP_END);
    flow_test_io_push_byte(SLIP_END);
    expect_no_frame(&pack);

    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);
}

static void test_slip_bad_crc_rejected(void)
{
    packet_buf_t payload;
    packet_buf_t corrupt;
    uint8_t wire[WIRE_CAP];
    size_t wire_length;
    x6200_flow_t pack;

    fill_payload(&payload, MAGIC, 0x0BADF00Du, 9);
    corrupt = payload;
    corrupt.bytes[100] ^= 0x01; /* CRC field intentionally left untouched */
    wire_length = slip_encode(corrupt.bytes, PACKET_SIZE, wire);

    reset_case();
    flow_test_io_push(wire, wire_length);
    expect_no_frame(&pack);

    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);
}

static void test_slip_wrong_length_rejected(void)
{
    packet_buf_t payload;
    uint8_t wire[WIRE_CAP];
    uint8_t short_wire[2 * PACKET_SIZE + 2];
    size_t wire_length;
    size_t i;
    x6200_flow_t pack;

    fill_payload(&payload, MAGIC, 0x00C0DB00u, 11);

    reset_case();

    /* 551-byte decoded frame: one byte short. */
    wire_length = slip_encode(payload.bytes, PACKET_SIZE - 1, wire);
    flow_test_io_push(wire, wire_length);
    expect_no_frame(&pack);

    /* 553-byte decoded frame: one byte long, decoded limit exceeded. */
    short_wire[0] = 0x11;
    for (i = 1; i < 553; i++)
        short_wire[i] = (uint8_t) (i & 0x7Fu);
    short_wire[553] = SLIP_END;
    flow_test_io_push(short_wire, 554);
    expect_no_frame(&pack);

    /* After the rejected frames a valid one still parses. */
    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);
    flow_test_io_push(wire, wire_length);
    /* The previous 553-byte frame was discarded up to its END; the valid
     * frame follows it cleanly in the stream. */
    expect_frame(&pack, &payload);
}

static void test_slip_illegal_escape_rejected(void)
{
    packet_buf_t payload;
    uint8_t wire[WIRE_CAP];
    uint8_t bad_wire[WIRE_CAP + 4];
    size_t wire_length;
    x6200_flow_t pack;

    fill_payload(&payload, MAGIC, 0x12345678u, 13);
    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);

    /* Escape followed by a byte that is not END/ESC: discard up to END. */
    reset_case();
    memcpy(bad_wire, wire, 120);
    bad_wire[120] = SLIP_ESC;
    bad_wire[121] = 0x00;
    memcpy(bad_wire + 122, wire + 120, wire_length - 120);
    flow_test_io_push(bad_wire, wire_length + 2);
    expect_no_frame(&pack);
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);

    /* Orphan escape right before the END: the frame is discarded, too. */
    reset_case();
    memcpy(bad_wire, wire, wire_length - 1);
    bad_wire[wire_length - 1] = SLIP_ESC;
    bad_wire[wire_length] = SLIP_END;
    flow_test_io_push(bad_wire, wire_length + 1);
    expect_no_frame(&pack);
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);

    /* Escape before the END of an otherwise valid frame (DB DB is illegal
     * here, following the issue contract, not the vendor lax behaviour). */
    reset_case();
    memcpy(bad_wire, wire, 40);
    bad_wire[40] = SLIP_ESC;
    bad_wire[41] = SLIP_ESC;
    memcpy(bad_wire + 42, wire + 40, wire_length - 40);
    flow_test_io_push(bad_wire, wire_length + 2);
    expect_no_frame(&pack);
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);
}

static void test_slip_overflow_and_resync(void)
{
    packet_buf_t payload;
    uint8_t wire[WIRE_CAP];
    uint8_t noise[1200];
    size_t wire_length;
    size_t i;
    x6200_flow_t pack;

    fill_payload(&payload, MAGIC, 0xA1B2C3D4u, 17);
    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);

    /* A run of data with no END overflows the decoded limit and is dropped
     * up to the next END; the frame that END belongs to is lost (same as the
     * vendor APP, which also drops everything up to the first delimiter). */
    for (i = 0; i < sizeof(noise); i++)
        noise[i] = 0x11;
    reset_case();
    flow_test_io_push(noise, sizeof(noise));
    flow_test_io_push(wire, wire_length);
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &payload);
    expect_no_frame(&pack);
}

static void test_slip_lock_and_no_raw_after(void)
{
    packet_buf_t slip_payload;
    packet_buf_t raw_payload;
    uint8_t wire[WIRE_CAP];
    size_t wire_length;
    x6200_flow_t pack;

    fill_payload(&slip_payload, MAGIC, 0x55555555u, 19);
    wire_length = slip_encode(slip_payload.bytes, PACKET_SIZE, wire);

    reset_case();
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &slip_payload);

    /* Transport is fixed to SLIP: a RAW-framed 552-byte packet is not a
     * packet in this stream and must not be emitted. */
    CHECK(fill_unescaped_raw_valid(&raw_payload, 0x77777777u, 3));
    flow_test_io_push(raw_payload.bytes, PACKET_SIZE);
    expect_no_frame(&pack);

    /* The discarded 552-byte block leaves the SLIP decoder between frames;
     * the END of the next frame closes that discard (that frame is lost) and
     * the following SLIP frame parses normally. */
    flow_test_io_push(wire, wire_length);
    expect_no_frame(&pack);
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &slip_payload);
}

static void test_raw_legacy_552(void)
{
    packet_buf_t payload_a;
    packet_buf_t payload_b;
    uint8_t slip_wire[WIRE_CAP];
    size_t slip_wire_length;
    x6200_flow_t pack;

    CHECK(fill_unescaped_raw_valid(&payload_a, 0x11223344u, 5));
    CHECK(fill_unescaped_raw_valid(&payload_b, 0x55667788u, 9));

    reset_case();
    flow_test_io_push(payload_a.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload_a);

    /* The next byte after a RAW-valid frame is the next packet's magic, so
     * the transport is fixed to RAW from here on. */
    flow_test_io_push(payload_b.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload_b);

    /* A SLIP frame must not be accepted anymore. */
    fill_payload(&payload_a, MAGIC, 0x99999999u, 21);
    slip_wire_length = slip_encode(payload_a.bytes, PACKET_SIZE, slip_wire);
    flow_test_io_push(slip_wire, slip_wire_length);
    expect_no_frame(&pack);

    /* RAW keeps working. */
    flow_test_io_push(payload_b.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload_b);
}

static void test_raw_c0_does_not_select_slip(void)
{
    packet_buf_t payload;
    packet_buf_t slip_payload;
    uint8_t slip_wire[WIRE_CAP];
    size_t slip_wire_length;
    size_t i;
    int c0_bytes = 0;
    x6200_flow_t pack;

    /* RAW payload with 0xC0/0xDB bytes inside (samples include them). */
    fill_payload(&payload, MAGIC, 0x0F0E0D0Cu, 23);
    for (i = 0; i < PACKET_SIZE; i++) {
        if (payload.bytes[i] == SLIP_END || payload.bytes[i] == SLIP_ESC)
            c0_bytes++;
    }
    CHECK(c0_bytes > 0);

    reset_case();
    flow_test_io_push(payload.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload);

    flow_test_io_push(payload.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload);

    /* The stray END/ESC bytes inside the RAW stream must not lock SLIP. */
    fill_payload(&slip_payload, MAGIC, 0xCAFEBABEu, 25);
    slip_wire_length = slip_encode(slip_payload.bytes, PACKET_SIZE, slip_wire);
    flow_test_io_push(slip_wire, slip_wire_length);
    expect_no_frame(&pack);

    flow_test_io_push(payload.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload);
}

static void test_raw_prev_hkey_legacy(void)
{
    packet_buf_t payload_a;
    packet_buf_t payload_b;
    packet_buf_t payload_c;
    uint32_t hkey_b = 0x55667788u; /* hkey of the last accepted RAW packet */
    uint32_t hkey_c = 0x0A0B0C0Du; /* hkey of the packet with an old CRC */
    x6200_flow_t pack;

    /* Lock RAW with two valid packets. */
    CHECK(fill_unescaped_raw_valid(&payload_a, 0x11223344u, 11));
    CHECK(fill_unescaped_raw_valid(&payload_b, 0x55667788u, 13));

    reset_case();
    flow_test_io_push(payload_a.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload_a);
    flow_test_io_push(payload_b.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload_b);

    /* Third packet: the CRC was computed over the previous hkey (v0.1.1
     * legacy retry).  It must be accepted and the real hkey preserved. */
    fill_payload(&payload_c, MAGIC, hkey_c, 27);
    store_u32(payload_c.bytes + HKEY_OFFSET, hkey_b);
    update_crc(&payload_c); /* CRC over hkey_b */
    store_u32(payload_c.bytes + HKEY_OFFSET, hkey_c);

    flow_test_io_push(payload_c.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload_c);
    CHECK(pack.hkey == hkey_c);
}

static void test_raw_crc_corrupt_resync(void)
{
    packet_buf_t payload_bad;
    packet_buf_t payload_good;
    x6200_flow_t pack;

    CHECK(fill_unescaped_raw_valid(&payload_bad, 0x12341234u, 15));
    CHECK(fill_unescaped_raw_valid(&payload_good, 0x56785678u, 17));

    payload_bad.bytes[CRC_OFFSET + 3] ^= 0x80; /* corrupt CRC */

    reset_case();
    flow_test_io_push(payload_bad.bytes, PACKET_SIZE);
    expect_no_frame(&pack);
    flow_test_io_push(payload_good.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload_good);
}

static void test_ambiguous_first_frame_resolved_by_lookahead(void)
{
    packet_buf_t raw_valid;
    packet_buf_t slip_payload;
    uint8_t slip_wire[WIRE_CAP];
    size_t slip_wire_length;
    x6200_flow_t pack;

    CHECK(fill_unescaped_raw_valid(&raw_valid, 0x01020304u, 19));
    fill_payload(&slip_payload, MAGIC, 0xCAFED00Du, 29);
    slip_wire_length = slip_encode(slip_payload.bytes, PACKET_SIZE, slip_wire);

    /* The first SLIP frame has no escaped byte, so its wire bytes are a valid
     * RAW packet; its END is the next wire byte and selects SLIP. */
    reset_case();
    flow_test_io_push(raw_valid.bytes, PACKET_SIZE);
    flow_test_io_push_byte(SLIP_END);
    expect_frame(&pack, &raw_valid);

    flow_test_io_push(slip_wire, slip_wire_length);
    expect_frame(&pack, &slip_payload);

    /* Fixed to SLIP now: an unescaped RAW-looking 552-byte block is not a
     * packet on its own. */
    flow_test_io_push(raw_valid.bytes, PACKET_SIZE);
    expect_no_frame(&pack);
}

static void test_lone_c0_does_not_select_slip(void)
{
    packet_buf_t payload;
    uint8_t noise[200];
    size_t i;
    x6200_flow_t pack;

    CHECK(fill_unescaped_raw_valid(&payload, 0x0F1E2D3Cu, 21));

    reset_case();
    for (i = 0; i < sizeof(noise); i++) {
        noise[i] = (i % 2 == 0) ? (uint8_t) SLIP_END : 0x5A;
    }
    flow_test_io_push(noise, sizeof(noise));
    expect_no_frame(&pack);

    flow_test_io_push(payload.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload);
    flow_test_io_push(payload.bytes, PACKET_SIZE);
    expect_frame(&pack, &payload);
}

static void test_prefix_noise_then_slip(void)
{
    packet_buf_t payload;
    uint8_t wire[WIRE_CAP];
    uint8_t prefix[64];
    size_t wire_length;
    size_t i;
    x6200_flow_t pack;

    fill_payload(&payload, MAGIC, 0xFEEDFACEu, 31);
    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);

    for (i = 0; i < sizeof(prefix); i++)
        prefix[i] = (uint8_t) (0x20 + i);

    reset_case();
    flow_test_io_push(prefix, sizeof(prefix));
    flow_test_io_push(wire, wire_length);
    flow_test_io_push(wire, wire_length);

    /* The frame that follows the junk prefix is lost when the decoder
     * overflows and discards up to its END (the vendor APP behaves the same);
     * the next frame parses. */
    expect_frame(&pack, &payload);
    expect_no_frame(&pack);
}

static void test_no_false_tx_atu_packet(void)
{
    packet_buf_t payload;
    packet_buf_t corrupt;
    uint8_t wire[WIRE_CAP];
    size_t wire_length;
    size_t i;
    x6200_flow_t pack;

    fill_payload(&payload, MAGIC, 0xDEADBEEFu, 33);
    /* Raise TX and ATU flags, then corrupt the CRC: never emit them. */
    payload.bytes[0x204] |= 0x03;
    update_crc(&payload);
    corrupt = payload;
    corrupt.bytes[200] ^= 0x40;
    wire_length = slip_encode(corrupt.bytes, PACKET_SIZE, wire);

    reset_case();
    flow_test_io_push(wire, wire_length);
    expect_no_frame(&pack);

    /* Partial packet: not emitted either. */
    wire_length = slip_encode(payload.bytes, PACKET_SIZE, wire);
    for (i = 0; i < wire_length - 1; i++)
        flow_test_io_push_byte(wire[i]);
    expect_no_frame(&pack);

    /* Completing it delivers the valid packet with its flags unchanged. */
    flow_test_io_push_byte(wire[wire_length - 1]);
    expect_frame(&pack, &payload);
}

static void test_restart_resets_mode_and_buffers(void)
{
    packet_buf_t raw_a;
    packet_buf_t raw_b;
    packet_buf_t slip_payload;
    uint8_t wire[WIRE_CAP];
    size_t wire_length;
    size_t i;
    int opens;
    x6200_flow_t pack;

    CHECK(fill_unescaped_raw_valid(&raw_a, 0x11112222u, 23));
    CHECK(fill_unescaped_raw_valid(&raw_b, 0x33334444u, 25));
    fill_payload(&slip_payload, MAGIC, 0x55556666u, 35);
    wire_length = slip_encode(slip_payload.bytes, PACKET_SIZE, wire);

    /* Lock RAW, then restart: a SLIP stream must be accepted again. */
    reset_case();
    flow_test_io_push(raw_a.bytes, PACKET_SIZE);
    expect_frame(&pack, &raw_a);
    flow_test_io_push(raw_b.bytes, PACKET_SIZE);
    expect_frame(&pack, &raw_b);

    opens = flow_test_io_open_count();
    CHECK(x6200_flow_restart());
    CHECK(flow_test_io_open_count() == opens + 1);
    CHECK(flow_test_io_close_count() >= 1);

    flow_test_io_push(wire, wire_length);
    expect_frame(&pack, &slip_payload);

    /* Restart in the middle of a packet: buffers are reset, no partial frame
     * is emitted and a complete packet parses. */
    x6200_flow_t pack2;
    for (i = 0; i < wire_length / 2; i++)
        flow_test_io_push_byte(wire[i]);
    expect_no_frame(&pack2);
    CHECK(x6200_flow_restart());
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack2, &slip_payload);

    /* Lock SLIP, restart, then RAW works again. */
    CHECK(x6200_flow_restart());
    flow_test_io_push(wire, wire_length);
    expect_frame(&pack2, &slip_payload);
    CHECK(x6200_flow_restart());
    flow_test_io_push(raw_a.bytes, PACKET_SIZE);
    expect_frame(&pack2, &raw_a);
    flow_test_io_push(raw_b.bytes, PACKET_SIZE);
    expect_frame(&pack2, &raw_b);
}

static void test_no_data_no_packet(void)
{
    x6200_flow_t pack;

    reset_case();
    expect_no_frame(&pack);
    CHECK(flow_test_io_malloc_calls() == 0);
}

int main(int argc, char **argv)
{
    const char *fixtures_dir = (argc > 1) ? argv[1] : "fixtures";

    /* Legacy ABI contract must stay untouched. */
    _Static_assert(sizeof(x6200_flow_t) == 552, "x6200_flow_t ABI changed");
    _Static_assert(SAMPLES_OFFSET == 4, "samples offset changed");
    _Static_assert(HKEY_OFFSET == 544, "hkey offset changed");
    _Static_assert(CRC_OFFSET == 548, "crc offset changed");

    RUN(test_device_parameters());
    RUN(test_slip_fixture2(fixtures_dir));
    RUN(test_slip_fixture1_escapes(fixtures_dir));
    RUN(test_slip_552_without_magic());
    RUN(test_slip_fragmented_byte_by_byte());
    RUN(test_slip_multiple_frames_per_read());
    RUN(test_slip_empty_ends_and_delimiters());
    RUN(test_slip_bad_crc_rejected());
    RUN(test_slip_wrong_length_rejected());
    RUN(test_slip_illegal_escape_rejected());
    RUN(test_slip_overflow_and_resync());
    RUN(test_slip_lock_and_no_raw_after());
    RUN(test_raw_legacy_552());
    RUN(test_raw_c0_does_not_select_slip());
    RUN(test_raw_prev_hkey_legacy());
    RUN(test_raw_crc_corrupt_resync());
    RUN(test_ambiguous_first_frame_resolved_by_lookahead());
    RUN(test_lone_c0_does_not_select_slip());
    RUN(test_prefix_noise_then_slip());
    RUN(test_no_false_tx_atu_packet());
    RUN(test_restart_resets_mode_and_buffers());
    RUN(test_no_data_no_packet());

    printf("flow_host_test: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
