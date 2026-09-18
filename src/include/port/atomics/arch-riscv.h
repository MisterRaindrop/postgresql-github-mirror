/*-------------------------------------------------------------------------
 *
 * arch-riscv.h
 *    Atomic operations considerations specific to RISC-V
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 * src/include/port/atomics/arch-riscv.h
 *
 *-------------------------------------------------------------------------
 */

/* intentionally no include guards, should only be included by atomics.h */
#ifndef INSIDE_ATOMICS_H
#error "should be included via atomics.h"
#endif

/*
 * The RV64 base ISA guarantees naturally aligned XLEN-bit loads and stores
 * are atomic.  PostgreSQL's pg_atomic_uint64 objects are naturally aligned,
 * so the generic implementation may use a single plain load/store rather
 * than a compare/exchange loop.  RV32 retains the generic fallback.
 */
#if __riscv_xlen == 64
#define PG_HAVE_8BYTE_SINGLE_COPY_ATOMICITY
#endif
