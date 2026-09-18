/* Windows 下 MBEDTLS_THREADING_ALT 的互斥量类型，存放一个 SRWLOCK（指针大小）。 */
#ifndef GIGACHAD_THREADING_ALT_H
#define GIGACHAD_THREADING_ALT_H
typedef struct mbedtls_threading_mutex_t {
    void *lock;
} mbedtls_threading_mutex_t;
#endif
