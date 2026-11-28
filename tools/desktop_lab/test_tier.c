#include <assert.h>
#include "jarbox_desktop_tier.h"
int main(void){for(int i=-1;i<=9;i++){assert(jarbox_desktop_ir_mode(i)==(i==5||i==7||i==8));assert(jarbox_desktop_residual_mode(i)==(i==6||i==7||i==8));assert(jarbox_desktop_logic_ir_mode(i)==(i==8));}return 0;}
