#ifndef JARBOX_REGION_SLOTS_H
#define JARBOX_REGION_SLOTS_H
// NativeBridge.drawRegion(JJIIIIIIII)V: long occupies two VM slots.
// Same inline accessors called by localvar_getLong_2slot_jni/getInt_jni.
static inline TreoRegionArgs jarbox_region_args(const LocalVarItem *locals, uint64_t owner) {
    return (TreoRegionArgs){locals[0].lvalue, locals[2].lvalue,
        locals[4].ivalue, locals[5].ivalue, locals[6].ivalue, locals[7].ivalue,
        locals[8].ivalue, locals[9].ivalue, locals[10].ivalue, locals[11].ivalue, owner};
}
#endif
