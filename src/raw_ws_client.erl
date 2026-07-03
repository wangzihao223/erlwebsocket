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

-record(ws, {
    socket,
    buffer = <<>>,
    timeout = 5000
}).

connect(Host, Port, Path) ->
    connect(Host, Port, Path, []).

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

send_text(#ws{socket = Socket}, Text) ->
    Payload = unicode:characters_to_binary(Text),
    gen_tcp:send(Socket, raw_ws_frame:encode(text, Payload)).

send_binary(#ws{socket = Socket}, Payload) ->
    gen_tcp:send(Socket, raw_ws_frame:encode(binary, Payload)).

send_ping(#ws{socket = Socket}) ->
    gen_tcp:send(Socket, raw_ws_frame:encode(ping, <<>>)).

close(#ws{socket = Socket}) ->
    _ = gen_tcp:send(Socket, raw_ws_frame:encode(close, <<>>)),
    gen_tcp:close(Socket).

recv(State = #ws{socket = Socket, buffer = Buffer, timeout = Timeout}) ->
    case raw_ws_frame:read(Socket, Buffer, Timeout) of
        {ok, Frame, Rest} ->
            handle_frame(State#ws{buffer = Rest}, Frame);
        Error ->
            Error
    end.

handle_frame(State = #ws{socket = Socket}, #ws_frame{opcode = 16#1, payload = Payload}) ->
    {ok, {text, Payload}, State};
handle_frame(State, #ws_frame{opcode = 16#2, payload = Payload}) ->
    {ok, {binary, Payload}, State};
handle_frame(State = #ws{socket = Socket}, #ws_frame{opcode = 16#9, payload = Payload}) ->
    ok = gen_tcp:send(Socket, raw_ws_frame:encode(pong, Payload)),
    {ok, {ping, Payload}, State};
handle_frame(State, #ws_frame{opcode = 16#A, payload = Payload}) ->
    {ok, {pong, Payload}, State};
handle_frame(State = #ws{socket = Socket}, #ws_frame{opcode = 16#8, payload = Payload}) ->
    _ = gen_tcp:send(Socket, raw_ws_frame:encode(close, Payload)),
    gen_tcp:close(Socket),
    {ok, parse_close(Payload), State};
handle_frame(State, #ws_frame{opcode = Opcode, payload = Payload}) ->
    {error, {unsupported_opcode, Opcode, Payload}, State}.

parse_close(<<Code:16/big, Reason/binary>>) ->
    {close, Code, Reason};
parse_close(<<>>) ->
    {close, undefined, <<>>};
parse_close(Reason) ->
    {close, malformed, Reason}.
