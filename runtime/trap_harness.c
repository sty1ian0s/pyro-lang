/* C harness for the runtime/trap.zig test: calls pyro_rt_trap the way
   compiled C-ABI code does. */
#include <stddef.h>
#include <stdint.h>

_Noreturn void pyro_rt_trap(uint32_t kind, const uint8_t *msg, size_t msg_len,
                            const uint8_t *file, size_t file_len, uint32_t line);

_Noreturn void pyro_test_trap_harness(void) {
    static const char msg[] = "index 5 out of bounds for length 3";
    static const char file[] = "src/main.pr";
    pyro_rt_trap(0 /* bounds */, (const uint8_t *)msg, sizeof msg - 1,
                 (const uint8_t *)file, sizeof file - 1, 12);
}
