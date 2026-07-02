# WebSocket 协议文件

## 1. 连接地址

客户端连接地址：

```text
ws://{host}:{port}/ws
wss://{host}:{port}/ws
```

生产环境必须使用 `wss://`。

## 2. 认证方式

推荐通过 URL 参数传递访问令牌：

```text
wss://example.com/ws?token={access_token}
```

也可以通过请求头传递：

```http
Authorization: Bearer {access_token}
```

如果认证失败，服务端关闭连接，关闭码为 `4001`。

## 3. 消息格式

所有文本消息统一使用 JSON 格式。

```json
{
  "id": "msg_001",
  "type": "event.name",
  "timestamp": 1719830400000,
  "payload": {}
}
```

字段说明：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | string | 是 | 消息唯一 ID，用于链路追踪或请求响应匹配。 |
| `type` | string | 是 | 消息类型。 |
| `timestamp` | number | 是 | Unix 毫秒时间戳。 |
| `payload` | object | 是 | 消息体。 |

## 4. 心跳机制

客户端每 30 秒发送一次心跳：

```json
{
  "id": "hb_001",
  "type": "ping",
  "timestamp": 1719830400000,
  "payload": {}
}
```

服务端响应：

```json
{
  "id": "hb_001",
  "type": "pong",
  "timestamp": 1719830400100,
  "payload": {}
}
```

如果服务端 90 秒内没有收到心跳，可以主动关闭连接，关闭码为 `4000`。

## 5. 客户端事件

### 5.1 订阅频道

```json
{
  "id": "sub_001",
  "type": "subscribe",
  "timestamp": 1719830400000,
  "payload": {
    "channel": "room.1001"
  }
}
```

### 5.2 取消订阅频道

```json
{
  "id": "unsub_001",
  "type": "unsubscribe",
  "timestamp": 1719830400000,
  "payload": {
    "channel": "room.1001"
  }
}
```

### 5.3 发送消息

```json
{
  "id": "chat_001",
  "type": "message.send",
  "timestamp": 1719830400000,
  "payload": {
    "channel": "room.1001",
    "content": "hello"
  }
}
```

## 6. 服务端事件

### 6.1 确认响应

```json
{
  "id": "chat_001",
  "type": "ack",
  "timestamp": 1719830400100,
  "payload": {
    "success": true
  }
}
```

### 6.2 推送消息

```json
{
  "id": "push_001",
  "type": "message.push",
  "timestamp": 1719830400200,
  "payload": {
    "channel": "room.1001",
    "sender": "user_001",
    "content": "hello"
  }
}
```

### 6.3 错误响应

```json
{
  "id": "chat_001",
  "type": "error",
  "timestamp": 1719830400300,
  "payload": {
    "code": "INVALID_MESSAGE",
    "message": "Invalid message format"
  }
}
```

## 7. 业务错误码

| 错误码 | 说明 |
| --- | --- |
| `INVALID_JSON` | 消息不是合法 JSON。 |
| `INVALID_MESSAGE` | 消息结构不合法。 |
| `UNAUTHORIZED` | 未认证、认证失败或令牌过期。 |
| `FORBIDDEN` | 用户没有目标频道权限。 |
| `CHANNEL_NOT_FOUND` | 频道不存在。 |
| `RATE_LIMITED` | 消息发送过于频繁。 |
| `INTERNAL_ERROR` | 服务端内部错误。 |

## 8. 连接关闭码

| 关闭码 | 说明 |
| --- | --- |
| `1000` | 正常关闭。 |
| `1008` | 策略违规。 |
| `4000` | 心跳超时。 |
| `4001` | 认证失败。 |
| `4002` | 令牌过期。 |
| `4003` | 重复连接。 |
| `4500` | 服务端内部错误。 |

## 9. 协议版本

协议版本可以通过连接地址传递：

```text
wss://example.com/ws?v=1
```

如果协议发生不兼容变更，必须升级主版本号。
