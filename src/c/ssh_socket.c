/*
 * 为 libssh2 建立原生 TCP 连接。
 *
 * Zig 0.16 的 std.Io 在 Windows 上直接通过 AFD 创建套接字，libssh2 内部的
 * Winsock 调用无法使用这种句柄，所以 SFTP 连接在这里用 getaddrinfo/connect
 * 建立，Windows 和 POSIX 共用一份代码。
 */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#endif
#include <stdio.h>
#include <string.h>
#include <libssh2.h>

int gigachad_net_init(void)
{
#ifdef _WIN32
    WSADATA data;
    return WSAStartup(MAKEWORD(2, 2), &data);
#else
    return 0;
#endif
}

int gigachad_tcp_connect(const char *host, unsigned short port, libssh2_socket_t *out)
{
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    struct addrinfo *ai;
    char port_str[8];
    libssh2_socket_t sock = LIBSSH2_INVALID_SOCKET;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    snprintf(port_str, sizeof(port_str), "%u", (unsigned)port);

    if(getaddrinfo(host, port_str, &hints, &res) != 0)
        return -1;

    for(ai = res; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if(sock == LIBSSH2_INVALID_SOCKET)
            continue;
        if(connect(sock, ai->ai_addr, (int)ai->ai_addrlen) == 0)
            break;
#ifdef _WIN32
        closesocket(sock);
#else
        close(sock);
#endif
        sock = LIBSSH2_INVALID_SOCKET;
    }
    freeaddrinfo(res);
    if(sock == LIBSSH2_INVALID_SOCKET)
        return -2;
    *out = sock;
    return 0;
}

void gigachad_tcp_close(libssh2_socket_t sock)
{
    if(sock == LIBSSH2_INVALID_SOCKET)
        return;
#ifdef _WIN32
    closesocket(sock);
#else
    close(sock);
#endif
}
