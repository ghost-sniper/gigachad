/* 仅用于生成 Zig 绑定。Release 模式下 mingw 的 _FORTIFY_SOURCE 内联包装函数
   会让 translate-c 生成无法编译的代码，而绑定本身并不需要它们。 */
#undef _FORTIFY_SOURCE

#include <libssh2.h>
#include <libssh2_sftp.h>

/* src/c/mbedtls_threading.c：必须在 libssh2_init 之前调用。 */
void gigachad_mbedtls_threading_init(void);

/* src/c/ssh_socket.c */
int gigachad_net_init(void);
/* 成功返回 0 并写入 *out。 */
int gigachad_tcp_connect(const char *host, unsigned short port, libssh2_socket_t *out);
void gigachad_tcp_close(libssh2_socket_t sock);
