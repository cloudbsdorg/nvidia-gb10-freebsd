/* host stub: an sx that only checks lock balance */
#ifndef _STUB_SX_H
#define _STUB_SX_H
struct sx { int held; };
extern int stub_sx_max_depth;
#define SX_SYSINIT(a, b, c)
static inline void sx_xlock(struct sx *s) { s->held++; if (s->held > stub_sx_max_depth) stub_sx_max_depth = s->held; }
static inline void sx_xunlock(struct sx *s) { s->held--; }
#endif
