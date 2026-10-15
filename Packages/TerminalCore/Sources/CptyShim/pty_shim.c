#include "CptyShim.h"
#include <sys/ioctl.h>

int dsh_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize w;
    w.ws_row = rows;
    w.ws_col = cols;
    w.ws_xpixel = 0;
    w.ws_ypixel = 0;
    return ioctl(fd, TIOCSWINSZ, &w);
}
