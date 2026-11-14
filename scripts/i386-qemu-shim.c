/* SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
 *
 * i386-qemu-shim.c — LD_PRELOAD shim for Valve's 32-bit Steam libraries
 * (steamclient.so, SteamCMD) running under qemu-i386 user-mode emulation on
 * non-x86 hosts (Apple silicon). Built and loaded only by the emulated
 * launchers from scripts/i386-compat.sh; x86 images never contain it.
 *
 * It papers over two places where qemu-user differs from a real x86 kernel:
 *
 *  1. Robust futex lists. qemu-user does not implement set_robust_list /
 *     get_robust_list (ENOSYS), and steamclient.so aborts with
 *     "futex robust_list not initialized by pthreads" when its sanity check
 *     can't read one back. syscall(SYS_get_robust_list) is answered with a
 *     per-thread list head (an empty list, or the one the thread registered
 *     through syscall(SYS_set_robust_list)) shaped like glibc's own, with
 *     the same futex_offset. Nothing in the kernel walks it under emulation,
 *     so this only satisfies the check.
 *
 *  2. /proc/cpuinfo. Under qemu-user it still describes the host ARM CPU and
 *     SteamCMD exits(1) when it finds no x86 "flags" line. Opens of
 *     /proc/cpuinfo are redirected to $I386_FAKE_CPUINFO when that is set.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>

/* i386 syscall numbers (fixed ABI) */
#ifndef SYS_set_robust_list
#define SYS_set_robust_list 311
#endif
#ifndef SYS_get_robust_list
#define SYS_get_robust_list 312
#endif

struct robust_list {
    struct robust_list *next;
};

struct robust_list_head {
    struct robust_list list;
    long futex_offset;
    struct robust_list *list_op_pending;
};

static __thread struct robust_list_head empty_head;
static __thread void *registered_head;
static __thread size_t registered_len;

#define REAL(name) static __typeof__(name) *real_##name; \
    if (real_##name == NULL) real_##name = (__typeof__(name) *)dlsym(RTLD_NEXT, #name)

long syscall(long number, ...)
{
    va_list ap;
    long a[6];
    int i;
    REAL(syscall);

    va_start(ap, number);
    for (i = 0; i < 6; i++)
        a[i] = va_arg(ap, long);
    va_end(ap);

    if (number == SYS_set_robust_list) {
        registered_head = (void *)a[0];
        registered_len = (size_t)a[1];
        return 0;
    }
    if (number == SYS_get_robust_list) {
        void **head_ptr = (void **)a[1];
        size_t *len_ptr = (size_t *)a[2];

        if (head_ptr == NULL || len_ptr == NULL) {
            errno = EFAULT;
            return -1;
        }
        if (registered_head == NULL) {
            /* Same shape glibc gives each thread: an empty circular list and
             * the offset from a mutex's list node to its futex word. */
            empty_head.list.next = &empty_head.list;
            empty_head.futex_offset =
                (long)offsetof(pthread_mutex_t, __data.__lock) -
                (long)offsetof(pthread_mutex_t, __data.__list.__next);
            registered_head = &empty_head;
            registered_len = sizeof(empty_head);
        }
        *head_ptr = registered_head;
        *len_ptr = registered_len;
        return 0;
    }
    return real_syscall(number, a[0], a[1], a[2], a[3], a[4], a[5]);
}

static const char *redirect(const char *path)
{
    const char *fake;

    if (path == NULL || strcmp(path, "/proc/cpuinfo") != 0)
        return path;
    fake = getenv("I386_FAKE_CPUINFO");
    return (fake != NULL && *fake != '\0') ? fake : path;
}

static mode_t mode_arg(int flags, va_list ap)
{
    return (flags & (O_CREAT | O_TMPFILE)) ? (mode_t)va_arg(ap, int) : 0;
}

int open(const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode;
    REAL(open);
    va_start(ap, flags);
    mode = mode_arg(flags, ap);
    va_end(ap);
    return real_open(redirect(path), flags, mode);
}

int open64(const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode;
    REAL(open64);
    va_start(ap, flags);
    mode = mode_arg(flags, ap);
    va_end(ap);
    return real_open64(redirect(path), flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode;
    REAL(openat);
    va_start(ap, flags);
    mode = mode_arg(flags, ap);
    va_end(ap);
    return real_openat(dirfd, redirect(path), flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode;
    REAL(openat64);
    va_start(ap, flags);
    mode = mode_arg(flags, ap);
    va_end(ap);
    return real_openat64(dirfd, redirect(path), flags, mode);
}

FILE *fopen(const char *path, const char *mode)
{
    REAL(fopen);
    return real_fopen(redirect(path), mode);
}

FILE *fopen64(const char *path, const char *mode)
{
    REAL(fopen64);
    return real_fopen64(redirect(path), mode);
}
