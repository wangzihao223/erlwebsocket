# Raw WebSocket Client

这是一个从 TCP 开始实现的 Erlang WebSocket 客户端学习项目。

当前第一版实现范围：

- TCP 连接
- HTTP/1.1 Upgrade 握手
- `Sec-WebSocket-Accept` 校验
- WebSocket frame 编码
- WebSocket frame 解码
- 客户端发送 frame 时自动 mask
- 文本、二进制、ping、pong、close

## 数据结构

WebSocket frame 使用固定 record，定义在 `include/raw_ws.hrl`：

```erlang
-record(ws_frame, {
    fin,
    rsv = 0,
    opcode,
    masked = false,
    payload = <<>>
}).
```

解码函数返回：

```erlang
{ok, #ws_frame{}, Rest}
```

暂未实现：

- `wss://` TLS 连接
- 分片消息重组
- extension / compression
- 完整 OTP `gen_server` 封装

## 编译

```bash
rebar3 compile
```

## 运行

先启动一个 WebSocket 服务端，例如监听：

```text
ws://localhost:8080/ws
```

然后进入 Erlang shell：

```bash
rebar3 shell
```

连接：

```erlang
{ok, C0} = raw_ws_client:connect("localhost", 8080, "/ws").
```

发送文本：

```erlang
ok = raw_ws_client:send_text(C0, <<"hello websocket">>).
```

接收一帧：

```erlang
{ok, Event, C1} = raw_ws_client:recv(C0).
```

发送 ping：

```erlang
ok = raw_ws_client:send_ping(C1).
```

关闭：

```erlang
ok = raw_ws_client:close(C1).
```

## 下一步

建议按这个顺序继续完善：

1. 把 `raw_ws_client` 改成 `gen_server`
2. 增加自动心跳
3. 增加断线重连
4. 支持分片消息
5. 支持 `wss://`
