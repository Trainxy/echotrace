// API 服务器：提供 HTTP API 接口用于获取通讯录和聊天记录
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/contact_record.dart';
import 'database_service.dart';
import 'logger_service.dart';

/// API 服务器服务
class ApiServerService {
  final DatabaseService _databaseService;

  HttpServer? _server;
  String? _authKey;
  int _port = 8080;

  // 通讯录缓存
  List<ContactRecord>? _contactsCache;
  DateTime? _contactsCacheTime;
  bool _isRefreshingContacts = false;

  // 定时刷新
  Timer? _refreshTimer;
  int _refreshIntervalSeconds = 300;

  // 服务器启动时间
  DateTime? _startTime;

  // 日志标签
  static const String _tag = 'ApiServerService';

  ApiServerService(this._databaseService);

  /// 服务器是否正在运行
  bool get isRunning => _server != null;

  /// 获取服务器端口
  int get port => _port;

  /// 获取通讯录缓存数量
  int get contactsCacheCount => _contactsCache?.length ?? 0;

  /// 获取通讯录缓存时间
  DateTime? get contactsCacheTime => _contactsCacheTime;

  /// 获取服务运行时长（秒）
  int get uptimeSeconds {
    if (_startTime == null) return 0;
    return DateTime.now().difference(_startTime!).inSeconds;
  }

  /// 启动 API 服务器
  Future<bool> start({
    int port = 8080,
    required String authKey,
    int refreshIntervalSeconds = 300,
  }) async {
    if (_server != null) {
      await logger.warning(_tag, 'API 服务器已在运行');
      return false;
    }

    _port = port;
    _authKey = authKey;
    _refreshIntervalSeconds = refreshIntervalSeconds;

    try {
      // 检查数据库连接
      if (!_databaseService.isConnected) {
        await logger.error(_tag, '数据库未连接，无法启动 API 服务器');
        return false;
      }

      // 初始加载通讯录缓存
      await _refreshContactsCache();

      // 启动 HTTP 服务器
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );

      _startTime = DateTime.now();
      await logger.info(_tag, 'API 服务器已启动，端口: $port');

      // 启动请求处理
      _server!.listen(
        _handleRequest,
        onError: (error, stackTrace) {
          logger.error(_tag, '请求处理错误', error, stackTrace);
        },
        onDone: () {
          logger.info(_tag, 'API 服务器连接已关闭');
        },
      );

      // 启动定时刷新
      _startAutoRefresh();

      return true;
    } catch (e, stack) {
      await logger.error(_tag, '启动 API 服务器失败', e, stack);
      return false;
    }
  }

  /// 停止 API 服务器
  Future<void> stop() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;

    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
      _startTime = null;
      await logger.info(_tag, 'API 服务器已停止');
    }
  }

  /// 启动定时刷新通讯录
  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      Duration(seconds: _refreshIntervalSeconds),
      (_) => _refreshContactsCache(),
    );
    logger.info(_tag, '定时刷新已启动，间隔: $_refreshIntervalSeconds 秒');
  }

  /// 刷新通讯录缓存
  Future<void> _refreshContactsCache() async {
    if (_isRefreshingContacts) {
      await logger.info(_tag, '通讯录刷新已在进行中，跳过');
      return;
    }

    _isRefreshingContacts = true;
    try {
      await logger.info(_tag, '开始刷新通讯录缓存...');
      final contacts = await _databaseService.getAllContacts(
        includeDeleted: false,
        includeStrangers: false,
        includeChatroomParticipants: false,
        includeOfficialAccounts: false,
      );
      _contactsCache = contacts;
      _contactsCacheTime = DateTime.now();
      await logger.info(_tag, '通讯录缓存已刷新，共 ${contacts.length} 条记录');
    } catch (e, stack) {
      await logger.error(_tag, '刷新通讯录缓存失败', e, stack);
    } finally {
      _isRefreshingContacts = false;
    }
  }

  /// 手动刷新通讯录（供 API 调用）
  Future<int> refreshContacts() async {
    await _refreshContactsCache();
    return _contactsCache?.length ?? 0;
  }

  /// 处理 HTTP 请求
  Future<void> _handleRequest(HttpRequest request) async {
    final startTime = DateTime.now();
    final method = request.method;
    final path = request.uri.path;

    try {
      // 设置 CORS 头
      _setCorsHeaders(request.response);

      // 处理 OPTIONS 预检请求
      if (method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      // 验证 Auth Key（除了 OPTIONS 请求）
      if (!_validateAuth(request)) {
        await _sendError(
          request.response,
          HttpStatus.unauthorized,
          'Unauthorized: Invalid or missing auth key',
        );
        return;
      }

      // 路由分发
      if (method == 'GET' && path == '/api/contacts') {
        await _handleGetContacts(request);
      } else if (method == 'GET' && path.startsWith('/api/messages/')) {
        await _handleGetMessages(request);
      } else if (method == 'GET' && path == '/api/status') {
        await _handleGetStatus(request);
      } else if (method == 'POST' && path == '/api/contacts/refresh') {
        await _handleRefreshContacts(request);
      } else {
        await _sendError(
          request.response,
          HttpStatus.notFound,
          'Not Found: $path',
        );
      }
    } catch (e, stack) {
      await logger.error(_tag, '处理请求时发生错误: $method $path', e, stack);
      await _sendError(
        request.response,
        HttpStatus.internalServerError,
        'Internal Server Error: ${e.toString()}',
      );
    } finally {
      final duration = DateTime.now().difference(startTime).inMilliseconds;
      await logger.info(_tag, '$method $path - ${request.response.statusCode} (${duration}ms)');
    }
  }

  /// 设置 CORS 头
  void _setCorsHeaders(HttpResponse response) {
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    response.headers.add('Content-Type', 'application/json; charset=utf-8');
  }

  /// 验证 Auth Key
  bool _validateAuth(HttpRequest request) {
    if (_authKey == null || _authKey!.isEmpty) {
      return true; // 如果没有设置 auth key，则不验证
    }

    // 从 Header 获取
    final authHeader = request.headers.value('Authorization');
    if (authHeader != null) {
      if (authHeader.startsWith('Bearer ')) {
        final token = authHeader.substring(7);
        if (token == _authKey) return true;
      }
    }

    // 从 Query 参数获取
    final queryAuthKey = request.uri.queryParameters['auth_key'];
    if (queryAuthKey != null && queryAuthKey == _authKey) {
      return true;
    }

    return false;
  }

  /// 发送成功响应
  Future<void> _sendSuccess(
    HttpResponse response,
    dynamic data, {
    String message = 'success',
  }) async {
    response.statusCode = HttpStatus.ok;
    final body = jsonEncode({
      'code': 0,
      'message': message,
      'data': data,
    });
    response.write(body);
    await response.close();
  }

  /// 发送错误响应
  Future<void> _sendError(
    HttpResponse response,
    int statusCode,
    String message,
  ) async {
    response.statusCode = statusCode;
    final body = jsonEncode({
      'code': statusCode,
      'message': message,
    });
    response.write(body);
    await response.close();
  }

  // ========== API 端点处理 ==========

  /// GET /api/contacts - 获取通讯录
  Future<void> _handleGetContacts(HttpRequest request) async {
    if (_contactsCache == null) {
      await _refreshContactsCache();
    }

    final contacts = _contactsCache ?? [];
    final contactsList = <Map<String, dynamic>>[];

    for (var i = 0; i < contacts.length; i++) {
      final record = contacts[i];
      final contact = record.contact;
      contactsList.add({
        'index': i + 1,
        'nickName': contact.nickName,
        'wxid': contact.username,
        'remark': contact.remark,
        'alias': contact.alias,
      });
    }

    await _sendSuccess(request.response, {
      'total': contactsList.length,
      'contacts': contactsList,
      'lastUpdateTime': _contactsCacheTime?.toIso8601String(),
    });
  }

  /// GET /api/messages/{wxid} - 获取聊天记录
  Future<void> _handleGetMessages(HttpRequest request) async {
    // 解析 wxid
    final pathSegments = request.uri.pathSegments;
    if (pathSegments.length < 3) {
      await _sendError(
        request.response,
        HttpStatus.badRequest,
        'Bad Request: Missing wxid parameter',
      );
      return;
    }

    final wxid = pathSegments[2];
    if (wxid.isEmpty) {
      await _sendError(
        request.response,
        HttpStatus.badRequest,
        'Bad Request: wxid cannot be empty',
      );
      return;
    }

    // 解析分页参数
    final queryParams = request.uri.queryParameters;
    final limit = int.tryParse(queryParams['limit'] ?? '') ?? 1000;
    final offset = int.tryParse(queryParams['offset'] ?? '') ?? 0;

    try {
      // 获取联系人信息
      final contact = await _databaseService.getContact(wxid);

      // 获取消息数量
      int messageCount = 0;
      try {
        messageCount = await _databaseService.getMessageCount(wxid);
      } catch (_) {}

      // 获取消息列表
      final messages = await _databaseService.getMessages(
        wxid,
        limit: limit,
        offset: offset,
      );

      // 获取发送者显示名称
      final senderUsernames = messages
          .where((m) => m.senderUsername != null && m.senderUsername!.isNotEmpty)
          .map((m) => m.senderUsername!)
          .toSet()
          .toList();
      
      final senderDisplayNames = senderUsernames.isNotEmpty
          ? await _databaseService.getDisplayNames(senderUsernames)
          : <String, String>{};

      // 构建消息列表
      final messagesList = <Map<String, dynamic>>[];
      for (final msg in messages) {
        final isSend = msg.isSend == 1;
        String senderDisplayName = '';
        
        if (isSend) {
          senderDisplayName = '我';
        } else if (msg.senderUsername != null && msg.senderUsername!.isNotEmpty) {
          senderDisplayName = senderDisplayNames[msg.senderUsername] ?? msg.senderUsername!;
        }

        messagesList.add({
          'localId': msg.localId,
          'createTime': msg.createTime,
          'formattedTime': msg.formattedCreateTime,
          'type': msg.typeDescription,
          'localType': msg.localType,
          'content': msg.displayContent,
          'isSend': isSend,
          'senderUsername': msg.senderUsername ?? '',
          'senderDisplayName': senderDisplayName,
        });
      }

      // 构建会话信息
      final sessionInfo = {
        'wxid': wxid,
        'nickname': contact?.nickName ?? '',
        'remark': contact?.remark ?? '',
        'displayName': contact?.displayName ?? wxid,
        'type': contact?.typeDescription ?? '未知',
        'messageCount': messageCount,
      };

      await _sendSuccess(request.response, {
        'session': sessionInfo,
        'messages': messagesList,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'total': messageCount,
          'hasMore': offset + messages.length < messageCount,
        },
        'exportTime': DateTime.now().toIso8601String(),
      });
    } catch (e, stack) {
      await logger.error(_tag, '获取聊天记录失败: $wxid', e, stack);
      await _sendError(
        request.response,
        HttpStatus.internalServerError,
        'Failed to get messages: ${e.toString()}',
      );
    }
  }

  /// GET /api/status - 获取服务状态
  Future<void> _handleGetStatus(HttpRequest request) async {
    await _sendSuccess(request.response, {
      'status': 'running',
      'databaseConnected': _databaseService.isConnected,
      'databaseMode': _databaseService.mode.name,
      'contactsCacheTime': _contactsCacheTime?.toIso8601String(),
      'contactsCount': _contactsCache?.length ?? 0,
      'uptime': uptimeSeconds,
      'refreshIntervalSeconds': _refreshIntervalSeconds,
      'port': _port,
    });
  }

  /// POST /api/contacts/refresh - 手动刷新通讯录
  Future<void> _handleRefreshContacts(HttpRequest request) async {
    try {
      final count = await refreshContacts();
      await _sendSuccess(
        request.response,
        {
          'contactsCount': count,
          'refreshTime': _contactsCacheTime?.toIso8601String(),
        },
        message: 'Contacts refreshed successfully',
      );
    } catch (e, stack) {
      await logger.error(_tag, '手动刷新通讯录失败', e, stack);
      await _sendError(
        request.response,
        HttpStatus.internalServerError,
        'Failed to refresh contacts: ${e.toString()}',
      );
    }
  }
}
