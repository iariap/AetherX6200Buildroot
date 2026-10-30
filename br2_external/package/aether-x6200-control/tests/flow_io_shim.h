/*
 * Host-test shims for src/low/flow.c.
 *
 * The host tests compile the real v0.1.1 flow.c (patched with the RX SLIP
 * decoder) against these shims, so no bus, no /dev/ttyS1 and no real serial
 * port is touched:
 *
 *   gcc -c flow.c -include tests/flow_io_shim.h -I include ...
 *
 * The shim redirects open/read/close/tcgetattr/tcsetattr/cfsetispeed/
 * cfsetospeed/cfmakeraw/usleep plus malloc/realloc/free to fakes that are
 * implemented in flow_test_io.c and driven by flow_host_test.c.
 */

#ifndef X6200_FLOW_TEST_IO_SHIM_H
#define X6200_FLOW_TEST_IO_SHIM_H

/* flow.c defines this itself; keep the fake system headers GNU-compatible. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <fcntl.h>
#include <stdlib.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

#include "flow_test_io.h"

int flow_test_open(const char *path, int flags, ...);
int flow_test_close(int fd);
ssize_t flow_test_read(int fd, void *buf, size_t count);
int flow_test_usleep(useconds_t usec);
int flow_test_tcgetattr(int fd, struct termios *t);
int flow_test_tcsetattr(int fd, int optional_actions, const struct termios *t);
void flow_test_cfmakeraw(struct termios *t);
int flow_test_cfsetispeed(struct termios *t, speed_t speed);
int flow_test_cfsetospeed(struct termios *t, speed_t speed);
void *flow_test_malloc(size_t size);
void *flow_test_realloc(void *ptr, size_t size);
void flow_test_free(void *ptr);

#define open flow_test_open
#define close flow_test_close
#define read flow_test_read
#define usleep flow_test_usleep
#define tcgetattr flow_test_tcgetattr
#define tcsetattr flow_test_tcsetattr
#define cfmakeraw flow_test_cfmakeraw
#define cfsetispeed flow_test_cfsetispeed
#define cfsetospeed flow_test_cfsetospeed
#define malloc flow_test_malloc
#define realloc flow_test_realloc
#define free flow_test_free

#endif
