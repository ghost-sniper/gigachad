/* 并发 SFTP 会话共享 libssh2 的全局 CTR-DRBG，必须开启 mbedTLS 的线程锁。 */
#define MBEDTLS_THREADING_C
#if defined(_WIN32)
#define MBEDTLS_THREADING_ALT
#else
#define MBEDTLS_THREADING_PTHREAD
#endif
