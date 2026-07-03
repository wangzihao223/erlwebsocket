-record(ws_frame, {
    fin :: boolean(),
    rsv = 0 :: 0..7,
    opcode :: non_neg_integer(),
    masked = false :: boolean(),
    payload = <<>> :: binary()
}).

