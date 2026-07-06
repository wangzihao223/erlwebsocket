-module(raw_ws_frame).

-export([encode/2, encode/3, try_encode/2, try_encode/3, decode/1, read/3]).

-include("../include/raw_ws.hrl").

%% WebSocket 帧类型和 opcode 的对应关系：
%% continuation=0, text=1, binary=2, close=8, ping=9, pong=10。
-type frame_type() :: continuation | text | binary | close | ping | pong.
-type opcode() :: 0..15.
-type decode_result() :: {ok, #ws_frame{}, binary()} | {more, binary()} | {error, term()}.
-type read_result() :: {ok, #ws_frame{}, binary()} | {error, term()}.
-type encode_result() :: {ok, binary()} | {error, term()}.
-type read_socket() :: gen_tcp:socket() | undefined.
-type mask_key() :: <<_:32>>.
-type mask_key_tuple() :: {byte(), byte(), byte(), byte()}.

%% 编码一个完整 WebSocket 帧，默认 FIN=true，表示这不是分片消息的中间片。
-spec encode(frame_type() | opcode(), iodata()) -> binary().
encode(Type, Payload) ->
    encode(true, Type, Payload).

%% 编码一个可指定 FIN 的 WebSocket 帧。
%% 分片发送时，第一片使用 text/binary 且 Fin=false；
%% 后续片使用 continuation，最后一片 Fin=true。
-spec encode(boolean(), frame_type() | opcode(), iodata()) -> binary().
encode(Fin, Type, Payload0) when is_boolean(Fin) ->
    Opcode = opcode(Type),
    Payload = iolist_to_binary(Payload0),
    Len = byte_size(Payload),
    assert_encode_allowed(Fin, Opcode, Len),
    encode_frame(Fin, Opcode, Payload, Len).

-spec opcode(frame_type() | opcode()) -> opcode().
opcode(continuation) -> ?OP_CONTINUATION;
opcode(text) -> ?OP_TEXT;
opcode(binary) -> ?OP_BINARY;
opcode(close) -> ?OP_CLOSE;
opcode(ping) -> ?OP_PING;
opcode(pong) -> ?OP_PONG;
opcode(Opcode) when is_integer(Opcode), Opcode >= 0, Opcode =< 15 ->
    Opcode;
opcode(Type) ->
    error({bad_opcode, Type}).

-spec validate_data_opcode(opcode()) -> ok | {error, term()}.
validate_data_opcode(Opcode)
        when Opcode =:= ?OP_CONTINUATION;
             Opcode =:= ?OP_TEXT;
             Opcode =:= ?OP_BINARY;
             Opcode =:= ?OP_CLOSE;
             Opcode =:= ?OP_PING;
             Opcode =:= ?OP_PONG ->
    ok;
validate_data_opcode(Opcode) ->
    {error, {unsupported_opcode, Opcode}}.

-spec assert_encode_allowed(boolean(), opcode(), non_neg_integer()) -> ok.
assert_encode_allowed(Fin, Opcode, Len) ->
    case validate_encode_allowed(Fin, Opcode, Len) of
        ok ->
            ok;
        {error, Reason} ->
            error(Reason)
    end.

-spec validate_encode_allowed(boolean(), opcode(), non_neg_integer()) -> ok | {error, term()}.
validate_encode_allowed(Fin, Opcode, Len) ->
    case validate_data_opcode(Opcode) of
        ok ->
            validate_control_frame(Fin, Opcode, Len);
        {error, _Reason} = Error ->
            Error
    end.

-spec encode_frame(boolean(), opcode(), binary(), non_neg_integer()) -> binary().
encode_frame(Fin, Opcode, Payload, Len) ->
    %% 第一个字节：最高位是 FIN，低 4 位是 opcode。
    FinBit =
        case Fin of
            true -> ?FIN_BIT;
            false -> 0
        end,
    FinAndOpcode = FinBit bor Opcode,
    %% 客户端发给服务端的帧必须带 mask，所以第二个字节最高位固定为 1。
    MaskBit = ?MASK_BIT,
    MaskKey = crypto:strong_rand_bytes(4),
    MaskedPayload = mask(Payload, MaskKey),
    %% payload 长度小于 126 时直接写入第二个字节；
    %% 126 表示后面跟 16 位长度，127 表示后面跟 64 位长度。
    case Len of
        _ when Len < ?PAYLOAD_LEN_16 ->
            <<FinAndOpcode, (MaskBit bor Len), MaskKey/binary, MaskedPayload/binary>>;
        _ when Len < 65536 ->
            <<FinAndOpcode, (MaskBit bor ?PAYLOAD_LEN_16), Len:16/big, MaskKey/binary, MaskedPayload/binary>>;
        _ ->
            <<FinAndOpcode, (MaskBit bor ?PAYLOAD_LEN_64), Len:64/big, MaskKey/binary, MaskedPayload/binary>>
    end.

-spec try_encode(frame_type() | opcode(), iodata()) -> encode_result().
try_encode(Type, Payload) ->
    try_encode(true, Type, Payload).

-spec try_encode(boolean(), frame_type() | opcode(), iodata()) -> encode_result().
try_encode(Fin, Type, Payload0) when is_boolean(Fin) ->
    try
        Opcode = opcode(Type),
        Payload = iolist_to_binary(Payload0),
        Len = byte_size(Payload),
        case validate_encode_allowed(Fin, Opcode, Len) of
            ok ->
                {ok, encode_frame(Fin, Opcode, Payload, Len)};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        error:ErrorReason ->
            {error, ErrorReason}
    end;
try_encode(Fin, _Type, _Payload) ->
    {error, {bad_fin, Fin}}.

%% 从已有二进制 Buffer 中非阻塞解析一个完整 frame。
%% active once 模式下不能在解析函数里 gen_tcp:recv，所以数据不够时返回 {more, Buffer}。
-spec decode(binary()) -> decode_result().
decode(Buffer) when byte_size(Buffer) < 2 ->
    {more, Buffer};
decode(Buffer = <<B1, B2, Rest1/binary>>) ->
    Fin = (B1 band ?FIN_BIT) =/= 0,
    Rsv = (B1 band ?RSV_MASK) bsr 4,
    Opcode = B1 band ?OPCODE_MASK,
    Masked = (B2 band ?MASK_BIT) =/= 0,
    Len0 = B2 band ?PAYLOAD_LEN_MASK,
    maybe
        ok ?= validate_rsv(Rsv),
        {ok, Len, Rest2} ?= decode_length(Len0, Rest1),
        ok ?= validate_control_frame(Fin, Opcode, Len),
        {ok, Frame, Rest} ?= decode_payload(Rest2, Fin, Rsv, Opcode, Masked, Len),
        {ok, Frame, Rest}
    else
        {more, _Partial} ->
            {more, Buffer};
        Error ->
            Error
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
    Fin = (B1 band ?FIN_BIT) =/= 0,
    Rsv = (B1 band ?RSV_MASK) bsr 4,
    Opcode = B1 band ?OPCODE_MASK,
    Masked = (B2 band ?MASK_BIT) =/= 0,
    Len0 = B2 band ?PAYLOAD_LEN_MASK,
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
is_control_opcode(?OP_CLOSE) -> true;
is_control_opcode(?OP_PING) -> true;
is_control_opcode(?OP_PONG) -> true;
is_control_opcode(_) -> false.

%% active once 模式下只从 Buffer 读取长度字段；不够就等待下一次 {tcp, Socket, Data}。
-spec decode_length(non_neg_integer(), binary()) ->
    {ok, non_neg_integer(), binary()} | {more, binary()}.
decode_length(Len, Rest) when Len < ?PAYLOAD_LEN_16 ->
    {ok, Len, Rest};
decode_length(?PAYLOAD_LEN_16, Rest) when byte_size(Rest) < 2 ->
    {more, Rest};
decode_length(?PAYLOAD_LEN_16, <<Len:16/big, Rest/binary>>) ->
    {ok, Len, Rest};
decode_length(?PAYLOAD_LEN_64, Rest) when byte_size(Rest) < 8 ->
    {more, Rest};
decode_length(?PAYLOAD_LEN_64, <<Len:64/big, Rest/binary>>) ->
    {ok, Len, Rest}.

%% 根据第二个字节里的长度标记读取真实 payload 长度。
-spec read_length(read_socket(), non_neg_integer(), binary(), timeout()) ->
    {ok, non_neg_integer(), binary()} | {error, term()}.
read_length(_Socket, Len, Rest, _Timeout) when Len < ?PAYLOAD_LEN_16 ->
    {ok, Len, Rest};
read_length(Socket, ?PAYLOAD_LEN_16, Rest, Timeout) ->
    case take(Socket, Rest, 2, Timeout) of
        {ok, <<Len:16/big>>, Rest2} -> {ok, Len, Rest2};
        Error -> Error
    end;
read_length(Socket, ?PAYLOAD_LEN_64, Rest, Timeout) ->
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

%% active once 模式下只从 Buffer 读取 payload；不够就等待更多 TCP 数据。
-spec decode_payload(binary(), boolean(), 0..7, opcode(), boolean(), non_neg_integer()) ->
    decode_result().
decode_payload(Rest, _Fin, _Rsv, _Opcode, true, Len) when byte_size(Rest) < 4 + Len ->
    {more, Rest};
decode_payload(<<MaskKey:4/binary, Rest/binary>>, Fin, Rsv, Opcode, true, Len) ->
    <<Payload0:Len/binary, Rest2/binary>> = Rest,
    Payload = mask(Payload0, MaskKey),
    {ok, #ws_frame{
        fin = Fin,
        rsv = Rsv,
        opcode = Opcode,
        masked = true,
        payload = Payload
    }, Rest2};
decode_payload(Rest, _Fin, _Rsv, _Opcode, false, Len) when byte_size(Rest) < Len ->
    {more, Rest};
decode_payload(Rest, Fin, Rsv, Opcode, false, Len) ->
    <<Payload:Len/binary, Rest2/binary>> = Rest,
    {ok, #ws_frame{
        fin = Fin,
        rsv = Rsv,
        opcode = Opcode,
        masked = false,
        payload = Payload
    }, Rest2}.

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
