/*
 * no_openat2.c — make SYS_openat2 report ENOSYS.
 *
 * GNU tar >= 1.35 (Ubuntu 24.04) uses openat2(..., RESOLVE_BENEATH) for safe
 * extraction. glibc has no openat2() wrapper, so tar issues it through the
 * raw syscall() entry point. pseudo (Yocto's fakeroot) hooks libc functions
 * via LD_PRELOAD and therefore never sees the resulting directory fd, so the
 * following *at() call fails:
 *
 *     openat2(4, "usr/", {resolve=RESOLVE_BENEATH}) = 5
 *     mkdirat(5, NULL, 0700) = -1 EFAULT
 *     -> "got *at() syscall for unknown directory, fd 5"
 *     -> do_package fails in perform_packagecopy for every recipe
 *
 * Forcing ENOSYS makes tar fall back to plain openat(), which pseudo does
 * intercept. Everything else is passed through untouched.
 *
 * Built and injected by build.sh; see scripts/hosttools/ wrapper generation.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <sys/syscall.h>

long syscall(long number, ...)
{
    static long (*real_syscall)(long, ...);
    va_list ap;
    long a[6];
    int i;

    if (number == SYS_openat2) {
        errno = ENOSYS;
        return -1;
    }
    if (!real_syscall) {
        real_syscall = (long (*)(long, ...))dlsym(RTLD_NEXT, "syscall");
        if (!real_syscall) {
            errno = ENOSYS;
            return -1;
        }
    }
    va_start(ap, number);
    for (i = 0; i < 6; i++)
        a[i] = va_arg(ap, long);
    va_end(ap);
    return real_syscall(number, a[0], a[1], a[2], a[3], a[4], a[5]);
}
