/* Retro's own C library for WebAssembly: what Nim's C and the toolkit
   need, on the browser (retro.js) underneath. Not a full libc -- what is
   here works, what is not here is not used. */
#ifndef _RL_H
#define _RL_H
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#define RL_IMPORT(name) __attribute__((import_module("env"), import_name(#name)))
#ifdef __cplusplus
#define RL_BEGIN extern "C" {
#define RL_END }
#else
#define RL_BEGIN
#define RL_END
#endif
#endif
