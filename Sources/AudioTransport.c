#include "AudioTransport.h"
#include "AudioDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

_Static_assert(ATOMIC_LONG_LOCK_FREE == 2, "The audio transport requires lock-free 64-bit counters");

struct MixerTransport {
    MixerDSP *dsp;
    float *fifo;
    float *renderInput;
    AudioBufferList inputList;
    uint32_t captureChannels;
    uint32_t outputChannels;
    uint32_t maximumOutputFrames;
    uint32_t capacity;
    uint32_t mask;
    uint32_t targetFrames;
    double captureRate;
    double nominalStep;
    double phase;
    bool primed;
    _Atomic uint64_t readFrame;
    _Atomic uint64_t writeFrame;
    _Atomic uint64_t captureCallbacks;
    _Atomic bool waitingForInput;
    _Atomic uint64_t invalidCapture;
    _Atomic uint64_t consecutiveInvalidCapture;
    _Atomic uint64_t droppedFrames;
    _Atomic uint64_t underflowFrames;
};

static double clamp(double value, double low, double high) {
    return value < low ? low : (value > high ? high : value);
}
static void zeroOutput(AudioBufferList *output) {
    if (!output) return;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
}

MixerTransport *MixerTransportCreate(float gain, uint32_t captureChannels, double captureRate,
                                    double outputRate, uint32_t outputChannels, uint32_t maximumOutputFrames) {
    if (!isfinite(captureRate) || !isfinite(outputRate) || captureRate < 8000 || captureRate > 384000 ||
        outputRate < 8000 || outputRate > 384000 || captureChannels < 1 || captureChannels > 2 ||
        outputChannels < 1 || outputChannels > 2 || !maximumOutputFrames || maximumOutputFrames > 65536) return NULL;
    MixerTransport *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->captureChannels = captureChannels;
    state->outputChannels = outputChannels;
    state->maximumOutputFrames = maximumOutputFrames;
    state->captureRate = captureRate;
    state->nominalStep = captureRate / outputRate;
    state->targetFrames = (uint32_t)fmax(32, ceil(captureRate * 0.02));
    state->capacity = 2048;
    double needed = fmax(ceil(captureRate * 0.25), ceil(maximumOutputFrames * state->nominalStep) + state->targetFrames + 4);
    while (state->capacity < needed) state->capacity <<= 1;
    state->mask = state->capacity - 1;
    state->fifo = calloc((size_t)state->capacity * 2, sizeof(float));
    state->renderInput = calloc((size_t)maximumOutputFrames * 2, sizeof(float));
    state->dsp = MixerDSPCreateWithSampleRate(gain, 0, 1, false, outputRate);
    if (!state->fifo || !state->renderInput || !state->dsp) {
        MixerTransportDestroy(state);
        return NULL;
    }
    state->inputList.mNumberBuffers = 1;
    state->inputList.mBuffers[0].mNumberChannels = 2;
    state->inputList.mBuffers[0].mData = state->renderInput;
    atomic_init(&state->readFrame, 0);
    atomic_init(&state->writeFrame, 0);
    atomic_init(&state->captureCallbacks, 0);
    atomic_init(&state->waitingForInput, true);
    atomic_init(&state->invalidCapture, 0);
    atomic_init(&state->consecutiveInvalidCapture, 0);
    atomic_init(&state->droppedFrames, 0);
    atomic_init(&state->underflowFrames, 0);
    return state;
}

void MixerTransportDestroy(MixerTransport *state) {
    if (!state) return;
    if (state->dsp) MixerDSPDestroy(state->dsp);
    free(state->fifo);
    free(state->renderInput);
    free(state);
}
void MixerTransportSetGain(MixerTransport *state, float gain) { MixerDSPSetGain(state->dsp, gain); }
void MixerTransportSetPlaybackEnabled(MixerTransport *state, bool enabled) { MixerDSPSetPlaybackEnabled(state->dsp, enabled); }
float MixerTransportTakePeak(MixerTransport *state) { return MixerDSPTakePeak(state->dsp); }
float MixerTransportTakeOutputPeak(MixerTransport *state) { return MixerDSPTakeOutputPeak(state->dsp); }
uint64_t MixerTransportCallbackCount(MixerTransport *state) { return MixerDSPCallbackCount(state->dsp); }
uint64_t MixerTransportValidCallbackCount(MixerTransport *state) { return MixerDSPValidCallbackCount(state->dsp); }
bool MixerTransportHasReceivedSignal(MixerTransport *state) { return MixerDSPHasReceivedSignal(state->dsp); }
uint64_t MixerTransportInvalidCount(MixerTransport *state) {
    return atomic_load_explicit(&state->invalidCapture, memory_order_relaxed) + MixerDSPInvalidCount(state->dsp);
}
uint64_t MixerTransportConsecutiveInvalidCount(MixerTransport *state) {
    uint64_t capture = atomic_load_explicit(&state->consecutiveInvalidCapture, memory_order_relaxed);
    uint64_t render = MixerDSPConsecutiveInvalidCount(state->dsp);
    return capture > render ? capture : render;
}
uint64_t MixerTransportCaptureCallbackCount(MixerTransport *state) { return atomic_load_explicit(&state->captureCallbacks, memory_order_relaxed); }
bool MixerTransportWaitingForInput(MixerTransport *state) { return atomic_load_explicit(&state->waitingForInput, memory_order_relaxed); }
uint64_t MixerTransportDroppedFrames(MixerTransport *state) { return atomic_load_explicit(&state->droppedFrames, memory_order_relaxed); }
uint64_t MixerTransportUnderflowFrames(MixerTransport *state) { return atomic_load_explicit(&state->underflowFrames, memory_order_relaxed); }
uint64_t MixerTransportQueuedFrames(MixerTransport *state) {
    uint64_t read = atomic_load_explicit(&state->readFrame, memory_order_acquire);
    uint64_t write = atomic_load_explicit(&state->writeFrame, memory_order_acquire);
    return write >= read ? write - read : 0;
}
uint32_t MixerTransportCapacityFrames(MixerTransport *state) { return state->capacity; }

static float captureSample(const AudioBufferList *input, uint32_t frame, uint32_t channel) {
    for (UInt32 b = 0; b < input->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (channel < buffer->mNumberChannels) {
            float sample = ((const float *)buffer->mData)[(size_t)frame * buffer->mNumberChannels + channel];
            return isfinite(sample) ? sample : 0;
        }
        channel -= buffer->mNumberChannels;
    }
    return 0;
}

OSStatus MixerTransportCaptureIOProc(AudioObjectID device, const AudioTimeStamp *now,
                                    const AudioBufferList *input, const AudioTimeStamp *inputTime,
                                    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    MixerTransport *state = context;
    zeroOutput(output); // A tap-only aggregate normally has no output buffers.
    if (!state) return noErr;
    atomic_fetch_add_explicit(&state->captureCallbacks, 1, memory_order_relaxed);
    if (!input || !input->mNumberBuffers) {
        atomic_store_explicit(&state->waitingForInput, true, memory_order_relaxed);
        atomic_store_explicit(&state->consecutiveInvalidCapture, 0, memory_order_relaxed);
        return noErr;
    }
    if (input->mNumberBuffers > 2) {
        atomic_store_explicit(&state->waitingForInput, false, memory_order_relaxed);
        atomic_fetch_add_explicit(&state->invalidCapture, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&state->consecutiveInvalidCapture, 1, memory_order_relaxed);
        return noErr;
    }
    // Idle CoreAudio clients may keep their I/O registered but deliver null or
    // empty buffers. Waiting is not malformed input and must not poison health.
    for (UInt32 b = 0; b < input->mNumberBuffers; ++b) {
        if (!input->mBuffers[b].mData || !input->mBuffers[b].mDataByteSize) {
            atomic_store_explicit(&state->waitingForInput, true, memory_order_relaxed);
            atomic_store_explicit(&state->consecutiveInvalidCapture, 0, memory_order_relaxed);
            return noErr;
        }
    }
    atomic_store_explicit(&state->waitingForInput, false, memory_order_relaxed);
    uint32_t channels = 0, frames = UINT32_MAX;
    bool malformed = false;
    for (UInt32 b = 0; b < input->mNumberBuffers && !malformed; ++b) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        channels += buffer->mNumberChannels;
        if (!buffer->mNumberChannels || buffer->mNumberChannels > 2 || !buffer->mData ||
            buffer->mDataByteSize % (sizeof(float) * buffer->mNumberChannels)) { malformed = true; break; }
        uint32_t available = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        if (available < frames) frames = available;
    }
    if (malformed || channels != state->captureChannels) {
        atomic_fetch_add_explicit(&state->invalidCapture, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&state->consecutiveInvalidCapture, 1, memory_order_relaxed);
        return noErr;
    }
    atomic_store_explicit(&state->consecutiveInvalidCapture, 0, memory_order_relaxed);
    if (!frames || frames == UINT32_MAX) return noErr;
    uint64_t write = atomic_load_explicit(&state->writeFrame, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&state->readFrame, memory_order_acquire);
    uint64_t freeFrames = state->capacity - (write - read);
    uint32_t accepted = frames < freeFrames ? frames : (uint32_t)freeFrames;
    for (uint32_t frame = 0; frame < accepted; ++frame) {
        size_t index = (size_t)((write + frame) & state->mask) * 2;
        float l = captureSample(input, frame, 0);
        float r = channels > 1 ? captureSample(input, frame, 1) : l;
        state->fifo[index] = l;
        state->fifo[index + 1] = r;
    }
    // Publish only after all samples are written. A full queue drops new frames;
    // the producer never advances readFrame or overwrites the consumer's data.
    atomic_store_explicit(&state->writeFrame, write + accepted, memory_order_release);
    atomic_fetch_add_explicit(&state->droppedFrames, frames - accepted, memory_order_relaxed);
    return noErr;
}

OSStatus MixerTransportRender(void *context, AudioUnitRenderActionFlags *flags,
                             const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *output) {
    (void)time; (void)bus;
    MixerTransport *state = context;
    if (!state || !output) { zeroOutput(output); return noErr; }
    if (frames > state->maximumOutputFrames) {
        zeroOutput(output);
        atomic_fetch_add_explicit(&state->invalidCapture, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&state->consecutiveInvalidCapture, 1, memory_order_relaxed);
        return noErr;
    }
    uint32_t outputChannels = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &output->mBuffers[b];
        outputChannels += buffer->mNumberChannels;
        if (!buffer->mData || !buffer->mNumberChannels ||
            buffer->mDataByteSize < (uint64_t)frames * buffer->mNumberChannels * sizeof(float)) {
            zeroOutput(output);
            return noErr;
        }
    }
    if (outputChannels != state->outputChannels) { zeroOutput(output); return noErr; }
    uint64_t read = atomic_load_explicit(&state->readFrame, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&state->writeFrame, memory_order_acquire);
    uint64_t available = write - read;
    uint64_t target = (uint64_t)ceil(frames * state->nominalStep) + 2;
    if (target < state->targetFrames) target = state->targetFrames;
    if (!state->primed && available >= target + 2) state->primed = true;
    // Only the consumer can safely discard old queued audio after a scheduling
    // stall. Bound stale latency without racing a producer overwrite.
    if (available > target + (uint64_t)(state->captureRate * 0.10)) {
        uint64_t skipped = available - target;
        read += skipped;
        available -= skipped;
        state->phase = 0;
        atomic_fetch_add_explicit(&state->droppedFrames, skipped, memory_order_relaxed);
    }
    double error = (double)available - target;
    // A slow proportional clock correction, capped at +/-0.3%. This absorbs
    // normal clock drift; larger stalls use bounded drops/rebuffering instead.
    double adjustment = clamp(error / (state->captureRate * 0.02) * 0.002, -0.003, 0.003);
    double step = state->nominalStep * (1 + adjustment);
    uint32_t produced = 0;
    if (state->primed) {
        for (; produced < frames; ++produced) {
            uint64_t advance = (uint64_t)floor(state->phase + step);
            if (write - read < advance + 2) break;
            size_t current = (size_t)(read & state->mask) * 2;
            size_t next = (size_t)((read + 1) & state->mask) * 2;
            float fraction = (float)state->phase;
            state->renderInput[(size_t)produced * 2] = state->fifo[current] + (state->fifo[next] - state->fifo[current]) * fraction;
            state->renderInput[(size_t)produced * 2 + 1] = state->fifo[current + 1] + (state->fifo[next + 1] - state->fifo[current + 1]) * fraction;
            state->phase += step;
            advance = (uint64_t)floor(state->phase);
            read += advance;
            state->phase -= advance;
        }
        if (produced < frames) {
            // Leave no stale partial frame for the next start. Concurrent new
            // producer samples beyond this callback's write snapshot are kept.
            read = write;
            state->phase = 0;
            state->primed = false;
        }
    }
    atomic_store_explicit(&state->readFrame, read, memory_order_release);
    atomic_fetch_add_explicit(&state->underflowFrames, frames - produced, memory_order_relaxed);
    state->inputList.mBuffers[0].mDataByteSize = produced * 2 * sizeof(float);
    MixerDSPProcess(state->dsp, produced ? &state->inputList : NULL, output);
    if (!produced && flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}
