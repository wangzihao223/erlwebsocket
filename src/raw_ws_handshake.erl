-module(raw_ws_handshake).

-export([client/5]).

-ifdef(TEST).
-export([read_response/3]).
-endif.

-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(MAX_HEADER_SIZE, 8192).

-type headers() :: #{binary() => binary()}.
-type handshake_result() :: {ok, binary()} | {error, term()}.

%% 客户端握手入口：发送 HTTP Upgrade 请求，并校验服务端 101 响应。
-spec client(gen_tcp:socket(), unicode:chardata(), inet:port_number(),
    unicode:chardata(),
    timeout()) ->
    handshake_result().
client(Socket, Host, Port, Path, Timeout) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    Request = request(Host, Port, Path, Key),
    case gen_tcp:send(Socket, Request) of
        ok ->
            read_and_validate(Socket, Key, Timeout);
        {error, Reason} ->
            {error, {handshake_send_failed, Reason}}
    end.

%% 构造 WebSocket HTTP Upgrade 请求头。
%% Sec-WebSocket-Key 是客户端随机生成的值，后续用于校验 Sec-WebSocket-Accept。
-spec request(unicode:chardata(), inet:port_number(), unicode:chardata(), binary()) -> iolist().
request(Host, Port, Path, Key) ->
    HostBin = format_host(Host),
    PathBin = unicode:characters_to_binary(Path),
    [
        <<"GET ">>, PathBin, <<" HTTP/1.1\r\n">>,
        <<"Host: ">>, HostBin, <<":">>, integer_to_binary(Port), <<"\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
        <<"Sec-WebSocket-Version: 13\r\n">>,
        <<"\r\n">>
    ].

%% 读取服务端 HTTP 响应并校验握手字段。
-spec read_and_validate(gen_tcp:socket(), binary(), timeout()) -> handshake_result().
read_and_validate(Socket, Key, Timeout) ->
    case read_response(Socket, <<>>, Timeout) of
        {ok, HeaderBlock, Rest} ->
            validate_response(HeaderBlock, Key, Rest);
        {error, Reason} ->
            {error, {handshake_read_failed, Reason}}
    end.

%% 读取 HTTP 响应头，直到遇到 \r\n\r\n。
%% 如果响应头后面已经带了 WebSocket frame 字节，会把它们作为 Rest 返回。
-spec read_response(gen_tcp:socket() | undefined, binary(), timeout()) ->
    {ok, binary(), binary()} | {error, term()}.
read_response(_Socket, Acc, _Timeout)
    when byte_size(Acc) > ?MAX_HEADER_SIZE ->
    {error, header_too_large};
read_response(Socket, Acc, Timeout) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, 4} ->
            HeaderSize = Pos + 4,
            <<HeaderBlock:HeaderSize/binary, Rest/binary>> = Acc,
            {ok, HeaderBlock, Rest};
        nomatch ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, Data} when byte_size(Acc) + byte_size(Data) =< ?MAX_HEADER_SIZE ->
                    read_response(Socket, <<Acc/binary, Data/binary>>, Timeout);
                {ok, _Data} ->
                    {error, header_too_large};
                Error ->
                    Error
            end
    end.

%% 校验 HTTP 状态码、Upgrade、Connection 和 Sec-WebSocket-Accept。
-spec validate_response(binary(), binary(), binary()) -> handshake_result().
validate_response(HeaderBlock, Key, Rest) ->
    Lines = binary:split(HeaderBlock, <<"\r\n">>, [global, trim_all]),
    case Lines of
        [StatusLine | HeaderLines] ->
            Headers = parse_headers(HeaderLines),
            case valid_status(StatusLine)
                andalso valid_upgrade(Headers)
                andalso valid_connection(Headers)
                andalso valid_accept(Headers, Key)
            of
                true ->
                    {ok, Rest};
                false ->
                    {error, {bad_handshake_response, StatusLine, Headers}}
            end;
        [] ->
            {error, empty_handshake_response}
    end.

-spec valid_status(binary()) -> boolean().
valid_status(<<"HTTP/1.1 101", _/binary>>) ->
    true;
valid_status(<<"HTTP/1.0 101", _/binary>>) ->
    true;
valid_status(_) ->
    false.

%% 把 header 名统一转成小写，方便后续大小写不敏感地查找。
-spec parse_headers([binary()]) -> headers().
parse_headers(Lines) ->
    lists:foldl(fun parse_header/2, #{}, Lines).

-spec parse_header(binary(), headers()) -> headers().
parse_header(Line, Acc) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            maps:put(lower_ascii(trim(Name)), trim(Value), Acc);
        _ ->
            Acc
    end.

%% Upgrade 必须是 websocket。
-spec valid_upgrade(headers()) -> boolean().
valid_upgrade(Headers) ->
    case maps:get(<<"upgrade">>, Headers, undefined) of
        undefined -> false;
            Value -> lower_ascii(Value) =:= <<"websocket">>
    end.

%% Connection 头里必须包含 upgrade。
-spec valid_connection(headers()) -> boolean().
valid_connection(Headers) ->
    case maps:get(<<"connection">>, Headers, undefined) of
        undefined ->
            false;
        Value ->
            binary:match(lower_ascii(Value), <<"upgrade">>) =/= nomatch
    end.

%% Sec-WebSocket-Accept 必须等于 base64(sha1(Key ++ GUID))。
-spec valid_accept(headers(), binary()) -> boolean().
valid_accept(Headers, Key) ->
    Expected = base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID/binary>>)),
    maps:get(<<"sec-websocket-accept">>, Headers, undefined) =:= Expected.

-spec trim(binary()) -> binary().
trim(Bin)->
    trim_left(trim_right(Bin)).


-spec trim_left(binary()) -> binary().
trim_left(<<C, Rest/binary>>) when C=:=$\s; C =:= $\t ->
    trim_left(Rest);
trim_left(Bin) ->
    Bin.


-spec trim_right(binary()) -> binary().
trim_right(Bin) ->
    trim_right(Bin, byte_size(Bin)).

-spec trim_right(binary(), non_neg_integer()) -> binary().
trim_right(_Bin, 0) ->
    <<>>;
trim_right(Bin, Size) ->
    case binary:at(Bin, Size-1) of
        C when C =:= $\s; C =:= $\t ->
            trim_right(Bin, Size-1);
        _ ->
            binary:part(Bin, 0, Size)
    end.

-spec lower_ascii(binary()) -> binary().
lower_ascii(Bin) ->
    << <<(lower_ascii_char(C))>> || <<C>> <= Bin >>.

-spec lower_ascii_char(byte()) -> byte().
lower_ascii_char(C) when C >=$A, C=<$Z ->
    C+32;
lower_ascii_char(C) ->
    C.

format_host(Host) when is_binary(Host) ->
    Host;
format_host(Host) when is_list(Host) ->
    unicode:characters_to_binary(Host);
format_host({A, B, C, D}) ->
    iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A, B, C, D]));
format_host({A, B, C, D, E, F, G, H}) ->
    iolist_to_binary(io_lib:format("[~.16B:~.16B:~.16B:~.16B:~.16B:~.16B:~.16B:~.16B]",
        [
          A, B, C, D, E, F, G, H
        ])).