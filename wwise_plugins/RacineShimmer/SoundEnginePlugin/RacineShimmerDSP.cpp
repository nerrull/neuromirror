/*******************************************************************************
Racine Shimmer - a reverb with a pitch shifter in its feedback loop.

    in --+--> diffusers --> FDN tank --+--> wet
         ^                             |
         +--- shimmer * clip(LP(HP(pitch shift))) <---+

The tank is an 8-line feedback delay network mixed with a Householder matrix
(orthogonal, so the only loss is the per-line decay gain and the damping
lowpass). Its output is shifted by Pitch and fed back to the input, so every
pass round the loop climbs another interval: an octave up gives the classic
shimmer, a fifth stacks into a chord. The shifter is the two-head granular
kind -- two taps on a delay line sweeping in opposite phase under a sine
crossfade, which is the same thing a comb sweep does but keeps sweeping.

The pitched path is soft-clipped rather than trusted to stay bounded: with
Shimmer near 1 and a long Decay the loop gain sits at or above unity, and the
bloom that comes from letting it lean on the clip is the sound people want
from this effect. The tank lines clip the same way, so what it leans on is
full scale and not the bus limiter.
*******************************************************************************/

#include "RacineShimmerDSP.h"

#include <cmath>
#include <cstring>

namespace
{
    const float kPi = 3.14159265358979f;

    /// Keeps the tank out of denormal range without audible offset.
    const float kDenormalGuard = 1e-18f;

    /// Ceiling on the tail estimate, in seconds. Shimmer at 1 sustains for as
    /// long as the clip lets it; the bus has to be let go at some point.
    const float kMaxTailSeconds = 30.0f;

    /// Diffuser lengths, in ms, and their gain. Dattorro's input diffusers.
    const float kDiffuserMs[RacineShimmer::kNumDiffusers] = { 4.77f, 3.59f, 12.73f, 9.31f };
    const float kDiffuserGain = 0.625f;

    /// Tank line lengths, in ms. Mutually irrational-ish so the modes spread.
    const float kLineMs[RacineShimmer::kNumLines] =
        { 31.1f, 37.3f, 43.9f, 51.7f, 59.3f, 67.1f, 73.7f, 83.3f };

    inline float Clamp(float v, float lo, float hi)
    {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    inline unsigned int MsToFrames(float in_fMs, unsigned int in_uSampleRate)
    {
        return (unsigned int)(in_fMs * 0.001f * (float)in_uSampleRate + 0.5f);
    }

    inline unsigned int ShiftFrames(unsigned int in_uSampleRate)
    {
        // Window plus interpolation slack, rounded up to a power of two.
        const unsigned int uNeeded = MsToFrames(RacineShimmer::kShiftWindowMs, in_uSampleRate) + 4;
        unsigned int u = 1;
        while (u < uNeeded)
            u <<= 1;
        return u;
    }

    /// Damping 0..1 -> one-pole coefficient, cutoff swept logarithmically.
    inline float DampingCoef(float in_fDamping, unsigned int in_uSampleRate)
    {
        const float d = Clamp(in_fDamping, 0.0f, 1.0f);
        const float fCutoff = RacineShimmer::kDampingMaxCutoff *
            powf(RacineShimmer::kDampingMinCutoff / RacineShimmer::kDampingMaxCutoff, d);
        if (fCutoff >= in_uSampleRate * 0.49f)
            return 1.0f;
        return 1.0f - expf(-2.0f * kPi * fCutoff / (float)in_uSampleRate);
    }

    /// Gain into the shimmer path's clip. The tank returns about half of
    /// what it is fed (the output tap sums four lines whose phases do not
    /// agree), so unity here would never let the loop sustain; at 2 the loop
    /// gain crosses unity around Shimmer 60-70% with a 2 s Decay, and 100%
    /// holds indefinitely on the clip.
    const float kShimmerGain = 2.0f;

    /// Bounded, smooth, unity slope at the origin.
    inline float SoftClip(float x)
    {
        return x / sqrtf(1.0f + x * x);
    }

    inline void SetupLine(RacineShimmer::DelayLine& io_line, float*& io_pMem, unsigned int in_uLength)
    {
        io_line.pBuf = io_pMem;
        io_line.uLength = in_uLength;
        io_line.uWritePos = 0;
        io_pMem += in_uLength;
    }

    inline void ClearLine(RacineShimmer::DelayLine& io_line)
    {
        memset(io_line.pBuf, 0, io_line.uLength * sizeof(float));
        io_line.uWritePos = 0;
    }

    /// Full-length read then write, i.e. a z^-N delay.
    inline float Tick(RacineShimmer::DelayLine& io_line, float in_fSample)
    {
        const float out = io_line.pBuf[io_line.uWritePos];
        io_line.pBuf[io_line.uWritePos] = in_fSample;
        if (++io_line.uWritePos >= io_line.uLength)
            io_line.uWritePos = 0;
        return out;
    }

    /// Schroeder allpass around a delay line.
    inline float Allpass(RacineShimmer::DelayLine& io_line, float in_fSample, float in_fGain)
    {
        const float delayed = io_line.pBuf[io_line.uWritePos];
        const float v = in_fSample - in_fGain * delayed;
        io_line.pBuf[io_line.uWritePos] = v;
        if (++io_line.uWritePos >= io_line.uLength)
            io_line.uWritePos = 0;
        return delayed + in_fGain * v;
    }
}

namespace RacineShimmer
{
    unsigned int MemoryFrames(unsigned int in_uSampleRate)
    {
        unsigned int u = ShiftFrames(in_uSampleRate);
        for (unsigned int i = 0; i < kNumDiffusers; ++i)
            u += MsToFrames(kDiffuserMs[i], in_uSampleRate);
        for (unsigned int i = 0; i < kNumLines; ++i)
            u += MsToFrames(kLineMs[i], in_uSampleRate);
        return u;
    }

    Processor::Processor()
        : m_uShiftMask(0)
        , m_fShiftWindow(0.0f)
        , m_fShiftDelay(0.0f)
        , m_fFeedback(0.0f)
        , m_fShimmerHP(0.0f)
        , m_fShimmerLP(0.0f)
        , m_uSampleRate(48000)
        , m_uNumChannels(0)
    {
        memset(m_diffusers, 0, sizeof(m_diffusers));
        memset(m_lines, 0, sizeof(m_lines));
        memset(&m_shift, 0, sizeof(m_shift));
        memset(m_fLineDamp, 0, sizeof(m_fLineDamp));
    }

    void Processor::Setup(unsigned int in_uSampleRate, unsigned int in_uNumChannels, float* in_pMemory)
    {
        m_uSampleRate = in_uSampleRate;
        m_uNumChannels = in_uNumChannels > kMaxChannels ? kMaxChannels : in_uNumChannels;

        float* pMem = in_pMemory;
        for (unsigned int i = 0; i < kNumDiffusers; ++i)
            SetupLine(m_diffusers[i], pMem, MsToFrames(kDiffuserMs[i], in_uSampleRate));
        for (unsigned int i = 0; i < kNumLines; ++i)
            SetupLine(m_lines[i], pMem, MsToFrames(kLineMs[i], in_uSampleRate));

        const unsigned int uShift = ShiftFrames(in_uSampleRate);
        SetupLine(m_shift, pMem, uShift);
        m_uShiftMask = uShift - 1;
        m_fShiftWindow = (float)MsToFrames(kShiftWindowMs, in_uSampleRate);

        Reset();
    }

    void Processor::Reset()
    {
        for (unsigned int i = 0; i < kNumDiffusers; ++i)
            ClearLine(m_diffusers[i]);
        for (unsigned int i = 0; i < kNumLines; ++i)
            ClearLine(m_lines[i]);
        ClearLine(m_shift);
        memset(m_fLineDamp, 0, sizeof(m_fLineDamp));
        m_fShiftDelay = 0.0f;
        m_fFeedback = 0.0f;
        m_fShimmerHP = 0.0f;
        m_fShimmerLP = 0.0f;
    }

    unsigned int Processor::TailFrames(const Settings& in_settings) const
    {
        // The pitched feedback keeps the tank topped up, so the tail
        // stretches with it; a heuristic, since the clip makes the true
        // decay depend on level.
        float fSeconds = in_settings.fDecaySeconds * (1.0f + 3.0f * in_settings.fShimmer);
        if (fSeconds > kMaxTailSeconds)
            fSeconds = kMaxTailSeconds;
        return (unsigned int)(fSeconds * (float)m_uSampleRate);
    }

    void Processor::Process(
        float* const* in_ppChannels,
        unsigned int in_uNumChannels,
        unsigned int in_uNumFrames,
        const Settings& in_prev,
        const Settings& in_cur)
    {
        if (in_uNumChannels > m_uNumChannels)
            in_uNumChannels = m_uNumChannels;
        if (in_uNumChannels == 0 || in_uNumFrames == 0)
            return;

        // Per-block coefficients. Decay and damping step at block rate, which
        // is inaudible inside a reverb; the gains below are ramped.
        const float fDecay = in_cur.fDecaySeconds > 0.05f ? in_cur.fDecaySeconds : 0.05f;
        float fLineGain[kNumLines];
        for (unsigned int i = 0; i < kNumLines; ++i)
            fLineGain[i] = powf(10.0f, -3.0f * (float)m_lines[i].uLength / ((float)m_uSampleRate * fDecay));
        const float fDamp = DampingCoef(in_cur.fDamping, m_uSampleRate);
        const float fHP = 1.0f - expf(-2.0f * kPi * kShimmerHighpassHz / (float)m_uSampleRate);

        // The read heads move at (ratio - 1) samples per sample relative to
        // the write head: negative for a shift up (the head catches up on
        // the writer), positive for a shift down.
        const float fRatio = powf(2.0f, in_cur.fPitchSemitones / 12.0f);
        const float fHeadStep = 1.0f - fRatio;
        const float fHalfWindow = 0.5f * m_fShiftWindow;
        const float fInvWindow = 1.0f / m_fShiftWindow;

        const float fInvFrames = 1.0f / (float)in_uNumFrames;
        const float fInvChannels = 1.0f / (float)in_uNumChannels;
        const float dShimmer = (in_cur.fShimmer - in_prev.fShimmer) * fInvFrames;
        const float dWet = (in_cur.fWetDryMix - in_prev.fWetDryMix) * fInvFrames;
        const float dGain = (in_cur.fOutputGain - in_prev.fOutputGain) * fInvFrames;
        float fShimmer = in_prev.fShimmer;
        float fWet = in_prev.fWetDryMix;
        float fGain = in_prev.fOutputGain;

        for (unsigned int n = 0; n < in_uNumFrames; ++n)
        {
            fShimmer += dShimmer;
            fWet += dWet;
            fGain += dGain;

            float in = 0.0f;
            for (unsigned int c = 0; c < in_uNumChannels; ++c)
                in += in_ppChannels[c][n];
            in *= fInvChannels;

            // Shimmer path: last tank output, through the shifter.
            m_shift.pBuf[m_shift.uWritePos] = m_fFeedback;
            float shifted = 0.0f;
            {
                float d1 = m_fShiftDelay + fHeadStep;
                if (d1 < 0.0f) d1 += m_fShiftWindow;
                else if (d1 >= m_fShiftWindow) d1 -= m_fShiftWindow;
                m_fShiftDelay = d1;
                float d2 = d1 + fHalfWindow;
                if (d2 >= m_fShiftWindow) d2 -= m_fShiftWindow;

                const float d[2] = { d1, d2 };
                for (unsigned int h = 0; h < 2; ++h)
                {
                    const unsigned int uInt = (unsigned int)d[h];
                    const float t = d[h] - (float)uInt;
                    const unsigned int i0 = (m_shift.uWritePos - uInt) & m_uShiftMask;
                    const unsigned int i1 = (i0 - 1) & m_uShiftMask;
                    const float s = m_shift.pBuf[i0] + t * (m_shift.pBuf[i1] - m_shift.pBuf[i0]);
                    // sin over the window: the two heads sum to constant power.
                    shifted += s * sinf(kPi * d[h] * fInvWindow);
                }
            }
            m_shift.uWritePos = (m_shift.uWritePos + 1) & m_uShiftMask;

            m_fShimmerHP += fHP * (shifted - m_fShimmerHP);
            float fb = shifted - m_fShimmerHP;
            m_fShimmerLP += fDamp * (fb - m_fShimmerLP);
            fb = SoftClip(m_fShimmerLP * kShimmerGain) * fShimmer;

            // Into the tank.
            float x = in + fb + kDenormalGuard;
            for (unsigned int i = 0; i < kNumDiffusers; ++i)
                x = Allpass(m_diffusers[i], x, kDiffuserGain);

            float r[kNumLines];
            float sum = 0.0f;
            for (unsigned int i = 0; i < kNumLines; ++i)
            {
                m_fLineDamp[i] += fDamp * (m_lines[i].pBuf[m_lines[i].uWritePos] - m_fLineDamp[i]);
                r[i] = m_fLineDamp[i];
                sum += r[i];
            }
            // Householder: A = I - (2/N) 1 1^T. Input enters the lines in
            // pairs of alternating sign (+ + - - + + - -), and each output
            // below reads every other line with the sign it went in with, so
            // the direct path comes out at unity instead of cancelling.
            // Each line is soft-clipped on the way in: with the shimmer
            // feeding a long Decay the tank would otherwise pile up well
            // past full scale. Linear at any sane level.
            const float fMix = sum * (2.0f / (float)kNumLines);
            for (unsigned int i = 0; i < kNumLines; ++i)
            {
                const float v = (r[i] - fMix) * fLineGain[i] + ((i & 2) ? -x : x);
                Tick(m_lines[i], SoftClip(v));
            }

            // Channel c takes the four lines starting at c: left the even
            // ones, right the odd, so the two differ by their delays.
            float outSum = 0.0f;
            for (unsigned int c = 0; c < in_uNumChannels; ++c)
            {
                const float wet = 0.25f * (r[c % kNumLines] - r[(c + 2) % kNumLines]
                                         + r[(c + 4) % kNumLines] - r[(c + 6) % kNumLines]);
                outSum += wet;
                const float dry = in_ppChannels[c][n];
                in_ppChannels[c][n] = (dry + fWet * (wet - dry)) * fGain;
            }
            m_fFeedback = outSum * fInvChannels;
        }
    }
}
