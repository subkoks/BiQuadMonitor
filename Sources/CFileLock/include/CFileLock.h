#ifndef BIQUAD_FILE_LOCK_H
#define BIQUAD_FILE_LOCK_H
/* Returns zero on ownership, or the errno value. The caller owns the descriptor. */
int biquad_try_exclusive_lock(int descriptor);
#endif
