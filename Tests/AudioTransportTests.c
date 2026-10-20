#include "AudioTransport.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static void capture(MixerTransport *state, float *samples, uint32_t frames, uint32_t channels) {
    AudioBufferList input = { .mNumberBuffers = 1, .mBuffers = {{channels, frames * channels * sizeof(float), samples}} };
    AudioBufferList output = { .mNumberBuffers = 0 };
    AudioTimeStamp time = {0};
    assert(MixerTransportCaptureIOProc(0, &time, &input, &time, &output, &time, state) == noErr);
}
static void render(MixerTransport *state, float *samples, uint32_t frames) {
    AudioBufferList output = { .mNumberBuffers = 1, .mBuffers = {{2, frames * 2 * sizeof(float), samples}} };
    AudioTimeStamp time = {0};
    AudioUnitRenderActionFlags flags = 0;
    assert(MixerTransportRender(state, &flags, &time, 0, frames, &output) == noErr);
}
static void fill(float *data, uint32_t frames, uint32_t channels, float value) {
    for (uint32_t i = 0; i < frames * channels; ++i) data[i] = value;
}

static void waiting_and_prepared_signal(void) {
    MixerTransport *state = MixerTransportCreate(1, 2, 48000, 48000, 2, 512);
    assert(state);
    float output[1024], input[4096];
    fill(output, 512, 2, 0.9);
    render(state, output, 512);
    for (uint32_t i = 0; i < 1024; ++i) assert(output[i] == 0);
    assert(MixerTransportValidCallbackCount(state) == 0 && !MixerTransportHasReceivedSignal(state));
    fill(input, 2048, 2, 0.125);
    capture(state, input, 2048, 2);
    for (uint32_t i = 0; i < 3; ++i) {
        render(state, output, 512);
        capture(state, input, 512, 2);
    }
    assert(MixerTransportValidCallbackCount(state) >= 3 && MixerTransportHasReceivedSignal(state));
    assert(fabs(MixerTransportTakePeak(state) - 0.125) < 0.00001);
    assert(MixerTransportTakeOutputPeak(state) == 0);
    MixerTransportSetPlaybackEnabled(state, true);
    render(state, output, 512);
    for (uint32_t i = 0; i < 1024; ++i) assert(fabs(output[i] - 0.125) < 0.00001);
    MixerTransportSetGain(state, 0.25);
    for (uint32_t i = 0; i < 5; ++i) { capture(state, input, 512, 2); render(state, output, 512); }
    for (uint32_t i = 0; i < 1024; ++i) assert(fabs(output[i] - 0.03125) < 0.00001);
    MixerTransportSetGain(state, 0);
    for (uint32_t i = 0; i < 5; ++i) { capture(state, input, 512, 2); render(state, output, 512); }
    for (uint32_t i = 0; i < 1024; ++i) assert(output[i] == 0);
    assert(MixerTransportInvalidCount(state) == 0);
    MixerTransportDestroy(state);
}

static void mono_and_planar_capture(void) {
    MixerTransport *state = MixerTransportCreate(1, 1, 48000, 48000, 2, 256);
    float input[2048], output[512];
    fill(input, 2048, 1, -0.125);
    capture(state, input, 2048, 1);
    MixerTransportSetPlaybackEnabled(state, true);
    render(state, output, 256);
    for (uint32_t i = 0; i < 256; ++i) assert(output[2 * i] == output[2 * i + 1] && fabs(output[2 * i] + 0.125) < 0.00001);
    MixerTransportDestroy(state);

    state = MixerTransportCreate(1, 2, 48000, 48000, 2, 256);
    float left[2048], right[2048];
    fill(left, 2048, 1, 0.1); fill(right, 2048, 1, -0.2);
    struct { UInt32 count; AudioBuffer buffers[2]; } planar = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    AudioBufferList emptyOutput = {.mNumberBuffers = 0};
    AudioTimeStamp time = {0};
    MixerTransportCaptureIOProc(0, &time, (const AudioBufferList *)&planar, &time, &emptyOutput, &time, state);
    MixerTransportSetPlaybackEnabled(state, true);
    render(state, output, 256);
    for (uint32_t i = 0; i < 256; ++i) assert(fabs(output[2 * i] - 0.1) < 0.00001 && fabs(output[2 * i + 1] + 0.2) < 0.00001);
    MixerTransportDestroy(state);
}

static void overflow_does_not_overwrite_unread(void) {
    MixerTransport *state = MixerTransportCreate(1, 2, 48000, 48000, 2, 256);
    uint32_t capacity = MixerTransportCapacityFrames(state);
    float *input = malloc((size_t)capacity * 2 * sizeof(float));
    float rejected[512], output[512];
    fill(input, capacity, 2, 0.125); fill(rejected, 256, 2, 0.875);
    capture(state, input, capacity, 2);
    capture(state, rejected, 256, 2);
    assert(MixerTransportDroppedFrames(state) == 256);
    MixerTransportSetPlaybackEnabled(state, true);
    render(state, output, 256);
    for (uint32_t i = 0; i < 512; ++i) assert(fabs(output[i] - 0.125) < 0.00001);
    assert(MixerTransportQueuedFrames(state) <= capacity);
    free(input); MixerTransportDestroy(state);
}

static void mismatched_rates_preserve_tone(double captureRate, double outputRate, uint32_t captureFrames, uint32_t outputFrames) {
    MixerTransport *state = MixerTransportCreate(1, 2, captureRate, outputRate, 2, outputFrames);
    float input[8192], output[2048];
    assert(outputFrames <= 1024 && captureFrames <= 4096);
    uint64_t sourceFrame = 0;
    for (uint32_t frame = 0; frame < 2048; ++frame, ++sourceFrame) {
        input[2 * frame] = input[2 * frame + 1] = 0.1 * sin(2 * 3.141592653589793 * 997 * sourceFrame / captureRate);
    }
    capture(state, input, 2048, 2);
    MixerTransportSetPlaybackEnabled(state, true);
    unsigned crossings = 0;
    float previous = 0;
    for (uint32_t cycle = 0; cycle < 110; ++cycle) {
        for (uint32_t frame = 0; frame < captureFrames; ++frame, ++sourceFrame) {
            input[2 * frame] = input[2 * frame + 1] = 0.1 * sin(2 * 3.141592653589793 * 997 * sourceFrame / captureRate);
        }
        capture(state, input, captureFrames, 2);
        render(state, output, outputFrames);
        if (cycle < 10) continue;
        for (uint32_t frame = 0; frame < outputFrames; ++frame) {
            assert(isfinite(output[2 * frame]) && fabs(output[2 * frame]) <= 0.101);
            if (previous <= 0 && output[2 * frame] > 0) ++crossings;
            previous = output[2 * frame];
        }
    }
    double expected = 997 * outputFrames * 100 / outputRate;
    assert(fabs(crossings - expected) < expected * 0.01 + 2);
    assert(MixerTransportValidCallbackCount(state) >= 100);
    assert(MixerTransportInvalidCount(state) == 0);
    MixerTransportDestroy(state);
}

typedef struct { MixerTransport *state; } Stress;
static void *producer(void *context) {
    Stress *stress = context;
    float input[256]; fill(input, 128, 2, 0.1);
    for (uint32_t i = 0; i < 10000; ++i) capture(stress->state, input, 128, 2);
    return NULL;
}
static void *consumer(void *context) {
    Stress *stress = context;
    float output[512];
    for (uint32_t i = 0; i < 10000; ++i) {
        render(stress->state, output, 256);
        for (uint32_t j = 0; j < 512; ++j) assert(isfinite(output[j]) && output[j] >= 0 && output[j] <= 0.10001);
    }
    return NULL;
}
static void concurrent_queue_stress(void) {
    Stress stress = {MixerTransportCreate(1, 2, 48000, 48000, 2, 256)};
    assert(stress.state);
    MixerTransportSetPlaybackEnabled(stress.state, true);
    pthread_t writer, reader;
    assert(!pthread_create(&writer, NULL, producer, &stress));
    assert(!pthread_create(&reader, NULL, consumer, &stress));
    pthread_join(writer, NULL); pthread_join(reader, NULL);
    assert(MixerTransportQueuedFrames(stress.state) <= MixerTransportCapacityFrames(stress.state));
    assert(MixerTransportInvalidCount(stress.state) == 0);
    MixerTransportDestroy(stress.state);
}

static void idle_null_is_waiting_not_invalid(void) {
    MixerTransport *state = MixerTransportCreate(1, 2, 48000, 48000, 2, 256);
    AudioBufferList idle = {.mNumberBuffers = 1, .mBuffers = {{2, 2048, NULL}}};
    AudioBufferList empty = {.mNumberBuffers = 0};
    AudioTimeStamp time = {0};
    for (uint32_t i = 0; i < 500; ++i) MixerTransportCaptureIOProc(0, &time, &idle, &time, &empty, &time, state);
    assert(MixerTransportWaitingForInput(state));
    assert(MixerTransportInvalidCount(state) == 0 && MixerTransportConsecutiveInvalidCount(state) == 0);
    float input[4096], output[512]; fill(input, 2048, 2, 0.1);
    capture(state, input, 2048, 2);
    render(state, output, 256);
    assert(!MixerTransportWaitingForInput(state) && MixerTransportHasReceivedSignal(state));
    AudioBufferList wrongChannels = {.mNumberBuffers = 1, .mBuffers = {{1, 2048, input}}};
    MixerTransportCaptureIOProc(0, &time, &wrongChannels, &time, &empty, &time, state);
    assert(MixerTransportInvalidCount(state) == 1 && MixerTransportConsecutiveInvalidCount(state) == 1);
    MixerTransportCaptureIOProc(0, &time, &idle, &time, &empty, &time, state);
    assert(MixerTransportWaitingForInput(state) && MixerTransportConsecutiveInvalidCount(state) == 0);
    MixerTransportDestroy(state);
}

static void asynchronous_small_clock_drift(double ppm) {
    // Simulate 120 seconds of two independently scheduled clocks without any
    // device I/O or wall-clock sleeps. Neither block size divides the other.
    MixerTransport *state = MixerTransportCreate(1, 2, 48000, 48000, 2, 509);
    assert(state);
    float input[634], output[1018]; fill(input, 317, 2, 0.1);
    MixerTransportSetPlaybackEnabled(state, true);
    double captureTime = 0, outputTime = 0;
    double capturePeriod = 317 / (48000 * (1 + ppm / 1000000));
    double outputPeriod = 509 / 48000.0;
    uint64_t maxQueuedAfterWarmup = 0;
    uint64_t underflowAfterWarmup = 0, dropsAfterWarmup = 0;
    bool warmed = false;
    while (captureTime < 120 || outputTime < 120) {
        if (captureTime <= outputTime && captureTime < 120) {
            capture(state, input, 317, 2);
            captureTime += capturePeriod;
        } else if (outputTime < 120) {
            render(state, output, 509);
            outputTime += outputPeriod;
            if (outputTime > 5 && !warmed) {
                underflowAfterWarmup = MixerTransportUnderflowFrames(state);
                dropsAfterWarmup = MixerTransportDroppedFrames(state);
                warmed = true;
            }
            if (warmed) {
                uint64_t queued = MixerTransportQueuedFrames(state);
                if (queued > maxQueuedAfterWarmup) maxQueuedAfterWarmup = queued;
                for (uint32_t i = 0; i < 1018; ++i) assert(isfinite(output[i]) && output[i] > 0.099 && output[i] < 0.101);
            }
        } else break;
    }
    assert(warmed && maxQueuedAfterWarmup < 2400);
    assert(MixerTransportUnderflowFrames(state) == underflowAfterWarmup);
    assert(MixerTransportDroppedFrames(state) == dropsAfterWarmup);
    printf("Asynchronous 317/509 blocks, clock offset %.0f ppm: queue <= %llu frames, no post-warmup underflow/drop.\n", ppm, (unsigned long long)maxQueuedAfterWarmup);
    MixerTransportDestroy(state);
}

int main(void) {
    assert(!MixerTransportCreate(1, 3, 48000, 48000, 2, 512));
    assert(!MixerTransportCreate(1, 2, NAN, 48000, 2, 512));
    waiting_and_prepared_signal();
    mono_and_planar_capture();
    overflow_does_not_overwrite_unread();
    mismatched_rates_preserve_tone(16000, 48000, 160, 480);
    mismatched_rates_preserve_tone(48000, 44100, 480, 441);
    concurrent_queue_stress();
    idle_null_is_waiting_not_invalid();
    asynchronous_small_clock_drift(150);
    asynchronous_small_clock_drift(-150);
    puts("AudioTransport: prepared gating, independent gains, mono/planar layouts, FIFO overflow, SRC and concurrent SPSC checks passed (memory only).");
    return 0;
}
