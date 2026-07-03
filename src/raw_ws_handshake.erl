-module(raw_ws_handshake).

-export([client/5]).

-ifdef(TEST).
-export([read_response/3]).
-endif.

-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(MAX_HEADER_SIZE, 8192).

-spec client(gen_tcp:socket(), unicode:chardata(), inet:port_number(),
    unicode:chardata(),
    timeout()) ->
    {ok, binary()} | {error, term()}.
client(Socket, Host, Port, Path, Timeout) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    Request = request(Host, Port, Path, Key),
    case gen_tcp:send(Socket, Request) of
        ok ->
            read_and_validate(Socket, Key, Timeout);
        {error, Reason} ->
            {error, {handshake_send_failed, Reason}}
    end.

% http 请求头
request(Host, Port, Path, Key) ->
    [
        <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
        <<"Host: ">>, Host, <<":">>, integer_to_binary(Port), <<"\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
        <<"Sec-WebSocket-Version: 13\r\n">>,
        <<"\r\n">>
    ].

read_and_validate(Socket, Key, Timeout) ->
    case read_response(Socket, <<>>, Timeout) of
        {ok, HeaderBlock, Rest} ->
            validate_response(HeaderBlock, Key, Rest);
        {error, Reason} ->
            {error, {handshake_read_failed, Reason}}
    end.

% 读取响应头
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

valid_status(<<"HTTP/1.1 101", _/binary>>) ->
    true;
valid_status(<<"HTTP/1.0 101", _/binary>>) ->
    true;
valid_status(_) ->
    false.

parse_headers(Lines) ->
    lists:foldl(fun parse_header/2, #{}, Lines).

parse_header(Line, Acc) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            maps:put(lower_ascii(trim(Name)), trim(Value), Acc);
        _ ->
            Acc
    end.

valid_upgrade(Headers) ->
    case maps:get(<<"upgrade">>, Headers, undefined) of
        undefined -> false;
        Value -> lower_ascii(Value) =:= <<"websocket">>
    end.

valid_connection(Headers) ->
    case maps:get(<<"connection">>, Headers, undefined) of
        undefined ->
            false;
        Value ->
            binary:match(lower_ascii(Value), <<"upgrade">>) =/= nomatch
    end.

valid_accept(Headers, Key) ->
    Expected = base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID/binary>>)),
    maps:get(<<"sec-websocket-accept">>, Headers, undefined) =:= Expected.

-spec trim(binary()) -> binary().
trim(Bin)->
    trim_left(trim_right(Bin)).


trim_left(<<C, Rest/binary>>) when C=:=$\s; C =:= $\t ->
    trim_left(Rest);
trim_left(Bin) ->
    Bin.


-spec trim_right(binary()) -> binary().
trim_right(Bin) ->
    trim_right(Bin, byte_size(Bin)).

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

lower_ascii_char(C) when C >=$A, C=<$Z ->
    C+32;
lower_ascii_char(C) ->
    C.
