/^	if (user_mode(regs) && isa_emu_handle_ud(regs))$/{
N
c\
	if (user_mode(regs)) {\
		bool handled;\
\
		/* The emulator may sleep (mmap lock, page faults, kmalloc): run it with IRQs on, as\
		 * do_error_trap() does. Returning to user mode with IRQs on can take an interrupt\
		 * between swapgs and iret and panic with a user GS. */\
		local_irq_enable();\
		handled = isa_emu_handle_ud(regs);\
		local_irq_disable();\
		if (handled)\
			return;\
	}
}
