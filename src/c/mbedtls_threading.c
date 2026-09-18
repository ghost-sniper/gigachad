#include "mbedtls/threading.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static void mutex_init(mbedtls_threading_mutex_t *m)
{
    InitializeSRWLock((PSRWLOCK)&m->lock);
}

static void mutex_free(mbedtls_threading_mutex_t *m)
{
    (void)m;
}

static int mutex_lock(mbedtls_threading_mutex_t *m)
{
    AcquireSRWLockExclusive((PSRWLOCK)&m->lock);
    return 0;
}

static int mutex_unlock(mbedtls_threading_mutex_t *m)
{
    ReleaseSRWLockExclusive((PSRWLOCK)&m->lock);
    return 0;
}

void gigachad_mbedtls_threading_init(void)
{
    mbedtls_threading_set_alt(mutex_init, mutex_free, mutex_lock, mutex_unlock);
}
#else
/* POSIX 使用 mbedTLS 内置的 pthread 实现，无需额外设置。 */
void gigachad_mbedtls_threading_init(void)
{
}
#endif
