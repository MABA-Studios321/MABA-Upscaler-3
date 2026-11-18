// MABA Upscaler module: registers the view extension and drives r.ScreenPercentage from the
// real C controller (maba_upscaler.h, synced into this plugin as MabaController.h).
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaUpscalerModule.h"
#include "MabaViewExtension.h"
#include "MabaCompat.h"
#include "MabaController.h"
#include "MabaFrameGen.h"
#include "MabaSettings.h"
#include "HAL/IConsoleManager.h"
#include "Containers/Ticker.h"
#include "Engine/Engine.h"
#include "Interfaces/IPluginManager.h"
#include "Misc/CoreDelegates.h"
#include "Misc/Paths.h"
#include "ShaderCore.h"

namespace
{
	TAutoConsoleVariable<bool> CVarEnable(
		TEXT("r.Maba.Enable"), true,
		TEXT("MABA Upscaler: upscale the tonemapped scene from render resolution to output."));
	TAutoConsoleVariable<int32> CVarMode(
		TEXT("r.Maba.Mode"), 0,
		TEXT("0 Dynamic, 1 Ultra Quality (0.77), 2 Quality (0.67), 3 Balanced (0.59), 4 Performance (0.50)"));
	TAutoConsoleVariable<float> CVarSharpness(
		TEXT("r.Maba.Sharpness"), 0.5f,
		TEXT("MABA sharpening strength, 0..1."));
	TAutoConsoleVariable<float> CVarTargetFps(
		TEXT("r.Maba.TargetFps"), 60.0f,
		TEXT("Frame rate the Dynamic mode holds."));
	TAutoConsoleVariable<bool> CVarTemporal(
		TEXT("r.Maba.Temporal"), true,
		TEXT("MABA Upscaler 3 temporal super-resolution: jittered render, depth-reprojected accumulation at output resolution. "
			"SM5 / desktop-class renderers only; takes the view out of the engine TAA / TSR."));
	TAutoConsoleVariable<int32> CVarFrameGeneration(
		TEXT("r.Maba.FrameGeneration"), 0,
		TEXT("MABA Frame Generation: 0 off, 1 renders every second frame (2x), 2 every third (3x). "
			"Takes effect only where the backend is available (see IsMabaFrameGenerationSupported)."));
	TAutoConsoleVariable<bool> CVarFrameGenerationAutoPause(
		TEXT("r.Maba.FrameGeneration.AutoPause"), true,
		TEXT("Pause Frame Generation while it would not show more frames per second than leaving it off."));
	TAutoConsoleVariable<float> CVarClipGamma(
		TEXT("r.Maba.Temporal.ClipGamma"), 1.25f,
		TEXT("Temporal tier: width of the colour clamp around the current frame, 1.0..1.5. Lower rejects ghosts harder."));
	TAutoConsoleVariable<float> CVarDepthTolerance(
		TEXT("r.Maba.Temporal.DepthTolerance"), 0.01f,
		TEXT("Temporal tier: relative depth difference that rejects history, 0.005..0.02."));
	TAutoConsoleVariable<bool> CVarOverrideAA(
		TEXT("r.Maba.OverrideAntiAliasing"), true,
		TEXT("While MABA renders a view, take it out of the engine TAA / TSR (they would upscale before MABA). "
			"Turn off only if you set r.AntiAliasingMethod yourself."));
	TAutoConsoleVariable<bool> CVarShowStats(
		TEXT("r.Maba.ShowStats"), false,
		TEXT("Show MABA mode, render scale, fps and temporal state on screen."));
	TAutoConsoleVariable<float> CVarMinScale(
		TEXT("r.Maba.MinScale"), 0.35f,
		TEXT("Dynamic mode never renders below this fraction of the output resolution (0.35..1)."));
	TAutoConsoleVariable<float> CVarMaxScale(
		TEXT("r.Maba.MaxScale"), 1.0f,
		TEXT("Dynamic mode never renders above this fraction of the output resolution (0.35..1; 1 = native). "
			"The fixed presets ignore the range."));

	MabaUpscaler GController;
	bool GControllerInit = false;
	float GAppliedTargetFps = 0.0f;
	float GAppliedMinScale = -1.0f;
	float GAppliedMaxScale = -1.0f;
	FMabaUpscalerModule::FStatus GStatus;
	float GAppliedScreenPct = -1.0f;   // last value this plugin wrote to r.ScreenPercentage
	bool GActive = false;              // true while this plugin owns r.ScreenPercentage
	TSharedPtr<FMabaViewExtension, ESPMode::ThreadSafe> GViewExtension;
	FMabaTickerHandle GTickerHandle;
	FDelegateHandle GPostEngineInitHandle;

	void SetScreenPercentage(float Percent)
	{
		if (Percent == GAppliedScreenPct)
		{
			return;
		}
		if (IConsoleVariable* ScreenPct = IConsoleManager::Get().FindConsoleVariable(TEXT("r.ScreenPercentage")))
		{
			ScreenPct->Set(Percent, ECVF_SetByCode);
			GAppliedScreenPct = Percent;
		}
	}

	void ShowStats(float DeltaSeconds)
	{
		if (!GEngine || !CVarShowStats.GetValueOnGameThread())
		{
			return;
		}
		static float SmoothedMs = 16.7f;
		SmoothedMs += (DeltaSeconds * 1000.0f - SmoothedMs) * 0.05f;
		const TCHAR* ModeNames[] = { TEXT("Dynamic"), TEXT("Ultra Quality"), TEXT("Quality"), TEXT("Balanced"), TEXT("Performance") };
		const TCHAR* TemporalText = !GStatus.bTemporalRequested ? TEXT("off")
			: (FMabaViewExtension::bTemporalRanLastFrame ? TEXT("on") : TEXT("requested, not running"));
		GEngine->AddOnScreenDebugMessage(static_cast<uint64>(0x4D414241), 0.0f, FColor::Cyan,
			FString::Printf(TEXT("MABA %s | render %.0f%% %s | %.0f fps (%.1f ms) | temporal %s%s"),
				ModeNames[FMath::Clamp(GStatus.Mode, 0, 4)], GStatus.Scale * 100.0f,
				GStatus.bQualityShader ? TEXT("quality") : TEXT("fast"), 1000.0f / FMath::Max(SmoothedMs, 0.1f),
				SmoothedMs, TemporalText, GStatus.bActive ? TEXT("") : TEXT(" | MABA disabled")));
	}

	void TickController(float DeltaSeconds)
	{
		FMabaViewExtension::TickCounter.fetch_add(1);
		// Project Settings -> Plugins -> MABA Upscaler is applied once; console variables set
		// later (or on the command line) win over it.
		static bool bAppliedSettings = false;
		if (!bAppliedSettings)
		{
			bAppliedSettings = true;
			if (const UMabaSettings* Settings = GetDefault<UMabaSettings>())
			{
				Settings->ApplyToConsoleVariables();
			}
		}

		if (!CVarEnable.GetValueOnGameThread())
		{
			MabaFg::BeginTick(0, true, DeltaSeconds);
			FMabaViewExtension::bEnabled = false;
			GStatus.bActive = false;
			ShowStats(DeltaSeconds);
			if (GActive)
			{
				// Hand the resolution back: without the upscale pass a lowered screen
				// percentage would just be a blurry engine upscale.
				SetScreenPercentage(100.0f);
				GActive = false;
				GAppliedScreenPct = -1.0f;
			}
			return;
		}

		const float TargetFps = CVarTargetFps.GetValueOnGameThread();
		if (!GControllerInit)
		{
			MabaInit(&GController, MABA_MODE_DYNAMIC, TargetFps);
			GAppliedTargetFps = TargetFps;
			GControllerInit = true;
		}

		// The scale range resets the controller's counters too: apply it only when it changed.
		const float MinScale = FMath::Clamp(CVarMinScale.GetValueOnGameThread(), 0.35f, 1.0f);
		const float MaxScale = FMath::Clamp(CVarMaxScale.GetValueOnGameThread(), 0.35f, 1.0f);
		if (MinScale != GAppliedMinScale || MaxScale != GAppliedMaxScale)
		{
			MabaSetScaleRange(&GController, MinScale, MaxScale);
			GAppliedMinScale = MinScale;
			GAppliedMaxScale = MaxScale;
		}

		const int32 Mode = FMath::Clamp(CVarMode.GetValueOnGameThread(), 0, 4);
		int Rung;
		if (Mode == 0)
		{
			// MabaSetTargetFps resets the controller's counters, so only call it when the
			// budget really changed; calling it every tick would freeze Dynamic mode.
			if (TargetFps != GAppliedTargetFps)
			{
				MabaSetTargetFps(&GController, TargetFps);
				GAppliedTargetFps = TargetFps;
			}
			// Present-to-present timing. UE's own GPU profiling can replace this later; the
			// hysteresis controller still settles correctly, it just learns by missing frames.
			MabaUpdateDynamic(&GController, DeltaSeconds * 1000.0f);
			Rung = GController.rung;
		}
		else
		{
			Rung = MabaModeRung((MabaMode)Mode);
		}

		FMabaViewExtension::bQualityShader = MabaRungQuality(Rung) != 0;
		FMabaViewExtension::Sharpness = FMath::Clamp(CVarSharpness.GetValueOnGameThread(), 0.0f, 1.0f);
		FMabaViewExtension::bTemporal = CVarTemporal.GetValueOnGameThread();
		FMabaViewExtension::bOverrideAntiAliasing = CVarOverrideAA.GetValueOnGameThread();
			FMabaViewExtension::ClipGamma = FMath::Clamp(CVarClipGamma.GetValueOnGameThread(), 0.5f, 3.0f);
		FMabaViewExtension::DepthTolerance = FMath::Clamp(CVarDepthTolerance.GetValueOnGameThread(), 0.001f, 0.1f);
		// Frame Generation: decide whether THIS tick is generated (before anything renders).
		MabaFg::BeginTick(CVarFrameGeneration.GetValueOnGameThread(), CVarFrameGenerationAutoPause.GetValueOnGameThread(), DeltaSeconds);
		FMabaViewExtension::RenderScale = MabaRungScale(Rung);
		FMabaViewExtension::bEnabled = true;
		GActive = true;
		if (!MabaFg::IsGeneratingThisTick())
		{
			SetScreenPercentage(MabaRungScale(Rung) * 100.0f);   // the render size must not change on a generated frame
		}

		GStatus.bActive = true;
		GStatus.Mode = Mode;
		GStatus.Rung = Rung;
		GStatus.Scale = MabaRungScale(Rung);
		GStatus.bQualityShader = MabaRungQuality(Rung) != 0;
		GStatus.bTemporalRequested = FMabaViewExtension::bTemporal;
		GStatus.bTemporalRunning = FMabaViewExtension::bTemporalRanLastFrame;
		GStatus.FrameGeneration = FMath::Clamp(CVarFrameGeneration.GetValueOnGameThread(), 0, 2);
		GStatus.bFrameGenerationSupported = FMabaUpscalerModule::IsFrameGenerationSupported();
		GStatus.bFrameGenerationActive = MabaFg::IsGeneratingThisTick();
		GStatus.bFrameGenerationPaused = GStatus.FrameGeneration > 0 && MabaFg::IsPaused();
		ShowStats(DeltaSeconds);
	}

	void RegisterViewExtension()
	{
		if (!GViewExtension.IsValid() && GEngine)
		{
			GViewExtension = FSceneViewExtensions::NewExtension<FMabaViewExtension>();
		}
	}
}

void FMabaUpscalerModule::StartupModule()
{
	// The shader directory must be mapped before global shaders compile (PostConfigInit).
	const TSharedPtr<IPlugin> Plugin = IPluginManager::Get().FindPlugin(TEXT("MabaUpscaler3"));
	if (Plugin.IsValid())
	{
		AddShaderSourceDirectoryMapping(TEXT("/Plugin/MabaUpscaler3"),
			FPaths::Combine(Plugin->GetBaseDir(), TEXT("Shaders")));
	}

	// View extensions register with GEngine, which does not exist yet at PostConfigInit.
	if (GEngine)
	{
		RegisterViewExtension();
	}
	else
	{
		GPostEngineInitHandle = MabaCompat::PostEngineInit().AddStatic(&RegisterViewExtension);
	}

	GTickerHandle = FMabaTicker::GetCoreTicker().AddTicker(FTickerDelegate::CreateLambda([](float DeltaSeconds)
	{
		TickController(DeltaSeconds);
		return true;
	}), 0.0f);
}

void FMabaUpscalerModule::ShutdownModule()
{
	FMabaTicker::GetCoreTicker().RemoveTicker(GTickerHandle);
	GTickerHandle.Reset();
	MabaCompat::PostEngineInit().Remove(GPostEngineInitHandle);
	GPostEngineInitHandle.Reset();
	if (GActive)
	{
		// Do not leave the engine rendering at the last lowered screen percentage once the
		// upscale pass that makes it look right is gone.
		SetScreenPercentage(100.0f);
		GActive = false;
		GAppliedScreenPct = -1.0f;
	}
	FMabaViewExtension::bEnabled = false;
	GViewExtension.Reset();
}

FMabaUpscalerModule::FStatus FMabaUpscalerModule::GetStatus()
{
	return GStatus;
}

bool FMabaUpscalerModule::IsFrameGenerationSupported()
{
	return MabaFg::IsSupported();
}

IMPLEMENT_MODULE(FMabaUpscalerModule, MabaUpscaler3)
