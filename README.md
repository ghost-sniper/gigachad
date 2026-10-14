# gigachad

跨平台终端下载器，支持 HTTP(S)、FTP、SFTP。同一个文件可以用多个连接分段并发下载。

- **分段并发**：按连接数把文件切成若干段，每段一个连接；小文件自动少开连接（每段默认至少 1 MiB，可用 `-k` 调整）。
- **断点续传**：下载中保存 `<文件>.part` 和进度文件 `<文件>.gigachad`（每秒更新）。中断后再次运行同一命令，会从已完成处继续。
- **失败重试**：单个分段失败后按指数退避重试（0.5s → 30s）。只要有进展就重新计数，不影响其他分段。
- **批量下载**：可以传入多个 URL，或用 `-i` 从文件读取。
- **认证**：FTP/SFTP 支持 URL 中的 `user:pass`；FTP 默认匿名登录。SFTP 支持 ssh-agent、私钥文件（`--identity`）、密码和 keyboard-interactive，并按 `~/.ssh/known_hosts` 校验主机密钥。
- **代理**：HTTP(S) 遵循 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 和 `NO_PROXY`。

## 构建

需要 Zig 0.17.0。libssh2 和 mbedTLS 在构建时从源码静态编译，不依赖系统库。

```bash
zig build -Doptimize=safe
```

交叉编译：

```bash
zig build -Doptimize=safe -Dtarget=x86_64-linux-musl
zig build -Doptimize=safe -Dtarget=aarch64-macos
```

验证构建和测试：`zig build`、`zig build test`。

## 用法

```
gigachad [选项] <URL>...

  -c, --connections <N>   每个文件的并发连接数（默认 8，范围 1-64）
  -o, --output <FILE>     输出文件名（仅限单个 URL）
  -d, --dir <DIR>         保存目录
  -i, --input-file <FILE> 从文件读取 URL，每行一个，'#' 开头为注释
  -k, --min-split <SIZE>  每个分段的最小大小，支持 K/M/G 后缀（默认 1M）
      --retries <N>       每个分段连续失败的重试次数（默认 5）
      --password <PASS>   FTP/SFTP 密码
      --identity <FILE>   SFTP 私钥文件
      --passphrase <PASS> 私钥口令
      --no-resume         忽略已有的续传进度
  -f, --force             覆盖已存在的文件
  -q, --quiet             不显示进度
```

示例：

```bash
gigachad -c 16 https://example.com/big.iso
gigachad ftp://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz
gigachad sftp://user@host/~/data/file.bin          # /~/ 表示用户主目录
gigachad --identity ~/.ssh/id_rsa sftp://user@host/srv/file.bin
gigachad -d downloads -i urls.txt
```

## 实现说明

| 协议 | 实现 | 分段方式 |
| --- | --- | --- |
| HTTP/HTTPS | `std.http.Client`（修补版，见下） | `Range: bytes=a-b`；先用 `bytes=0-0` 探测大小和是否支持 Range |
| FTP | `src/proto/ftp.zig`，被动模式（EPSV/PASV） | 每段一个控制连接，`REST` + `RETR`，读够即断开 |
| SFTP | libssh2 + mbedTLS | 每段一个 SSH 会话，`sftp_seek64` 后读取 |

服务器不支持分段时（没有 Range 支持或大小未知），自动退化为单连接下载。

需要注意的几点：

- `src/http/Client.zig` 基于 Zig 0.16.0 `std.http.Client`，已适配 Zig 0.17.0。它修复了经 HTTP 代理访问 HTTPS 时不在 CONNECT 隧道内建立 TLS 的问题；0.17.0 上游仍未修复，因此保留此副本。
- 所有平台都使用 mbedTLS 作为 libssh2 的加密后端，并开启 mbedTLS 的线程锁，因为并发的 SSH 会话共享同一个随机数生成器。这个后端不支持 ed25519 密钥，SFTP 公钥认证请使用 RSA 或 ECDSA 密钥，或者通过 ssh-agent。
- 在 Windows 上，Zig 0.16 的 `std.Io` 通过 AFD 直接创建套接字，libssh2 无法使用这种句柄。所以 SFTP 连接由 `src/c/ssh_socket.c` 用标准 socket API 建立。
