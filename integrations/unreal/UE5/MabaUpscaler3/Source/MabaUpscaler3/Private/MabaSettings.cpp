// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaSettings.h"
#include "HAL/IConsoleManager.h"

UMabaSettings::UMabaSettings()
{
	CategoryName = TEXT("Plugins");
	SectionName = TEXT("MABA Upscaler");
}

namespace
{
	template <typename T>
	void SetCVar(const TCHAR* Name, T Value)
	{
		if (IConsoleVariable* CVar = IConsoleManager::Get().FindConsoleVariable(Name))
		{
			// Project-setting priority: anything set from code, the console or the command line wins.
			CVar->Set(Value, ECVF_SetByProjectSetting);
		}
	}
}

FMabaUserSettings UMabaSettings::ToUserSettings() const
{
	FMabaUserSettings S;
	S.bEnabled = bEnabled;
	S.Mode = Mode;
	S.Sharpness = Sharpness;
	S.TargetFps = TargetFps;
	S.MinScale = MinScale;
	S.MaxScale = MaxScale;
	S.bTemporal = bTemporal;
	S.FrameGeneration = FrameGeneration;
	S.bFrameGenerationAutoPause = bFrameGenerationAutoPause;
	return S;
}

void UMabaSettings::ApplyToConsoleVariables() const
{
	SetCVar(TEXT("r.Maba.Enable"), bEnabled ? 1 : 0);
	SetCVar(TEXT("r.Maba.Mode"), static_cast<int32>(Mode));
	SetCVar(TEXT("r.Maba.Sharpness"), Sharpness);
	SetCVar(TEXT("r.Maba.TargetFps"), TargetFps);
	SetCVar(TEXT("r.Maba.MinScale"), MinScale);
	SetCVar(TEXT("r.Maba.MaxScale"), MaxScale);
	SetCVar(TEXT("r.Maba.Temporal"), bTemporal ? 1 : 0);
	SetCVar(TEXT("r.Maba.Temporal.ClipGamma"), ClipGamma);
	SetCVar(TEXT("r.Maba.Temporal.DepthTolerance"), DepthTolerance);
	SetCVar(TEXT("r.Maba.FrameGeneration"), static_cast<int32>(FrameGeneration));
	SetCVar(TEXT("r.Maba.FrameGeneration.AutoPause"), bFrameGenerationAutoPause ? 1 : 0);
	SetCVar(TEXT("r.Maba.OverrideAntiAliasing"), bOverrideAntiAliasing ? 1 : 0);
	SetCVar(TEXT("r.Maba.ShowStats"), bShowStats ? 1 : 0);
}

#if WITH_EDITOR
void UMabaSettings::PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent)
{
	Super::PostEditChangeProperty(PropertyChangedEvent);
	// Live feedback while editing in Project Settings during Play In Editor.
	ApplyToConsoleVariables();
}
#endif
