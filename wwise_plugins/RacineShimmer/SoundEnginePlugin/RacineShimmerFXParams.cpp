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

#include "RacineShimmerFXParams.h"

#include <AK/Tools/Common/AkBankReadHelpers.h>

RacineShimmerFXParams::RacineShimmerFXParams()
{
}

RacineShimmerFXParams::~RacineShimmerFXParams()
{
}

RacineShimmerFXParams::RacineShimmerFXParams(const RacineShimmerFXParams& in_rParams)
{
    RTPC = in_rParams.RTPC;
    NonRTPC = in_rParams.NonRTPC;
    m_paramChangeHandler.SetAllParamChanges();
}

AK::IAkPluginParam* RacineShimmerFXParams::Clone(AK::IAkPluginMemAlloc* in_pAllocator)
{
    return AK_PLUGIN_NEW(in_pAllocator, RacineShimmerFXParams(*this));
}

AKRESULT RacineShimmerFXParams::Init(AK::IAkPluginMemAlloc* in_pAllocator, const void* in_pParamsBlock, AkUInt32 in_ulBlockSize)
{
    if (in_ulBlockSize == 0)
    {
        // Must match the DefaultValue entries in RacineShimmer.xml.
        RTPC.fDecay = 4.0f;
        RTPC.fShimmer = 50.0f;
        RTPC.fPitch = 12.0f;
        RTPC.fDamping = 30.0f;
        RTPC.fWetDryMix = 40.0f;
        RTPC.fOutputLevel = 0.0f;
        m_paramChangeHandler.SetAllParamChanges();
        return AK_Success;
    }

    return SetParamsBlock(in_pParamsBlock, in_ulBlockSize);
}

AKRESULT RacineShimmerFXParams::Term(AK::IAkPluginMemAlloc* in_pAllocator)
{
    AK_PLUGIN_DELETE(in_pAllocator, this);
    return AK_Success;
}

AKRESULT RacineShimmerFXParams::SetParamsBlock(const void* in_pParamsBlock, AkUInt32 in_ulBlockSize)
{
    AKRESULT eResult = AK_Success;
    AkUInt8* pParamsBlock = (AkUInt8*)in_pParamsBlock;

    // Read order must match RacineShimmerPlugin::GetBankParameters.
    RTPC.fDecay = READBANKDATA(AkReal32, pParamsBlock, in_ulBlockSize);
    RTPC.fShimmer = READBANKDATA(AkReal32, pParamsBlock, in_ulBlockSize);
    RTPC.fPitch = READBANKDATA(AkReal32, pParamsBlock, in_ulBlockSize);
    RTPC.fDamping = READBANKDATA(AkReal32, pParamsBlock, in_ulBlockSize);
    RTPC.fWetDryMix = READBANKDATA(AkReal32, pParamsBlock, in_ulBlockSize);
    RTPC.fOutputLevel = READBANKDATA(AkReal32, pParamsBlock, in_ulBlockSize);
    CHECKBANKDATASIZE(in_ulBlockSize, eResult);
    m_paramChangeHandler.SetAllParamChanges();

    return eResult;
}

AKRESULT RacineShimmerFXParams::SetParam(AkPluginParamID in_paramID, const void* in_pValue, AkUInt32 in_ulParamSize)
{
    AKRESULT eResult = AK_Success;

    switch (in_paramID)
    {
    case PARAM_DECAY_ID:
        RTPC.fDecay = *((AkReal32*)in_pValue);
        m_paramChangeHandler.SetParamChange(PARAM_DECAY_ID);
        break;
    case PARAM_SHIMMER_ID:
        RTPC.fShimmer = *((AkReal32*)in_pValue);
        m_paramChangeHandler.SetParamChange(PARAM_SHIMMER_ID);
        break;
    case PARAM_PITCH_ID:
        RTPC.fPitch = *((AkReal32*)in_pValue);
        m_paramChangeHandler.SetParamChange(PARAM_PITCH_ID);
        break;
    case PARAM_DAMPING_ID:
        RTPC.fDamping = *((AkReal32*)in_pValue);
        m_paramChangeHandler.SetParamChange(PARAM_DAMPING_ID);
        break;
    case PARAM_WETDRYMIX_ID:
        RTPC.fWetDryMix = *((AkReal32*)in_pValue);
        m_paramChangeHandler.SetParamChange(PARAM_WETDRYMIX_ID);
        break;
    case PARAM_OUTPUTLEVEL_ID:
        RTPC.fOutputLevel = *((AkReal32*)in_pValue);
        m_paramChangeHandler.SetParamChange(PARAM_OUTPUTLEVEL_ID);
        break;
    default:
        eResult = AK_InvalidParameter;
        break;
    }

    return eResult;
}
