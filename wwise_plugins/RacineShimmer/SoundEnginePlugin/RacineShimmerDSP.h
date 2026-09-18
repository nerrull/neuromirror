#ifndef RacineShimmerDSP_H
#define RacineShimmerDSP_H

namespace RacineShimmer
{
    /// Upper bound on channels handled by one instance. Covers 7.1.4 with room
    /// to spare; anything wider is passed through untouched.
    static const unsigned int kMaxChannels = 16;

    /// Delay lines in the feedback delay network. Eight is enough density for
    /// a tail that has a pitch shifter smearing it further on every pass.
    static const unsigned int kNumLines = 8;

    /// Series allpasses on the tank input, so a click arrives as a cloud.
    static const unsigned int kNumDiffusers = 4;

    /// Grain window of the pitch shifter. Long enough that the octave-up
    /// grain rate (12.5 Hz at this length) reads as texture, not tremolo.
    static const float kShiftWindowMs = 80.0f;

    /// Damping maps onto one-pole lowpasses (per line, and on the shimmer
    /// path), sweeping their cutoff between these bounds.
    static const float kDampingMaxCutoff = 20000.0f;
    static const float kDampingMinCutoff = 1000.0f;

    /// Highpass on the shimmer path. Downward shifts and the octave's own
    /// sub-harmonics pile up below this otherwise.
    static const float kShimmerHighpassHz = 120.0f;

    /// Parameters in DSP-native units (as opposed to the authoring units used
    /// in the property XML).
    struct Settings
    {
        float fDecaySeconds;     ///< T60 of the tank on its own (shimmer off)
        float fShimmer;          ///< 0 .. 1, gain of the pitched feedback
        float fPitchSemitones;   ///< Shift applied on each pass round the loop
        float fDamping;          ///< 0 .. 1
        float fWetDryMix;        ///< 0 = dry, 1 = wet
        float fOutputGain;       ///< Linear
    };

    /// An integer-length circular delay line. Memory is not owned.
    struct DelayLine
    {
        float* pBuf;
        unsigned int uLength;
        unsigned int uWritePos;
    };

    /// Floats of memory needed for the whole tank at this sample rate.
    unsigned int MemoryFrames(unsigned int in_uSampleRate);

    class Processor
    {
    public:
        Processor();

        /// in_pMemory must hold MemoryFrames() floats and outlive the
        /// processor. Ownership stays with the caller.
        void Setup(unsigned int in_uSampleRate, unsigned int in_uNumChannels, float* in_pMemory);

        /// Clears the tank.
        void Reset();

        /// Processes all channels in place. The tank is mono: the channels are
        /// averaged into it and each channel takes its own combination of the
        /// lines back out. Parameters ramp from in_prev to in_cur across the
        /// buffer.
        void Process(
            float* const* in_ppChannels,
            unsigned int in_uNumChannels,
            unsigned int in_uNumFrames,
            const Settings& in_prev,
            const Settings& in_cur);

        /// Frames for the tail to fall below -60 dB, for tail handling.
        unsigned int TailFrames(const Settings& in_settings) const;

        unsigned int NumChannels() const { return m_uNumChannels; }

    private:
        DelayLine m_diffusers[kNumDiffusers];
        DelayLine m_lines[kNumLines];
        float m_fLineDamp[kNumLines];      ///< One-pole state per line

        DelayLine m_shift;                 ///< Pitch shifter memory
        unsigned int m_uShiftMask;         ///< Its length is a power of two
        float m_fShiftWindow;              ///< kShiftWindowMs in samples
        float m_fShiftDelay;               ///< Head 1's delay; head 2 sits half a window behind

        float m_fFeedback;                 ///< Last tank output, the shimmer path's input
        float m_fShimmerHP;                ///< Highpass state (input follower)
        float m_fShimmerLP;                ///< Lowpass state

        unsigned int m_uSampleRate;
        unsigned int m_uNumChannels;
    };
}

#endif // RacineShimmerDSP_H
