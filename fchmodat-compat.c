/* Vendor kernels that put a private syscall on 452 make fchmodat2 return
 * EFAULT, not ENOSYS, so glibc will not fall back. Emulate only that case.
 *
 * The real call runs first; its result is returned untouched unless it failed
 * with exactly EFAULT on a no-follow request. entrypoint.sh only preloads this
 * after a live tar probe proves the kernel is affected.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*fchmodat_fn)(int, const char *, mode_t, int);

int fchmodat(int dirfd, const char *path, mode_t mode, int flags)
{
    static fchmodat_fn real;
    int rc, saved;
    int entry_errno = errno;

    if (!real) {
        real = (fchmodat_fn) dlsym(RTLD_NEXT, "fchmodat");
        if (!real) {
            errno = ENOSYS;
            return -1;
        }
    }

    rc = real(dirfd, path, mode, flags);
    if (rc == 0 || errno != EFAULT || !(flags & AT_SYMLINK_NOFOLLOW))
        return rc;

    /* glibc 2.36's emulation. Pin the file with O_PATH|O_NOFOLLOW first so the
     * mode change cannot be redirected by a symlink swapped in underneath us —
     * the whole point of AT_SYMLINK_NOFOLLOW. */
    int fd = openat(dirfd, path, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return -1;

    struct stat st;
    if (fstat(fd, &st) < 0) {
        saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }

    /* Traditional chmod cannot change a symlink; return the pre-2.39
     * EOPNOTSUPP that GNU tar already ignores for SYMTYPE. */
    if (S_ISLNK(st.st_mode)) {
        close(fd);
        errno = EOPNOTSUPP;
        return -1;
    }

    char proc[64];
    snprintf(proc, sizeof proc, "/proc/self/fd/%d", fd);
    rc = chmod(proc, mode);
    saved = errno;
    close(fd);

    if (rc < 0) {
        /* glibc maps this case too: a missing /proc/self/fd/N means /proc is
         * not mounted, not that the file vanished. Passing ENOENT up would
         * hand tar a fatal error about a file that plainly exists, trading one
         * hard failure for a more confusing one; EOPNOTSUPP is the benign
         * answer it expects. */
        if (saved == ENOENT)
            saved = EOPNOTSUPP;
        errno = saved;
        return -1;
    }

    /* chmod/close leave errno unchanged on success; restore the caller's
     * value so the EFAULT from real() does not leak. */
    errno = entry_errno;
    return 0;
}
