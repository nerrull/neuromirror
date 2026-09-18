// Offline validation for the Racine Shimmer DSP. No Wwise SDK required.
//
// Asserts the things that make a shimmer a shimmer: a burst at f comes back
// with energy at 2f that was not there with the pitched feedback off, the
// tail decays when it is meant to, and the loop stays bounded at the top of
// its range. Also writes a WAV of a plucked tone through it, for ears.
//
// Build (from wwise_plugins/):
//   c++ -std=c++17 -O2 -I. tests/shimmer_response_test.cpp \
//       RacineShimmer/SoundEnginePlugin/RacineShimmerDSP.cpp -o shimmer_response_test

#include "RacineShimmer/SoundEnginePlugin/RacineShimmerDSP.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace
{
    const unsigned int kSampleRate = 48000;
    const unsigned int kBlockSize = 256;

    int g_failures = 0;

    void Check(bool in_bOk, const char* in_szLabel, const char* in_szDetail = "")
    {
        printf("  [%s] %s %s\n", in_bOk ? "PASS" : "FAIL", in_szLabel, in_szDetail);
        if (!in_bOk)
            ++g_failures;
    }

    RacineShimmer::Settings MakeSettings(float in_fDecay, float in_fShimmer, float in_fPitch)
    {
        RacineShimmer::Settings s;
        s.fDecaySeconds = in_fDecay;
        s.fShimmer = in_fShimmer;
        s.fPitchSemitones = in_fPitch;
        s.fDamping = 0.0f;
        s.fWetDryMix = 1.0f;
        s.fOutputGain = 1.0f;
        return s;
    }

    /// Stereo render: a 100 ms sine burst at in_fHz, then silence, for
    /// in_fSeconds total. Returns the left channel.
    std::vector<float> Render(float in_fHz, float in_fSeconds, const RacineShimmer::Settings& in_settings)
    {
        std::vector<float> mem(RacineShimmer::MemoryFrames(kSampleRate));
        RacineShimmer::Processor dsp;
        dsp.Setup(kSampleRate, 2, mem.data());

        const unsigned int uTotal = (unsigned int)(in_fSeconds * kSampleRate);
        const unsigned int uBurst = kSampleRate / 10;
        std::vector<float> out(uTotal);
        float bufL[kBlockSize], bufR[kBlockSize];
        float* ch[2] = { bufL, bufR };

        for (unsigned int n = 0; n < uTotal; n += kBlockSize)
        {
            for (unsigned int i = 0; i < kBlockSize; ++i)
            {
                const unsigned int t = n + i;
                const float v = t < uBurst ? 0.5f * sinf(2.0f * 3.14159265f * in_fHz * t / kSampleRate) : 0.0f;
                bufL[i] = bufR[i] = v;
            }
            dsp.Process(ch, 2, kBlockSize, in_settings, in_settings);
            for (unsigned int i = 0; i < kBlockSize && n + i < uTotal; ++i)
                out[n + i] = bufL[i];
        }
        return out;
    }

    float RMS(const std::vector<float>& in_v, unsigned int in_uFrom, unsigned int in_uTo)
    {
        double acc = 0.0;
        for (unsigned int i = in_uFrom; i < in_uTo; ++i)
            acc += (double)in_v[i] * in_v[i];
        return (float)sqrt(acc / (in_uTo - in_uFrom));
    }

    /// Goertzel magnitude at in_fHz over [from, to).
    float Tone(const std::vector<float>& in_v, unsigned int in_uFrom, unsigned int in_uTo, float in_fHz)
    {
        const double w = 2.0 * M_PI * in_fHz / kSampleRate;
        const double coef = 2.0 * cos(w);
        double s0 = 0, s1 = 0, s2 = 0;
        for (unsigned int i = in_uFrom; i < in_uTo; ++i)
        {
            s0 = in_v[i] + coef * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        return (float)sqrt(s1 * s1 + s2 * s2 - coef * s1 * s2) / (in_uTo - in_uFrom);
    }

    bool Finite(const std::vector<float>& in_v)
    {
        for (float f : in_v)
            if (!std::isfinite(f))
                return false;
        return true;
    }

    void WriteWav(const char* in_szPath, const std::vector<float>& in_v)
    {
        FILE* f = fopen(in_szPath, "wb");
        if (!f)
            return;
        const uint32_t uData = (uint32_t)in_v.size() * 2;
        const uint32_t uRate = kSampleRate, uByteRate = kSampleRate * 2;
        const uint16_t uFmt = 1, uCh = 1, uAlign = 2, uBits = 16;
        const uint32_t uFmtLen = 16, uRiff = 36 + uData;
        fwrite("RIFF", 1, 4, f); fwrite(&uRiff, 4, 1, f); fwrite("WAVE", 1, 4, f);
        fwrite("fmt ", 1, 4, f); fwrite(&uFmtLen, 4, 1, f); fwrite(&uFmt, 2, 1, f); fwrite(&uCh, 2, 1, f);
        fwrite(&uRate, 4, 1, f); fwrite(&uByteRate, 4, 1, f); fwrite(&uAlign, 2, 1, f); fwrite(&uBits, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&uData, 4, 1, f);
        for (float v : in_v)
        {
            const float c = v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);
            const int16_t s = (int16_t)(c * 32767.0f);
            fwrite(&s, 2, 1, f);
        }
        fclose(f);
    }
}

int main()
{
    printf("Racine Shimmer DSP\n");

    const float kHz = 440.0f;
    const unsigned int uWinFrom = 2 * kSampleRate, uWinTo = 3 * kSampleRate;

    // 1. Plain reverb: the tail decays and holds no octave that the input lacked.
    const std::vector<float> dry = Render(kHz, 4.0f, MakeSettings(2.0f, 0.0f, 12.0f));
    const float dryOct = Tone(dry, uWinFrom, uWinTo, 2 * kHz);
    const float dryFifth = Tone(dry, uWinFrom, uWinTo, kHz * powf(2.0f, 7.0f / 12.0f));
    {
        char detail[128];
        const float early = RMS(dry, kSampleRate / 10, kSampleRate / 10 + kSampleRate / 4);
        const float late = RMS(dry, 3 * kSampleRate, 4 * kSampleRate);
        snprintf(detail, sizeof(detail), "(early %.4f, late %.6f)", early, late);
        Check(Finite(dry), "shimmer off: finite");
        Check(early > 0.01f, "shimmer off: has a tail", detail);
        Check(late < early * 0.05f, "shimmer off: tail decays", detail);

        const float fund = Tone(dry, uWinFrom, uWinTo, kHz);
        snprintf(detail, sizeof(detail), "(f %.2e, 2f %.2e)", fund, dryOct);
        Check(dryOct < fund * 0.2f, "shimmer off: no octave", detail);
    }

    // 2. Shimmer on, +12: the octave shows up in the tail where the plain
    //    reverb had none; +7: the fifth does, and not the octave.
    {
        const std::vector<float> v = Render(kHz, 4.0f, MakeSettings(2.0f, 0.6f, 12.0f));
        char detail[128];
        const float fund = Tone(v, uWinFrom, uWinTo, kHz);
        const float oct = Tone(v, uWinFrom, uWinTo, 2 * kHz);
        snprintf(detail, sizeof(detail), "(f %.2e, 2f %.2e, 2f dry %.2e)", fund, oct, dryOct);
        Check(Finite(v), "+12: finite");
        Check(oct > dryOct * 10.0f && oct > fund * 0.25f, "+12: octave in the tail", detail);
        WriteWav("shimmer_octave.wav", v);

        const std::vector<float> w = Render(kHz, 4.0f, MakeSettings(2.0f, 0.6f, 7.0f));
        const float fifth = Tone(w, uWinFrom, uWinTo, kHz * powf(2.0f, 7.0f / 12.0f));
        const float oct2 = Tone(w, uWinFrom, uWinTo, 2 * kHz);
        snprintf(detail, sizeof(detail), "(fifth %.2e, fifth dry %.2e, octave %.2e)", fifth, dryFifth, oct2);
        Check(fifth > dryFifth * 10.0f && fifth > oct2, "+7: fifth, not octave", detail);
    }

    // 3. Full shimmer sustains: that is the point of the clip.
    {
        const std::vector<float> v = Render(kHz, 8.0f, MakeSettings(2.0f, 1.0f, 12.0f));
        char detail[128];
        const float late = RMS(v, 7 * kSampleRate, 8 * kSampleRate);
        snprintf(detail, sizeof(detail), "(rms at 7 s %.4f)", late);
        Check(late > 0.05f, "shimmer 100%: sustains", detail);
    }

    // 4. Everything at the top of its range stays bounded.
    {
        const std::vector<float> v = Render(kHz, 8.0f, MakeSettings(20.0f, 1.0f, 12.0f));
        float peak = 0.0f;
        for (float f : v)
            peak = fabsf(f) > peak ? fabsf(f) : peak;
        char detail[64];
        snprintf(detail, sizeof(detail), "(peak %.3f)", peak);
        Check(Finite(v), "max: finite");
        Check(peak < 4.0f, "max: bounded", detail);
    }

    // 5. A block-rate jump of the ramped parameters does not click: the
    //    steepest sample step after the jump is no worse than before it.
    {
        std::vector<float> mem(RacineShimmer::MemoryFrames(kSampleRate));
        RacineShimmer::Processor dsp;
        dsp.Setup(kSampleRate, 2, mem.data());
        RacineShimmer::Settings a = MakeSettings(3.0f, 0.5f, 12.0f);
        RacineShimmer::Settings b = a;
        b.fShimmer = 0.0f;
        b.fWetDryMix = 0.2f;
        b.fOutputGain = 0.5f;
        float bufL[kBlockSize], bufR[kBlockSize];
        float* ch[2] = { bufL, bufR };
        const unsigned int uSwap = 2 * kSampleRate;
        float stepBefore = 0.0f, stepAfter = 0.0f, last = 0.0f;
        for (unsigned int n = 0; n < 3 * kSampleRate; n += kBlockSize)
        {
            for (unsigned int i = 0; i < kBlockSize; ++i)
                bufL[i] = bufR[i] = 0.3f * sinf(2.0f * 3.14159265f * kHz * (n + i) / kSampleRate);
            const RacineShimmer::Settings& prev = n <= uSwap ? a : b;
            const RacineShimmer::Settings& cur = n < uSwap ? a : b;
            dsp.Process(ch, 2, kBlockSize, prev, cur);
            for (unsigned int i = 0; i < kBlockSize; ++i)
            {
                const float step = fabsf(bufL[i] - last);
                last = bufL[i];
                if (n + i < kSampleRate)
                    continue;
                float& worst = n + i < uSwap ? stepBefore : stepAfter;
                worst = step > worst ? step : worst;
            }
        }
        char detail[64];
        snprintf(detail, sizeof(detail), "(max step before %.3f, after %.3f)", stepBefore, stepAfter);
        Check(stepAfter < stepBefore * 1.5f, "param jump: no click", detail);
    }

    printf("%s\n", g_failures ? "SOME CHECKS FAILED" : "ALL CHECKS PASSED");
    return g_failures ? 1 : 0;
}
