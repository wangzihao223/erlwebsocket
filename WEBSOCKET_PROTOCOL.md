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

## 10. 底层 Frame 格式

WebSocket 握手成功后，不再传输 HTTP 请求和响应，而是传输 WebSocket frame。

一个 WebSocket frame 的基本结构如下：

```text
0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-------+-+-------------+-------------------------------+
|F|R|R|R| opcode|M| Payload len | Extended payload length       |
|I|S|S|S|  (4)  |A|     (7)     | 16 bits 或 64 bits            |
|N|V|V|V|       |S|             |                               |
+-+-+-+-+-------+-+-------------+-------------------------------+
| Masking-key, if MASK set                                      |
+---------------------------------------------------------------+
| Payload data                                                  |
+---------------------------------------------------------------+
```

### 10.1 第 1 字节

第 1 字节由 `FIN`、`RSV1`、`RSV2`、`RSV3` 和 `opcode` 组成：

```text
FIN RSV1 RSV2 RSV3 opcode
1bit 1bit 1bit 1bit 4bit
```

字段说明：

| 字段 | 位数 | 说明 |
| --- | --- | --- |
| `FIN` | 1 | 是否为当前消息的最后一帧。`1` 表示最后一帧。 |
| `RSV1` | 1 | 扩展保留位。未协商扩展时必须为 `0`。 |
| `RSV2` | 1 | 扩展保留位。未协商扩展时必须为 `0`。 |
| `RSV3` | 1 | 扩展保留位。未协商扩展时必须为 `0`。 |
| `opcode` | 4 | 帧类型。 |

常见 `opcode`：

| opcode | 含义 |
| --- | --- |
| `0x0` | continuation frame，延续帧。 |
| `0x1` | text frame，文本帧。 |
| `0x2` | binary frame，二进制帧。 |
| `0x8` | close，关闭连接。 |
| `0x9` | ping。 |
| `0xA` | pong。 |

例如：

```text
1000 0001
```

表示：

```text
FIN = 1
RSV1 = 0
RSV2 = 0
RSV3 = 0
opcode = 0x1
```

也就是完整文本帧。十六进制是：

```erlang
16#81
```

### 10.2 第 2 字节

第 2 字节由 `MASK` 和 `Payload len` 组成：

```text
MASK Payload len
1bit 7bit
```

字段说明：

| 字段 | 位数 | 说明 |
| --- | --- | --- |
| `MASK` | 1 | payload 是否经过 mask。客户端发给服务端的 frame 必须为 `1`。 |
| `Payload len` | 7 | payload 长度或扩展长度标记。 |

payload 长度规则：

| `Payload len` 值 | 实际含义 |
| --- | --- |
| `0` 到 `125` | 该值就是 payload 实际长度。 |
| `126` | 后面继续读取 2 字节 unsigned integer，作为实际长度。 |
| `127` | 后面继续读取 8 字节 unsigned integer，作为实际长度。 |

### 10.3 Masking Key

如果 `MASK = 1`，payload 前面会有 4 字节 `masking key`。

客户端发给服务端的 frame 必须 mask：

```text
MASK = 1
```

服务端发给客户端的 frame 通常不 mask：

```text
MASK = 0
```

解码规则：

```text
payload[i] = masked_payload[i] XOR masking_key[i mod 4]
```

Erlang 中对应：

```erlang
UnmaskedByte = MaskedByte bxor MaskKeyByte.
```

### 10.4 示例：服务端发送文本 hello

服务端发送文本消息 `hello`：

```text
81 05 68 65 6c 6c 6f
```

解释：

```text
81 = FIN=1, opcode=0x1 text
05 = MASK=0, payload length=5
68 65 6c 6c 6f = hello
```

Erlang binary 表示：

```erlang
<<16#81, 5, "hello">>
```

### 10.5 示例：客户端发送文本 hello

客户端发送文本消息 `hello` 时必须 mask。一个可能的 frame：

```text
81 85 37 fa 21 3d 5f 9f 4d 51 58
```

解释：

```text
81 = FIN=1, opcode=0x1 text
85 = MASK=1, payload length=5
37 fa 21 3d = masking key
5f 9f 4d 51 58 = masked payload
```

其中 `0x85` 的二进制是：

```text
1000 0101
```

含义是：

```text
MASK = 1
payload length = 5
```

### 10.6 解码步骤

解析一个 frame 的顺序：

```text
1. 读取第 1 字节，解析 FIN、RSV1、RSV2、RSV3、opcode。
2. 读取第 2 字节，解析 MASK 和 Payload len。
3. 如果 Payload len 是 126，继续读取 2 字节扩展长度。
4. 如果 Payload len 是 127，继续读取 8 字节扩展长度。
5. 如果 MASK 是 1，继续读取 4 字节 masking key。
6. 读取 payload data。
7. 如果 MASK 是 1，对 payload data 做 XOR 解码。
```

Erlang 中常用位运算解析：

```erlang
Fin = (B1 band 16#80) =/= 0,
Rsv = (B1 band 16#70) bsr 4,
Opcode = B1 band 16#0F,

Masked = (B2 band 16#80) =/= 0,
Len0 = B2 band 16#7F.
```

掩码说明：

| 表达式 | 二进制 | 作用 |
| --- | --- | --- |
| `16#80` | `1000 0000` | 取最高位。 |
| `16#70` | `0111 0000` | 取 RSV1、RSV2、RSV3。 |
| `16#0F` | `0000 1111` | 取 opcode。 |
| `16#7F` | `0111 1111` | 取 payload length。 |

### 10.7 控制帧限制

`close`、`ping`、`pong` 属于控制帧，限制如下：

```text
payload length 必须 <= 125
不能被分片
FIN 必须为 1
```

### 10.8 分片消息

一条消息可以被拆成多个 frame：

```text
第一帧：
FIN=0, opcode=0x1 text

中间帧：
FIN=0, opcode=0x0 continuation

最后一帧：
FIN=1, opcode=0x0 continuation
```

例如：

```text
frame 1: FIN=0, opcode=text, payload="hel"
frame 2: FIN=1, opcode=continuation, payload="lo"
```

最终组合成：

```text
hello
```

当前项目第一版可以先不实现分片，只处理：

```text
FIN=1
opcode=text / binary / ping / pong / close
```
