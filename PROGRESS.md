# Pebble QEMU 10.x Port — Progress

## Phase 2: Port Pebble Device Models to QEMU 10.x

**Goal:** Port ~8,500 lines of Pebble device models from QEMU 2.5.0-pebble8 to QEMU 10.x APIs so PebbleOS boots on modern QEMU (prerequisite for Phase 3: WASM compilation).

---

### Step 1: Setup
- [x] `build.sh` — overlays Pebble files onto QEMU 10.0, patches Kconfig/meson, configures, builds
- [x] Vanilla QEMU 10.0 builds with `--target-list=arm-softmmu`
- [x] `.gitignore` created

### Step 2: Port STM32 Peripherals
- [x] `include/hw/arm/stm32_common.h` — types, enums, IRQ numbers
- [x] `include/hw/arm/stm32_clktree.h` — clock tree API
- [x] `include/hw/arm/pebble.h` — board types
- [x] `hw/misc/stm32_pebble_rcc.c` — RCC clock controller
- [x] `hw/misc/stm32_pebble_clktree.c` — clock tree
- [x] `hw/misc/stm32_pebble_common.c` — shared helpers
- [x] `hw/gpio/stm32_pebble_gpio.c` — GPIO with pin output IRQs
- [x] `hw/misc/stm32_pebble_exti.c` — external interrupts
- [x] `hw/misc/stm32_pebble_syscfg.c` — system config
- [x] `hw/char/stm32_pebble_uart.c` — UART (CharBackend API)
- [x] `hw/ssi/stm32_pebble_spi.c` — SPI controller
- [x] `hw/timer/stm32_pebble_tim.c` — timers
- [x] `hw/dma/stm32_pebble_dma.c` — DMA controller
- [x] `hw/timer/stm32_pebble_rtc.c` — RTC
- [x] `hw/misc/stm32_pebble_adc.c` — ADC stub
- [x] `hw/misc/stm32_pebble_i2c.c` — I2C (rewritten with SB/AF/ADDR protocol)
- [x] `hw/misc/stm32_pebble_crc.c` — CRC
- [x] `hw/misc/stm32_pebble_pwr.c` — power stub
- [x] `hw/misc/stm32_pebble_flash.c` — flash interface stub
- [x] `hw/misc/stm32_pebble_dummy.c` — dummy devices

### Step 3: SoC Container
- [x] `hw/arm/pebble_stm32f4xx_soc.c` — ARMv7MState, flash/SRAM/CCM/SDRAM, all peripherals wired

### Step 4: Display
- [x] `hw/display/pebble_snowy_display.c` — SSI slave + GraphicHwOps
- [x] `hw/display/pebble_snowy_display.h`
- [x] `hw/display/pebble_snowy_display_overlays.h`
- [x] GPIO wiring: G8→CS, G15→RESET, G13→SCLK, G9←DONE, G10←INTN

### Step 5: Board/Machine Definitions
- [x] `hw/arm/pebble.c` — 6 machine variants
- [x] `hw/arm/pebble_control.c` / `.h` — UART control protocol
- [x] `hw/arm/pebble_robert.c` — Robert init
- [x] `hw/arm/pebble_silk.c` — Silk init
- [x] Kconfig, meson.build, default.mak entries
- [x] `patches/pflash_cfi02_cfi_entry.patch` — Macronix flash support

### Step 6: Build, Debug, Boot
- [x] Full build succeeds (1898+ compilation units)
- [x] Firmware loads, vector table correct
- [x] Bootloader runs (ASCII art, FPGA programming, display init)
- [x] Firmware v4.9.77-3-geb9f6e61 boots, RTOS scheduler starts
- [x] Serial output on USART3
- [x] Display renders frames (47+ frames, 45600 bytes each)
- [x] **Fixed:** DMA2 streams 5-7 IRQ routing (68-70, not 61-63) — commit `079d941`
- [x] DMA switched to `address_space_write` for MMIO dispatch
- [ ] **TicToc watchface not starting** — needs investigation

### Bugs Found & Fixed
1. **DMA IRQ routing** (`079d941`): Non-contiguous STM32F4 DMA stream IRQs. Fixed with lookup tables.
2. **pflash CFI**: Macronix MX29VS128FB added via patch.
3. **Display GPIO**: CS/RESET/SCLK wired via GPIO G pins.
4. **I2C**: Rewritten with proper protocol for firmware compat.

### Current Issue
- TicToc watchface app does not start despite firmware booting successfully
- Serial log shows `NL:2108 'system' 'TicToc'` but app doesn't render
- Display shows frames but content may be blank/wrong

### Commits
- `500d370` — Port Pebble device models to QEMU 10.x (Phase 2 WIP)
- `079d941` — Fix DMA IRQ routing for non-contiguous STM32F4 stream interrupts
