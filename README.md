# pebble-qemu-wasm

Pebble smartwatch emulator running in the browser. QEMU compiled to WebAssembly boots real Pebble firmware and renders the display to an HTML canvas.

![Pebble in browser](pebble_wasm_first_frame.png)

## How it works

Pebble's original emulator used a [custom QEMU 2.5 fork](https://github.com/nicethings/qemu-pebble) with STM32 peripheral models and Pebble-specific board definitions. This project ports those device models (~8,500 lines of C across 27 files) to QEMU 10.1, then compiles the result to WebAssembly using Emscripten's TCI (Tiny Code Interpreter) backend.

Key pieces:
- **STM32F4 SoC emulation** — RCC, GPIO, DMA, SPI, I2C, UART, timers, RTC, EXTI, flash, ADC, power
- **Pebble board definitions** — 6 machine types (aplite through flint), display controller, control protocol
- **Macronix flash patch** — CFI02 NOR flash support for the Pebble bootloader
- **WASM adaptations** — virtual clock (`-icount shift=auto`), `QEMU_CLOCK_VIRTUAL` for display timing, `setInterval` render loop (rAF is hijacked by `PROXY_TO_PTHREAD`), direct `SharedArrayBuffer` writes for button input

## Quick start (browser)

Prerequisites: Python 3 (for the dev server), pre-built WASM artifacts in `web/`

```sh
python3 server.py 8080
# Open http://localhost:8080/pebble.html
```

The server adds `Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers required for `SharedArrayBuffer` (Emscripten pthreads). A plain file server won't work.

The page fetches firmware files (`qemu_micro_flash.bin` 827KB + `qemu_spi_flash.bin` 16MB) via HTTP, then boots the emulator. The WASM binary is 33MB.

## Controls

| Key | Button |
|-----|--------|
| Arrow Up / W | Up |
| Arrow Down / X | Down |
| Enter / Arrow Right / S | Select |
| Escape / Backspace / Arrow Left / Q | Back |

Buttons can also be clicked with the mouse. Keys are held for 1 second minimum to ensure the firmware registers the press under slow TCI execution.

## Building

### Prerequisites

- Docker (for WASM build)
- QEMU 10.1 source at `~/dev/qemu-10.1.0` (WASM) or QEMU 10.0 at `~/dev/qemu-10.0` (native)
- Pebble SDK 4.9.77 firmware files (see [Firmware](#firmware) below)

### WASM build

```sh
bash build_wasm.sh
```

This uses a Docker container (`qemu101-wasm-base`) built from QEMU 10.1's `emsdk-wasm32-cross.docker` image. The script:
1. Copies QEMU 10.1 source into the container
2. Overlays Pebble device model files from `hw/` and `include/`
3. Applies patches (Macronix flash, WASM configure fixes)
4. Configures with `--enable-tcg-interpreter --enable-system --target-list=arm-softmmu`
5. Builds `qemu-system-arm.js` + `.wasm` + `.worker.js`
6. Copies artifacts to `web/`

For incremental rebuilds after editing a source file:

```sh
docker cp hw/arm/pebble.c build-pebble-wasm:/qemu-rw/hw/arm/pebble.c
docker exec build-pebble-wasm bash -c 'cd /build && ninja -j10 qemu-system-arm.js'
docker cp build-pebble-wasm:/build/qemu-system-arm.js web/
docker cp build-pebble-wasm:/build/qemu-system-arm.wasm web/
docker cp build-pebble-wasm:/build/qemu-system-arm.worker.js web/
```

### Native build

```sh
bash build.sh
```

Overlays Pebble files into QEMU 10.0 source, configures with `--enable-sdl`, and builds with ninja. Output: `~/dev/qemu-10.0/build/qemu-system-arm`.

Requires SDL2, glib, pixman, and other QEMU dependencies (`brew install sdl2 glib pixman`).

## Running native QEMU

### With pebble-tool (TCP serial)

```sh
bash boot_for_pebble_tool.sh
```

Starts QEMU with TCP serial ports for pebble-tool connectivity:
- Port 12344 — Pebble protocol (FEED/BEEF framing)
- Port 12345 — debug console

Then connect with pebble-tool:

```sh
pebble screenshot --qemu localhost:12344
pebble install --qemu localhost:12344 /path/to/app.pbw
pebble logs --qemu localhost:12344
```

### With file-based logs

```sh
bash boot_with_logs.sh
```

Writes serial output to `/tmp/pebble_serial.log` for standalone debugging.

## Firmware

Firmware files come from the Pebble SDK 4.9.77 (emery platform):

```
~/Library/Application Support/Pebble SDK/SDKs/4.9.77/sdk-core/pebble/emery/qemu/
├── qemu_micro_flash.bin       # 827KB — bootloader + firmware (copy as-is)
└── qemu_spi_flash.bin.bz2     # 16MB decompressed — filesystem (decompress with bunzip2)
```

Place `qemu_micro_flash.bin` and `qemu_spi_flash.bin` in both `firmware/` (native) and `web/` (WASM).

## Project structure

```
├── build.sh                 # Native QEMU 10.0 build script
├── build_wasm.sh            # WASM QEMU 10.1 build script (Docker)
├── boot_for_pebble_tool.sh  # Launch native QEMU with TCP serial
├── boot_with_logs.sh        # Launch native QEMU with file logs
├── server.py                # Dev server with COOP/COEP headers
├── hw/                      # Pebble device models (27 source files)
│   ├── arm/                 #   Board definitions, SoC, control protocol
│   ├── char/                #   UART / USART
│   ├── display/             #   Pebble display controller
│   ├── dma/                 #   DMA controller
│   ├── gpio/                #   GPIO
│   ├── misc/                #   RCC, clock tree, I2C, ADC, CRC, flash, power
│   ├── ssi/                 #   SPI controller
│   └── timer/               #   General-purpose timers, RTC
├── include/hw/arm/          # Headers (stm32_common, pebble, clktree)
├── patches/                 # QEMU source patches
├── scripts/                 # Build helper scripts
├── firmware/                # Pebble firmware binaries (not checked in)
└── web/                     # WASM artifacts + HTML pages
    ├── pebble.html          #   Main emulator page
    ├── qemu-system-arm.js   #   Emscripten loader (343KB)
    ├── qemu-system-arm.wasm #   QEMU binary (33MB)
    └── qemu-system-arm.worker.js
```

## Supported platforms

The emery machine (`pebble-snowy-emery-bb`, Pebble Time 2) is the primary target. The device models also define machines for aplite, basalt, chalk, diorite, and flint, but only emery has been tested.

## License

QEMU is licensed under GPLv2. The Pebble device model code originates from [Pebble's QEMU fork](https://github.com/nicethings/qemu-pebble).
