-module(raw_ws_frame).

-export([encode/2, read/3]).

encode(text, Payload) ->
    encode(16#1, Payload);
encode(binary, Payload) ->
    encode(16#2, Payload);
encode(close, Payload) ->
    encode(16#8, Payload);
encode(ping, Payload) ->
    encode(16#9, Payload);
encode(pong, Payload) ->
    encode(16#A, Payload);
encode(Opcode, Payload0) when is_integer(Opcode) ->
    Payload = iolist_to_binary(Payload0),
    Len = byte_size(Payload),
    FinAndOpcode = 16#80 bor Opcode,
    MaskBit = 16#80,
    MaskKey = crypto:strong_rand_bytes(4),
    MaskedPayload = mask(Payload, MaskKey),
    case Len of
        _ when Len < 126 ->
            <<FinAndOpcode, (MaskBit bor Len), MaskKey/binary, MaskedPayload/binary>>;
        _ when Len < 65536 ->
            <<FinAndOpcode, (MaskBit bor 126), Len:16/big, MaskKey/binary, MaskedPayload/binary>>;
        _ ->
            <<FinAndOpcode, (MaskBit bor 127), Len:64/big, MaskKey/binary, MaskedPayload/binary>>
    end.

read(Socket, Buffer, Timeout) ->
    case take(Socket, Buffer, 2, Timeout) of
        {ok, <<B1, B2>>, Rest1} ->
            parse_header(Socket, B1, B2, Rest1, Timeout);
        Error ->
            Error
    end.

parse_header(Socket, B1, B2, Rest1, Timeout) ->
    Fin = (B1 band 16#80) =/= 0,
    Rsv = (B1 band 16#70) bsr 4,
    Opcode = B1 band 16#0F,
    Masked = (B2 band 16#80) =/= 0,
    Len0 = B2 band 16#7F,
    case read_length(Socket, Len0, Rest1, Timeout) of
        {ok, Len, Rest2} ->
            read_mask_and_payload(Socket, Rest2, Timeout, Fin, Rsv, Opcode, Masked, Len);
        Error ->
            Error
    end.

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

read_mask_and_payload(Socket, Rest, Timeout, Fin, Rsv, Opcode, true, Len) ->
    case take(Socket, Rest, 4, Timeout) of
        {ok, MaskKey, Rest2} ->
            read_payload(Socket, Rest2, Timeout, Fin, Rsv, Opcode, Len, MaskKey);
        Error ->
            Error
    end;
read_mask_and_payload(Socket, Rest, Timeout, Fin, Rsv, Opcode, false, Len) ->
    read_payload(Socket, Rest, Timeout, Fin, Rsv, Opcode, Len, undefined).

read_payload(Socket, Rest, Timeout, Fin, Rsv, Opcode, Len, MaskKey) ->
    case take(Socket, Rest, Len, Timeout) of
        {ok, Payload0, Rest2} ->
            Payload =
                case MaskKey of
                    undefined -> Payload0;
                    _ -> mask(Payload0, MaskKey)
                end,
            {ok, #{fin => Fin, rsv => Rsv, opcode => Opcode, payload => Payload}, Rest2};
        Error ->
            Error
    end.

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

mask(Payload, <<K1, K2, K3, K4>>) ->
    mask(Payload, {K1, K2, K3, K4}, 0, []).

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

