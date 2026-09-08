#include <stdatomic.h>
#include <stdint.h>
#include <unistd.h>

static atomic_int phase = 0;
static atomic_int permitted = 0;
static atomic_int call_count = 0;
static atomic_int last_gpu_layers = -1;

int32_t create_phase(void) { return atomic_load(&phase); }
void allow_create(void) { atomic_store(&permitted, 1); }
int32_t create_call_count(void) { return atomic_load(&call_count); }
int32_t create_last_gpu_layers(void) { return atomic_load(&last_gpu_layers); }

int64_t llb_create_session(
    const char* model_path,
    int32_t n_ctx,
    int32_t n_threads,
    int32_t n_gpu_layers
) {
    (void) model_path;
    (void) n_ctx;
    (void) n_threads;

    const int current_call = atomic_fetch_add(&call_count, 1) + 1;
    atomic_store(&last_gpu_layers, n_gpu_layers);

    if (current_call == 1 && n_gpu_layers > 0) {
        atomic_store(&phase, 1);
        // Bounded wait: a caller-isolate regression fails instead of hanging
        // the test runner forever.
        for (int i = 0; i < 2000 && !atomic_load(&permitted); ++i) {
            usleep(1000);
        }
        return -3;
    }

    atomic_store(&phase, 2);
    return 84;
}
