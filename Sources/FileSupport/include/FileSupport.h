#ifndef FILE_SUPPORT_H
#define FILE_SUPPORT_H
#include <sys/types.h>
int he_open_parent(const char *absolute_path);
int he_copy_metadata(int source, int destination);
#endif
