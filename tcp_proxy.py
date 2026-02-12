#!/usr/bin/env python3
"""TCP proxy that logs FEED/BEEF protocol traffic between pebble-tool and QEMU."""
import socket, select, sys, time

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 12340
TARGET_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 12344

def hex_dump(data, prefix=""):
    """Compact hex dump with ASCII sidebar."""
    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        hex_part = " ".join(f"{b:02x}" for b in chunk)
        ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append(f"{prefix}  {i:04x}: {hex_part:<48s} {ascii_part}")
    return "\n".join(lines)

def parse_packets(data, label):
    """Parse and display FEED/BEEF packets."""
    i = 0
    while i < len(data) - 1:
        if data[i] == 0xfe and data[i+1] == 0xed:
            # Find BEEF footer
            for j in range(i+2, len(data)-1):
                if data[j] == 0xbe and data[j+1] == 0xef:
                    pkt = data[i:j+2]
                    # Parse header: FEED(2) + protocol(2) + length(2) + data + BEEF(2)
                    if len(pkt) >= 6:
                        proto = int.from_bytes(pkt[2:4], 'big')
                        dlen = int.from_bytes(pkt[4:6], 'big')
                        payload = pkt[6:-2]
                        print(f"  [{label}] PACKET: proto=0x{proto:04x} len={dlen} payload={payload.hex()}")
                    i = j + 2
                    break
            else:
                break
        else:
            i += 1

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', LISTEN_PORT))
server.listen(1)
print(f"Proxy listening on :{LISTEN_PORT} -> localhost:{TARGET_PORT}")
print(f"Connect pebble-tool to localhost:{LISTEN_PORT}")

client, addr = server.accept()
print(f"Client connected from {addr}")

target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
target.connect(('localhost', TARGET_PORT))
print(f"Connected to QEMU on :{TARGET_PORT}")

start = time.time()
try:
    while True:
        readable, _, _ = select.select([client, target], [], [], 1.0)
        for sock in readable:
            data = sock.recv(4096)
            if not data:
                print(f"[t={time.time()-start:.1f}s] Connection closed")
                sys.exit(0)

            t = time.time() - start
            if sock is client:
                label = "TOOL->QEMU"
                target.sendall(data)
            else:
                label = "QEMU->TOOL"
                client.sendall(data)

            print(f"[t={t:.1f}s] {label}: {len(data)} bytes")
            print(hex_dump(data, "  "))
            parse_packets(data, label)
            sys.stdout.flush()
except KeyboardInterrupt:
    print("\nProxy stopped")
finally:
    client.close()
    target.close()
    server.close()
