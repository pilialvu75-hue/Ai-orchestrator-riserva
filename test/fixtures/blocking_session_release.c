#include <stdatomic.h>
#include <stdint.h>
#include <unistd.h>

static atomic_int phase = 0;
static atomic_int permitted = 0;

int32_t release_phase(void) { return atomic_load(&phase); }
void allow_release(void) { atomic_store(&permitted, 1); }

void llb_release_session(int64_t id) {
    if (id != 42) return;
    atomic_store(&phase, 1);
    // A bounded handshake makes an accidental UI-thread call fail, not hang
    // the test runner indefinitely.
    for (int i = 0; i < 2000 && !atomic_load(&permitted); ++i) usleep(1000);
    atomic_store(&phase, 2);
}
