#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BDF=${BDF:-0000:01:00.0}
RXIF=${RXIF:-enp1s0}
TXIF=${TXIF:-enp1s0d1}
BIN=${BIN:-/home/conor/fpga/itch-data/real_20k_mid.bin}
GAP=${GAP:-200}
OUT=${OUT:-/tmp/itch_compare}
CLEANUP_VETH=0
TXIF0=$TXIF

[ "$EUID" -eq 0 ] || { echo "must run as root (sudo $0)"; exit 1; }
[ -f "$BIN" ] || { echo "missing $BIN"; exit 1; }

NMSG=$(python3 - "$BIN" <<'PY'
import struct,sys
d=open(sys.argv[1],'rb').read(); o=n=0
while o+2<=len(d):
    (l,)=struct.unpack_from('>H',d,o)
    if l==0 or o+2+l>len(d): break
    o+=2+l; n+=1
print(n)
PY
)
WANT=$(( NMSG * 95 / 100 ))
mkdir -p "$OUT"
echo "stream=$BIN messages=$NMSG want=$WANT (5% drop tolerance)"
echo

send() { python3 "$HERE/itch_replay_send.py" "$TXIF" "$BIN" --msgs-per-frame 1 --gap-us "$GAP" >/dev/null; }

echo "=== 0. RX sanity check on $RXIF ==="
timeout 20 tcpdump -i "$RXIF" -c 3 -nn ether proto 0x88b5 > "$OUT/tcpdump.txt" 2>&1 &
TD=$!
sleep 2; send; wait $TD 2>/dev/null
if grep -q "3 packets captured" "$OUT/tcpdump.txt"; then
    echo "  host RX works on $RXIF"
else
    echo "  $RXIF does not deliver to the host; falling back to a veth pair."
    echo "  itch_afpacket timestamps at kernel software RX, which already excludes"
    echo "  the NIC, DMA and PCIe -- so veth exercises the same measured path."
    ip link del itchv0 2>/dev/null
    ip link add itchv0 type veth peer name itchv1 || { echo "  veth create failed"; exit 1; }
    ip link set itchv0 up; ip link set itchv1 up
    TXIF=itchv0; RXIF=itchv1
    CLEANUP_VETH=1
    timeout 20 tcpdump -i "$RXIF" -c 3 -nn ether proto 0x88b5 > "$OUT/tcpdump2.txt" 2>&1 &
    TD=$!
    sleep 2; send; wait $TD 2>/dev/null
    grep -q "3 packets captured" "$OUT/tcpdump2.txt" \
        && echo "  veth path works ($TXIF -> $RXIF)" \
        || { echo "  veth path also failed:"; sed 's/^/    /' "$OUT/tcpdump2.txt" | head -4; exit 1; }
fi
echo

for tool in itch_afpacket itch_afxdp; do
    [ -x "$HERE/$tool" ] || { echo "=== $tool: not built, skipping ==="; continue; }
    echo "=== $tool baseline ==="
    timeout 180 "$HERE/$tool" "$RXIF" "$WANT" > "$OUT/$tool.txt" 2>&1 &
    RX=$!
    sleep 2; send
    if ! wait $RX 2>/dev/null; then echo "  (timed out or exited early)"; fi
    grep -E "path|boundary|latency ns|p50=|msgs" "$OUT/$tool.txt" | sed 's/^/  /'
    echo
done

echo "=== FPGA in-fabric ==="
echo "  (processed the same $NMSG messages during the sanity-check send on $TXIF0)"
"$HERE/itch_poll" "$BDF" --count 1 | sed 's/^/  /'
echo
echo "raw output in $OUT/"
[ "$CLEANUP_VETH" = 1 ] && ip link del itchv0 2>/dev/null && echo "removed veth pair"
exit 0
