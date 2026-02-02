// 独立 API 服务器入口 - 不依赖 Flutter，纯 Dart 实现
// 用法: dart run bin/api_server.dart --db-path <path> --port 8080 --auth-key <key>

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 简化日志
void log(String message) {
  final timestamp = DateTime.now().toIso8601String();
  print('[$timestamp] $message');
}

void logError(String message) {
  final timestamp = DateTime.now().toIso8601String();
  stderr.writeln('[$timestamp] [ERROR] $message');
}

/// 联系人数据模型
class ContactInfo {
  final int id;
  final String username;
  final String nickName;
  final String remark;
  final String alias;
  final int localType;

  ContactInfo({
    required this.id,
    required this.username,
    required this.nickName,
    required this.remark,
    required this.alias,
    required this.localType,
  });

  String get displayName {
    if (remark.isNotEmpty) return remark;
    if (nickName.isNotEmpty) return nickName;
    if (alias.isNotEmpty) return alias;
    return username;
  }

  Map<String, dynamic> toJson() => {
        'wxid': username,
        'nickName': nickName,
        'remark': remark,
        'alias': alias,
      };
}

/// 消息数据模型
class MessageInfo {
  final int localId;
  final int createTime;
  final int localType;
  final String content;
  final int isSend;
  final String? senderUsername;

  MessageInfo({
    required this.localId,
    required this.createTime,
    required this.localType,
    required this.content,
    required this.isSend,
    this.senderUsername,
  });

  String get formattedTime {
    final dt = DateTime.fromMillisecondsSinceEpoch(createTime * 1000);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  String get typeDescription {
    switch (localType) {
      case 1:
        return '文本';
      case 3:
        return '图片';
      case 34:
        return '语音';
      case 43:
        return '视频';
      case 47:
        return '表情';
      case 49:
        return '链接/文件';
      case 10000:
        return '系统消息';
      default:
        return '其他($localType)';
    }
  }

  Map<String, dynamic> toJson(String senderDisplayName) => {
        'localId': localId,
        'createTime': createTime,
        'formattedTime': formattedTime,
        'type': typeDescription,
        'localType': localType,
        'content': content,
        'isSend': isSend == 1,
        'senderUsername': senderUsername ?? '',
        'senderDisplayName': senderDisplayName,
      };
}

/// 独立 API 服务器
class StandaloneApiServer {
  final String dbPath;
  final int port;
  final String authKey;
  final int refreshInterval;

  HttpServer? _server;
  Database? _contactDb;
  final Map<String, Database> _messageDbs = {};

  // 通讯录缓存
  List<ContactInfo>? _contactsCache;
  DateTime? _contactsCacheTime;
  bool _isRefreshingContacts = false;

  // 定时器
  Timer? _refreshTimer;
  DateTime? _startTime;

  StandaloneApiServer({
    required this.dbPath,
    required this.port,
    required this.authKey,
    required this.refreshInterval,
  });

  /// 获取运行时长（秒）
  int get uptimeSeconds {
    if (_startTime == null) return 0;
    return DateTime.now().difference(_startTime!).inSeconds;
  }

  /// 启动服务器
  Future<bool> start() async {
    try {
      // 初始化 SQLite FFI
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      log('SQLite FFI 初始化完成');

      // 验证数据库路径
      final dbDir = Directory(dbPath);
      if (!dbDir.existsSync()) {
        logError('数据库目录不存在: $dbPath');
        return false;
      }

      // 查找并连接联系人数据库
      final contactDbPath = await _findContactDatabase();
      if (contactDbPath == null) {
        logError('找不到联系人数据库 (contact.db)');
        return false;
      }

      _contactDb = await databaseFactory.openDatabase(
        contactDbPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      log('联系人数据库已连接: $contactDbPath');

      // 初始加载通讯录
      await _refreshContactsCache();

      // 启动 HTTP 服务器
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );
      _startTime = DateTime.now();
      log('API 服务器已启动: http://0.0.0.0:$port');

      // 启动请求处理
      _server!.listen(
        _handleRequest,
        onError: (e, s) => logError('请求处理错误: $e'),
      );

      // 启动定时刷新
      _startAutoRefresh();

      return true;
    } catch (e, s) {
      logError('启动服务器失败: $e\n$s');
      return false;
    }
  }

  /// 停止服务器
  Future<void> stop() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;

    await _contactDb?.close();
    for (final db in _messageDbs.values) {
      await db.close();
    }
    _messageDbs.clear();

    await _server?.close(force: true);
    _server = null;
    log('API 服务器已停止');
  }

  /// 查找联系人数据库
  Future<String?> _findContactDatabase() async {
    // 在 dbPath 目录下递归查找 contact.db
    final dir = Directory(dbPath);
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('contact.db')) {
        return entity.path;
      }
    }
    return null;
  }

  /// 查找消息数据库
  Future<List<String>> _findMessageDatabases() async {
    final results = <String>[];
    final dir = Directory(dbPath);
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('message_') && name.endsWith('.db')) {
          results.add(entity.path);
        }
      }
    }
    return results;
  }

  /// 获取消息数据库连接
  Future<Database> _getMessageDb(String path) async {
    if (_messageDbs.containsKey(path)) {
      return _messageDbs[path]!;
    }
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    _messageDbs[path] = db;
    return db;
  }

  /// 启动定时刷新
  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      Duration(seconds: refreshInterval),
      (_) => _refreshContactsCache(),
    );
    log('定时刷新已启动，间隔: $refreshInterval 秒');
  }

  /// 刷新通讯录缓存
  Future<void> _refreshContactsCache() async {
    if (_isRefreshingContacts) return;
    _isRefreshingContacts = true;

    try {
      log('开始刷新通讯录缓存...');
      final contacts = await _loadAllContacts();
      _contactsCache = contacts;
      _contactsCacheTime = DateTime.now();
      log('通讯录缓存已刷新，共 ${contacts.length} 条记录');
    } catch (e) {
      logError('刷新通讯录失败: $e');
    } finally {
      _isRefreshingContacts = false;
    }
  }

  /// 加载所有联系人
  Future<List<ContactInfo>> _loadAllContacts() async {
    if (_contactDb == null) return [];

    final results = <ContactInfo>[];
    try {
      final rows = await _contactDb!.query(
        'contact',
        columns: [
          'id',
          'username',
          'nick_name',
          'remark',
          'alias',
          'local_type'
        ],
        where: 'delete_flag = 0',
      );

      for (final row in rows) {
        final username = row['username'] as String? ?? '';
        // 过滤系统账号和公众号
        if (username.isEmpty ||
            username.startsWith('gh_') ||
            username.contains('@chatroom') ||
            username == 'filehelper' ||
            username == 'fmessage' ||
            username == 'medianote' ||
            username == 'floatbottle' ||
            username == 'weixin') {
          continue;
        }

        results.add(ContactInfo(
          id: row['id'] as int? ?? 0,
          username: username,
          nickName: row['nick_name'] as String? ?? '',
          remark: row['remark'] as String? ?? '',
          alias: row['alias'] as String? ?? '',
          localType: row['local_type'] as int? ?? 0,
        ));
      }

      // 按显示名称排序
      results.sort(
          (a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    } catch (e) {
      logError('加载联系人失败: $e');
    }

    return results;
  }

  /// 获取单个联系人
  Future<ContactInfo?> _getContact(String username) async {
    if (_contactDb == null) return null;

    try {
      final rows = await _contactDb!.query(
        'contact',
        where: 'username = ?',
        whereArgs: [username],
        limit: 1,
      );

      if (rows.isNotEmpty) {
        final row = rows.first;
        return ContactInfo(
          id: row['id'] as int? ?? 0,
          username: row['username'] as String? ?? '',
          nickName: row['nick_name'] as String? ?? '',
          remark: row['remark'] as String? ?? '',
          alias: row['alias'] as String? ?? '',
          localType: row['local_type'] as int? ?? 0,
        );
      }
    } catch (e) {
      logError('获取联系人失败: $e');
    }

    return null;
  }

  /// 获取消息表名
  String _getMessageTableName(String username) {
    // 微信消息表名格式：Msg_md5(username)
    return 'Msg_${md5Hash(username)}';
  }

  /// 获取消息列表
  Future<List<MessageInfo>> _getMessages(
    String username, {
    int limit = 1000,
    int offset = 0,
  }) async {
    final results = <MessageInfo>[];
    final messageDbs = await _findMessageDatabases();
    final tableName = _getMessageTableName(username);

    for (final dbPath in messageDbs) {
      try {
        final db = await _getMessageDb(dbPath);

        // 检查表是否存在
        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (tables.isEmpty) continue;

        // 查询消息
        final rows = await db.query(
          tableName,
          columns: [
            'local_id',
            'create_time',
            'local_type',
            'message_content',
            'is_send',
            'sender_username'
          ],
          orderBy: 'create_time DESC',
          limit: limit,
          offset: offset,
        );

        for (final row in rows) {
          results.add(MessageInfo(
            localId: row['local_id'] as int? ?? 0,
            createTime: row['create_time'] as int? ?? 0,
            localType: row['local_type'] as int? ?? 0,
            content: row['message_content'] as String? ?? '',
            isSend: row['is_send'] as int? ?? 0,
            senderUsername: row['sender_username'] as String?,
          ));
        }
      } catch (e) {
        // 忽略单个数据库的错误，继续处理其他数据库
      }
    }

    // 按时间排序
    results.sort((a, b) => b.createTime.compareTo(a.createTime));
    return results.take(limit).toList();
  }

  /// 获取消息总数
  Future<int> _getMessageCount(String username) async {
    int total = 0;
    final messageDbs = await _findMessageDatabases();
    final tableName = _getMessageTableName(username);

    for (final dbPath in messageDbs) {
      try {
        final db = await _getMessageDb(dbPath);

        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (tables.isEmpty) continue;

        final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM $tableName');
        total += (result.first['cnt'] as int? ?? 0);
      } catch (e) {
        // 忽略错误
      }
    }

    return total;
  }

  /// 批量获取显示名称
  Future<Map<String, String>> _getDisplayNames(List<String> usernames) async {
    final result = <String, String>{};
    if (_contactDb == null || usernames.isEmpty) return result;

    try {
      final placeholders = usernames.map((_) => '?').join(',');
      final rows = await _contactDb!.rawQuery(
        'SELECT username, nick_name, remark FROM contact WHERE username IN ($placeholders)',
        usernames,
      );

      for (final row in rows) {
        final username = row['username'] as String? ?? '';
        final remark = row['remark'] as String? ?? '';
        final nickName = row['nick_name'] as String? ?? '';
        result[username] = remark.isNotEmpty ? remark : nickName;
      }
    } catch (e) {
      // 忽略错误
    }

    return result;
  }

  // ========== HTTP 请求处理 ==========

  /// 处理 HTTP 请求
  Future<void> _handleRequest(HttpRequest request) async {
    final method = request.method;
    final path = request.uri.path;

    try {
      // CORS 头
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      request.response.headers.add('Access-Control-Allow-Headers', 'Authorization, Content-Type');
      request.response.headers.add('Content-Type', 'application/json; charset=utf-8');

      // OPTIONS 预检
      if (method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      // Auth 验证
      if (!_validateAuth(request)) {
        await _sendError(request.response, 401, 'Unauthorized: Invalid or missing auth key');
        return;
      }

      // 路由
      if (method == 'GET' && path == '/api/contacts') {
        await _handleGetContacts(request);
      } else if (method == 'GET' && path.startsWith('/api/messages/')) {
        await _handleGetMessages(request);
      } else if (method == 'GET' && path == '/api/status') {
        await _handleGetStatus(request);
      } else if (method == 'POST' && path == '/api/contacts/refresh') {
        await _handleRefreshContacts(request);
      } else {
        await _sendError(request.response, 404, 'Not Found: $path');
      }
    } catch (e, s) {
      logError('处理请求错误: $method $path - $e\n$s');
      await _sendError(request.response, 500, 'Internal Server Error: $e');
    }
  }

  /// 验证 Auth
  bool _validateAuth(HttpRequest request) {
    if (authKey.isEmpty) return true;

    final authHeader = request.headers.value('Authorization');
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      if (authHeader.substring(7) == authKey) return true;
    }

    final queryKey = request.uri.queryParameters['auth_key'];
    if (queryKey == authKey) return true;

    return false;
  }

  /// 发送成功响应
  Future<void> _sendSuccess(HttpResponse response, dynamic data, {String message = 'success'}) async {
    response.statusCode = HttpStatus.ok;
    response.write(jsonEncode({'code': 0, 'message': message, 'data': data}));
    await response.close();
  }

  /// 发送错误响应
  Future<void> _sendError(HttpResponse response, int code, String message) async {
    response.statusCode = code;
    response.write(jsonEncode({'code': code, 'message': message}));
    await response.close();
  }

  /// GET /api/contacts
  Future<void> _handleGetContacts(HttpRequest request) async {
    if (_contactsCache == null) {
      await _refreshContactsCache();
    }

    final contacts = _contactsCache ?? [];
    final contactsList = <Map<String, dynamic>>[];

    for (var i = 0; i < contacts.length; i++) {
      final c = contacts[i];
      contactsList.add({
        'index': i + 1,
        ...c.toJson(),
      });
    }

    await _sendSuccess(request.response, {
      'total': contactsList.length,
      'contacts': contactsList,
      'lastUpdateTime': _contactsCacheTime?.toIso8601String(),
    });
  }

  /// GET /api/messages/{wxid}
  Future<void> _handleGetMessages(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length < 3) {
      await _sendError(request.response, 400, 'Missing wxid parameter');
      return;
    }

    final wxid = segments[2];
    if (wxid.isEmpty) {
      await _sendError(request.response, 400, 'wxid cannot be empty');
      return;
    }

    final params = request.uri.queryParameters;
    final limit = int.tryParse(params['limit'] ?? '') ?? 1000;
    final offset = int.tryParse(params['offset'] ?? '') ?? 0;

    try {
      final contact = await _getContact(wxid);
      final messageCount = await _getMessageCount(wxid);
      final messages = await _getMessages(wxid, limit: limit, offset: offset);

      // 获取发送者显示名称
      final senderUsernames = messages
          .where((m) => m.senderUsername != null && m.senderUsername!.isNotEmpty)
          .map((m) => m.senderUsername!)
          .toSet()
          .toList();
      final senderNames = await _getDisplayNames(senderUsernames);

      final messagesList = messages.map((m) {
        String senderDisplayName = '';
        if (m.isSend == 1) {
          senderDisplayName = '我';
        } else if (m.senderUsername != null && m.senderUsername!.isNotEmpty) {
          senderDisplayName = senderNames[m.senderUsername] ?? m.senderUsername!;
        }
        return m.toJson(senderDisplayName);
      }).toList();

      await _sendSuccess(request.response, {
        'session': {
          'wxid': wxid,
          'nickname': contact?.nickName ?? '',
          'remark': contact?.remark ?? '',
          'displayName': contact?.displayName ?? wxid,
          'messageCount': messageCount,
        },
        'messages': messagesList,
        'pagination': {
          'limit': limit,
          'offset': offset,
          'total': messageCount,
          'hasMore': offset + messages.length < messageCount,
        },
        'exportTime': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      logError('获取消息失败: $wxid - $e');
      await _sendError(request.response, 500, 'Failed to get messages: $e');
    }
  }

  /// GET /api/status
  Future<void> _handleGetStatus(HttpRequest request) async {
    await _sendSuccess(request.response, {
      'status': 'running',
      'databasePath': dbPath,
      'contactsCacheTime': _contactsCacheTime?.toIso8601String(),
      'contactsCount': _contactsCache?.length ?? 0,
      'uptime': uptimeSeconds,
      'refreshIntervalSeconds': refreshInterval,
      'port': port,
    });
  }

  /// POST /api/contacts/refresh
  Future<void> _handleRefreshContacts(HttpRequest request) async {
    await _refreshContactsCache();
    await _sendSuccess(
      request.response,
      {
        'contactsCount': _contactsCache?.length ?? 0,
        'refreshTime': _contactsCacheTime?.toIso8601String(),
      },
      message: 'Contacts refreshed successfully',
    );
  }
}

// MD5 计算（纯 Dart 实现，不依赖 Flutter）
String md5Hash(String input) {
  final data = utf8.encode(input);
  
  final s = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];

  final k = [
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
    0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
    0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
    0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
    0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
    0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
    0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
    0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
    0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
  ];

  var a0 = 0x67452301;
  var b0 = 0xefcdab89;
  var c0 = 0x98badcfe;
  var d0 = 0x10325476;

  final bitLength = data.length * 8;

  // 填充
  final padded = List<int>.from(data);
  padded.add(0x80);
  while ((padded.length % 64) != 56) {
    padded.add(0);
  }

  // 添加长度（小端序）
  for (var i = 0; i < 8; i++) {
    padded.add((bitLength >> (i * 8)) & 0xFF);
  }

  // 处理块
  for (var chunkStart = 0; chunkStart < padded.length; chunkStart += 64) {
    final m = List<int>.generate(16, (i) {
      final offset = chunkStart + i * 4;
      return padded[offset] |
          (padded[offset + 1] << 8) |
          (padded[offset + 2] << 16) |
          (padded[offset + 3] << 24);
    });

    var a = a0, b = b0, c = c0, d = d0;

    for (var i = 0; i < 64; i++) {
      int f, g;
      if (i < 16) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d & 0xFFFFFFFF) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d & 0xFFFFFFFF));
        g = (7 * i) % 16;
      }

      f = (f + a + k[i] + m[g]) & 0xFFFFFFFF;
      a = d;
      d = c;
      c = b;
      final rotated = ((f << s[i]) | (f >>> (32 - s[i]))) & 0xFFFFFFFF;
      b = (b + rotated) & 0xFFFFFFFF;
    }

    a0 = (a0 + a) & 0xFFFFFFFF;
    b0 = (b0 + b) & 0xFFFFFFFF;
    c0 = (c0 + c) & 0xFFFFFFFF;
    d0 = (d0 + d) & 0xFFFFFFFF;
  }

  // 输出（小端序）
  String toHex(int val) {
    final bytes = [
      val & 0xFF,
      (val >> 8) & 0xFF,
      (val >> 16) & 0xFF,
      (val >> 24) & 0xFF,
    ];
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  return toHex(a0) + toHex(b0) + toHex(c0) + toHex(d0);
}

/// 主入口
Future<void> main(List<String> args) async {
  print('');
  print('========================================');
  print('  EchoTrace Standalone API Server');
  print('========================================');
  print('');

  // 解析参数
  String? dbPath;
  int port = 8080;
  String authKey = '';
  int refreshInterval = 300;
  bool showHelp = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-h' || arg == '--help') {
      showHelp = true;
    } else if ((arg == '--db-path' || arg == '-d') && i + 1 < args.length) {
      dbPath = args[++i];
    } else if ((arg == '--port' || arg == '-p') && i + 1 < args.length) {
      port = int.tryParse(args[++i]) ?? 8080;
    } else if ((arg == '--auth-key' || arg == '-k') && i + 1 < args.length) {
      authKey = args[++i];
    } else if ((arg == '--refresh-interval' || arg == '-r') && i + 1 < args.length) {
      refreshInterval = int.tryParse(args[++i]) ?? 300;
    }
  }

  if (showHelp || dbPath == null || authKey.isEmpty) {
    print('用法: dart run bin/api_server.dart [选项]');
    print('');
    print('必需参数:');
    print('  --db-path, -d <路径>         解密后的微信数据库目录路径');
    print('  --auth-key, -k <密钥>        API 验证密钥');
    print('');
    print('可选参数:');
    print('  --port, -p <端口>            API 端口 (默认: 8080)');
    print('  --refresh-interval, -r <秒>  通讯录刷新间隔 (默认: 300)');
    print('  --help, -h                   显示帮助');
    print('');
    print('示例:');
    print('  dart run bin/api_server.dart -d "C:\\WeChatData\\decrypted" -k my-secret-key');
    print('  dart run bin/api_server.dart -d /data/wechat -p 9000 -k abc123 -r 600');
    print('');
    print('Windows 编译后运行:');
    print('  api_server.exe -d "C:\\WeChatData\\decrypted" -k my-secret-key');
    print('');
    exit(showHelp ? 0 : 1);
  }

  log('参数: db-path=$dbPath, port=$port, refresh-interval=$refreshInterval');

  final server = StandaloneApiServer(
    dbPath: dbPath,
    port: port,
    authKey: authKey,
    refreshInterval: refreshInterval,
  );

  // 信号处理
  var cancelled = false;
  ProcessSignal.sigint.watch().listen((_) {
    if (!cancelled) {
      cancelled = true;
      log('收到中断信号，正在停止服务器...');
      server.stop().then((_) => exit(0));
    }
  });

  final started = await server.start();
  if (!started) {
    logError('服务器启动失败');
    exit(1);
  }

  print('');
  print('API 端点:');
  print('  GET  /api/contacts          - 获取通讯录');
  print('  GET  /api/messages/{wxid}   - 获取聊天记录');
  print('  GET  /api/status            - 服务状态');
  print('  POST /api/contacts/refresh  - 刷新通讯录');
  print('');
  print('按 Ctrl+C 停止服务器...');
  print('');

  // 保持运行
  while (!cancelled) {
    await Future.delayed(const Duration(seconds: 1));
  }
}
