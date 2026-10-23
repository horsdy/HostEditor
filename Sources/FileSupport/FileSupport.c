#include "FileSupport.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <copyfile.h>

// Walk from the root using descriptors; never follow a changed directory symlink.
int he_open_parent(const char *path) {
    if (!path || path[0] != '/') { errno = EINVAL; return -1; }
    char *copy = strdup(path);
    if (!copy) return -1;
    char *last = strrchr(copy, '/');
    *last = '\0';
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    char *state = NULL;
    for (char *p = strtok_r(copy, "/", &state); p && fd >= 0; p = strtok_r(NULL, "/", &state)) {
        if (!strcmp(p, ".") || !strcmp(p, "..")) { close(fd); fd = -1; errno = EINVAL; break; }
        int next = openat(fd, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int saved = errno;
        close(fd); fd = next; errno = saved;
    }
    free(copy);
    return fd;
}

int he_copy_metadata(int source, int destination) {
    struct stat s;
    if (fstat(source, &s)) return -1;
    if (fchown(destination, s.st_uid, s.st_gid)) {
        struct stat d;
        if (fstat(destination, &d) || d.st_uid != s.st_uid || d.st_gid != s.st_gid) return -1;
    }
    if (fcopyfile(source, destination, NULL, COPYFILE_ACL | COPYFILE_XATTR)) return -1;
    return fchmod(destination, s.st_mode & 07777);
}
