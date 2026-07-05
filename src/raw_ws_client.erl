-module(raw_ws_client).

-export([
    connect/3,
    connect/4,
    send_text/2,
    send_binary/2,
    send_ping/1,
    close/1,
    recv/1
]).

-include("../include/raw_ws.hrl").

%% 客户端连接状态。
%% buffer 保存上一次读取后剩余的字节；fragments 保存正在重组的分片消息。
-record(ws, {
    socket,
    buffer = <<>>,
    timeout = 5000,
    fragments = undefined
}).

-type ws() :: #ws{}.
-type connect_option() :: {timeout, timeout()}.
-type event() ::
    {text, binary()}
    | {binary, binary()}
    | {ping, binary()}
    | {pong, binary()}
    | {close, undefined | non_neg_integer() | malformed, binary()}.
-type recv_result() :: {ok, event(), ws()} | {error, term()} | {error, term(), ws()}.

%% 建立 TCP 连接并完成 WebSocket HTTP Upgrade 握手。
-spec connect(inet:hostname() | inet:ip_address(), inet:port_number(), unicode:chardata()) ->
    {ok, ws()} | {error, term()}.
connect(Host, Port, Path) ->
    connect(Host, Port, Path, []).

-spec connect(inet:hostname() | inet:ip_address(), inet:port_number(), unicode:chardata(),
    [connect_option()]) -> {ok, ws()} | {error, term()}.
connect(Host, Port, Path, Options) ->
    Timeout = proplists:get_value(timeout, Options, 5000),
    TcpOptions = [
        binary,
        {packet, raw},
        {active, false},
        {nodelay, true}
    ],
    case gen_tcp:connect(Host, Port, TcpOptions, Timeout) of
        {ok, Socket} ->
            case raw_ws_handshake:client(Socket, Host, Port, Path, Timeout) of
                {ok, Rest} ->
                    {ok, #ws{socket = Socket, buffer = Rest, timeout = Timeout}};
                Error ->
                    gen_tcp:close(Socket),
                    Error
            end;
        Error ->
            Error
    end.

%% 发送文本消息。当前高级 API 默认发一个完整 frame，不主动按大小分片。
-spec send_text(ws(), unicode:chardata()) -> ok | {error, term()}.
send_text(#ws{socket = Socket}, Text) ->
    Payload = unicode:characters_to_binary(Text),
    gen_tcp:send(Socket, raw_ws_frame:encode(text, Payload)).

%% 发送二进制消息。Payload 可以是 binary 或 iolist。
-spec send_binary(ws(), iodata()) -> ok | {error, term()}.
send_binary(#ws{socket = Socket}, Payload) ->
    gen_tcp:send(Socket, raw_ws_frame:encode(binary, Payload)).

%% 发送 ping 控制帧。
-spec send_ping(ws()) -> ok | {error, term()}.
send_ping(#ws{socket = Socket}) ->
    gen_tcp:send(Socket, raw_ws_frame:encode(ping, <<>>)).

%% 主动发送 close 帧，然后关闭 TCP socket。
-spec close(ws()) -> ok.
close(#ws{socket = Socket}) ->
    _ = gen_tcp:send(Socket, raw_ws_frame:encode(close, <<>>)),
    gen_tcp:close(Socket).

%% 接收一个业务事件。
%% 如果读到分片消息的中间片，会继续读取后续 continuation，直到拼出完整消息。
-spec recv(ws()) -> recv_result().
recv(State = #ws{socket = Socket, buffer = Buffer, timeout = Timeout}) ->
    case raw_ws_frame:read(Socket, Buffer, Timeout) of
        {ok, Frame, Rest} ->
            handle_frame(State#ws{buffer = Rest}, Frame);
        {error, Reason} ->
            {error, Reason, State}
    end.

%% 根据 opcode 处理单个 frame。
%% text/binary 分片会暂存在 State#ws.fragments，最后一个 continuation 到达后再返回事件。
-spec handle_frame(ws(), #ws_frame{}) -> recv_result().
handle_frame(State = #ws{fragments = undefined}, #ws_frame{fin = true, opcode = ?OP_TEXT, payload = Payload}) ->
    {ok, {text, Payload}, State};
handle_frame(State = #ws{fragments = undefined}, #ws_frame{fin = true, opcode = ?OP_BINARY, payload = Payload}) ->
    {ok, {binary, Payload}, State};
handle_frame(State = #ws{fragments = undefined}, #ws_frame{fin = false, opcode = ?OP_TEXT, payload = Payload}) ->
    recv(State#ws{fragments = {text, [Payload]}});
handle_frame(State = #ws{fragments = undefined}, #ws_frame{fin = false, opcode = ?OP_BINARY, payload = Payload}) ->
    recv(State#ws{fragments = {binary, [Payload]}});
handle_frame(State = #ws{fragments = undefined}, #ws_frame{opcode = ?OP_CONTINUATION, payload = Payload}) ->
    {error, {unexpected_continuation, Payload}, State};
handle_frame(State = #ws{fragments = {Type, Parts}}, #ws_frame{fin = false, opcode = ?OP_CONTINUATION, payload = Payload}) ->
    recv(State#ws{fragments = {Type, [Payload | Parts]}});
handle_frame(State = #ws{fragments = {Type, Parts}}, #ws_frame{fin = true, opcode = ?OP_CONTINUATION, payload = Payload}) ->
    FullPayload = iolist_to_binary(lists:reverse([Payload | Parts])),
    {ok, {Type, FullPayload}, State#ws{fragments = undefined}};
handle_frame(State = #ws{fragments = Fragments}, #ws_frame{opcode = ?OP_TEXT, payload = Payload})
        when Fragments =/= undefined ->
    {error, {fragment_interrupted, ?OP_TEXT, Payload}, State};
handle_frame(State = #ws{fragments = Fragments}, #ws_frame{opcode = ?OP_BINARY, payload = Payload})
        when Fragments =/= undefined ->
    {error, {fragment_interrupted, ?OP_BINARY, Payload}, State};
handle_frame(State = #ws{socket = Socket}, #ws_frame{opcode = ?OP_PING, payload = Payload}) ->
    ok = gen_tcp:send(Socket, raw_ws_frame:encode(pong, Payload)),
    {ok, {ping, Payload}, State};
handle_frame(State, #ws_frame{opcode = ?OP_PONG, payload = Payload}) ->
    {ok, {pong, Payload}, State};
handle_frame(State = #ws{socket = Socket}, #ws_frame{opcode = ?OP_CLOSE, payload = Payload}) ->
    _ = gen_tcp:send(Socket, raw_ws_frame:encode(close, Payload)),
    gen_tcp:close(Socket),
    {ok, parse_close(Payload), State};
handle_frame(State, #ws_frame{opcode = Opcode, payload = Payload}) ->
    {error, {unsupported_opcode, Opcode, Payload}, State}.

%% close 帧的 payload 可以为空，也可以是 2 字节状态码 + 原因文本。
-spec parse_close(binary()) -> {close, undefined | non_neg_integer() | malformed, binary()}.
parse_close(<<Code:16/big, Reason/binary>>) ->
    {close, Code, Reason};
parse_close(<<>>) ->
    {close, undefined, <<>>};
parse_close(Reason) ->
    {close, malformed, Reason}.
