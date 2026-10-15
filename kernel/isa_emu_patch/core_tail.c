
#ifndef __PKVM_HYP__
#include "isa_emu.h"
/* ISA emulation support: expose current's FPU state in memory for modification. */
struct xregs_state *fpu_emu_begin(void)
{
	struct fpu *fpu = x86_task_fpu(current);

	fpregs_lock();
	if (!test_thread_flag(TIF_NEED_FPU_LOAD)) {
		save_fpregs_to_fpstate(fpu);
		set_thread_flag(TIF_NEED_FPU_LOAD);
	}
	__fpu_invalidate_fpregs_state(fpu);
	return &fpu->fpstate->regs.xsave;
}

void fpu_emu_end(void)
{
	fpregs_unlock();
}
#endif /* !__PKVM_HYP__ */
