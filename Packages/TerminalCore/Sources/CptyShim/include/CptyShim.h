#ifndef DSH_PTY_SHIM_H
#define DSH_PTY_SHIM_H

#include <sys/types.h>

/* Swift 无法调用变参 ioctl，用 C shim 包一层 TIOCSWINSZ。 */
int dsh_set_winsize(int fd, unsigned short rows, unsigned short cols);

#endif
