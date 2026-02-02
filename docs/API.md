# EchoTrace API 接口文档

EchoTrace 提供 HTTP API 服务，用于获取微信通讯录和聊天记录数据。

## 启动方式

### 命令行启动

```bash
echotrace.exe --api --port 8080 --auth-key your-secret-key --refresh-interval 300
```

### 参数说明

| 参数 | 简写 | 必须 | 默认值 | 说明 |
|------|------|------|--------|------|
| `--api` | - | 是 | - | 启动 API 服务模式 |
| `--port` | `-p` | 否 | 8080 | API 服务端口 |
| `--auth-key` | `-k` | 是 | - | API 验证密钥 |
| `--refresh-interval` | `-r` | 否 | 300 | 通讯录自动刷新间隔（秒） |
| `--help` | `-h` | 否 | - | 显示帮助信息 |

### 启动示例

```bash
# 基本启动
echotrace.exe --api --auth-key my-secret-key

# 自定义端口和刷新间隔
echotrace.exe --api -p 9000 -k abc123 -r 600
```

## 认证方式

所有 API 请求都需要携带 Auth Key 进行验证，支持两种方式：

### 1. Header 方式（推荐）

```
Authorization: Bearer <auth_key>
```

### 2. Query 参数方式

```
?auth_key=<auth_key>
```

### 认证失败响应

```json
{
  "code": 401,
  "message": "Unauthorized: Invalid or missing auth key"
}
```

## API 端点

### 1. 获取通讯录

获取完整的微信通讯录列表。

**请求**

```
GET /api/contacts
```

**响应**

```json
{
  "code": 0,
  "message": "success",
  "data": {
    "total": 100,
    "contacts": [
      {
        "index": 1,
        "nickName": "瓶子",
        "wxid": "wxid_u97ofh5ga3vc12",
        "remark": "",
        "alias": "pingzi53813"
      },
      {
        "index": 2,
        "nickName": "NanNan💋",
        "wxid": "jessica_85114",
        "remark": "",
        "alias": "wn49698516"
      }
    ],
    "lastUpdateTime": "2026-02-02T10:00:00.000Z"
  }
}
```

**字段说明**

| 字段 | 类型 | 说明 |
|------|------|------|
| `total` | int | 通讯录总数 |
| `contacts` | array | 联系人列表 |
| `contacts[].index` | int | 序号 |
| `contacts[].nickName` | string | 昵称 |
| `contacts[].wxid` | string | 微信 ID |
| `contacts[].remark` | string | 备注名 |
| `contacts[].alias` | string | 微信号 |
| `lastUpdateTime` | string | 通讯录最后更新时间（ISO 8601 格式） |

---

### 2. 获取聊天记录

通过微信 ID 获取与该联系人的聊天记录。

**请求**

```
GET /api/messages/{wxid}?limit=1000&offset=0
```

**路径参数**

| 参数 | 类型 | 必须 | 说明 |
|------|------|------|------|
| `wxid` | string | 是 | 微信 ID |

**查询参数**

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `limit` | int | 1000 | 返回消息数量限制 |
| `offset` | int | 0 | 分页偏移量 |

**响应**

```json
{
  "code": 0,
  "message": "success",
  "data": {
    "session": {
      "wxid": "wxid_u97ofh5ga3vc12",
      "nickname": "瓶子",
      "remark": "",
      "displayName": "瓶子",
      "type": "普通联系人",
      "messageCount": 1500
    },
    "messages": [
      {
        "localId": 12345,
        "createTime": 1706860800,
        "formattedTime": "2026-02-02 10:00:00",
        "type": "文本",
        "localType": 1,
        "content": "你好！",
        "isSend": false,
        "senderUsername": "wxid_u97ofh5ga3vc12",
        "senderDisplayName": "瓶子"
      },
      {
        "localId": 12346,
        "createTime": 1706860860,
        "formattedTime": "2026-02-02 10:01:00",
        "type": "文本",
        "localType": 1,
        "content": "你好呀！",
        "isSend": true,
        "senderUsername": "",
        "senderDisplayName": "我"
      }
    ],
    "pagination": {
      "limit": 1000,
      "offset": 0,
      "total": 1500,
      "hasMore": true
    },
    "exportTime": "2026-02-02T12:00:00.000Z"
  }
}
```

**字段说明**

| 字段 | 类型 | 说明 |
|------|------|------|
| `session.wxid` | string | 微信 ID |
| `session.nickname` | string | 昵称 |
| `session.remark` | string | 备注名 |
| `session.displayName` | string | 显示名称（优先备注，其次昵称） |
| `session.type` | string | 联系人类型（普通联系人/群聊/公众号） |
| `session.messageCount` | int | 消息总数 |
| `messages[].localId` | int | 本地消息 ID |
| `messages[].createTime` | int | 创建时间戳（秒） |
| `messages[].formattedTime` | string | 格式化时间 |
| `messages[].type` | string | 消息类型描述 |
| `messages[].localType` | int | 消息类型代码 |
| `messages[].content` | string | 消息内容 |
| `messages[].isSend` | bool | 是否为自己发送 |
| `messages[].senderUsername` | string | 发送者微信 ID |
| `messages[].senderDisplayName` | string | 发送者显示名称 |
| `pagination.limit` | int | 当前请求的限制数量 |
| `pagination.offset` | int | 当前请求的偏移量 |
| `pagination.total` | int | 消息总数 |
| `pagination.hasMore` | bool | 是否还有更多数据 |
| `exportTime` | string | 导出时间（ISO 8601 格式） |

**消息类型代码 (localType)**

| 代码 | 类型 |
|------|------|
| 1 | 文本 |
| 3 | 图片 |
| 34 | 语音 |
| 43 | 视频 |
| 47 | 表情 |
| 49 | 链接/文件/小程序等 |
| 10000 | 系统消息 |

---

### 3. 获取服务状态

获取 API 服务器的运行状态。

**请求**

```
GET /api/status
```

**响应**

```json
{
  "code": 0,
  "message": "success",
  "data": {
    "status": "running",
    "databaseConnected": true,
    "databaseMode": "decrypted",
    "contactsCacheTime": "2026-02-02T10:00:00.000Z",
    "contactsCount": 100,
    "uptime": 3600,
    "refreshIntervalSeconds": 300,
    "port": 8080
  }
}
```

**字段说明**

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | 服务状态 |
| `databaseConnected` | bool | 数据库是否已连接 |
| `databaseMode` | string | 数据库模式（decrypted/realtime） |
| `contactsCacheTime` | string | 通讯录缓存时间 |
| `contactsCount` | int | 通讯录缓存数量 |
| `uptime` | int | 服务运行时长（秒） |
| `refreshIntervalSeconds` | int | 通讯录刷新间隔（秒） |
| `port` | int | 服务端口 |

---

### 4. 刷新通讯录

手动触发通讯录缓存刷新。

**请求**

```
POST /api/contacts/refresh
```

**响应**

```json
{
  "code": 0,
  "message": "Contacts refreshed successfully",
  "data": {
    "contactsCount": 105,
    "refreshTime": "2026-02-02T10:05:00.000Z"
  }
}
```

---

## 错误码说明

| 错误码 | 说明 |
|--------|------|
| 0 | 成功 |
| 400 | 请求参数错误 |
| 401 | 认证失败 |
| 404 | 资源不存在 |
| 500 | 服务器内部错误 |

---

## 使用示例

### curl

```bash
# 获取通讯录
curl -H "Authorization: Bearer your-secret-key" \
     http://localhost:8080/api/contacts

# 获取聊天记录
curl -H "Authorization: Bearer your-secret-key" \
     "http://localhost:8080/api/messages/wxid_xxx?limit=100"

# 获取服务状态
curl -H "Authorization: Bearer your-secret-key" \
     http://localhost:8080/api/status

# 刷新通讯录
curl -X POST -H "Authorization: Bearer your-secret-key" \
     http://localhost:8080/api/contacts/refresh
```

### Python

```python
import requests

BASE_URL = "http://localhost:8080"
AUTH_KEY = "your-secret-key"

headers = {
    "Authorization": f"Bearer {AUTH_KEY}"
}

# 获取通讯录
response = requests.get(f"{BASE_URL}/api/contacts", headers=headers)
contacts = response.json()
print(f"通讯录数量: {contacts['data']['total']}")

for contact in contacts['data']['contacts']:
    print(f"{contact['index']}. {contact['nickName']} ({contact['wxid']})")

# 获取聊天记录
wxid = "wxid_xxx"
response = requests.get(
    f"{BASE_URL}/api/messages/{wxid}",
    headers=headers,
    params={"limit": 100, "offset": 0}
)
messages = response.json()
print(f"消息数量: {messages['data']['pagination']['total']}")

for msg in messages['data']['messages']:
    sender = msg['senderDisplayName']
    content = msg['content']
    time = msg['formattedTime']
    print(f"[{time}] {sender}: {content}")
```

### JavaScript (Node.js / 浏览器)

```javascript
const BASE_URL = 'http://localhost:8080';
const AUTH_KEY = 'your-secret-key';

const headers = {
  'Authorization': `Bearer ${AUTH_KEY}`
};

// 获取通讯录
async function getContacts() {
  const response = await fetch(`${BASE_URL}/api/contacts`, { headers });
  const data = await response.json();
  console.log(`通讯录数量: ${data.data.total}`);
  return data.data.contacts;
}

// 获取聊天记录
async function getMessages(wxid, limit = 100, offset = 0) {
  const url = `${BASE_URL}/api/messages/${wxid}?limit=${limit}&offset=${offset}`;
  const response = await fetch(url, { headers });
  const data = await response.json();
  console.log(`消息数量: ${data.data.pagination.total}`);
  return data.data.messages;
}

// 全量导出某个联系人的聊天记录
async function exportAllMessages(wxid) {
  const allMessages = [];
  let offset = 0;
  const limit = 1000;
  
  while (true) {
    const url = `${BASE_URL}/api/messages/${wxid}?limit=${limit}&offset=${offset}`;
    const response = await fetch(url, { headers });
    const data = await response.json();
    
    allMessages.push(...data.data.messages);
    
    if (!data.data.pagination.hasMore) {
      break;
    }
    
    offset += limit;
  }
  
  return allMessages;
}
```

---

## 典型使用场景

### 场景 1：加载通讯录并本地搜索

```python
import requests

def load_and_search_contacts(keyword):
    """加载通讯录并搜索"""
    response = requests.get(
        "http://localhost:8080/api/contacts",
        headers={"Authorization": "Bearer your-key"}
    )
    contacts = response.json()['data']['contacts']
    
    # 本地搜索
    results = [
        c for c in contacts
        if keyword.lower() in c['nickName'].lower()
        or keyword.lower() in c['remark'].lower()
        or keyword.lower() in c['wxid'].lower()
        or keyword.lower() in c['alias'].lower()
    ]
    
    return results

# 使用
results = load_and_search_contacts("张三")
for contact in results:
    print(f"{contact['nickName']} - {contact['wxid']}")
```

### 场景 2：全量导出所有聊天记录

```python
import requests
import json
import os

def export_all_chats(output_dir):
    """导出所有联系人的聊天记录"""
    base_url = "http://localhost:8080"
    headers = {"Authorization": "Bearer your-key"}
    
    # 创建输出目录
    os.makedirs(output_dir, exist_ok=True)
    
    # 获取通讯录
    contacts_resp = requests.get(f"{base_url}/api/contacts", headers=headers)
    contacts = contacts_resp.json()['data']['contacts']
    
    for contact in contacts:
        wxid = contact['wxid']
        name = contact['remark'] or contact['nickName'] or wxid
        
        # 获取所有消息
        all_messages = []
        offset = 0
        limit = 1000
        
        while True:
            resp = requests.get(
                f"{base_url}/api/messages/{wxid}",
                headers=headers,
                params={"limit": limit, "offset": offset}
            )
            data = resp.json()['data']
            all_messages.extend(data['messages'])
            
            if not data['pagination']['hasMore']:
                break
            offset += limit
        
        if all_messages:
            # 保存为 JSON 文件
            filename = f"{name}_{wxid}.json"
            filepath = os.path.join(output_dir, filename)
            with open(filepath, 'w', encoding='utf-8') as f:
                json.dump({
                    'contact': contact,
                    'messages': all_messages
                }, f, ensure_ascii=False, indent=2)
            
            print(f"已导出: {name} ({len(all_messages)} 条消息)")

# 使用
export_all_chats("./exports")
```

---

## 注意事项

1. **首次启动**：API 服务启动时会自动加载通讯录缓存，首次加载可能需要一些时间。

2. **数据库连接**：启动 API 服务前，请确保已通过 GUI 完成数据库解密配置。

3. **通讯录刷新**：
   - 通讯录会按设定间隔自动刷新
   - 也可通过 `POST /api/contacts/refresh` 手动刷新
   - 刷新过程中请求仍会返回旧缓存数据

4. **大数据量处理**：获取聊天记录时，建议使用分页参数避免单次请求数据量过大。

5. **安全建议**：
   - 请使用复杂的 Auth Key
   - 建议仅在局域网内使用
   - 如需外网访问，请配置防火墙和 HTTPS 反向代理
