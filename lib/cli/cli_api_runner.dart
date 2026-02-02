// CLI API 入口：解析命令行参数，初始化数据库，启动 API 服务器
import 'dart:io';
import 'dart:async';

import 'package:flutter/widgets.dart';
import '../providers/app_state.dart';
import '../services/api_server_service.dart';
import '../services/config_service.dart';
import '../services/logger_service.dart';

/// CLI API 服务器启动器
class CliApiRunner {
  File? _logFile;
  bool _cancelled = false;
  StreamSubscription<ProcessSignal>? _sigIntSub;
  StreamSubscription<ProcessSignal>? _sigTermSub;
  ApiServerService? _apiServer;

  /// 尝试处理 CLI 参数并启动 API 服务器
  /// 返回 null 表示未检测到 API 参数，继续正常 UI 启动
  /// 返回 int 表示 CLI 模式已完成，应使用该退出码退出
  Future<int?> tryHandle(List<String> args) async {
    final parsed = _parseArgs(args);
    if (parsed == null) {
      return null; // 未检测到 API CLI 参数，继续正常启动 UI
    }

    // 初始化 CLI 本地日志文件
    final logPath = '${Directory.systemTemp.path}${Platform.pathSeparator}echotrace_api.log';
    _logFile = File(logPath);
    _log('CLI API 参数: ${args.join(' ')}, 日志: $logPath');

    if (parsed.showHelp) {
      _printUsage();
      return 0;
    }

    if (parsed.error != null) {
      stderr.writeln('参数错误: ${parsed.error}');
      _printUsage();
      return 1;
    }

    if (!Platform.isWindows) {
      stderr.writeln('当前 API 服务模式仅支持 Windows 平台');
      return 1;
    }

    final options = parsed.options;
    if (options == null) {
      stderr.writeln('未检测到有效的 API 参数');
      return 1;
    }

    if (options.authKey.isEmpty) {
      stderr.writeln('错误: 必须提供 --auth-key 参数');
      _printUsage();
      return 1;
    }

    _log('EchoTrace API 服务模式已启动，正在初始化...');

    try {
      _setupSignalHandlers();

      WidgetsFlutterBinding.ensureInitialized();
      await logger.initialize();
      
      final config = ConfigService();
      await config.saveDatabaseMode('backup');
      
      _log('EchoTrace API 服务启动中...');
      _log('参数 -> 端口: ${options.port}, 刷新间隔: ${options.refreshInterval}秒');

      // 初始化应用状态（包含数据库与配置）
      final appState = AppState();
      _log('正在初始化应用状态/数据库...');
      await appState.initialize();
      _log('应用状态初始化完成');

      final databaseService = appState.databaseService;
      if (!databaseService.isConnected) {
        _logError('数据库未连接，请先在应用内完成解密或配置实时数据库。');
        return 1;
      }

      // 创建并启动 API 服务器
      _apiServer = ApiServerService(databaseService);
      final started = await _apiServer!.start(
        port: options.port,
        authKey: options.authKey,
        refreshIntervalSeconds: options.refreshInterval,
      );

      if (!started) {
        _logError('API 服务器启动失败');
        return 1;
      }

      _log('');
      _log('========================================');
      _log('  EchoTrace API 服务器已启动');
      _log('  端口: ${options.port}');
      _log('  通讯录刷新间隔: ${options.refreshInterval} 秒');
      _log('========================================');
      _log('');
      _log('可用端点:');
      _log('  GET  /api/contacts          - 获取通讯录');
      _log('  GET  /api/messages/{wxid}   - 获取聊天记录');
      _log('  GET  /api/status            - 服务状态');
      _log('  POST /api/contacts/refresh  - 刷新通讯录');
      _log('');
      _log('按 Ctrl+C 停止服务器...');

      // 保持运行直到收到退出信号
      while (!_cancelled) {
        await Future.delayed(const Duration(seconds: 1));
      }

      _log('正在停止 API 服务器...');
      await _apiServer?.stop();
      _log('API 服务器已停止');

      return 0;
    } catch (e, stack) {
      _logError('CLI API 服务发生异常: $e');
      _logError(stack.toString());
      return 1;
    } finally {
      await _disposeSignalHandlers();
    }
  }

  /// 解析 CLI 参数
  _CliApiParseResult? _parseArgs(List<String> args) {
    if (args.isEmpty) {
      return null;
    }

    final wantsHelp = args.any((a) => a == '-h' || a == '--help');
    final hasApiFlag = args.any((a) => a == '--api' || a == '-api');

    if (!hasApiFlag) {
      if (wantsHelp && !args.any((a) => a == '-e' || a == '--export')) {
        // 如果只是 --help 且没有 --export，也显示 API 帮助
        return null;
      }
      return null;
    }

    if (wantsHelp) {
      return _CliApiParseResult(showHelp: true);
    }

    int port = 8080;
    String authKey = '';
    int refreshInterval = 300;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if ((arg == '--port' || arg == '-p') && i + 1 < args.length) {
        final portValue = int.tryParse(args[i + 1]);
        if (portValue == null || portValue < 1 || portValue > 65535) {
          return _CliApiParseResult(error: '无效的端口号: ${args[i + 1]}');
        }
        port = portValue;
      } else if ((arg == '--auth-key' || arg == '-k') && i + 1 < args.length) {
        authKey = args[i + 1];
      } else if ((arg == '--refresh-interval' || arg == '-r') && i + 1 < args.length) {
        final interval = int.tryParse(args[i + 1]);
        if (interval == null || interval < 10) {
          return _CliApiParseResult(error: '无效的刷新间隔（最小 10 秒）: ${args[i + 1]}');
        }
        refreshInterval = interval;
      }
    }

    return _CliApiParseResult(
      options: _CliApiOptions(
        port: port,
        authKey: authKey,
        refreshInterval: refreshInterval,
      ),
    );
  }

  /// 打印使用说明
  void _printUsage() {
    stdout.writeln('EchoTrace API 服务模式 (仅 Windows)');
    stdout.writeln('');
    stdout.writeln('用法: echotrace.exe --api [选项]');
    stdout.writeln('');
    stdout.writeln('选项:');
    stdout.writeln('  --api                        启动 API 服务模式（必须）');
    stdout.writeln('  --port, -p <端口>            API 服务端口（默认: 8080）');
    stdout.writeln('  --auth-key, -k <密钥>        API 验证密钥（必须）');
    stdout.writeln('  --refresh-interval, -r <秒>  通讯录刷新间隔（默认: 300 秒）');
    stdout.writeln('  --help, -h                   显示此帮助信息');
    stdout.writeln('');
    stdout.writeln('示例:');
    stdout.writeln('  echotrace.exe --api --port 8080 --auth-key my-secret-key');
    stdout.writeln('  echotrace.exe --api -p 9000 -k abc123 -r 600');
    stdout.writeln('');
    stdout.writeln('API 端点:');
    stdout.writeln('  GET  /api/contacts          - 获取通讯录列表');
    stdout.writeln('  GET  /api/messages/{wxid}   - 获取指定联系人的聊天记录');
    stdout.writeln('  GET  /api/status            - 获取服务状态');
    stdout.writeln('  POST /api/contacts/refresh  - 手动刷新通讯录缓存');
    stdout.writeln('');
    stdout.writeln('认证方式:');
    stdout.writeln('  Header: Authorization: Bearer <auth_key>');
    stdout.writeln('  Query:  ?auth_key=<auth_key>');
  }

  void _log(String message) {
    final line = '[API] $message';
    stdout.writeln(line);
    _logFile?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  void _logError(String message) {
    final line = '[API][ERR] $message';
    stderr.writeln(line);
    _logFile?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  void _setupSignalHandlers() {
    _sigIntSub = ProcessSignal.sigint.watch().listen((_) {
      _cancelled = true;
      _log('收到 Ctrl+C/SIGINT，准备停止服务...');
    });
    try {
      _sigTermSub = ProcessSignal.sigterm.watch().listen((_) {
        _cancelled = true;
        _log('收到 SIGTERM，准备停止服务...');
      });
    } catch (_) {
      // Windows 可能不支持 SIGTERM，忽略
    }
  }

  Future<void> _disposeSignalHandlers() async {
    await _sigIntSub?.cancel();
    await _sigTermSub?.cancel();
  }
}

/// CLI API 选项
class _CliApiOptions {
  final int port;
  final String authKey;
  final int refreshInterval;

  _CliApiOptions({
    required this.port,
    required this.authKey,
    required this.refreshInterval,
  });
}

/// CLI API 解析结果
class _CliApiParseResult {
  final _CliApiOptions? options;
  final String? error;
  final bool showHelp;

  _CliApiParseResult({
    this.options,
    this.error,
    this.showHelp = false,
  });
}
