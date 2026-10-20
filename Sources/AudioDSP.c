#include "AudioDSP.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <libproc.h>

struct MixerDSP {
    _Atomic float targetGain;
    _Atomic float peak;
    _Atomic float outputPeak;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t invalidBuffers;
    _Atomic uint64_t validCallbacks;
    _Atomic uint64_t consecutiveInvalid;
    _Atomic bool receivedSignal;
    float currentGain;
    uint32_t firstInputBuffer;
    uint32_t inputBufferCount;
    _Atomic bool playback;
};

static float clampGain(float value) { return isfinite(value) ? fmaxf(0, fminf(1, value)) : 1; }

MixerDSP *MixerDSPCreate(float gain, uint32_t start, uint32_t count, bool playback) {
    MixerDSP *state = calloc(1, sizeof(MixerDSP));
    if (!state) return NULL;
    atomic_init(&state->targetGain, clampGain(gain));
    atomic_init(&state->peak, 0);
    atomic_init(&state->outputPeak, 0);
    atomic_init(&state->callbacks, 0);
    atomic_init(&state->invalidBuffers, 0);
    atomic_init(&state->validCallbacks, 0);
    atomic_init(&state->consecutiveInvalid, 0);
    atomic_init(&state->receivedSignal, false);
    state->currentGain = clampGain(gain);
    state->firstInputBuffer = start;
    state->inputBufferCount = count;
    atomic_init(&state->playback, playback);
    return state;
}
void MixerDSPDestroy(MixerDSP *state) { free(state); }
void MixerDSPSetGain(MixerDSP *state, float gain) { atomic_store_explicit(&state->targetGain, clampGain(gain), memory_order_relaxed); }
void MixerDSPSetPlaybackEnabled(MixerDSP *state, bool enabled) { atomic_store_explicit(&state->playback, enabled, memory_order_relaxed); }
float MixerDSPTakePeak(MixerDSP *state) { return atomic_exchange_explicit(&state->peak, 0, memory_order_relaxed); }
float MixerDSPTakeOutputPeak(MixerDSP *state) { return atomic_exchange_explicit(&state->outputPeak, 0, memory_order_relaxed); }
uint64_t MixerDSPCallbackCount(MixerDSP *state) { return atomic_load_explicit(&state->callbacks, memory_order_relaxed); }
uint64_t MixerDSPInvalidCount(MixerDSP *state) { return atomic_load_explicit(&state->invalidBuffers, memory_order_relaxed); }
uint64_t MixerDSPValidCallbackCount(MixerDSP *state) { return atomic_load_explicit(&state->validCallbacks, memory_order_relaxed); }
bool MixerDSPHasReceivedSignal(MixerDSP *state) { return atomic_load_explicit(&state->receivedSignal, memory_order_relaxed); }
uint64_t MixerDSPConsecutiveInvalidCount(MixerDSP *state) { return atomic_load_explicit(&state->consecutiveInvalid, memory_order_relaxed); }

static float sample(const AudioBufferList *input, uint32_t start, uint32_t count, uint32_t frame, uint32_t channel) {
    for (uint32_t b = start; b < start + count && b < input->mNumberBuffers; ++b) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (channel < buffer->mNumberChannels) {
            uint64_t index = (uint64_t)frame * buffer->mNumberChannels + channel;
            if (!buffer->mData || index >= buffer->mDataByteSize / sizeof(float)) return 0;
            float value = ((const float *)buffer->mData)[index];
            return isfinite(value) ? value : 0;
        }
        channel -= buffer->mNumberChannels;
    }
    return 0;
}

// The audio thread only touches preallocated memory and lock-free atomics.
// The tap and physical output share one aggregate clock; there is no growing queue.
void MixerDSPProcess(MixerDSP *state, const AudioBufferList *input, AudioBufferList *output) {
    atomic_fetch_add_explicit(&state->callbacks, 1, memory_order_relaxed);
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b) {
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    // An idle auto-start tap can have no input yet. That is waiting, not failure.
    if (!input || input->mNumberBuffers == 0) {
        atomic_store_explicit(&state->consecutiveInvalid, 0, memory_order_relaxed);
        return;
    }
    if (state->firstInputBuffer + state->inputBufferCount > input->mNumberBuffers) {
        atomic_fetch_add_explicit(&state->invalidBuffers, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&state->consecutiveInvalid, 1, memory_order_relaxed);
        return;
    }
    uint32_t frames = UINT32_MAX, inputChannels = 0, outputChannels = 0;
    for (uint32_t b = state->firstInputBuffer; b < state->firstInputBuffer + state->inputBufferCount; ++b) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        inputChannels += buffer->mNumberChannels;
        if (!buffer->mNumberChannels || !buffer->mData) { frames = 0; break; }
        uint32_t available = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        if (available < frames) frames = available;
    }
    uint32_t inputFrames = frames == UINT32_MAX ? 0 : frames;
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b) {
        AudioBuffer *buffer = &output->mBuffers[b];
        outputChannels += buffer->mNumberChannels;
        if (!buffer->mNumberChannels || !buffer->mData) continue;
        uint32_t available = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
        if (available < frames) frames = available;
    }
    float target = atomic_load_explicit(&state->targetGain, memory_order_relaxed);
    bool playback = atomic_load_explicit(&state->playback, memory_order_relaxed);
    if (inputFrames > 0 && outputChannels > 0 && frames > 0) {
        atomic_fetch_add_explicit(&state->validCallbacks, 1, memory_order_relaxed);
        atomic_store_explicit(&state->consecutiveInvalid, 0, memory_order_relaxed);
    } else {
        atomic_store_explicit(&state->consecutiveInvalid, 0, memory_order_relaxed);
    }
    float initial = state->currentGain;
    float peak = 0, outputPeak = 0;
    // Capture meters also work when playback is disabled for the permission check.
    for (uint32_t f = 0; f < inputFrames; ++f) {
        float l = sample(input, state->firstInputBuffer, state->inputBufferCount, f, 0);
        float r = inputChannels > 1 ? sample(input, state->firstInputBuffer, state->inputBufferCount, f, 1) : l;
        peak = fmaxf(peak, fmaxf(fabsf(l), fabsf(r)));
        if (!playback || f >= frames) continue;
        float gain = initial + (target - initial) * fminf(1, (float)(f + 1) / 128);
        uint32_t channelOffset = 0;
        for (uint32_t b = 0; b < output->mNumberBuffers; ++b) {
            AudioBuffer *buffer = &output->mBuffers[b];
            if (buffer->mData) {
                for (uint32_t c = 0; c < buffer->mNumberChannels; ++c) {
                    uint32_t channel = channelOffset + c;
                    float value = outputChannels == 1 ? (l + r) * 0.5f : (channel == 0 ? l : (channel == 1 ? r : 0));
                    ((float *)buffer->mData)[(uint64_t)f * buffer->mNumberChannels + c] = value * gain;
                    outputPeak = fmaxf(outputPeak, fabsf(value * gain));
                }
            }
            channelOffset += buffer->mNumberChannels;
        }
    }
    state->currentGain = initial + (target - initial) * fminf(1, (float)inputFrames / 128);
    if (peak > 0.0000001f) atomic_store_explicit(&state->receivedSignal, true, memory_order_relaxed);
    float oldPeak = atomic_load_explicit(&state->peak, memory_order_relaxed);
    while (peak > oldPeak && !atomic_compare_exchange_weak_explicit(&state->peak, &oldPeak, peak, memory_order_relaxed, memory_order_relaxed)) {}
    oldPeak = atomic_load_explicit(&state->outputPeak, memory_order_relaxed);
    while (outputPeak > oldPeak && !atomic_compare_exchange_weak_explicit(&state->outputPeak, &oldPeak, outputPeak, memory_order_relaxed, memory_order_relaxed)) {}
}

OSStatus MixerIOProc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                    const AudioTimeStamp *inputTime, AudioBufferList *output,
                    const AudioTimeStamp *outputTime, void *context) {
    MixerDSPProcess(context, input, output);
    return noErr;
}

OSStatus MixerUseTapInputOnly(AudioObjectID device, AudioDeviceIOProcID ioProc) {
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    if (status) return status;
    UInt32 count = size / sizeof(AudioStreamID);
    if (!count) return kAudioHardwareIllegalOperationError;
    size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32));
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)ioProc;
    usage->mNumberStreams = count;
    usage->mStreamIsOn[count - 1] = 1; // The appended tap is the only input we use.
    address.mSelector = kAudioDevicePropertyIOProcStreamUsage;
    status = AudioObjectSetPropertyData(device, &address, 0, NULL, size, usage);
    free(usage);
    return status;
}
int MixerExecutablePath(int pid, char *path, uint32_t capacity) { return proc_pidpath(pid, path, capacity); }
int MixerParentPID(int pid) {
    struct proc_bsdinfo info;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return size == sizeof(info) ? (int)info.pbi_ppid : 0;
}
