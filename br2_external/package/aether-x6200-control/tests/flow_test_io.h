/*
 * Fake serial port used by the host tests of src/low/flow.c.
 */

#ifndef X6200_FLOW_TEST_IO_H
#define X6200_FLOW_TEST_IO_H

#include <stddef.h>
#include <stdint.h>

/* Drop queued bytes and reset the call counters (not the parser state). */
void flow_test_io_reset(void);

/* Queue wire bytes for the next read() calls. */
void flow_test_io_push(const uint8_t *bytes, size_t length);
void flow_test_io_push_byte(uint8_t byte);

/* Bytes still queued for the fake device. */
size_t flow_test_io_pending(void);

/* Open/close/termios instrumentation. */
int flow_test_io_open_count(void);
int flow_test_io_close_count(void);
int flow_test_io_speed(void);
const char *flow_test_io_open_path(void);
int flow_test_io_open_flags(void);

/* Allocation instrumentation: the RX parser must not allocate. */
int flow_test_io_malloc_calls(void);

#endif
