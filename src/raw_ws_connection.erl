-module(raw_ws_connection).

-behaviour(gen_server).

-export([
    start_link/3,
    start_link/4,
    send_text/2,
    send_binary/2,
    send_ping/1,
    close/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("../include/raw_ws.hrl").

%% active once 版本连接进程。
%% 一个进程持有一条 TCP/WebSocket 连接，业务进程通过消息接收事件。
-record(state, {
    socket,
    owner,
    buffer = <<>>,
    fragments = undefined
}).

-type option() :: {owner, pid()} | {timeout, timeout()}.
-type state() :: #state{}.
-type event() ::
    {text, binary()}
    | {binary, binary()}
    | {ping, binary()}
    | {pong, binary()}
    | {close, undefined | non_neg_integer() | malformed, binary()}.

-spec start_link(inet:hostname() | inet:ip_address(), inet:port_number(), unicode:chardata()) ->
    gen_server:start_ret().
start_link(Host, Port, Path) ->
    start_link(Host, Port, Path, []).

-spec start_link(inet:hostname() | inet:ip_address(), inet:port_number(), unicode:chardata(),
    [option()]) -> gen_server:start_ret().
start_link(Host, Port, Path, Options) ->
    Options1 =
        case proplists:is_defined(owner, Options) of
            true -> Options;
            false -> [{owner, self()} | Options]
        end,
    gen_server:start_link(?MODULE, {Host, Port, Path, Options1}, []).

-spec send_text(pid(), unicode:chardata()) -> ok | {error, term()}.
send_text(Pid, Text) ->
    gen_server:call(Pid, {send_text, Text}).

-spec send_binary(pid(), iodata()) -> ok | {error, term()}.
send_binary(Pid, Payload) ->
    gen_server:call(Pid, {send_binary, Payload}).

-spec send_ping(pid()) -> ok | {error, term()}.
send_ping(Pid) ->
    gen_server:call(Pid, send_ping).

-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:call(Pid, close).

%% 先用 passive socket 完成 HTTP Upgrade；握手完成后切到 active once。
-spec init({inet:hostname() | inet:ip_address(), inet:port_number(), unicode:chardata(),
    [option()]}) -> {ok, state()} | {stop, term()}.
init({Host, Port, Path, Options}) ->
    Owner = proplists:get_value(owner, Options, self()),
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
                    ok = inet:setopts(Socket, [{active, once}]),
                    State = #state{socket = Socket, owner = Owner, buffer = Rest},
                    self() ! process_buffer,
                    {ok, State};
                Error ->
                    gen_tcp:close(Socket),
                    {stop, Error}
            end;
        Error ->
            {stop, Error}
    end.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, term(), state()} | {stop, term(), term(), state()}.
handle_call({send_text, Text}, _From, State = #state{socket = Socket}) ->
    Payload = unicode:characters_to_binary(Text),
    {reply, gen_tcp:send(Socket, raw_ws_frame:encode(text, Payload)), State};
handle_call({send_binary, Payload}, _From, State = #state{socket = Socket}) ->
    {reply, gen_tcp:send(Socket, raw_ws_frame:encode(binary, Payload)), State};
handle_call(send_ping, _From, State = #state{socket = Socket}) ->
    {reply, gen_tcp:send(Socket, raw_ws_frame:encode(ping, <<>>)), State};
handle_call(close, _From, State = #state{socket = Socket}) ->
    _ = gen_tcp:send(Socket, raw_ws_frame:encode(close, <<>>)),
    gen_tcp:close(Socket),
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()} | {stop, term(), state()}.
handle_info(process_buffer, State) ->
    process_and_rearm(State);
handle_info({tcp, Socket, Data}, State = #state{socket = Socket, buffer = Buffer}) ->
    process_and_rearm(State#state{buffer = <<Buffer/binary, Data/binary>>});
handle_info({tcp_closed, Socket}, State = #state{socket = Socket, owner = Owner}) ->
    Owner ! {websocket_closed, self(), closed},
    {stop, normal, State};
handle_info({tcp_error, Socket, Reason}, State = #state{socket = Socket, owner = Owner}) ->
    Owner ! {websocket_error, self(), Reason},
    Owner ! {websocket_closed, self(), Reason},
    {stop, Reason, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec process_and_rearm(state()) -> {noreply, state()} | {stop, term(), state()}.
process_and_rearm(State = #state{socket = Socket, owner = Owner}) ->
    case process_buffer(State) of
        {ok, State1} ->
            case inet:setopts(Socket, [{active, once}]) of
                ok ->
                    {noreply, State1};
                {error, Reason} ->
                    Owner ! {websocket_error, self(), Reason},
                    {stop, Reason, State1}
            end;
        {stop, normal, State1} ->
            {stop, normal, State1};
        {stop, Reason, State1} ->
            Owner ! {websocket_error, self(), Reason},
            gen_tcp:close(Socket),
            {stop, Reason, State1}
    end.

-spec process_buffer(state()) -> {ok, state()} | {stop, term(), state()}.
process_buffer(State = #state{buffer = Buffer}) ->
    case raw_ws_frame:decode(Buffer) of
        {ok, Frame, Rest} ->
            case handle_frame(Frame, State#state{buffer = Rest}) of
                {ok, State1} ->
                    process_buffer(State1);
                {stop, Reason, State1} ->
                    {stop, Reason, State1}
            end;
        {more, Rest} ->
            {ok, State#state{buffer = Rest}};
        {error, Reason} ->
            {stop, Reason, State}
    end.

-spec handle_frame(#ws_frame{}, state()) -> {ok, state()} | {stop, term(), state()}.
handle_frame(#ws_frame{fin = true, opcode = ?OP_TEXT, payload = Payload},
        State = #state{fragments = undefined}) ->
    notify(State, {text, Payload}),
    {ok, State};
handle_frame(#ws_frame{fin = true, opcode = ?OP_BINARY, payload = Payload},
        State = #state{fragments = undefined}) ->
    notify(State, {binary, Payload}),
    {ok, State};
handle_frame(#ws_frame{fin = false, opcode = ?OP_TEXT, payload = Payload},
        State = #state{fragments = undefined}) ->
    {ok, State#state{fragments = {text, [Payload]}}};
handle_frame(#ws_frame{fin = false, opcode = ?OP_BINARY, payload = Payload},
        State = #state{fragments = undefined}) ->
    {ok, State#state{fragments = {binary, [Payload]}}};
handle_frame(#ws_frame{opcode = ?OP_CONTINUATION, payload = Payload},
        State = #state{fragments = undefined}) ->
    {stop, {unexpected_continuation, Payload}, State};
handle_frame(#ws_frame{fin = false, opcode = ?OP_CONTINUATION, payload = Payload},
        State = #state{fragments = {Type, Parts}}) ->
    {ok, State#state{fragments = {Type, [Payload | Parts]}}};
handle_frame(#ws_frame{fin = true, opcode = ?OP_CONTINUATION, payload = Payload},
        State = #state{fragments = {Type, Parts}}) ->
    FullPayload = iolist_to_binary(lists:reverse([Payload | Parts])),
    State1 = State#state{fragments = undefined},
    notify(State1, {Type, FullPayload}),
    {ok, State1};
handle_frame(#ws_frame{opcode = ?OP_TEXT, payload = Payload},
        State = #state{fragments = Fragments}) when Fragments =/= undefined ->
    {stop, {fragment_interrupted, ?OP_TEXT, Payload}, State};
handle_frame(#ws_frame{opcode = ?OP_BINARY, payload = Payload},
        State = #state{fragments = Fragments}) when Fragments =/= undefined ->
    {stop, {fragment_interrupted, ?OP_BINARY, Payload}, State};
handle_frame(#ws_frame{opcode = ?OP_PING, payload = Payload}, State = #state{socket = Socket}) ->
    ok = gen_tcp:send(Socket, raw_ws_frame:encode(pong, Payload)),
    notify(State, {ping, Payload}),
    {ok, State};
handle_frame(#ws_frame{opcode = ?OP_PONG, payload = Payload}, State) ->
    notify(State, {pong, Payload}),
    {ok, State};
handle_frame(#ws_frame{opcode = ?OP_CLOSE, payload = Payload}, State = #state{socket = Socket}) ->
    _ = gen_tcp:send(Socket, raw_ws_frame:encode(close, Payload)),
    notify(State, parse_close(Payload)),
    gen_tcp:close(Socket),
    {stop, normal, State};
handle_frame(#ws_frame{opcode = Opcode, payload = Payload}, State) ->
    {stop, {unsupported_opcode, Opcode, Payload}, State}.

-spec notify(state(), event()) -> ok.
notify(#state{owner = Owner}, Event) ->
    Owner ! {websocket, self(), Event},
    ok.

-spec parse_close(binary()) -> {close, undefined | non_neg_integer() | malformed, binary()}.
parse_close(<<Code:16/big, Reason/binary>>) ->
    {close, Code, Reason};
parse_close(<<>>) ->
    {close, undefined, <<>>};
parse_close(Reason) ->
    {close, malformed, Reason}.
