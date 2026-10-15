
#include "isa_emu.h"
/* Like get_xsave_addr() but brings an init-state component into the image, zeroed. */
void *xstate_addr_for_write(struct xregs_state *xsave, int xfeature_nr)
{
	void *p = get_xsave_addr(xsave, xfeature_nr);

	if (p || !boot_cpu_has(X86_FEATURE_XSAVE) || !xfeature_enabled(xfeature_nr))
		return p;
	p = __raw_xsave_addr(xsave, xfeature_nr);
	if (!p)
		return NULL;
	memset(p, 0, xstate_sizes[xfeature_nr]);
	xsave->header.xfeatures |= BIT_ULL(xfeature_nr);
	return p;
}
