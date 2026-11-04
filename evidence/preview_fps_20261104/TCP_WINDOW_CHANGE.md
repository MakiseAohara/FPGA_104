# Bounded TCP response window

The shared firmware/native TCP core now permits two MSS of unacknowledged
response data. `net_input` and `net_tick` still emit at most one Ethernet frame
per call. The next service tick fills the second slot without waiting for the
receiver's delayed ACK. The peer's unscaled advertised window remains the lower
limit; no window scaling is negotiated.

`snd_nxt` is a monotonic sequence high-water mark. RTO retransmits from `snd_una`,
including partial-ACK offsets, without rewinding `snd_nxt` or the response cursor.
New packets do not postpone the timeout of already outstanding data. Cumulative
ACK progress restarts that timer. SYN and FIN retain explicit retransmission
paths. No FIN is sent until all response bytes have been acknowledged.

With `NET_PAIR_TAIL=1`, a lone short final burst is split once into two packets,
so a receiver that ACKs every second packet can acknowledge immediately. A
per-response flag prevents repeated subdivision when the receiver instead ACKs
every individual packet. Bytes and HTTP Content-Length are unchanged.

Rollback: define `NET_TX_SEGMENTS=1` at compile time. Define `NET_PAIR_TAIL=0` to
keep two-MSS flight without splitting the tail. The default send window is two,
not an unbounded sender. The subsequent multi-client change adds two independent
connection slots by default; see `TCP_MULTI_CHANGE.md`. Timeouts and retry limits
remain unchanged. This is not a full general-purpose TCP stack or Internet
congestion-control implementation.

## Verification

`build_tcp_window.bat` builds one-segment, two-segment and no-tail-pair variants,
each with `NET_CONN_COUNT=1` so the original single-connection isolation cases
remain valid. The default two-connection variant is tested separately.
`test_tcp_window.py` exercises the actual C core with complete Ethernet/IP/TCP
packets and verifies outgoing checksums and byte-for-byte HTTP response contents.
Fourteen checks cover cumulative/partial ACKs, segment loss, bounded receive
windows, zero-window resume/probes, SYN/FIN loss, sequence wrap, corrupted input,
RTO timing, rollback and the immediate-ACK short-tail corner case.

`tcp_window_test.json` records PASS. Its controlled model uses a zero-latency peer,
2 ms service ticks and ACKs every two packets or after 200 ms: a 9216-byte payload
takes 1400 ms with stop-and-wait, 206 ms with two segments alone and 8 ms with tail
pairing. Those are model timings, not measured FPGA network throughput or webpage
video frame rate. Actual browser/board measurements must be reported separately.

The pre-existing `mot_web_20261104/test_net.py` also passed after the initial window
implementation, including complete dashboard/JSON/PNG transmission, checksum and
connection isolation, retransmission and immutable snapshot checks. After the
final one-time tail guard, the dedicated fourteen-case suite was rerun and passed.
