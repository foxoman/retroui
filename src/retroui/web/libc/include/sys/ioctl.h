#ifndef _RL_SYS_IOCTL_H
#define _RL_SYS_IOCTL_H
#include "../_rl.h"
RL_BEGIN
#define FIONREAD 0x541B
#define FIONBIO 0x5421
#define FIONCLEX 0x5450
#define FIOCLEX 0x5451
#define TIOCGWINSZ 0x5413
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
int ioctl(int fd, unsigned long req, ...);
RL_END
#endif
