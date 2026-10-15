/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __X86_KERNEL_FPU_ISA_EMU_H
#define __X86_KERNEL_FPU_ISA_EMU_H
struct xregs_state;
struct pt_regs;
bool isa_emu_handle_ud(struct pt_regs *regs);
/* Save current's FPU state to memory, mark it for reload on return to user, return the image. */
struct xregs_state *fpu_emu_begin(void);
void fpu_emu_end(void);
void *xstate_addr_for_write(struct xregs_state *xsave, int xfeature_nr);
#endif
