/* Bare-metal NVIC regression: three implemented priority bits.
 * 0xbf must mask IRQ priority 0xa0; 0 and unimplemented-only 1 must not.
 * Assemble with clang --target=arm-none-eabi -mcpu=cortex-m33 -mthumb -c;
 * llvm-objcopy -O binary, then boot pebble-emery with -semihosting.
 */
.syntax unified
.thumb
.section .text
.word 0x2007f000, 0x101
.org 64
.word 0x301
.org 256
reset:
    ldr r0, =0x20000000
    movs r1, #0
    str r1, [r0]
    ldr r0, =0xe000e400
    movs r1, #0xa0
    strb r1, [r0]
    ldr r0, =0xe000e100
    movs r1, #1
    str r1, [r0]
    movs r0, #0xbf
    msr basepri, r0
    dsb
    isb
    ldr r0, =0xe000e200
    str r1, [r0]
    movs r2, #100
1:  subs r2, #1
    bne 1b
    ldr r0, =0x20000000
    ldr r1, [r0]
    cmp r1, #0
    bne failed
    movs r0, #0
    msr basepri, r0
    dsb
    isb
    movs r2, #100
2:  subs r2, #1
    bne 2b
    ldr r0, =0x20000000
    ldr r1, [r0]
    cmp r1, #1
    bne failed
    movs r0, #1
    msr basepri, r0
    dsb
    isb
    ldr r0, =0xe000e200
    movs r1, #1
    str r1, [r0]
    movs r2, #100
3:  subs r2, #1
    bne 3b
    ldr r0, =0x20000000
    ldr r1, [r0]
    cmp r1, #2
    bne failed
    movs r0, #4
    ldr r1, =0x400
    bkpt #0xab
    movs r0, #0x20
    ldr r1, =0x440
    bkpt #0xab
failed:
    movs r0, #4
    ldr r1, =0x420
    bkpt #0xab
    movs r0, #0x20
    ldr r1, =0x448
    bkpt #0xab
4:  b 4b
.ltorg
.org 768
irq:
    ldr r0, =0x20000000
    ldr r1, [r0]
    adds r1, #1
    str r1, [r0]
    bx lr
.ltorg
.org 1024
.asciz "PASS: NVIC BASEPRI masking\n"
.org 1056
.asciz "FAIL: NVIC BASEPRI masking\n"
.org 1088
.word 0x20026, 0
.word 0x20026, 1
