#ifndef _RL_SETJMP_H
#define _RL_SETJMP_H
/* (no setjmp in WebAssembly without its exceptions: Nim's C here uses
   goto for its exceptions, and nothing else jumps) */
#include "_rl.h"
typedef long jmp_buf[8];
typedef long sigjmp_buf[8];
#endif
