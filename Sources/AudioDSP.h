#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN
typedef struct MixerDSP MixerDSP;
MixerDSP * _Nullable MixerDSPCreate(float gain, uint32_t firstInputBuffer, uint32_t inputBufferCount, bool playback);
// Gains are linear amplitude (0 = silence, 1 = unity, 2 = 200%). Changes ramp
// for 30 ms at the stream's actual sample rate; linked peak limiting caps output.
// The compatibility constructor above assumes 48 kHz.
MixerDSP * _Nullable MixerDSPCreateWithSampleRate(float gain, uint32_t firstInputBuffer, uint32_t inputBufferCount, bool playback, double sampleRate);
void MixerDSPDestroy(MixerDSP *state);
void MixerDSPSetGain(MixerDSP *state, float gain);
void MixerDSPSetPlaybackEnabled(MixerDSP *state, bool enabled);
float MixerDSPTakePeak(MixerDSP *state);
float MixerDSPTakeOutputPeak(MixerDSP *state);
uint64_t MixerDSPCallbackCount(MixerDSP *state);
uint64_t MixerDSPInvalidCount(MixerDSP *state);
uint64_t MixerDSPValidCallbackCount(MixerDSP *state);
bool MixerDSPHasReceivedSignal(MixerDSP *state);
uint64_t MixerDSPConsecutiveInvalidCount(MixerDSP *state);
void MixerDSPProcess(MixerDSP *state, const AudioBufferList * _Nullable input, AudioBufferList *output);
OSStatus MixerIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
OSStatus MixerUseTapInputOnly(AudioObjectID device, AudioDeviceIOProcID ioProc);
int MixerExecutablePath(int pid, char *path, uint32_t capacity);
int MixerParentPID(int pid);
CF_ASSUME_NONNULL_END
