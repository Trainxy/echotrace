# EchoTrace API Server Docker Image
# 用于在 Linux 服务器上部署 API 服务

FROM dart:stable AS build

WORKDIR /app

# 复制项目文件
COPY pubspec.yaml .
COPY bin/ bin/

# 获取依赖并编译
RUN dart pub get
RUN dart build cli

# 运行时镜像
FROM debian:bookworm-slim

# 安装运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 复制编译好的程序（包含运行时库）
COPY --from=build /app/build/cli/linux_x64/bundle/ /app/

# 设置工作目录
WORKDIR /app

# 暴露端口
EXPOSE 8080

# 数据目录挂载点
VOLUME ["/data/wechat"]

# 启动命令
ENTRYPOINT ["/app/bin/api_server"]
CMD ["-d", "/data/wechat", "-k", "changeme", "-p", "8080"]
