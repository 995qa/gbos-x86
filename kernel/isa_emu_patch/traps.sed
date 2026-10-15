/^DEFINE_IDTENTRY(exc_overflow)$/i\
bool isa_emu_handle_ud(struct pt_regs *regs);\

/^	do_error_trap(regs, 0, "invalid opcode", X86_TRAP_UD, SIGILL,$/i\
	if (user_mode(regs) && isa_emu_handle_ud(regs))\
		return;\

