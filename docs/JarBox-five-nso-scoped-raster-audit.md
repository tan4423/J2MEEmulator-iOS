# Five NSO archive scoped raster audit (2026-11-28)
Read-only javap disassembly of the five user-supplied archives, no game code executed. All contain NSO resource-family signatures (6/7 AngelChip, 7/7 others). Exact hashes are recorded in jarbox_ninja_core_policy.h. Nick alias profile 2 retained.
| Archive | Classes | Canvas | Delegate | Graphics wrapper | Paint bytecode |
|---|---:|---|---|---|---|
| NinjaSchool_251 | 130 | main.b | main.c.a | t | 9 bytes |
| Nicknsonet_t5 | 296 | Class_hef | Class_bs.a | Class_hvi | 9 bytes |
| 217_TrungDucTV_51026 | 184 | Class_ek | Class_bv.a | Class_gp | 9 bytes |
| V9_X1_NOKEY | 291 | cu | am.a | eg | 20 bytes, null guard and Throwable handler |
| NSOAngelChip_Mod | 175 | aq | ei.a | bo | 9 bytes |

Direct bytecode inventory: no direct Graphics.copyArea/getPixels/getNativeContext references in these five archives; Image.getGraphics exists in all five, Image.getRGB in Nick and AngelChip. Offscreen rendering remains real. V9 reflection sites target operating-system CPU metrics (ManagementFactory/OperatingSystemMXBean), not a raster bypass. Static analysis is not alias or runtime correctness proof. Conservative class hierarchy reachability includes field/array writes, RMS calls, time reads and exception handlers. Retain all Java paint and game wrappers. 

New activation is exact archive + bundled API/boot verification (unified build), profile-specific Canvas, mode1 owner, existing full repaint / no explicit buffer / pixel guard, same TLS context. V9's separate core-only recognition does not extend legacy mode8 eligibility. Raster admission no longer waits for a residual plan. Only profile 2 is authorized for existing Nick-specific residual, IR, island and glyph code. Fault rejection, JIT exclusion, wake/rebuild and all Graphics state/offscreen paths remain. No new mode8 shortcut, no changes to FPS, game timing, JAR bytes, network or QoS. Device logs and live differential needed; this is a candidate, not demonstrated device CPU benefit.