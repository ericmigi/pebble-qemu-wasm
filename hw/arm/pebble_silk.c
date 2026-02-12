/*
 * Pebble Silk (Diorite) Board - stub for QEMU 10.x
 * TODO: Fully port when F412/silk display is needed
 */

#include "qemu/osdep.h"
#include "hw/boards.h"
#if __has_include("hw/arm/machines-qom.h")
#include "hw/arm/machines-qom.h"
#endif
#ifndef DEFINE_MACHINE_ARM
#define DEFINE_MACHINE_ARM DEFINE_MACHINE
#endif
#include "hw/arm/pebble.h"
#include "target/arm/cpu-qom.h"
#include "qemu/error-report.h"

const static PblBoardConfig s_board_config_silk_bb = {
    .dbgserial_uart_index = 0,       /* USART1 */
    .pebble_control_uart_index = 1,  /* USART2 */
    .button_map = {
        { STM32_GPIOC_INDEX, 13, true },
        { STM32_GPIOD_INDEX, 2, true },
        { STM32_GPIOH_INDEX, 0, true },
        { STM32_GPIOH_INDEX, 1, true },
    },
    .gpio_idr_masks = {
        [STM32_GPIOC_INDEX] = 1 << 13,
        [STM32_GPIOD_INDEX] = 1 << 2,
        [STM32_GPIOH_INDEX] = (1 << 1) | (1 << 0),
    },
    .flash_size = 4096,
    .ram_size = 256,
    .num_rows = 172,
    .num_cols = 148,
    .num_border_rows = 2,
    .num_border_cols = 2,
    .row_major = false,
    .row_inverted = false,
    .col_inverted = false,
    .round_mask = false
};

void pebble_32f412_init(MachineState *machine,
                        const PblBoardConfig *board_config)
{
    /* F412 SoC init - reuse F4xx for now (same peripherals, different memory) */
    pebble_32f439_init(machine, board_config);
}

static void pebble_silk_init(MachineState *machine)
{
    pebble_32f412_init(machine, &s_board_config_silk_bb);
}

static void pebble_silk_bb_machine_init(MachineClass *mc)
{
    static const char * const valid_cpu_types[] = {
        ARM_CPU_TYPE_NAME("cortex-m4"),
        NULL
    };
    mc->desc = "Pebble smartwatch (silk/diorite)";
    mc->init = pebble_silk_init;
    mc->valid_cpu_types = valid_cpu_types;
}

DEFINE_MACHINE_ARM("pebble-silk-bb", pebble_silk_bb_machine_init)
