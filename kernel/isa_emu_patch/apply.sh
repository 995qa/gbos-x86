#!/bin/sh
# Run inside the kernel source root (/build/src). Idempotent.
set -e
P=${P:-/host/kernel/isa_emu_patch}
F=arch/x86/kernel/fpu
cp $P/isa_emu.c $P/isa_emu.h $P/isa_emu_core.c $P/isa_emu_core.h $F/
grep -q isa_emu $F/Makefile || sed -i 's/ xstate\.o$/ xstate.o isa_emu.o isa_emu_core.o/' $F/Makefile
grep -q isa_emu $F/Makefile
grep -q fpu_emu_begin $F/core.c || cat $P/core_tail.c >> $F/core.c
grep -q xstate_addr_for_write $F/xstate.c || cat $P/xstate_tail.c >> $F/xstate.c
sed -i '/^bool isa_emu_handle_ud(struct pt_regs \*regs);$/d' arch/x86/include/asm/traps.h
grep -q 'isa_emu_handle_ud(regs)' arch/x86/kernel/traps.c || sed -i -f $P/traps.sed arch/x86/kernel/traps.c
grep -q '^bool isa_emu_handle_ud' arch/x86/kernel/traps.c || sed -i '/^DEFINE_IDTENTRY(exc_overflow)$/i bool isa_emu_handle_ud(struct pt_regs *regs);\n' arch/x86/kernel/traps.c
grep -q "handled = isa_emu_handle_ud(regs);" arch/x86/kernel/traps.c || sed -i -f $P/traps_irq.sed arch/x86/kernel/traps.c
grep -c isa_emu_handle_ud arch/x86/kernel/traps.c
