#!/bin/bash
# Test native QEMU FPS with timeline animation running
# Boots QEMU, navigates to timeline "No events" sloth animation,
# keeps pressing back+down to maintain animation, measures FPS.

set +e  # don't exit on grep returning no matches

QEMU=/Users/eric/dev/qemu-10.0/build/qemu-system-arm
MICRO=/Users/eric/dev/pebble-qemu-wasm/firmware/qemu_micro_flash.bin
SPI=/Users/eric/dev/pebble-qemu-wasm/firmware/qemu_spi_flash.bin
FPS_LOG=/tmp/qemu_native_fps.log
MON_PORT=55777

# Clean up any existing QEMU
pkill -f "qemu-system-arm.*pebble-snowy-emery" 2>/dev/null || true
sleep 1

echo "=== Starting native QEMU ==="

$QEMU \
  -machine pebble-snowy-emery-bb \
  -kernel "$MICRO" \
  -drive if=none,id=spi-flash,file="$SPI",format=raw \
  -serial null -serial null -serial file:/tmp/native_serial.log \
  -monitor tcp::${MON_PORT},server,nowait \
  -d unimp -D /tmp/qemu_unimp.log \
  2>"$FPS_LOG" &
QEMU_PID=$!
echo "QEMU PID: $QEMU_PID"

send_key() {
    # macOS nc: use -w1 for timeout, -G1 for connect timeout
    echo "sendkey $1" | nc -w1 localhost $MON_PORT 2>/dev/null || true
    sleep 0.1
}

echo "Waiting 25s for boot to Settings screen..."
sleep 25

echo "=== Boot FPS ==="
grep '\[fps\]' "$FPS_LOG"

echo ""
echo "=== Navigating to timeline ==="
echo "Pressing Back (left) to go to watchface..."
send_key left
sleep 3

echo "Pressing Down to enter timeline..."
send_key down
sleep 3

echo "=== Measuring FPS with timeline animation ==="
echo "(pressing left+down every 3s to keep animation alive)"

# Mark the start of animation measurement
ANIM_START_LINE=$(wc -l < "$FPS_LOG")

for i in $(seq 1 15); do
    send_key left
    sleep 0.5
    send_key down
    sleep 2.5
done

echo ""
echo "=== Animation FPS Results ==="
# Only show FPS lines after animation started
tail -n +$((ANIM_START_LINE + 1)) "$FPS_LOG" | grep '\[fps\]'

echo ""
echo "=== Full Session FPS ==="
grep '\[fps\]' "$FPS_LOG"

echo ""
echo "=== Summary ==="
ANIM_FPS=$(tail -n +$((ANIM_START_LINE + 1)) "$FPS_LOG" | grep '\[fps\]' | sed 's/\[fps\] //' | cut -d' ' -f1)
if [ -n "$ANIM_FPS" ]; then
    echo "$ANIM_FPS" | awk '{sum+=$1; n++} END {printf "Animation Average FPS: %.1f (%d readings)\n", sum/n, n}'
fi

ALL_FPS=$(grep '\[fps\]' "$FPS_LOG" | sed 's/\[fps\] //' | cut -d' ' -f1)
if [ -n "$ALL_FPS" ]; then
    echo "$ALL_FPS" | awk '{sum+=$1; n++} END {printf "Overall Average FPS: %.1f (%d readings)\n", sum/n, n}'
fi

echo ""
echo "Killing QEMU..."
kill $QEMU_PID 2>/dev/null
wait $QEMU_PID 2>/dev/null || true
echo "Done"
