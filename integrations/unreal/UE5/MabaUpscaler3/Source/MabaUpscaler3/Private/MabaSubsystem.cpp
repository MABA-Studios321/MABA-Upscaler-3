// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaSubsystem.h"
#include "MabaUpscalerModule.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/GameViewportClient.h"
#include "GameFramework/GameUserSettings.h"
#include "Misc/ConfigCacheIni.h"
#include "Misc/Paths.h"

const TCHAR* UMabaSubsystem::Section()
{
	return TEXT("MabaUpscaler3");
}

void UMabaSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);
	LoadUserSettings();
}

FMabaUserSettings UMabaSubsystem::GetUserSettings() const
{
	return UMabaBlueprintLibrary::GetMabaUserSettings();
}

void UMabaSubsystem::ApplyUserSettings(const FMabaUserSettings& Settings, bool bSave)
{
	UMabaBlueprintLibrary::ApplyMabaUserSettings(Settings);
	if (bSave)
	{
		SaveUserSettings();
	}
	OnSettingsChanged.Broadcast(GetUserSettings());
}

void UMabaSubsystem::SaveUserSettings()
{
	const FMabaUserSettings S = GetUserSettings();
	const FString& Ini = GGameUserSettingsIni;
	GConfig->SetBool(Section(), TEXT("Enabled"), S.bEnabled, Ini);
	GConfig->SetInt(Section(), TEXT("Mode"), static_cast<int32>(S.Mode), Ini);
	GConfig->SetFloat(Section(), TEXT("Sharpness"), S.Sharpness, Ini);
	GConfig->SetFloat(Section(), TEXT("TargetFps"), S.TargetFps, Ini);
	GConfig->SetFloat(Section(), TEXT("MinScale"), S.MinScale, Ini);
	GConfig->SetFloat(Section(), TEXT("MaxScale"), S.MaxScale, Ini);
	GConfig->SetBool(Section(), TEXT("Temporal"), S.bTemporal, Ini);
	GConfig->SetInt(Section(), TEXT("FrameGeneration"), static_cast<int32>(S.FrameGeneration), Ini);
	GConfig->SetBool(Section(), TEXT("FrameGenerationAutoPause"), S.bFrameGenerationAutoPause, Ini);
	GConfig->Flush(false, Ini);
}

bool UMabaSubsystem::LoadUserSettings()
{
	const FString& Ini = GGameUserSettingsIni;
	int32 Mode = 0;
	if (!GConfig->GetInt(Section(), TEXT("Mode"), Mode, Ini))
	{
		return false;   // nothing saved yet: the Project Settings defaults stay in force
	}
	FMabaUserSettings S = GetUserSettings();
	S.Mode = static_cast<EMabaMode>(FMath::Clamp(Mode, 0, 4));
	bool bValue = false;
	float Value = 0.0f;
	int32 IntValue = 0;
	if (GConfig->GetBool(Section(), TEXT("Enabled"), bValue, Ini)) { S.bEnabled = bValue; }
	if (GConfig->GetFloat(Section(), TEXT("Sharpness"), Value, Ini)) { S.Sharpness = Value; }
	if (GConfig->GetFloat(Section(), TEXT("TargetFps"), Value, Ini)) { S.TargetFps = Value; }
	if (GConfig->GetFloat(Section(), TEXT("MinScale"), Value, Ini)) { S.MinScale = Value; }
	if (GConfig->GetFloat(Section(), TEXT("MaxScale"), Value, Ini)) { S.MaxScale = Value; }
	if (GConfig->GetBool(Section(), TEXT("Temporal"), bValue, Ini)) { S.bTemporal = bValue; }
	if (GConfig->GetInt(Section(), TEXT("FrameGeneration"), IntValue, Ini)) { S.FrameGeneration = static_cast<EMabaFrameGeneration>(FMath::Clamp(IntValue, 0, 2)); }
	if (GConfig->GetBool(Section(), TEXT("FrameGenerationAutoPause"), bValue, Ini)) { S.bFrameGenerationAutoPause = bValue; }
	UMabaBlueprintLibrary::ApplyMabaUserSettings(S);
	OnSettingsChanged.Broadcast(GetUserSettings());
	return true;
}

void UMabaSubsystem::ResetToProjectDefaults(bool bSave)
{
	const UMabaSettings* Defaults = GetDefault<UMabaSettings>();
	ApplyUserSettings(Defaults->ToUserSettings(), bSave);
}

FIntPoint UMabaSubsystem::GetOutputSize() const
{
	if (GEngine && GEngine->GameViewport)
	{
		FVector2D Size = FVector2D::ZeroVector;
		GEngine->GameViewport->GetViewportSize(Size);
		return FIntPoint(FMath::RoundToInt(Size.X), FMath::RoundToInt(Size.Y));
	}
	return FIntPoint::ZeroValue;
}

void UMabaSubsystem::ApplyRecommendedMode(bool bSave)
{
	FMabaUserSettings S = GetUserSettings();
	S.Mode = UMabaBlueprintLibrary::GetMabaRecommendedMode(GetOutputSize());
	ApplyUserSettings(S, bSave);
}

FText UMabaSubsystem::GetStatusText() const
{
	const FMabaUpscalerModule::FStatus St = FMabaUpscalerModule::GetStatus();
	if (!St.bActive)
	{
		return NSLOCTEXT("MabaUpscaler3", "StatusOff", "MABA Upscaler is off");
	}
	FString Line = FString::Printf(TEXT("Render %d%% | %s"), FMath::RoundToInt(St.Scale * 100.0f),
		St.bTemporalRunning ? TEXT("temporal super-resolution") : (St.bTemporalRequested ? TEXT("spatial (temporal not running)") : TEXT("spatial upscale")));
	if (St.FrameGeneration > 0)
	{
		Line += St.bFrameGenerationSupported
			? FString::Printf(TEXT(" | Frame Generation %dx %s"), St.FrameGeneration + 1,
				St.bFrameGenerationPaused ? TEXT("paused") : (St.bFrameGenerationActive ? TEXT("on") : TEXT("ready")))
			: FString(TEXT(" | Frame Generation: not available on this renderer"));
	}
	return FText::FromString(Line);
}