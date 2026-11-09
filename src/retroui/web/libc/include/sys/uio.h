#ifndef _RL_SYS_UIO_H
#define _RL_SYS_UIO_H
#include "../_rl.h"
#include <sys/types.h>
RL_BEGIN
struct iovec { void *iov_base; size_t iov_len; };
ssize_t readv(int fd, const struct iovec *v, int n);
ssize_t writev(int fd, const struct iovec *v, int n);
RL_END
#endif
