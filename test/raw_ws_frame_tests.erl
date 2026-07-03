-module(raw_ws_frame_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../include/raw_ws.hrl").

decode_unmasked_text_frame_test() ->
    Frame = <<16#81, 5, "hello">>,
    {ok, Decoded, Rest} = raw_ws_frame:read(undefined, Frame, 1000),
    ?assertEqual(<<>>, Rest),
    ?assertEqual(true, Decoded#ws_frame.fin),
    ?assertEqual(16#1, Decoded#ws_frame.opcode),
    ?assertEqual(<<"hello">>, Decoded#ws_frame.payload).

decode_masked_client_text_frame_test() ->
    Frame = raw_ws_frame:encode(text, <<"hello">>),
    {ok, Decoded, Rest} = raw_ws_frame:read(undefined, Frame, 1000),
    ?assertEqual(<<>>, Rest),
    ?assertEqual(true, Decoded#ws_frame.fin),
    ?assertEqual(16#1, Decoded#ws_frame.opcode),
    ?assertEqual(true, Decoded#ws_frame.masked),
    ?assertEqual(<<"hello">>, Decoded#ws_frame.payload).

decode_extended_16bit_payload_length_test() ->
    Payload = binary:copy(<<"a">>, 126),
    Frame = raw_ws_frame:encode(text, Payload),
    {ok, Decoded, Rest} = raw_ws_frame:read(undefined, Frame, 1000),
    ?assertEqual(<<>>, Rest),
    ?assertEqual(16#1, Decoded#ws_frame.opcode),
    ?assertEqual(Payload, Decoded#ws_frame.payload).

decode_ping_frame_test() ->
    Frame = raw_ws_frame:encode(ping, <<"abc">>),
    {ok, Decoded, Rest} = raw_ws_frame:read(undefined, Frame, 1000),
    ?assertEqual(<<>>, Rest),
    ?assertEqual(16#9, Decoded#ws_frame.opcode),
    ?assertEqual(<<"abc">>, Decoded#ws_frame.payload).

preserve_leftover_buffer_after_one_frame_test() ->
    Frame = <<16#81, 5, "hello", 16#81, 5, "again">>,
    {ok, Decoded, Rest} = raw_ws_frame:read(undefined, Frame, 1000),
    ?assertEqual(<<"hello">>, Decoded#ws_frame.payload),
    ?assertEqual(<<16#81, 5, "again">>, Rest).
