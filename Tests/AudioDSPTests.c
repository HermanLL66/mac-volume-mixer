#include "AudioDSP.h"
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FRAMES 512
static void near(float actual, float expected) { assert(fabsf(actual - expected) < 0.00001f); }
static AudioBufferList *list(unsigned count) {
    AudioBufferList *value = calloc(1, offsetof(AudioBufferList, mBuffers) + count * sizeof(AudioBuffer));
    value->mNumberBuffers = count;
    return value;
}

static void checkTimeBasedRamp(double sampleRate) {
    float input[2] = { 0.25f, -0.125f }, output[2];
    AudioBufferList *in = list(1), *out = list(1);
    in->mBuffers[0] = (AudioBuffer){ 2, sizeof(input), input };
    out->mBuffers[0] = (AudioBuffer){ 2, sizeof(output), output };
    MixerDSP *state = MixerDSPCreateWithSampleRate(0, 0, 1, true, sampleRate);
    assert(state);
    unsigned rampFrames = (unsigned)ceil(sampleRate * 0.030);
    MixerDSPSetGain(state, 2);
    float previous = 0;
    for (unsigned frame = 0; frame < rampFrames; ++frame) {
        // One-frame callbacks prove the transition carries across buffers.
        MixerDSPProcess(state, in, out);
        float expected = 0.5f * (float)(frame + 1) / rampFrames;
        near(output[0], expected); near(output[1], -expected * 0.5f);
        assert(output[0] >= previous && output[0] - previous <= 0.5f / rampFrames + 0.000001f);
        previous = output[0];
    }
    near(output[0], 0.5f);
    MixerDSPProcess(state, in, out); near(output[0], 0.5f);
    MixerDSPSetGain(state, 0);
    for (unsigned frame = 0; frame < rampFrames; ++frame) {
        MixerDSPProcess(state, in, out);
        assert(output[0] <= previous && output[0] >= 0);
        if (frame + 1 < rampFrames) assert(output[0] > 0);
        previous = output[0];
    }
    assert(output[0] == 0 && output[1] == 0);
    MixerDSPProcess(state, in, out); assert(output[0] == 0);
    MixerDSPDestroy(state); free(in); free(out);
}

static void checkBoostAndLimiter(void) {
    float input[FRAMES * 2], output[FRAMES * 2];
    AudioBufferList *in = list(1), *out = list(1);
    in->mBuffers[0] = (AudioBuffer){ 2, sizeof(input), input };
    out->mBuffers[0] = (AudioBuffer){ 2, sizeof(output), output };
    for (unsigned i = 0; i < FRAMES; ++i) { input[i * 2] = 0.25f; input[i * 2 + 1] = -0.125f; }
    MixerDSP *boost = MixerDSPCreateWithSampleRate(2, 0, 1, true, 48000);
    MixerDSP *capped = MixerDSPCreateWithSampleRate(9, 0, 1, true, 48000);
    MixerDSP *unity = MixerDSPCreateWithSampleRate(1, 0, 1, true, 48000);
    assert(boost && capped && unity);
    MixerDSPProcess(boost, in, out); near(output[0], 0.5f); near(output[1], -0.25f);
    MixerDSPProcess(capped, in, out); near(output[0], 0.5f);
    input[0] = 1; input[1] = -1;
    MixerDSPProcess(unity, in, out); near(output[0], 1); near(output[1], -1);
    for (unsigned i = 0; i < FRAMES; ++i) { input[i * 2] = 0.8f; input[i * 2 + 1] = -0.4f; }
    MixerDSPProcess(boost, in, out);
    for (unsigned i = 0; i < FRAMES; ++i) {
        near(output[i * 2], 1); near(output[i * 2 + 1], -0.5f);
        assert(isfinite(output[i * 2]) && fabsf(output[i * 2]) <= 1);
    }
    // The release is smooth, linked between channels, and lasts across blocks.
    for (unsigned i = 0; i < FRAMES; ++i) { input[i * 2] = 0.2f; input[i * 2 + 1] = -0.1f; }
    float previous = 0.25f;
    for (unsigned block = 0; block < 8; ++block) {
        MixerDSPProcess(boost, in, out);
        for (unsigned i = 0; i < FRAMES; ++i) {
            assert(output[i * 2] >= previous && output[i * 2] <= 0.4f);
            assert(output[i * 2] - previous < 0.0001f);
            near(output[i * 2 + 1], -0.5f * output[i * 2]);
            previous = output[i * 2];
        }
    }
    assert(previous > 0.34f && previous < 0.36f);
    // Extremely large finite samples must not overflow the boost multiply.
    input[0] = FLT_MAX; input[1] = -FLT_MAX * 0.5f;
    MixerDSPProcess(capped, in, out);
    near(output[0], 1); near(output[1], -0.5f);
    for (unsigned i = 0; i < FRAMES * 2; ++i) assert(isfinite(output[i]) && fabsf(output[i]) <= 1);
    MixerDSPDestroy(boost); MixerDSPDestroy(capped); MixerDSPDestroy(unity); free(in); free(out);
}

int main(void) {
    checkTimeBasedRamp(44100); checkTimeBasedRamp(48000); checkTimeBasedRamp(96000);
    checkBoostAndLimiter();
    float input[FRAMES * 2], output[FRAMES * 2];
    for (unsigned i = 0; i < FRAMES; ++i) { input[i * 2] = 0.8f; input[i * 2 + 1] = -0.4f; }
    AudioBufferList *in = list(1), *out = list(1);
    in->mBuffers[0] = (AudioBuffer){ 2, sizeof(input), input };
    out->mBuffers[0] = (AudioBuffer){ 2, sizeof(output), output };
    MixerDSP *a = MixerDSPCreate(0.25f, 0, 1, true);
    MixerDSP *b = MixerDSPCreate(0.75f, 0, 1, true);
    // Silent but structurally valid callbacks cannot authorize intercepting audio.
    MixerDSP *silent = MixerDSPCreate(1, 0, 1, false);
    float silence[FRAMES * 2] = {0};
    AudioBufferList *silentIn = list(1);
    silentIn->mBuffers[0] = (AudioBuffer){ 2, sizeof(silence), silence };
    for (unsigned i = 0; i < 5; ++i) MixerDSPProcess(silent, silentIn, out);
    assert(MixerDSPValidCallbackCount(silent) == 5 && !MixerDSPHasReceivedSignal(silent));
    MixerDSPProcess(silent, in, out);
    assert(MixerDSPHasReceivedSignal(silent));
    (void)MixerDSPTakePeak(silent);
    assert(MixerDSPHasReceivedSignal(silent));
    MixerDSPDestroy(silent); free(silentIn);
    MixerDSPProcess(a, in, out);
    near(output[0], 0.2f); near(output[1], -0.1f);
    near(MixerDSPTakePeak(a), 0.8f); near(MixerDSPTakeOutputPeak(a), 0.2f);
    MixerDSPProcess(b, in, out);
    near(output[0], 0.6f); near(output[1], -0.3f);
    MixerDSPSetGain(a, 0);
    MixerDSPProcess(a, in, out);
    assert(output[0] > 0 && output[0] < 0.2f);
    assert(output[FRAMES * 2 - 2] > 0); // A 48 kHz ramp lasts 1440 frames, not 128.
    for (unsigned block = 0; block < 3; ++block) MixerDSPProcess(a, in, out);
    for (unsigned i = 0; i < FRAMES * 2; ++i) near(output[i], 0);
    MixerDSPProcess(b, in, out); near(output[0], 0.6f); // A's mute never affects B.
    MixerDSPSetGain(a, 1);
    for (unsigned block = 0; block < 3; ++block) MixerDSPProcess(a, in, out);
    near(output[FRAMES * 2 - 2], 0.8f);
    MixerDSPSetGain(a, NAN); MixerDSPProcess(a, in, out); near(output[0], 0.8f);
    input[0] = NAN; input[1] = INFINITY;
    MixerDSPProcess(a, in, out); near(output[0], 0); near(output[1], 0);
    input[0] = 0.8f; input[1] = -0.4f;
    MixerDSP *monitor = MixerDSPCreate(1, 0, 1, false);
    MixerDSPProcess(monitor, in, out);
    for (unsigned i = 0; i < FRAMES * 2; ++i) near(output[i], 0);
    near(MixerDSPTakePeak(monitor), 0.8f);
    assert(MixerDSPValidCallbackCount(monitor) == 1);
    MixerDSPSetPlaybackEnabled(monitor, true);
    MixerDSPProcess(monitor, in, out); near(output[0], 0.8f);
    MixerDSPSetPlaybackEnabled(monitor, false);
    MixerDSPProcess(monitor, in, out); near(output[0], 0);

    // Physical microphone buffers precede the tap; they must never be mixed in.
    float mic[FRAMES], left[FRAMES], right[FRAMES], leftOut[FRAMES + 1], rightOut[FRAMES + 1];
    for (unsigned i = 0; i < FRAMES; ++i) { mic[i] = 99; left[i] = 0.2f; right[i] = -0.6f; }
    leftOut[FRAMES] = 123; rightOut[FRAMES] = 456;
    AudioBufferList *planarIn = list(3), *planarOut = list(2);
    planarIn->mBuffers[0] = (AudioBuffer){ 1, sizeof(mic), mic };
    planarIn->mBuffers[1] = (AudioBuffer){ 1, sizeof(left), left };
    planarIn->mBuffers[2] = (AudioBuffer){ 1, sizeof(right), right };
    planarOut->mBuffers[0] = (AudioBuffer){ 1, sizeof(float) * FRAMES, leftOut };
    planarOut->mBuffers[1] = (AudioBuffer){ 1, sizeof(float) * FRAMES, rightOut };
    MixerDSP *planar = MixerDSPCreate(0.5f, 1, 2, true);
    MixerDSPProcess(planar, planarIn, planarOut);
    near(leftOut[0], 0.1f); near(rightOut[0], -0.3f);
    near(leftOut[FRAMES], 123); near(rightOut[FRAMES], 456);
    // Short buffers and missing input must produce silence without reading past memory.
    planarIn->mBuffers[2].mDataByteSize = sizeof(float) * 7;
    MixerDSPProcess(planar, planarIn, planarOut);
    near(rightOut[6], -0.3f); near(rightOut[7], 0); near(leftOut[7], 0);
    planarIn->mBuffers[2].mData = NULL;
    MixerDSPProcess(planar, planarIn, planarOut); near(leftOut[0], 0);
    MixerDSPProcess(planar, NULL, planarOut); assert(MixerDSPInvalidCount(planar) == 0);
    planarIn->mNumberBuffers = 1;
    MixerDSPProcess(planar, planarIn, planarOut);
    assert(MixerDSPInvalidCount(planar) == 1 && MixerDSPConsecutiveInvalidCount(planar) == 1);
    planarIn->mNumberBuffers = 3;
    planarIn->mBuffers[2].mData = right;
    planarIn->mBuffers[2].mDataByteSize = sizeof(right);
    for (unsigned i = 0; i < 10000; ++i) MixerDSPProcess(planar, planarIn, planarOut);
    assert(MixerDSPCallbackCount(planar) == 10005);
    assert(MixerDSPConsecutiveInvalidCount(planar) == 0);
    MixerDSPDestroy(a); MixerDSPDestroy(b); MixerDSPDestroy(planar); MixerDSPDestroy(monitor);
    free(in); free(out); free(planarIn); free(planarOut);
    puts("PASS: 0-200% gains, unity, sample-rate-correct 30 ms ramps, linked limiter/release, finite safety, independent mute, planar stereo, isolation, short buffers, 10,000 callbacks");
}
