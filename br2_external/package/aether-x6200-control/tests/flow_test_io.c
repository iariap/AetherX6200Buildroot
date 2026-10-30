/*
 * Fake serial port for the host tests of src/low/flow.c.
 *
 * The parser is driven exclusively through the public
 * x6200_flow_init()/x6200_flow_read()/x6200_flow_restart() API; no real
 * /dev/ttyS1, I2C, UART or bus is opened.  Bytes queued with
 * flow_test_io_push() are returned by the read() shim on demand, which is
 * how packet fragmentation, several packets per read and resynchronisation
 * after noise are exercised deterministically.
 */

#include "flow_test_io.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#define FLOW_TEST_QUEUE_SIZE (1u << 20)
#define FLOW_TEST_FAKE_FD 42

static uint8_t queue[FLOW_TEST_QUEUE_SIZE];
static size_t queue_head;
static size_t queue_tail;

static int open_count;
static int close_count;
static int speed;
static int open_flags;
static char open_path[128];
static int malloc_calls;

static int queue_used(void)
{
    return (int) (queue_tail - queue_head);
}

void flow_test_io_reset(void)
{
    queue_head = 0;
    queue_tail = 0;
    open_count = 0;
    close_count = 0;
    speed = 0;
    open_flags = 0;
    open_path[0] = '\0';
    malloc_calls = 0;
}

void flow_test_io_push(const uint8_t *bytes, size_t length)
{
    if (queue_tail + length > FLOW_TEST_QUEUE_SIZE) {
        fprintf(stderr, "flow_test_io: queue overflow\n");
        __builtin_trap();
    }
    memcpy(queue + queue_tail, bytes, length);
    queue_tail += length;
}

void flow_test_io_push_byte(uint8_t byte)
{
    flow_test_io_push(&byte, 1);
}

size_t flow_test_io_pending(void)
{
    return (size_t) queue_used();
}

int flow_test_io_open_count(void)
{
    return open_count;
}

int flow_test_io_close_count(void)
{
    return close_count;
}

int flow_test_io_speed(void)
{
    return speed;
}

const char *flow_test_io_open_path(void)
{
    return open_path;
}

int flow_test_io_open_flags(void)
{
    return open_flags;
}

int flow_test_io_malloc_calls(void)
{
    return malloc_calls;
}

int flow_test_open(const char *path, int flags, ...)
{
    open_count++;
    open_flags = flags;
    snprintf(open_path, sizeof(open_path), "%s", path);
    return FLOW_TEST_FAKE_FD;
}

int flow_test_close(int fd)
{
    (void) fd;
    close_count++;
    return 0;
}

ssize_t flow_test_read(int fd, void *buf, size_t count)
{
    size_t used;

    if (fd != FLOW_TEST_FAKE_FD) {
        errno = EBADF;
        return -1;
    }

    used = (size_t) queue_used();
    if (used == 0) {
        /* Same as a non-blocking tty with no data available. */
        errno = EAGAIN;
        return -1;
    }

    if (count > used)
        count = used;

    memcpy(buf, queue + queue_head, count);
    queue_head += count;

    return (ssize_t) count;
}

int flow_test_usleep(useconds_t usec)
{
    (void) usec;
    return 0;
}

int flow_test_tcgetattr(int fd, struct termios *t)
{
    (void) fd;
    memset(t, 0, sizeof(*t));
    return 0;
}

int flow_test_tcsetattr(int fd, int optional_actions, const struct termios *t)
{
    (void) fd;
    (void) optional_actions;
    (void) t;
    return 0;
}

void flow_test_cfmakeraw(struct termios *t)
{
    (void) t;
}

int flow_test_cfsetispeed(struct termios *t, speed_t value)
{
    (void) t;
    speed = (int) value;
    return 0;
}

int flow_test_cfsetospeed(struct termios *t, speed_t value)
{
    (void) t;
    speed = (int) value;
    return 0;
}

void *flow_test_malloc(size_t size)
{
    (void) size;
    malloc_calls++;
    return NULL;
}

void *flow_test_realloc(void *ptr, size_t size)
{
    (void) ptr;
    (void) size;
    malloc_calls++;
    return NULL;
}

void flow_test_free(void *ptr)
{
    (void) ptr;
}
