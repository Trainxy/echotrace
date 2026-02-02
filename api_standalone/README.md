# EchoTrace Standalone API Server

独立的 API 服务器，不依赖 Flutter 框架，可单独编译和部署。

## 前置要求

- Dart SDK 3.0+
- 已解密的微信数据库目录

## 快速开始

### 1. 安装依赖

```bash
cd api_standalone
dart pub get
```

### 2. 直接运行

```bash
dart run api_server.dart -d "C:\WeChatData\decrypted" -k your-secret-key
```

### 3. 编译为可执行文件

使用 `dart build cli` 命令（推荐，支持原生库）：

**Windows (PowerShell):**
```powershell
cd api_standalone
dart pub get
dart build cli

# 编译后的可执行文件位于:
# build\cli\windows_x64\bundle\bin\api_server.exe
```

**Linux/macOS:**
```bash
cd api_standalone
dart pub get
dart build cli

# 编译后的可执行文件位于:
# build/cli/{platform}/bundle/bin/api_server
```

> 注意: `dart build cli` 会自动处理原生库依赖（如 SQLite），生成的 bundle 包含所有必需的运行时文件。

### 4. 部署运行

```bash
# Windows
.\api_server.exe -d "C:\WeChatData\decrypted" -k your-secret-key -p 8080

# Linux
./api_server -d /data/wechat/decrypted -k your-secret-key -p 8080
```

## 命令行参数

| 参数 | 简写 | 必须 | 默认值 | 说明 |
|------|------|------|--------|------|
| `--db-path` | `-d` | 是 | - | 解密后的微信数据库目录 |
| `--auth-key` | `-k` | 是 | - | API 验证密钥 |
| `--port` | `-p` | 否 | 8080 | API 端口 |
| `--refresh-interval` | `-r` | 否 | 300 | 通讯录刷新间隔(秒) |
| `--help` | `-h` | 否 | - | 显示帮助 |

## API 端点

- `GET /api/contacts` - 获取通讯录
- `GET /api/messages/{wxid}` - 获取聊天记录
- `GET /api/status` - 服务状态
- `POST /api/contacts/refresh` - 刷新通讯录

详细文档请参考 [docs/API.md](../docs/API.md)

## Docker 部署

```dockerfile
FROM dart:stable AS build

WORKDIR /app
COPY api_standalone/ .
RUN dart pub get
RUN dart build cli api_server.dart

FROM debian:stable-slim
COPY --from=build /app/bin/api_server /app/api_server
COPY --from=build /runtime/ /

EXPOSE 8080
ENTRYPOINT ["/app/api_server"]
CMD ["-d", "/data/wechat", "-k", "changeme", "-p", "8080"]
```

## 数据库目录结构

解密后的数据库目录应包含：

```
decrypted_dbs/
├── contact.db          # 联系人数据库（必须）
├── message_0.db        # 消息数据库
├── message_1.db
├── ...
```
