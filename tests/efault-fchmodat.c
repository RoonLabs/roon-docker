/* Test stub: make fchmodat(..., AT_SYMLINK_NOFOLLOW) return EFAULT so
 * smoke.sh can exercise the compat shim on a healthy kernel. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>

int fchmodat(int dirfd, const char *path, mode_t mode, int flags)
{
    static int (*real)(int, const char *, mode_t, int);

    if (flags & AT_SYMLINK_NOFOLLOW) {
        errno = EFAULT;
        return -1;
    }
    if (!real) {
        real = (int (*)(int, const char *, mode_t, int)) dlsym(RTLD_NEXT, "fchmodat");
        if (!real) {
            errno = ENOSYS;
            return -1;
        }
    }
    return real(dirfd, path, mode, flags);
}
