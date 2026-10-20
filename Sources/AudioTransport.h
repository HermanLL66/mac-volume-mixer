#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN
typedef struct MixerTransport MixerTransport;

// Capture and output have independent clocks. The fixed SPSC queue stores stereo
// Float32 at captureRate; the output callback resamples and applies the DSP gain.
MixerTransport * _Nullable MixerTransportCreate(float gain, uint32_t captureChannels,
                                                double captureRate, double outputRate,
                                                uint32_t outputChannels, uint32_t maximumOutputFrames);
void MixerTransportDestroy(MixerTransport *transport);
void MixerTransportSetGain(MixerTransport *transport, float gain);
void MixerTransportSetPlaybackEnabled(MixerTransport *transport, bool enabled);
float MixerTransportTakePeak(MixerTransport *transport);
float MixerTransportTakeOutputPeak(MixerTransport *transport);
uint64_t MixerTransportCallbackCount(MixerTransport *transport);
uint64_t MixerTransportValidCallbackCount(MixerTransport *transport);
bool MixerTransportHasReceivedSignal(MixerTransport *transport);
uint64_t MixerTransportInvalidCount(MixerTransport *transport);
uint64_t MixerTransportConsecutiveInvalidCount(MixerTransport *transport);
uint64_t MixerTransportCaptureCallbackCount(MixerTransport *transport);
bool MixerTransportWaitingForInput(MixerTransport *transport);
uint64_t MixerTransportDroppedFrames(MixerTransport *transport);
uint64_t MixerTransportUnderflowFrames(MixerTransport *transport);
uint64_t MixerTransportQueuedFrames(MixerTransport *transport);
uint32_t MixerTransportCapacityFrames(MixerTransport *transport);

// These callbacks use only preallocated memory and lock-free atomics. Neither
// callback opens a physical input, calls Swift, allocates, or takes a mutex.
OSStatus MixerTransportCaptureIOProc(AudioObjectID device, const AudioTimeStamp *now,
                                    const AudioBufferList *input, const AudioTimeStamp *inputTime,
                                    AudioBufferList *output, const AudioTimeStamp *outputTime,
                                    void * _Nullable context);
OSStatus MixerTransportRender(void *context, AudioUnitRenderActionFlags *flags,
                             const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                             AudioBufferList * _Nullable output);
CF_ASSUME_NONNULL_END
