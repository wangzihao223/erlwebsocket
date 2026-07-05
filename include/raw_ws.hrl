-record(ws_frame, {
    fin :: boolean(),
    rsv = 0 :: 0..7,
    opcode :: non_neg_integer(),
    masked = false :: boolean(),
    payload = <<>> :: binary()
}).

-define(OP_CONTINUATION, 16#0).
-define(OP_TEXT, 16#1).
-define(OP_BINARY, 16#2).
-define(OP_CLOSE, 16#8).
-define(OP_PING, 16#9).
-define(OP_PONG, 16#A).

-define(FIN_BIT, 16#80).
-define(MASK_BIT, 16#80).
-define(RSV_MASK, 16#70).
-define(OPCODE_MASK, 16#0F).
-define(PAYLOAD_LEN_MASK, 16#7F).
-define(PAYLOAD_LEN_16, 126).
-define(PAYLOAD_LEN_64, 127).
