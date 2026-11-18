// MABA Upscaler - Project Settings page (Edit > Project Settings > Plugins > MABA Upscaler).
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "Engine/DeveloperSettings.h"
#include "MabaSettings.generated.h"

/** Which render scale the upscaler uses. Matches r.Maba.Mode. */
UENUM(BlueprintType)
enum class EMabaMode : uint8
{
	/** Holds the target frame rate by moving the render scale in 1% steps. */
	Dynamic = 0,
	/** Fixed 77% render scale. */
	UltraQuality = 1,
	/** Fixed 67% render scale. */
	Quality = 2,
	/** Fixed 59% render scale. */
	Balanced = 3,
	/** Fixed 50% render scale. */
	Performance = 4,
};

/** Frame Generation: extra frames between the rendered ones. Matches r.Maba.FrameGeneration. */
UENUM(BlueprintType)
enum class EMabaFrameGeneration : uint8
{
	/** Every frame is rendered. */
	Off = 0,
	/** Renders every second frame and generates the one in between. */
	X2 = 1,
	/** Renders every third frame and generates the two in between. */
	X3 = 2,
};

/**
 * Everything a player can change, as one value: pass it around, bind it to a menu, save it. The MABA subsystem applies it
 * to the r.Maba.* console variables and stores it in GameUserSettings.ini.
 */
USTRUCT(BlueprintType)
struct MABAUPSCALER3_API FMabaUserSettings
{
	GENERATED_BODY()

	/** Master switch. Off restores r.ScreenPercentage to 100. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA")
	bool bEnabled = true;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA")
	EMabaMode Mode = EMabaMode::Dynamic;

	/** 0..1, 0.5 default. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA", meta = (ClampMin = "0.0", ClampMax = "1.0"))
	float Sharpness = 0.5f;

	/** Dynamic mode: the frame rate it holds. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA", meta = (ClampMin = "15.0", ClampMax = "240.0"))
	float TargetFps = 60.0f;

	/** Dynamic mode: lowest render scale. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA", meta = (ClampMin = "0.35", ClampMax = "1.0"))
	float MinScale = 0.35f;

	/** Dynamic mode: highest render scale (1.0 = native). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA", meta = (ClampMin = "0.35", ClampMax = "1.0"))
	float MaxScale = 1.0f;

	/** Temporal super-resolution (SM5 / desktop-class renderers); off = the spatial upscale. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA")
	bool bTemporal = true;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA")
	EMabaFrameGeneration FrameGeneration = EMabaFrameGeneration::Off;

	/** Pause Frame Generation while it would not show more frames per second than leaving it off. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA")
	bool bFrameGenerationAutoPause = true;
};

/**
 * Defaults for MABA Upscaler. They are written to the r.Maba.* console variables when the game
 * starts; a console variable set later (console, Blueprint, command line, DefaultEngine.ini
 * [SystemSettings]) wins over them.
 */
UCLASS(Config = Game, DefaultConfig, meta = (DisplayName = "MABA Upscaler"))
class MABAUPSCALER3_API UMabaSettings : public UDeveloperSettings
{
	GENERATED_BODY()

public:
	UMabaSettings();

	/** Master switch (r.Maba.Enable). Off removes the pass and restores r.ScreenPercentage to 100. */
	UPROPERTY(Config, EditAnywhere, Category = "General")
	bool bEnabled = true;

	/** Dynamic follows the target frame rate; the others are fixed render scales. */
	UPROPERTY(Config, EditAnywhere, Category = "General")
	EMabaMode Mode = EMabaMode::Dynamic;

	/** Sharpening strength (r.Maba.Sharpness). 0.5 is the measured sweet spot. */
	UPROPERTY(Config, EditAnywhere, Category = "General", meta = (ClampMin = "0.0", ClampMax = "1.0"))
	float Sharpness = 0.5f;

	/** Frame rate Dynamic mode holds (r.Maba.TargetFps). */
	UPROPERTY(Config, EditAnywhere, Category = "Dynamic", meta = (ClampMin = "15.0", ClampMax = "240.0"))
	float TargetFps = 60.0f;

	/** Dynamic mode never renders below this fraction of the output (r.Maba.MinScale). */
	UPROPERTY(Config, EditAnywhere, Category = "Dynamic", meta = (ClampMin = "0.35", ClampMax = "1.0"))
	float MinScale = 0.35f;

	/** Dynamic mode never renders above this fraction of the output (r.Maba.MaxScale); 1.0 = native. */
	UPROPERTY(Config, EditAnywhere, Category = "Dynamic", meta = (ClampMin = "0.35", ClampMax = "1.0"))
	float MaxScale = 1.0f;

	/** Temporal super-resolution (r.Maba.Temporal): jittered render, output-resolution accumulation. Desktop-class (SM5) renderers; elsewhere the spatial pass is used. */
	UPROPERTY(Config, EditAnywhere, Category = "Temporal")
	bool bTemporal = true;

	/** Width of the colour clamp that rejects ghosts, 1.0..1.5 (r.Maba.Temporal.ClipGamma). */
	UPROPERTY(Config, EditAnywhere, Category = "Temporal", meta = (EditCondition = "bTemporal", ClampMin = "0.5", ClampMax = "3.0"))
	float ClipGamma = 1.25f;

	/** Relative depth difference that rejects history (r.Maba.Temporal.DepthTolerance). */
	UPROPERTY(Config, EditAnywhere, Category = "Temporal", meta = (EditCondition = "bTemporal", ClampMin = "0.001", ClampMax = "0.1"))
	float DepthTolerance = 0.01f;

	/** Frame Generation (r.Maba.FrameGeneration). Only takes effect where the Frame Generation backend is available: see IsMabaFrameGenerationSupported. */
	UPROPERTY(Config, EditAnywhere, Category = "Frame Generation")
	EMabaFrameGeneration FrameGeneration = EMabaFrameGeneration::Off;

	/** Pause Frame Generation automatically while it would not help (r.Maba.FrameGeneration.AutoPause). */
	UPROPERTY(Config, EditAnywhere, Category = "Frame Generation")
	bool bFrameGenerationAutoPause = true;

	/** Take views out of the engine TAA / TSR while MABA renders them (r.Maba.OverrideAntiAliasing). */
	UPROPERTY(Config, EditAnywhere, Category = "Advanced")
	bool bOverrideAntiAliasing = true;

	/** Show mode, render scale, fps and temporal state on screen (r.Maba.ShowStats). */
	UPROPERTY(Config, EditAnywhere, Category = "Advanced")
	bool bShowStats = false;

	/** These settings as the value the subsystem and the Blueprint API use. */
	FMabaUserSettings ToUserSettings() const;

	/** Writes every value above into its r.Maba.* console variable (priority: project setting). */
	void ApplyToConsoleVariables() const;

#if WITH_EDITOR
	virtual void PostEditChangeProperty(FPropertyChangedEvent& PropertyChangedEvent) override;
#endif
};
