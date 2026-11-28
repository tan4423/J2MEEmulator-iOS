#ifndef JARBOX_DESKTOP_TIER_H
#define JARBOX_DESKTOP_TIER_H
/* Modes 5 and 6 remain independent controls. Mode 7 combines only
 * the existing scoped execution paths, not their per-frame plans. */
static inline int jarbox_desktop_ir_mode(int level) { return level == 5 || level == 7; }
static inline int jarbox_desktop_residual_mode(int level) { return level == 6 || level == 7; }
#endif
