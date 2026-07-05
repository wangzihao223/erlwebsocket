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

decode_partial_frame_needs_more_data_test() ->
    Partial = <<16#81, 5, "he">>,
    ?assertEqual({more, Partial}, raw_ws_frame:decode(Partial)).

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

reject_unsupported_rsv_test() ->
    Frame = <<16#C1, 0>>,
    ?assertEqual({error, {unsupported_rsv, 4}}, raw_ws_frame:read(undefined, Frame, 1000)).

reject_fragmented_control_frame_test() ->
    Frame = <<16#09, 0>>,
    ?assertEqual({error, {fragmented_control_frame, 16#9}}, raw_ws_frame:read(undefined, Frame, 1000)).

reject_oversized_control_frame_test() ->
    Payload = binary:copy(<<"a">>, 126),
    Frame = <<16#89, 126, 126:16/big, Payload/binary>>,
    ?assertEqual({error, {control_frame_too_large, 16#9, 126}}, raw_ws_frame:read(undefined, Frame, 1000)).

decode_fragmented_text_frames_test() ->
    Frame1 = raw_ws_frame:encode(false, text, <<"hel">>),
    Frame2 = raw_ws_frame:encode(true, continuation, <<"lo">>),
    {ok, Decoded1, Rest1} = raw_ws_frame:read(undefined, <<Frame1/binary, Frame2/binary>>, 1000),
    ?assertEqual(false, Decoded1#ws_frame.fin),
    ?assertEqual(16#1, Decoded1#ws_frame.opcode),
    ?assertEqual(<<"hel">>, Decoded1#ws_frame.payload),
    {ok, Decoded2, Rest2} = raw_ws_frame:read(undefined, Rest1, 1000),
    ?assertEqual(<<>>, Rest2),
    ?assertEqual(true, Decoded2#ws_frame.fin),
    ?assertEqual(16#0, Decoded2#ws_frame.opcode),
    ?assertEqual(<<"lo">>, Decoded2#ws_frame.payload).

preserve_leftover_buffer_after_one_frame_test() ->
    Frame = <<16#81, 5, "hello", 16#81, 5, "again">>,
    {ok, Decoded, Rest} = raw_ws_frame:read(undefined, Frame, 1000),
    ?assertEqual(<<"hello">>, Decoded#ws_frame.payload),
    ?assertEqual(<<16#81, 5, "again">>, Rest).
