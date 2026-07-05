-module(raw_ws_frame).

-export([encode/2, encode/3, read/3]).

-include("../include/raw_ws.hrl").

%% WebSocket 帧类型和 opcode 的对应关系：
%% continuation=0, text=1, binary=2, close=8, ping=9, pong=10。
-type frame_type() :: continuation | text | binary | close | ping | pong.
-type opcode() :: 0..15.
-type read_result() :: {ok, #ws_frame{}, binary()} | {error, term()}.
-type read_socket() :: gen_tcp:socket() | undefined.
-type mask_key() :: <<_:32>>.
-type mask_key_tuple() :: {byte(), byte(), byte(), byte()}.

%% 编码一个完整 WebSocket 帧，默认 FIN=true，表示这不是分片消息的中间片。
-spec encode(frame_type() | opcode(), iodata()) -> binary().
encode(text, Payload) ->
    encode(true, text, Payload);
encode(binary, Payload) ->
    encode(true, binary, Payload);
encode(close, Payload) ->
    encode(true, close, Payload);
encode(ping, Payload) ->
    encode(true, ping, Payload);
encode(pong, Payload) ->
    encode(true, pong, Payload);
encode(Opcode, Payload) when is_integer(Opcode) ->
    encode(true, Opcode, Payload).

%% 编码一个可指定 FIN 的 WebSocket 帧。
%% 分片发送时，第一片使用 text/binary 且 Fin=false；
%% 后续片使用 continuation，最后一片 Fin=true。
-spec encode(boolean(), frame_type() | opcode(), iodata()) -> binary().
encode(Fin, continuation, Payload) ->
    encode(Fin, 16#0, Payload);
encode(Fin, text, Payload) ->
    encode(Fin, 16#1, Payload);
encode(Fin, binary, Payload) ->
    encode(Fin, 16#2, Payload);
encode(Fin, close, Payload) ->
    encode(Fin, 16#8, Payload);
encode(Fin, ping, Payload) ->
    encode(Fin, 16#9, Payload);
encode(Fin, pong, Payload) ->
    encode(Fin, 16#A, Payload);
encode(Fin, Opcode, Payload0) when is_boolean(Fin), is_integer(Opcode) ->
    Payload = iolist_to_binary(Payload0),
    Len = byte_size(Payload),
    %% 第一个字节：最高位是 FIN，低 4 位是 opcode。
    FinBit =
        case Fin of
            true -> 16#80;
            false -> 0
        end,
    FinAndOpcode = FinBit bor Opcode,
    %% 客户端发给服务端的帧必须带 mask，所以第二个字节最高位固定为 1。
    MaskBit = 16#80,
    MaskKey = crypto:strong_rand_bytes(4),
    MaskedPayload = mask(Payload, MaskKey),
    %% payload 长度小于 126 时直接写入第二个字节；
    %% 126 表示后面跟 16 位长度，127 表示后面跟 64 位长度。
    case Len of
        _ when Len < 126 ->
            <<FinAndOpcode, (MaskBit bor Len), MaskKey/binary, MaskedPayload/binary>>;
        _ when Len < 65536 ->
            <<FinAndOpcode, (MaskBit bor 126), Len:16/big, MaskKey/binary, MaskedPayload/binary>>;
        _ ->
            <<FinAndOpcode, (MaskBit bor 127), Len:64/big, MaskKey/binary, MaskedPayload/binary>>
    end.

%% 从已有 Buffer 和 Socket 中读取一个完整 frame。
%% 如果 Buffer 里有多余字节，会作为 Rest 返回给下一次解析。
-spec read(read_socket(), binary(), timeout()) -> read_result().
read(Socket, Buffer, Timeout) ->
    case take(Socket, Buffer, 2, Timeout) of
        {ok, <<B1, B2>>, Rest1} ->
            parse_header(Socket, B1, B2, Rest1, Timeout);
        Error ->
            Error
    end.

%% 解析 WebSocket 帧头的前两个字节：FIN/RSV/opcode/MASK/长度标记。
-spec parse_header(read_socket(), byte(), byte(), binary(), timeout()) -> read_result().
parse_header(Socket, B1, B2, Rest1, Timeout) ->
    Fin = (B1 band 16#80) =/= 0,
    Rsv = (B1 band 16#70) bsr 4,
    Opcode = B1 band 16#0F,
    Masked = (B2 band 16#80) =/= 0,
    Len0 = B2 band 16#7F,
    case validate_rsv(Rsv) of
        ok ->
            case read_length(Socket, Len0, Rest1, Timeout) of
                {ok, Len, Rest2} ->
                    case validate_control_frame(Fin, Opcode, Len) of
                        ok ->
                            read_mask_and_payload(Socket, Rest2, Timeout, Fin, Rsv, Opcode, Masked, Len);
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% 当前客户端没有协商任何扩展，所以 RSV1/RSV2/RSV3 必须全是 0。
-spec validate_rsv(0..7) -> ok | {error, term()}.
validate_rsv(0) ->
    ok;
validate_rsv(Rsv) ->
    {error, {unsupported_rsv, Rsv}}.

%% close/ping/pong 是控制帧：不能分片，payload 长度不能超过 125。
-spec validate_control_frame(boolean(), opcode(), non_neg_integer()) -> ok | {error, term()}.
validate_control_frame(Fin, Opcode, Len) ->
    case is_control_opcode(Opcode) of
        true when Fin =:= false ->
            {error, {fragmented_control_frame, Opcode}};
        true when Len > 125 ->
            {error, {control_frame_too_large, Opcode, Len}};
        _ ->
            ok
    end.

-spec is_control_opcode(opcode()) -> boolean().
is_control_opcode(16#8) -> true;
is_control_opcode(16#9) -> true;
is_control_opcode(16#A) -> true;
is_control_opcode(_) -> false.

%% 根据第二个字节里的长度标记读取真实 payload 长度。
-spec read_length(read_socket(), non_neg_integer(), binary(), timeout()) ->
    {ok, non_neg_integer(), binary()} | {error, term()}.
read_length(_Socket, Len, Rest, _Timeout) when Len < 126 ->
    {ok, Len, Rest};
read_length(Socket, 126, Rest, Timeout) ->
    case take(Socket, Rest, 2, Timeout) of
        {ok, <<Len:16/big>>, Rest2} -> {ok, Len, Rest2};
        Error -> Error
    end;
read_length(Socket, 127, Rest, Timeout) ->
    case take(Socket, Rest, 8, Timeout) of
        {ok, <<Len:64/big>>, Rest2} -> {ok, Len, Rest2};
        Error -> Error
    end.

%% 如果 frame 带 mask，先读取 4 字节 mask key，再读取 payload。
-spec read_mask_and_payload(read_socket(), binary(), timeout(), boolean(), 0..7,
    opcode(), boolean(), non_neg_integer()) -> read_result().
read_mask_and_payload(Socket, Rest, Timeout, Fin, Rsv, Opcode, true, Len) ->
    case take(Socket, Rest, 4, Timeout) of
        {ok, MaskKey, Rest2} ->
            read_payload(Socket, Rest2, Timeout, Fin, Rsv, Opcode, Len, MaskKey);
        Error ->
            Error
    end;
read_mask_and_payload(Socket, Rest, Timeout, Fin, Rsv, Opcode, false, Len) ->
    read_payload(Socket, Rest, Timeout, Fin, Rsv, Opcode, Len, undefined).

%% 读取 payload，并在有 mask key 时做一次 XOR 还原原始数据。
-spec read_payload(read_socket(), binary(), timeout(), boolean(), 0..7,
    opcode(), non_neg_integer(), mask_key() | undefined) -> read_result().
read_payload(Socket, Rest, Timeout, Fin, Rsv, Opcode, Len, MaskKey) ->
    case take(Socket, Rest, Len, Timeout) of
        {ok, Payload0, Rest2} ->
            Payload =
                case MaskKey of
                    undefined -> Payload0;
                    _ -> mask(Payload0, MaskKey)
                end,
            {ok, #ws_frame{
                fin = Fin,
                rsv = Rsv,
                opcode = Opcode,
                masked = MaskKey =/= undefined,
                payload = Payload
            }, Rest2};
        Error ->
            Error
    end.

%% 从 Buffer 中取 N 字节；不够时继续从 TCP socket 读取并拼到 Buffer 后面。
-spec take(read_socket(), binary(), non_neg_integer(), timeout()) ->
    {ok, binary(), binary()} | {error, term()}.
take(_Socket, Buffer, N, _Timeout) when byte_size(Buffer) >= N ->
    <<Part:N/binary, Rest/binary>> = Buffer,
    {ok, Part, Rest};
take(Socket, Buffer, N, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            take(Socket, <<Buffer/binary, Data/binary>>, N, Timeout);
        Error ->
            Error
    end.

%% WebSocket mask 算法：payload 每个字节和 4 字节 mask key 循环 XOR。
%% XOR 两次会还原，所以 encode 和 decode 都可以复用这个函数。
-spec mask(binary(), mask_key()) -> binary().
mask(Payload, <<K1, K2, K3, K4>>) ->
    mask(Payload, {K1, K2, K3, K4}, 0, []).

-spec mask(binary(), mask_key_tuple(), non_neg_integer(), iolist()) -> binary().
mask(<<>>, _Key, _Index, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
mask(<<Byte, Rest/binary>>, Key, Index, Acc) ->
    MaskByte =
        case Index rem 4 of
            0 -> element(1, Key);
            1 -> element(2, Key);
            2 -> element(3, Key);
            3 -> element(4, Key)
        end,
    mask(Rest, Key, Index + 1, [Byte bxor MaskByte | Acc]).
