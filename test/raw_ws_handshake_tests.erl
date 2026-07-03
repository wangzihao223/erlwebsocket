-module(raw_ws_handshake_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).

successful_handshake_test() ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(Listen),
    DoneRef = make_ref(),
    Parent = self(),
    spawn_link(fun() -> handshake_server(Listen, Parent, DoneRef, <<>>) end),

    {ok, Socket} = gen_tcp:connect("localhost", Port, [
        binary,
        {packet, raw},
        {active, false}
    ]),
    Result = raw_ws_handshake:client(Socket, <<"localhost">>, Port, <<"/ws">>, 1000),
    gen_tcp:close(Socket),

    ?assertEqual({ok, <<>>}, Result),
    assert_server_done(DoneRef).

read_response_preserves_rest_test() ->
    RestFrame = <<16#81, 5, "hello">>,
    Header = <<"HTTP/1.1 101 Switching Protocols\r\n\r\n">>,
    Result = raw_ws_handshake:read_response(undefined, <<Header/binary, RestFrame/binary>>, 1000),
    ?assertEqual({ok, Header, RestFrame}, Result).

bad_accept_header_test() ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(Listen),
    DoneRef = make_ref(),
    Parent = self(),
    spawn_link(fun() -> bad_accept_server(Listen, Parent, DoneRef) end),

    {ok, Socket} = gen_tcp:connect("localhost", Port, [
        binary,
        {packet, raw},
        {active, false}
    ]),
    Result = raw_ws_handshake:client(Socket, <<"localhost">>, Port, <<"/ws">>, 1000),
    gen_tcp:close(Socket),

    ?assertMatch({error, {bad_handshake_response, _, _}}, Result),
    assert_server_done(DoneRef).

handshake_server(Listen, Parent, DoneRef, Rest) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    {ok, Request} = read_http_header(Socket, <<>>),
    Key = header_value(Request, <<"sec-websocket-key">>),
    Accept = accept_value(Key),
    Response = [
        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Accept: ">>, Accept, <<"\r\n">>,
        <<"\r\n">>,
        Rest
    ],
    ok = gen_tcp:send(Socket, Response),
    gen_tcp:close(Socket),
    gen_tcp:close(Listen),
    Parent ! {server_done, DoneRef}.

bad_accept_server(Listen, Parent, DoneRef) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    {ok, _Request} = read_http_header(Socket, <<>>),
    Response = [
        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Accept: bad\r\n">>,
        <<"\r\n">>
    ],
    ok = gen_tcp:send(Socket, Response),
    gen_tcp:close(Socket),
    gen_tcp:close(Listen),
    Parent ! {server_done, DoneRef}.

read_http_header(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, 4} ->
            HeaderSize = Pos + 4,
            <<Header:HeaderSize/binary, _Rest/binary>> = Acc,
            {ok, Header};
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 1000),
            read_http_header(Socket, <<Acc/binary, Data/binary>>)
    end.

header_value(HeaderBlock, Name) ->
    Lines = binary:split(HeaderBlock, <<"\r\n">>, [global, trim_all]),
    Headers = lists:foldl(fun parse_header/2, #{}, tl(Lines)),
    maps:get(Name, Headers).

parse_header(Line, Acc) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            maps:put(lower_ascii(trim_ows(Name)), trim_ows(Value), Acc);
        _ ->
            Acc
    end.

accept_value(Key) ->
    base64:encode(crypto:hash(sha, <<Key/binary, ?WS_GUID/binary>>)).

trim_ows(Bin) ->
    trim_right(trim_left(Bin)).

trim_left(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t ->
    trim_left(Rest);
trim_left(Bin) ->
    Bin.

trim_right(Bin) ->
    trim_right(Bin, byte_size(Bin)).

trim_right(_Bin, 0) ->
    <<>>;
trim_right(Bin, Size) ->
    case binary:at(Bin, Size - 1) of
        C when C =:= $\s; C =:= $\t ->
            trim_right(Bin, Size - 1);
        _ ->
            binary:part(Bin, 0, Size)
    end.

lower_ascii(Bin) ->
    << <<(lower_ascii_char(C))>> || <<C>> <= Bin >>.

lower_ascii_char(C) when C >= $A, C =< $Z ->
    C + 32;
lower_ascii_char(C) ->
    C.

assert_server_done(DoneRef) ->
    receive
        {server_done, DoneRef} ->
            ok
    after 1000 ->
        ?assert(false)
    end.
