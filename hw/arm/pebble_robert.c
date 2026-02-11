/*
 * Pebble Robert Board - stub for QEMU 10.x
 * TODO: Fully port when F7xx SoC is needed
 */

#include "qemu/osdep.h"
#include "hw/boards.h"
#include "hw/arm/pebble.h"
#include "target/arm/cpu-qom.h"
#include "qemu/error-report.h"

const static PblBoardConfig s_board_config_robert_bb = {
    .dbgserial_uart_index = 2,       /* USART3 */
    .pebble_control_uart_index = 1,  /* USART2 */
    .button_map = {
        {STM32_GPIOG_INDEX, 6, false},
        {STM32_GPIOG_INDEX, 3, false},
        {STM32_GPIOG_INDEX, 5, false},
        {STM32_GPIOG_INDEX, 4, false},
    },
    .flash_size = 4096,
    .ram_size = 512,
    .num_rows = 228,
    .num_cols = 200,
    .num_border_rows = 0,
    .num_border_cols = 0,
    .row_major = true,
    .row_inverted = true,
    .col_inverted = true,
    .round_mask = false
};

void pebble_32f7xx_init(MachineState *machine,
                        const PblBoardConfig *board_config)
{
    error_report("Robert (F7xx) platform not yet ported to QEMU 10.x");
    exit(1);
}

static void pebble_robert_init(MachineState *machine)
{
    pebble_32f7xx_init(machine, &s_board_config_robert_bb);
}

static void pebble_robert_bb_machine_init(MachineClass *mc)
{
    static const char * const valid_cpu_types[] = {
        ARM_CPU_TYPE_NAME("cortex-m4"),
        NULL
    };
    mc->desc = "Pebble smartwatch (robert)";
    mc->init = pebble_robert_init;
    mc->valid_cpu_types = valid_cpu_types;
}

DEFINE_MACHINE("pebble-robert-bb", pebble_robert_bb_machine_init)
