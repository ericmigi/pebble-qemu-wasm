#!/usr/bin/env python3
"""Patch QEMU source for WASM cross-compilation and performance.

1. Add exe_wrapper = ['node'] to configure's cross-file generation
2. Remove -sEXPORT_ES6=1 from emscripten.txt (we use script tag loading)
3. Add --profiling-funcs to emscripten.txt link flags (Chrome DevTools profiling)
3b. Add ASYNCIFY_REMOVE for TCI hot path (avoids ASYNCIFY overhead in interpreter)
4. Upgrade meson optimization from -O2 to -O3
5. Add TCI instrumentation counters (enabled by -DTCI_INSTRUMENT)
6. Add inline TLB fast path in TCI memory access functions
"""
import sys
import os
import re

qemu_dir = sys.argv[1] if len(sys.argv) > 1 else '/qemu-rw'

# 1. Patch configure to add exe_wrapper
configure_path = os.path.join(qemu_dir, 'configure')
with open(configure_path, 'r') as f:
    content = f.read()

target = 'echo "strip = [$(meson_quote $strip)]" >> $cross'
if 'exe_wrapper' not in content:
    replacement = target + "\n  echo \"exe_wrapper = ['node']\" >> $cross"
    content = content.replace(target, replacement, 1)
    with open(configure_path, 'w') as f:
        f.write(content)
    print('Patched configure for exe_wrapper')
else:
    print('configure already has exe_wrapper')

# 2. Remove EXPORT_ES6 from emscripten.txt
ems_path = os.path.join(qemu_dir, 'configs/meson/emscripten.txt')
with open(ems_path, 'r') as f:
    content = f.read()

if '-sEXPORT_ES6=1' in content:
    content = content.replace("'-sEXPORT_ES6=1',", '')
    with open(ems_path, 'w') as f:
        f.write(content)
    print('Removed EXPORT_ES6 from emscripten.txt')
else:
    print('EXPORT_ES6 already removed')

# 3. Add --profiling-funcs to emscripten.txt link flags
#    This preserves WASM function names in Chrome profiler with minimal overhead
with open(ems_path, 'r') as f:
    content = f.read()

if '--profiling-funcs' not in content:
    # Add --profiling-funcs to c_link_args
    content = content.replace(
        "'-sEXPORTED_RUNTIME_METHODS=addFunction,removeFunction,TTY,FS']",
        "'-sEXPORTED_RUNTIME_METHODS=addFunction,removeFunction,TTY,FS','--profiling-funcs']"
    )
    with open(ems_path, 'w') as f:
        f.write(content)
    print('Added --profiling-funcs to emscripten.txt')
else:
    print('--profiling-funcs already in emscripten.txt')

# 3b. Add ASYNCIFY_REMOVE for TCI hot path functions
#     ASYNCIFY=1 (Binaryen) instruments every function with stack save/restore
#     code for async unwinding. The TCI interpreter hot loop never needs async
#     (it never calls emscripten_fiber_swap), but Binaryen can't prove this
#     statically due to indirect calls (ffi_call). Excluding these 3 functions
#     eliminates ~44% overhead on the hottest code path.
with open(ems_path, 'r') as f:
    content = f.read()

asyncify_remove = "'-sASYNCIFY_REMOVE=[\"tcg_qemu_tb_exec\",\"tci_qemu_ld\",\"tci_qemu_st\"]'"
if 'ASYNCIFY_REMOVE' not in content:
    content = content.replace(
        "'--profiling-funcs'",
        asyncify_remove + ",'--profiling-funcs'"
    )
    with open(ems_path, 'w') as f:
        f.write(content)
    print('Added ASYNCIFY_REMOVE for TCI hot path')
else:
    print('ASYNCIFY_REMOVE already in emscripten.txt')

# 4. Upgrade meson default optimization from -O2 to -O3
meson_path = os.path.join(qemu_dir, 'meson.build')
with open(meson_path, 'r') as f:
    content = f.read()

if "'optimization=2'" in content:
    content = content.replace("'optimization=2'", "'optimization=3'")
    with open(meson_path, 'w') as f:
        f.write(content)
    print('Upgraded meson optimization from -O2 to -O3')
else:
    print('meson optimization already changed')

# 5. Patch tcg/tci.c — add instrumentation counters and inline TLB fast path
tci_path = os.path.join(qemu_dir, 'tcg/tci.c')
with open(tci_path, 'r') as f:
    content = f.read()

if 'TCI_INSTRUMENT' not in content:
    # --- Instrumentation block: inserted after #include <ffi.h> ---
    instrumentation_code = '''

/*
 * TCI performance instrumentation (enabled by -DTCI_INSTRUMENT).
 * Reports op throughput and distribution every 10M ops to stderr.
 */
#ifdef TCI_INSTRUMENT
#include <time.h>

#define TCI_REPORT_INTERVAL 10000000  /* 10M ops */

static uint64_t tci_total_ops;
static uint64_t tci_arith_ops;
static uint64_t tci_mem_ld_ops;
static uint64_t tci_mem_st_ops;
static uint64_t tci_call_ops;
static uint64_t tci_branch_ops;
static uint64_t tci_last_report_ops;
static double tci_last_report_time;

static double tci_get_time_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void tci_report_stats(void)
{
    double now = tci_get_time_sec();
    double dt = now - tci_last_report_time;
    uint64_t dops = tci_total_ops - tci_last_report_ops;
    double mops = dt > 0 ? (dops / dt / 1e6) : 0;
    uint64_t tot = tci_total_ops ? tci_total_ops : 1;
    fprintf(stderr, "[tci] %.1f Mops/s | total=%lluM arith=%llu%% ld=%llu%% "
            "st=%llu%% call=%llu%% br=%llu%%\\n",
            mops, (unsigned long long)(tci_total_ops / 1000000),
            (unsigned long long)(tci_arith_ops * 100 / tot),
            (unsigned long long)(tci_mem_ld_ops * 100 / tot),
            (unsigned long long)(tci_mem_st_ops * 100 / tot),
            (unsigned long long)(tci_call_ops * 100 / tot),
            (unsigned long long)(tci_branch_ops * 100 / tot));
    tci_last_report_time = now;
    tci_last_report_ops = tci_total_ops;
}
#endif /* TCI_INSTRUMENT */
'''
    content = content.replace('#include <ffi.h>\n',
                              '#include <ffi.h>\n' + instrumentation_code, 1)

    # --- Instrumentation: counter increment in the main loop ---
    # Insert after "opc = extract32(insn, 0, 8);"
    counter_increment = '''
#ifdef TCI_INSTRUMENT
        tci_total_ops++;
        if (__builtin_expect(
                tci_total_ops - tci_last_report_ops >= TCI_REPORT_INTERVAL,
                0)) {
            if (tci_last_report_time == 0) {
                tci_last_report_time = tci_get_time_sec();
                tci_last_report_ops = tci_total_ops;
            } else {
                tci_report_stats();
            }
        }
#endif
'''
    content = content.replace(
        'opc = extract32(insn, 0, 8);\n\n        switch (opc)',
        'opc = extract32(insn, 0, 8);\n' + counter_increment +
        '\n        switch (opc)', 1)

    # --- Instrumentation: count call ops ---
    content = content.replace(
        'ffi_call(cif, func, stack, call_slots);\n            }',
        'ffi_call(cif, func, stack, call_slots);\n'
        '#ifdef TCI_INSTRUMENT\n'
        '                tci_call_ops++;\n'
        '#endif\n'
        '            }', 1)

    # --- Instrumentation: count branch ops (INDEX_op_br) ---
    content = content.replace(
        'case INDEX_op_br:\n'
        '            tci_args_l(insn, tb_ptr, &ptr);\n'
        '            tb_ptr = ptr;\n'
        '            continue;',
        'case INDEX_op_br:\n'
        '            tci_args_l(insn, tb_ptr, &ptr);\n'
        '            tb_ptr = ptr;\n'
        '#ifdef TCI_INSTRUMENT\n'
        '            tci_branch_ops++;\n'
        '#endif\n'
        '            continue;', 1)

    # --- Instrumentation: count brcond ops ---
    content = content.replace(
        'case INDEX_op_brcond:\n'
        '            tci_args_rl(insn, tb_ptr, &r0, &ptr);\n'
        '            if (regs[r0]) {\n'
        '                tb_ptr = ptr;\n'
        '            }\n'
        '            break;',
        'case INDEX_op_brcond:\n'
        '            tci_args_rl(insn, tb_ptr, &r0, &ptr);\n'
        '            if (regs[r0]) {\n'
        '                tb_ptr = ptr;\n'
        '            }\n'
        '#ifdef TCI_INSTRUMENT\n'
        '            tci_branch_ops++;\n'
        '#endif\n'
        '            break;', 1)

    # --- Instrumentation: count qemu_ld ops ---
    content = content.replace(
        'case INDEX_op_qemu_ld:\n'
        '            tci_args_rrm(insn, &r0, &r1, &oi);\n'
        '            taddr = regs[r1];\n'
        '            regs[r0] = tci_qemu_ld(env, taddr, oi, tb_ptr);\n'
        '            break;',
        'case INDEX_op_qemu_ld:\n'
        '            tci_args_rrm(insn, &r0, &r1, &oi);\n'
        '            taddr = regs[r1];\n'
        '            regs[r0] = tci_qemu_ld(env, taddr, oi, tb_ptr);\n'
        '#ifdef TCI_INSTRUMENT\n'
        '            tci_mem_ld_ops++;\n'
        '#endif\n'
        '            break;', 1)

    # --- Instrumentation: count qemu_st ops ---
    content = content.replace(
        'case INDEX_op_qemu_st:\n'
        '            tci_args_rrm(insn, &r0, &r1, &oi);\n'
        '            taddr = regs[r1];\n'
        '            tci_qemu_st(env, taddr, regs[r0], oi, tb_ptr);\n'
        '            break;',
        'case INDEX_op_qemu_st:\n'
        '            tci_args_rrm(insn, &r0, &r1, &oi);\n'
        '            taddr = regs[r1];\n'
        '            tci_qemu_st(env, taddr, regs[r0], oi, tb_ptr);\n'
        '#ifdef TCI_INSTRUMENT\n'
        '            tci_mem_st_ops++;\n'
        '#endif\n'
        '            break;', 1)

    with open(tci_path, 'w') as f:
        f.write(content)
    print('Added TCI instrumentation to tci.c')
else:
    print('TCI instrumentation already present')

# 6. Patch tcg/tci.c — add inline TLB fast path for memory access
#    This avoids the function call chain through helper_ld*_mmu for TLB hits.
#    The fast path does:
#      1. Compute TLB index from guest address
#      2. Check if TLB entry matches (hit)
#      3. If hit and no special flags, load/store directly via host pointer
#      4. If miss, fall through to normal helper_ld*_mmu path
with open(tci_path, 'r') as f:
    content = f.read()

if 'TCI_TLB_FAST_PATH' not in content:
    # Add required headers for TLB access
    content = content.replace(
        '#include <ffi.h>\n',
        '#include <ffi.h>\n\n'
        '/* Inline TLB fast path for memory access (TCI_TLB_FAST_PATH) */\n'
        '#ifndef CONFIG_USER_ONLY\n'
        '#include "exec/cpu-common.h"\n'
        '#include "exec/tlb-common.h"\n'
        '#include "exec/tlb-flags.h"\n'
        '#include "exec/target_page.h"\n'
        '#define TCI_TLB_FAST_PATH 1\n'
        '#endif\n', 1)

    # Replace tci_qemu_ld with inline TLB fast path version
    old_tci_qemu_ld = (
        'static uint64_t tci_qemu_ld(CPUArchState *env, uint64_t taddr,\n'
        '                            MemOpIdx oi, const void *tb_ptr)\n'
        '{\n'
        '    MemOp mop = get_memop(oi);\n'
        '    uintptr_t ra = (uintptr_t)tb_ptr;\n'
        '\n'
        '    switch (mop & MO_SSIZE) {\n'
        '    case MO_UB:\n'
        '        return helper_ldub_mmu(env, taddr, oi, ra);\n'
        '    case MO_SB:\n'
        '        return helper_ldsb_mmu(env, taddr, oi, ra);\n'
        '    case MO_UW:\n'
        '        return helper_lduw_mmu(env, taddr, oi, ra);\n'
        '    case MO_SW:\n'
        '        return helper_ldsw_mmu(env, taddr, oi, ra);\n'
        '    case MO_UL:\n'
        '        return helper_ldul_mmu(env, taddr, oi, ra);\n'
        '    case MO_SL:\n'
        '        return helper_ldsl_mmu(env, taddr, oi, ra);\n'
        '    case MO_UQ:\n'
        '        return helper_ldq_mmu(env, taddr, oi, ra);\n'
        '    default:\n'
        '        g_assert_not_reached();\n'
        '    }\n'
        '}'
    )

    new_tci_qemu_ld = (
        'static uint64_t tci_qemu_ld(CPUArchState *env, uint64_t taddr,\n'
        '                            MemOpIdx oi, const void *tb_ptr)\n'
        '{\n'
        '    MemOp mop = get_memop(oi);\n'
        '    uintptr_t ra = (uintptr_t)tb_ptr;\n'
        '\n'
        '#ifdef TCI_TLB_FAST_PATH\n'
        '    /* Inline TLB fast path: check if guest address hits the TLB.\n'
        '     * On hit with no special flags, load directly from host memory,\n'
        '     * avoiding the full helper_ld*_mmu function call chain. */\n'
        '    {\n'
        '        CPUState *cpu = env_cpu(env);\n'
        '        int mmu_idx = get_mmuidx(oi);\n'
        '        uintptr_t tlb_mask = cpu->neg.tlb.f[mmu_idx].mask;\n'
        '        uintptr_t idx = (taddr >> TARGET_PAGE_BITS)\n'
        '                        & (tlb_mask >> CPU_TLB_ENTRY_BITS);\n'
        '        CPUTLBEntry *tlbe = &cpu->neg.tlb.f[mmu_idx].table[idx];\n'
        '        uintptr_t tlb_addr = tlbe->addr_read;\n'
        '        uintptr_t page = taddr & TARGET_PAGE_MASK;\n'
        '\n'
        '        if (__builtin_expect(\n'
        '                page == (tlb_addr & (TARGET_PAGE_MASK | TLB_INVALID_MASK))\n'
        '                && !(tlb_addr & TLB_FORCE_SLOW), 1)) {\n'
        '            void *haddr = (void *)(taddr + tlbe->addend);\n'
        '            switch (mop & MO_SSIZE) {\n'
        '            case MO_UB: return *(uint8_t *)haddr;\n'
        '            case MO_SB: return (int8_t)*(uint8_t *)haddr;\n'
        '            case MO_UW: { uint16_t v; memcpy(&v, haddr, 2); return v; }\n'
        '            case MO_SW: { uint16_t v; memcpy(&v, haddr, 2); return (int16_t)v; }\n'
        '            case MO_UL: { uint32_t v; memcpy(&v, haddr, 4); return v; }\n'
        '            case MO_SL: { uint32_t v; memcpy(&v, haddr, 4); return (int32_t)v; }\n'
        '            case MO_UQ: { uint64_t v; memcpy(&v, haddr, 8); return v; }\n'
        '            default: break;\n'
        '            }\n'
        '        }\n'
        '    }\n'
        '#endif\n'
        '\n'
        '    /* Slow path: full softMMU lookup */\n'
        '    switch (mop & MO_SSIZE) {\n'
        '    case MO_UB:\n'
        '        return helper_ldub_mmu(env, taddr, oi, ra);\n'
        '    case MO_SB:\n'
        '        return helper_ldsb_mmu(env, taddr, oi, ra);\n'
        '    case MO_UW:\n'
        '        return helper_lduw_mmu(env, taddr, oi, ra);\n'
        '    case MO_SW:\n'
        '        return helper_ldsw_mmu(env, taddr, oi, ra);\n'
        '    case MO_UL:\n'
        '        return helper_ldul_mmu(env, taddr, oi, ra);\n'
        '    case MO_SL:\n'
        '        return helper_ldsl_mmu(env, taddr, oi, ra);\n'
        '    case MO_UQ:\n'
        '        return helper_ldq_mmu(env, taddr, oi, ra);\n'
        '    default:\n'
        '        g_assert_not_reached();\n'
        '    }\n'
        '}'
    )

    content = content.replace(old_tci_qemu_ld, new_tci_qemu_ld, 1)

    # Replace tci_qemu_st with inline TLB fast path version
    old_tci_qemu_st = (
        'static void tci_qemu_st(CPUArchState *env, uint64_t taddr, uint64_t val,\n'
        '                        MemOpIdx oi, const void *tb_ptr)\n'
        '{\n'
        '    MemOp mop = get_memop(oi);\n'
        '    uintptr_t ra = (uintptr_t)tb_ptr;\n'
        '\n'
        '    switch (mop & MO_SIZE) {\n'
        '    case MO_UB:\n'
        '        helper_stb_mmu(env, taddr, val, oi, ra);\n'
        '        break;\n'
        '    case MO_UW:\n'
        '        helper_stw_mmu(env, taddr, val, oi, ra);\n'
        '        break;\n'
        '    case MO_UL:\n'
        '        helper_stl_mmu(env, taddr, val, oi, ra);\n'
        '        break;\n'
        '    case MO_UQ:\n'
        '        helper_stq_mmu(env, taddr, val, oi, ra);\n'
        '        break;\n'
        '    default:\n'
        '        g_assert_not_reached();\n'
        '    }\n'
        '}'
    )

    new_tci_qemu_st = (
        'static void tci_qemu_st(CPUArchState *env, uint64_t taddr, uint64_t val,\n'
        '                        MemOpIdx oi, const void *tb_ptr)\n'
        '{\n'
        '    MemOp mop = get_memop(oi);\n'
        '    uintptr_t ra = (uintptr_t)tb_ptr;\n'
        '\n'
        '#ifdef TCI_TLB_FAST_PATH\n'
        '    /* Inline TLB fast path for stores */\n'
        '    {\n'
        '        CPUState *cpu = env_cpu(env);\n'
        '        int mmu_idx = get_mmuidx(oi);\n'
        '        uintptr_t tlb_mask = cpu->neg.tlb.f[mmu_idx].mask;\n'
        '        uintptr_t idx = (taddr >> TARGET_PAGE_BITS)\n'
        '                        & (tlb_mask >> CPU_TLB_ENTRY_BITS);\n'
        '        CPUTLBEntry *tlbe = &cpu->neg.tlb.f[mmu_idx].table[idx];\n'
        '        uintptr_t tlb_addr = tlbe->addr_write;\n'
        '        uintptr_t page = taddr & TARGET_PAGE_MASK;\n'
        '\n'
        '        if (__builtin_expect(\n'
        '                page == (tlb_addr & (TARGET_PAGE_MASK | TLB_INVALID_MASK))\n'
        '                && !(tlb_addr & TLB_FORCE_SLOW), 1)) {\n'
        '            void *haddr = (void *)(taddr + tlbe->addend);\n'
        '            switch (mop & MO_SIZE) {\n'
        '            case MO_UB: *(uint8_t *)haddr = val; return;\n'
        '            case MO_UW: { uint16_t v = val; memcpy(haddr, &v, 2); return; }\n'
        '            case MO_UL: { uint32_t v = val; memcpy(haddr, &v, 4); return; }\n'
        '            case MO_UQ: { uint64_t v = val; memcpy(haddr, &v, 8); return; }\n'
        '            default: break;\n'
        '            }\n'
        '        }\n'
        '    }\n'
        '#endif\n'
        '\n'
        '    /* Slow path: full softMMU lookup */\n'
        '    switch (mop & MO_SIZE) {\n'
        '    case MO_UB:\n'
        '        helper_stb_mmu(env, taddr, val, oi, ra);\n'
        '        break;\n'
        '    case MO_UW:\n'
        '        helper_stw_mmu(env, taddr, val, oi, ra);\n'
        '        break;\n'
        '    case MO_UL:\n'
        '        helper_stl_mmu(env, taddr, val, oi, ra);\n'
        '        break;\n'
        '    case MO_UQ:\n'
        '        helper_stq_mmu(env, taddr, val, oi, ra);\n'
        '        break;\n'
        '    default:\n'
        '        g_assert_not_reached();\n'
        '    }\n'
        '}'
    )

    content = content.replace(old_tci_qemu_st, new_tci_qemu_st, 1)

    with open(tci_path, 'w') as f:
        f.write(content)
    print('Added inline TLB fast path to tci.c')
else:
    print('TLB fast path already present')
