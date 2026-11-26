#ifndef JARBOX_PAINT_QOS_POLICY_H
#define JARBOX_PAINT_QOS_POLICY_H
#include <stdint.h>
// Conservative experiment guard, NOT a measurement of game tick deadlines.
// A VM with three over-budget Utility paints remains on its original QoS.
enum { JARBOX_PAINT_QOS_STRIKES = 3 };
#define JARBOX_PAINT_QOS_BUDGET_NS UINT64_C(40000000)
static inline int jarbox_paint_qos_over_budget(uint64_t elapsed) {
    return elapsed > JARBOX_PAINT_QOS_BUDGET_NS;
}
static inline int jarbox_paint_qos_backoff(uint64_t strikes) {
    return strikes >= JARBOX_PAINT_QOS_STRIKES;
}
#endif
