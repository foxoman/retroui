#ifndef _RL_STDIO_H
#define _RL_STDIO_H
#include "_rl.h"
#include <sys/types.h>
RL_BEGIN
typedef struct _RlFile FILE;
typedef long long fpos_t;
#define EOF (-1)
#define BUFSIZ 8192
#define FILENAME_MAX 4096
#define FOPEN_MAX 64
#define L_tmpnam 32
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2
extern FILE *const stdin;
extern FILE *const stdout;
extern FILE *const stderr;
FILE *fopen(const char *restrict p, const char *restrict m);
FILE *fdopen(int fd, const char *m);
FILE *freopen(const char *restrict p, const char *restrict m, FILE *restrict f);
int fclose(FILE *f);
int fflush(FILE *f);
size_t fread(void *restrict p, size_t s, size_t n, FILE *restrict f);
size_t fwrite(const void *restrict p, size_t s, size_t n, FILE *restrict f);
int fgetc(FILE *f);
int getc(FILE *f);
int getchar(void);
int ungetc(int c, FILE *f);
char *fgets(char *restrict s, int n, FILE *restrict f);
int fputc(int c, FILE *f);
int putc(int c, FILE *f);
int putchar(int c);
int fputs(const char *restrict s, FILE *restrict f);
int puts(const char *s);
int fseek(FILE *f, long off, int whence);
int fseeko(FILE *f, off_t off, int whence);
long ftell(FILE *f);
off_t ftello(FILE *f);
void rewind(FILE *f);
int fgetpos(FILE *restrict f, fpos_t *restrict p);
int fsetpos(FILE *f, const fpos_t *p);
int feof(FILE *f);
int ferror(FILE *f);
void clearerr(FILE *f);
int fileno(FILE *f);
int setvbuf(FILE *restrict f, char *restrict b, int mode, size_t n);
void setbuf(FILE *restrict f, char *restrict b);
int printf(const char *restrict fmt, ...);
int fprintf(FILE *restrict f, const char *restrict fmt, ...);
int sprintf(char *restrict s, const char *restrict fmt, ...);
int snprintf(char *restrict s, size_t n, const char *restrict fmt, ...);
int vprintf(const char *restrict fmt, va_list ap);
int vfprintf(FILE *restrict f, const char *restrict fmt, va_list ap);
int vsprintf(char *restrict s, const char *restrict fmt, va_list ap);
int vsnprintf(char *restrict s, size_t n, const char *restrict fmt, va_list ap);
int dprintf(int fd, const char *restrict fmt, ...);
int sscanf(const char *restrict s, const char *restrict fmt, ...);
int remove(const char *p);
int rename(const char *a, const char *b);
FILE *tmpfile(void);
char *tmpnam(char *s);
void perror(const char *s);
FILE *popen(const char *cmd, const char *mode);
int pclose(FILE *f);
ssize_t getline(char **restrict l, size_t *restrict n, FILE *restrict f);
ssize_t getdelim(char **restrict l, size_t *restrict n, int d, FILE *restrict f);
void flockfile(FILE *f);
void funlockfile(FILE *f);
int getc_unlocked(FILE *f);
int putc_unlocked(int c, FILE *f);
RL_END
#endif
