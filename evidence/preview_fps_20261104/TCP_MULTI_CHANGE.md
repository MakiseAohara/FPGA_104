# Independent TCP slots for PC mirror and board browser

The prior preview firmware allowed only one live TCP connection. A frequent PC
mirror request could occupy that connection when the board browser sent a SYN;
the browser then waited for its own SYN retransmission timer. A faster per-packet
send window alone did not remove those multi-second gaps.

`NET_CONN_COUNT` now defaults to **2**, bounded at compile time between 1 and 4.
The original `net_t.conn` and `net_t.rbuf` remain slot zero for native wrapper
compatibility. Each extra slot owns its connection state and a separate 32 KiB
response buffer. `active_slot` selects pointers; no connection or response cache
is swapped/copied to select a client.

Incoming validated TCP packets select a slot by client IPv4 address and source
port. A new SYN uses an available or expired slot. Duplicate half-open SYNs use
the existing slot; when all slots are occupied, an extra SYN is dropped without
overwriting either connection. ACK, RST, retransmission timers and FIN state are
independent. Source ports may also match when client IP addresses differ.

The shared HTTP callback may return a temporary global buffer. `nc_http` copies
the complete header/body into the requesting slot's response cache immediately,
before another GET can overwrite the callback's temporary output. Thus a PC
binary preview and a board HTML request cannot replace each other's in-flight
bytes. `net_input` and `net_tick` still emit at most one Ethernet frame per call.
Periodic service starts at the next round-robin slot after any emitted frame;
a connection awaiting an ACK, or retrying SYN/data/FIN, cannot monopolize ticks.

## Validation

```powershell
.\build_tcp_multi.bat
py -3 .\test_tcp_multi.py
.\build_tcp_window.bat
py -3 .\test_tcp_window.py
```

`tcp_multi_test.json` records **13 PASS checks** over real Ethernet/IP/TCP wire
packets sent to the shared native C implementation:

- simultaneous SYN and duplicate SYN handling;
- fair periodic filling of both bounded send windows;
- concurrent complete, byte-accurate HTML and binary responses, deliberately
  generated in one shared callback buffer to detect cross-connection corruption;
- a withheld data ACK does not prevent the other transfer finishing;
- simultaneous retransmission deadlines are served fairly;
- a third SYN cannot overwrite live sessions or their response bytes;
- RST closes only its own slot and that slot can be reused;
- loss of a FIN ACK does not block another response;
- loss of a SYN-ACK does not block another response;
- independent advertised windows and cumulative ACK progress;
- the same client source port on different IP addresses;
- expiry/reuse of one idle slot while another slot remains live;
- `NET_CONN_COUNT=1` rollback preserves single-slot isolation and reuse.

Every emitted packet's IPv4/TCP checksums and final HTTP Content-Length/body
bytes are checked. The prior **14 send-window regressions** also pass; they build
with `NET_CONN_COUNT=1` to retain their original single-slot SYN-rejection case.

Native x64 `sizeof(net_t)` is 33,944 bytes for one slot and 67,824 for two, an
increase of 33,880 bytes. Firmware RV32 RAM usage must be taken from its actual
linker report. There is no dynamic allocation. This packet-level suite does not
claim a measured browser frame rate; physical board/browser measurements remain
a separate required check.
