// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaBlueprintLibrary.h"
#include "MabaUpscalerModule.h"
#include "MabaViewExtension.h"
#include "MabaController.h"
#include "MabaSettingsWidget.h"
#include "MabaSubsystem.h"
#include "Engine/GameInstance.h"
#include "Blueprint/UserWidget.h"
#include "Kismet/GameplayStatics.h"
#include "Engine/World.h"
#include "HAL/IConsoleManager.h"
#include "RHI.h"

namespace
{
	// Code priority: wins over Project Settings and the ini, loses only to the console and the
	// command line, like any other engine setting made from code.
	template <typename T>
	void Set(const TCHAR* Name, T Value)
	{
		if (IConsoleVariable* CVar = IConsoleManager::Get().FindConsoleVariable(Name))
		{
			CVar->Set(Value, ECVF_SetByCode);
		}
	}
}

void UMabaBlueprintLibrary::SetMabaEnabled(bool bEnabled) { Set(TEXT("r.Maba.Enable"), bEnabled ? 1 : 0); }
void UMabaBlueprintLibrary::SetMabaMode(EMabaMode Mode) { Set(TEXT("r.Maba.Mode"), static_cast<int32>(Mode)); }
void UMabaBlueprintLibrary::SetMabaSharpness(float Sharpness) { Set(TEXT("r.Maba.Sharpness"), FMath::Clamp(Sharpness, 0.0f, 1.0f)); }
void UMabaBlueprintLibrary::SetMabaTargetFps(float TargetFps) { Set(TEXT("r.Maba.TargetFps"), FMath::Clamp(TargetFps, 15.0f, 240.0f)); }
void UMabaBlueprintLibrary::SetMabaTemporal(bool bTemporal) { Set(TEXT("r.Maba.Temporal"), bTemporal ? 1 : 0); }
void UMabaBlueprintLibrary::SetMabaShowStats(bool bShow) { Set(TEXT("r.Maba.ShowStats"), bShow ? 1 : 0); }

void UMabaBlueprintLibrary::SetMabaFrameGeneration(EMabaFrameGeneration Mode) { Set(TEXT("r.Maba.FrameGeneration"), static_cast<int32>(Mode)); }
void UMabaBlueprintLibrary::SetMabaFrameGenerationAutoPause(bool bAutoPause) { Set(TEXT("r.Maba.FrameGeneration.AutoPause"), bAutoPause ? 1 : 0); }

bool UMabaBlueprintLibrary::IsMabaSupported()
{
	return FModuleManager::Get().IsModuleLoaded(TEXT("MabaUpscaler3"));
}

bool UMabaBlueprintLibrary::IsMabaTemporalSupported()
{
	return GMaxRHIFeatureLevel >= ERHIFeatureLevel::SM5;
}

bool UMabaBlueprintLibrary::IsMabaFrameGenerationSupported()
{
	return FMabaUpscalerModule::IsFrameGenerationSupported();
}

FMabaModeInfo UMabaBlueprintLibrary::GetMabaModeInfo(EMabaMode Mode, FIntPoint OutputSize)
{
	FMabaModeInfo Info;
	Info.Mode = Mode;
	switch (Mode)
	{
	case EMabaMode::UltraQuality: Info.DisplayName = NSLOCTEXT("MabaUpscaler3", "ModeUltraQuality", "Ultra Quality"); break;
	case EMabaMode::Quality:      Info.DisplayName = NSLOCTEXT("MabaUpscaler3", "ModeQuality", "Quality"); break;
	case EMabaMode::Balanced:     Info.DisplayName = NSLOCTEXT("MabaUpscaler3", "ModeBalanced", "Balanced"); break;
	case EMabaMode::Performance:  Info.DisplayName = NSLOCTEXT("MabaUpscaler3", "ModePerformance", "Performance"); break;
	default:                      Info.DisplayName = NSLOCTEXT("MabaUpscaler3", "ModeDynamic", "Dynamic"); break;
	}
	Info.bFixedScale = Mode != EMabaMode::Dynamic;
	Info.RenderScale = Info.bFixedScale ? MabaRungScale(MabaModeRung(static_cast<MabaMode>(Mode))) : 1.0f;
	Info.RenderSize = FIntPoint(FMath::Max(2, FMath::RoundToInt(OutputSize.X * Info.RenderScale)),
		FMath::Max(2, FMath::RoundToInt(OutputSize.Y * Info.RenderScale)));
	return Info;
}

TArray<FMabaModeInfo> UMabaBlueprintLibrary::GetMabaModeInfos(FIntPoint OutputSize)
{
	TArray<FMabaModeInfo> List;
	for (int32 M = 0; M <= static_cast<int32>(EMabaMode::Performance); ++M)
	{
		List.Add(GetMabaModeInfo(static_cast<EMabaMode>(M), OutputSize));
	}
	return List;
}

EMabaMode UMabaBlueprintLibrary::GetMabaRecommendedMode(FIntPoint OutputSize)
{
	const int64 Pixels = static_cast<int64>(OutputSize.X) * OutputSize.Y;
	if (Pixels >= 8000000) return EMabaMode::Performance;     // 4K and above
	if (Pixels >= 3500000) return EMabaMode::Balanced;        // 1440p
	if (Pixels >= 1900000) return EMabaMode::Quality;         // 1080p
	return EMabaMode::UltraQuality;
}

namespace
{
	template <typename T>
	T GetCVar(const TCHAR* Name, T Default);
	template <>
	float GetCVar<float>(const TCHAR* Name, float Default)
	{
		const IConsoleVariable* CVar = IConsoleManager::Get().FindConsoleVariable(Name);
		return CVar ? CVar->GetFloat() : Default;
	}
	template <>
	int32 GetCVar<int32>(const TCHAR* Name, int32 Default)
	{
		const IConsoleVariable* CVar = IConsoleManager::Get().FindConsoleVariable(Name);
		return CVar ? CVar->GetInt() : Default;
	}
}

FMabaUserSettings UMabaBlueprintLibrary::GetMabaUserSettings()
{
	FMabaUserSettings S;
	S.bEnabled = GetCVar<int32>(TEXT("r.Maba.Enable"), 1) != 0;
	S.Mode = static_cast<EMabaMode>(FMath::Clamp(GetCVar<int32>(TEXT("r.Maba.Mode"), 0), 0, 4));
	S.Sharpness = GetCVar<float>(TEXT("r.Maba.Sharpness"), 0.5f);
	S.TargetFps = GetCVar<float>(TEXT("r.Maba.TargetFps"), 60.0f);
	S.MinScale = GetCVar<float>(TEXT("r.Maba.MinScale"), 0.35f);
	S.MaxScale = GetCVar<float>(TEXT("r.Maba.MaxScale"), 1.0f);
	S.bTemporal = GetCVar<int32>(TEXT("r.Maba.Temporal"), 1) != 0;
	S.FrameGeneration = static_cast<EMabaFrameGeneration>(FMath::Clamp(GetCVar<int32>(TEXT("r.Maba.FrameGeneration"), 0), 0, 2));
	S.bFrameGenerationAutoPause = GetCVar<int32>(TEXT("r.Maba.FrameGeneration.AutoPause"), 1) != 0;
	return S;
}

void UMabaBlueprintLibrary::ApplyMabaUserSettings(const FMabaUserSettings& S)
{
	SetMabaEnabled(S.bEnabled);
	SetMabaMode(S.Mode);
	SetMabaSharpness(S.Sharpness);
	SetMabaTargetFps(S.TargetFps);
	SetMabaScaleRange(S.MinScale, S.MaxScale);
	SetMabaTemporal(S.bTemporal);
	SetMabaFrameGeneration(S.FrameGeneration);
	SetMabaFrameGenerationAutoPause(S.bFrameGenerationAutoPause);
}

void UMabaBlueprintLibrary::ResetMabaHistory()
{
	FMabaViewExtension::ResetToken.fetch_add(1);
}

void UMabaBlueprintLibrary::SetMabaScaleRange(float MinScale, float MaxScale)
{
	MinScale = FMath::Clamp(MinScale, 0.35f, 1.0f);
	MaxScale = FMath::Clamp(MaxScale, MinScale, 1.0f);
	Set(TEXT("r.Maba.MinScale"), MinScale);
	Set(TEXT("r.Maba.MaxScale"), MaxScale);
}

UMabaSubsystem* UMabaBlueprintLibrary::GetMabaSubsystem(UObject* WorldContextObject)
{
	const UWorld* World = GEngine ? GEngine->GetWorldFromContextObject(WorldContextObject, EGetWorldErrorMode::ReturnNull) : nullptr;
	const UGameInstance* GI = World ? World->GetGameInstance() : nullptr;
	return GI ? GI->GetSubsystem<UMabaSubsystem>() : nullptr;
}

UUserWidget* UMabaBlueprintLibrary::ShowMabaSettingsMenu(UObject* WorldContextObject, int32 ZOrder, bool bCaptureInput)
{
	UWorld* World = GEngine ? GEngine->GetWorldFromContextObject(WorldContextObject, EGetWorldErrorMode::LogAndReturnNull) : nullptr;
	APlayerController* Controller = World ? UGameplayStatics::GetPlayerController(World, 0) : nullptr;
	if (Controller == nullptr)
	{
		return nullptr;
	}
	UMabaSettingsWidget* Menu = CreateWidget<UMabaSettingsWidget>(Controller);
	if (Menu != nullptr)
	{
		Menu->AddToViewport(ZOrder);
		if (bCaptureInput)
		{
			Menu->CaptureInput();
		}
	}
	return Menu;
}

FMabaStatus UMabaBlueprintLibrary::GetMabaStatus()
{
	const FMabaUpscalerModule::FStatus S = FMabaUpscalerModule::GetStatus();
	FMabaStatus Result;
	Result.bActive = S.bActive;
	Result.Mode = static_cast<EMabaMode>(FMath::Clamp(S.Mode, 0, 4));
	Result.RenderScale = S.Scale;
	Result.Rung = S.Rung;
	Result.bQualityKernel = S.bQualityShader;
	Result.bTemporalRequested = S.bTemporalRequested;
	Result.bTemporalRunning = S.bTemporalRunning;
	Result.FrameGeneration = static_cast<EMabaFrameGeneration>(FMath::Clamp(S.FrameGeneration, 0, 2));
	Result.bFrameGenerationSupported = S.bFrameGenerationSupported;
	Result.bFrameGenerationActive = S.bFrameGenerationActive;
	Result.bFrameGenerationPaused = S.bFrameGenerationPaused;
	return Result;
}
