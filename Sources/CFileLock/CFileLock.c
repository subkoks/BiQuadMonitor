#include "CFileLock.h"
#include <sys/file.h>
#include <errno.h>

int biquad_try_exclusive_lock(int descriptor) {
    return flock(descriptor, LOCK_EX | LOCK_NB) == 0 ? 0 : errno;
}
