/*******************************************************************************
The content of this file includes portions of the AUDIOKINETIC Wwise Technology
released in source code form as part of the SDK installer package.

Commercial License Usage

Licensees holding valid commercial licenses to the AUDIOKINETIC Wwise Technology
may use this file in accordance with the end user license agreement provided
with the software or, alternatively, in accordance with the terms contained in a
written agreement between you and Audiokinetic Inc.

Apache License Usage

Alternatively, this file may be used under the Apache License, Version 2.0 (the
"Apache License"); you may not use this file except in compliance with the
Apache License. You may obtain a copy of the Apache License at
http://www.apache.org/licenses/LICENSE-2.0.

Unless required by applicable law or agreed to in writing, software distributed
under the Apache License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
OR CONDITIONS OF ANY KIND, either express or implied. See the Apache License for
the specific language governing permissions and limitations under the License.

  Copyright (c) 2026 Audiokinetic Inc.
*******************************************************************************/

#include "RacineShimmerFX.h"
#include "../RacineShimmerConfig.h"

#include <AK/AkWwiseSDKVersion.h>
#include <AK/DSP/AkApplyGain.h>
#include <AK/Tools/Common/AkAssert.h>

#include <math.h>

AK::IAkPlugin* CreateRacineShimmerFX(AK::IAkPluginMemAlloc* in_pAllocator)
{
    return AK_PLUGIN_NEW(in_pAllocator, RacineShimmerFX());
}

AK::IAkPluginParam* CreateRacineShimmerFXParams(AK::IAkPluginMemAlloc* in_pAllocator)
{
    return AK_PLUGIN_NEW(in_pAllocator, RacineShimmerFXParams());
}

AK_IMPLEMENT_PLUGIN_FACTORY(RacineShimmerFX, AkPluginTypeEffect, RacineShimmerConfig::CompanyID, RacineShimmerConfig::PluginID)

RacineShimmerFX::RacineShimmerFX()
    : m_pParams(nullptr)
    , m_pAllocator(nullptr)
    , m_pContext(nullptr)
    , m_pMemory(nullptr)
    , m_bSettingsPrimed(false)
{
    memset(&m_previousSettings, 0, sizeof(m_previousSettings));
}

RacineShimmerFX::~RacineShimmerFX()
{
}

RacineShimmer::Settings RacineShimmerFX::CurrentSettings() const
{
    RacineShimmer::Settings s;
    s.fDecaySeconds = m_pParams->RTPC.fDecay;
    s.fShimmer = m_pParams->RTPC.fShimmer * 0.01f;
    s.fPitchSemitones = m_pParams->RTPC.fPitch;
    s.fDamping = m_pParams->RTPC.fDamping * 0.01f;
    s.fWetDryMix = m_pParams->RTPC.fWetDryMix * 0.01f;
    s.fOutputGain = powf(10.0f, m_pParams->RTPC.fOutputLevel * 0.05f);
    return s;
}

AKRESULT RacineShimmerFX::Init(AK::IAkPluginMemAlloc* in_pAllocator, AK::IAkEffectPluginContext* in_pContext, AK::IAkPluginParam* in_pParams, AkAudioFormat& in_rFormat)
{
    m_pParams = (RacineShimmerFXParams*)in_pParams;
    m_pAllocator = in_pAllocator;
    m_pContext = in_pContext;

    AkUInt32 uNumChannels = in_rFormat.channelConfig.uNumChannels;
    if (uNumChannels > RacineShimmer::kMaxChannels)
        uNumChannels = RacineShimmer::kMaxChannels;
    if (uNumChannels == 0)
        return AK_Fail;

    // The tank is mono whatever the channel count, so this is fixed by the
    // sample rate alone.
    const AkUInt32 uBytes = RacineShimmer::MemoryFrames(in_rFormat.uSampleRate) * sizeof(AkReal32);

    m_pMemory = (AkReal32*)AK_PLUGIN_ALLOC(in_pAllocator, uBytes);
    if (!m_pMemory)
        return AK_InsufficientMemory;

    m_dsp.Setup(in_rFormat.uSampleRate, uNumChannels, m_pMemory);

    return Reset();
}

AKRESULT RacineShimmerFX::Term(AK::IAkPluginMemAlloc* in_pAllocator)
{
    if (m_pMemory)
    {
        AK_PLUGIN_FREE(in_pAllocator, m_pMemory);
        m_pMemory = nullptr;
    }
    AK_PLUGIN_DELETE(in_pAllocator, this);
    return AK_Success;
}

AKRESULT RacineShimmerFX::Reset()
{
    m_dsp.Reset();
    m_bSettingsPrimed = false;
    return AK_Success;
}

AKRESULT RacineShimmerFX::GetPluginInfo(AkPluginInfo& out_rPluginInfo)
{
    out_rPluginInfo.eType = AkPluginTypeEffect;
    out_rPluginInfo.bIsInPlace = true;
    out_rPluginInfo.bCanProcessObjects = false;
    out_rPluginInfo.uBuildVersion = AK_WWISESDK_VERSION_COMBINED;
    return AK_Success;
}

void RacineShimmerFX::Execute(AkAudioBuffer* io_pBuffer)
{
    const RacineShimmer::Settings current = CurrentSettings();

    // On the first buffer there is nothing to ramp from, so start flat rather
    // than sweeping up from zeroed settings.
    if (!m_bSettingsPrimed)
    {
        m_previousSettings = current;
        m_bSettingsPrimed = true;
    }

    // Extends the buffer with silence while the tail rings out. Must run
    // before reading uValidFrames, since it zero-pads to the full frame count.
    m_tailHandler.HandleTail(io_pBuffer, m_dsp.TailFrames(current));

    const AkUInt32 uNumFrames = io_pBuffer->uValidFrames;
    if (uNumFrames == 0)
    {
        m_previousSettings = current;
        return;
    }

    const AkUInt32 uNumChannels = io_pBuffer->NumChannels() < m_dsp.NumChannels()
        ? io_pBuffer->NumChannels()
        : m_dsp.NumChannels();

    AkReal32* ppChannels[RacineShimmer::kMaxChannels];
    for (AkUInt32 i = 0; i < uNumChannels; ++i)
        ppChannels[i] = io_pBuffer->GetChannel(i);
    m_dsp.Process(ppChannels, uNumChannels, uNumFrames, m_previousSettings, current);

    m_previousSettings = current;
}

AKRESULT RacineShimmerFX::TimeSkip(AkUInt32 in_uFrames)
{
    // The tank is not advanced while virtual: it comes back with a stale
    // tail rather than a silent one, which is cheaper and inaudible after
    // Reset on revival.
    return AK_DataReady;
}
