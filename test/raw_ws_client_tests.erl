-module(raw_ws_client_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).

recv_fragmented_text_message_test() ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(Listen),
    DoneRef = make_ref(),
    Parent = self(),
    spawn_link(fun() -> fragmented_text_server(Listen, Parent, DoneRef) end),

    {ok, Client0} = raw_ws_client:connect("localhost", Port, "/ws", [{timeout, 1000}]),
    {ok, {text, <<"hello">>}, _Client1} = raw_ws_client:recv(Client0),
    assert_server_done(DoneRef).

recv_timeout_keeps_fragment_state_test() ->
    {ok, Listen} = gen_tcp:listen(0, [
        binary,
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(Listen),
    DoneRef = make_ref(),
    Parent = self(),
    spawn_link(fun() -> delayed_fragmented_text_server(Listen, Parent, DoneRef) end),

    {ok, Client0} = raw_ws_client:connect("localhost", Port, "/ws", [{timeout, 50}]),
    {error, timeout, Client1} = raw_ws_client:recv(Client0),
    timer:sleep(120),
    {ok, {text, <<"hello">>}, _Client2} = raw_ws_client:recv(Client1),
    assert_server_done(DoneRef).

fragmented_text_server(Listen, Parent, DoneRef) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    {ok, Request} = read_http_header(Socket, <<>>),
    Key = header_value(Request, <<"sec-websocket-key">>),
    Accept = accept_value(Key),
    Response = [
        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Accept: ">>, Accept, <<"\r\n">>,
        <<"\r\n">>
    ],
    ok = gen_tcp:send(Socket, Response),
    ok = gen_tcp:send(Socket, <<16#01, 3, "hel", 16#80, 2, "lo">>),
    gen_tcp:close(Socket),
    gen_tcp:close(Listen),
    Parent ! {server_done, DoneRef}.

delayed_fragmented_text_server(Listen, Parent, DoneRef) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    {ok, Request} = read_http_header(Socket, <<>>),
    Key = header_value(Request, <<"sec-websocket-key">>),
    Accept = accept_value(Key),
    Response = [
        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Accept: ">>, Accept, <<"\r\n">>,
        <<"\r\n">>
    ],
    ok = gen_tcp:send(Socket, Response),
    ok = gen_tcp:send(Socket, <<16#01, 3, "hel">>),
    timer:sleep(150),
    ok = gen_tcp:send(Socket, <<16#80, 2, "lo">>),
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
