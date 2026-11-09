#ifndef _RL_TERMIOS_H
#define _RL_TERMIOS_H
#include "_rl.h"
RL_BEGIN
typedef unsigned char cc_t;
typedef unsigned int speed_t, tcflag_t;
#define NCCS 32
struct termios { tcflag_t c_iflag, c_oflag, c_cflag, c_lflag; cc_t c_line; cc_t c_cc[NCCS]; speed_t c_ispeed, c_ospeed; };
#define TCSANOW 0
#define TCSADRAIN 1
#define TCSAFLUSH 2
#define ECHO 0000010
#define ICANON 0000002
#define ISIG 0000001
#define IEXTEN 0100000
#define VMIN 6
#define VTIME 5
int tcgetattr(int fd, struct termios *t);
int tcsetattr(int fd, int a, const struct termios *t);
RL_END
#endif
