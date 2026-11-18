// MABA Upscaler - Blueprint / C++ control API.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "MabaSettings.h"
#include "MabaBlueprintLibrary.generated.h"

/** What MABA is doing right now (read-only). */
USTRUCT(BlueprintType)
struct MABAUPSCALER3_API FMabaStatus
{
	GENERATED_BODY()

	/** False when MABA is switched off. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bActive = false;

	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	EMabaMode Mode = EMabaMode::Dynamic;

	/** Render scale in use, 0.35 .. 1.0 (1.0 = native, nothing upscaled). */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	float RenderScale = 1.0f;

	/** Position on the 1% ladder, -15 .. 51. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	int32 Rung = 0;

	/** True when the 12-tap quality kernel is in use. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bQualityKernel = false;

	/** The temporal tier was asked for. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bTemporalRequested = false;

	/** The temporal resolve pass actually ran on the last frame. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bTemporalRunning = false;

	/** The Frame Generation mode that was asked for. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	EMabaFrameGeneration FrameGeneration = EMabaFrameGeneration::Off;

	/** The Frame Generation backend is available on this renderer. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bFrameGenerationSupported = false;

	/** Frames are being generated right now. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bFrameGenerationActive = false;

	/** Frame Generation was asked for but the governor paused it (it would not show more frames per second). */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bFrameGenerationPaused = false;
};

/** One quality preset, for building a menu. */
USTRUCT(BlueprintType)
struct MABAUPSCALER3_API FMabaModeInfo
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	EMabaMode Mode = EMabaMode::Dynamic;

	/** Localizable display name: "Balanced", "Quality", ... */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	FText DisplayName;

	/** Render scale of the preset (Dynamic: its highest, 1.0, because the controller moves it). */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	float RenderScale = 1.0f;

	/** The 3D render resolution for the output size that was asked about. */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	FIntPoint RenderSize = FIntPoint::ZeroValue;

	/** False for Dynamic (the scale follows the target frame rate). */
	UPROPERTY(BlueprintReadOnly, Category = "MABA")
	bool bFixedScale = true;
};

class UUserWidget;
class UMabaSubsystem;

UCLASS()
class MABAUPSCALER3_API UMabaBlueprintLibrary : public UBlueprintFunctionLibrary
{
	GENERATED_BODY()

public:
	/** Switch MABA on or off (r.Maba.Enable). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaEnabled(bool bEnabled);

	/** Choose Dynamic or one of the fixed presets (r.Maba.Mode). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaMode(EMabaMode Mode);

	/** Sharpening strength, 0..1 (r.Maba.Sharpness). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaSharpness(float Sharpness);

	/** Frame rate Dynamic mode holds (r.Maba.TargetFps). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaTargetFps(float TargetFps);

	/** Narrow Dynamic mode's render-scale range (r.Maba.MinScale / MaxScale). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaScaleRange(float MinScale, float MaxScale);

	/** Turn the temporal tier on or off (r.Maba.Temporal). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaTemporal(bool bTemporal);

	/**
	 * Drop the temporal history of every view (camera cut, teleport, level switch). The next frame
	 * starts fresh. Engine camera cuts (Sequencer, Set Game Camera Cut This Frame) already do this.
	 */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void ResetMabaHistory();

	/** Show or hide the on-screen stats line (r.Maba.ShowStats). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaShowStats(bool bShow);

	/** Frame Generation mode (r.Maba.FrameGeneration). Has an effect only where IsMabaFrameGenerationSupported is true. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaFrameGeneration(EMabaFrameGeneration Mode);

	/** Pause Frame Generation while it would not show more frames per second than leaving it off. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void SetMabaFrameGenerationAutoPause(bool bAutoPause);

	/** True: the plugin is loaded and its upscale pass can run. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static bool IsMabaSupported();

	/** True when temporal super-resolution can run on this renderer (SM5 / desktop-class); elsewhere the spatial upscale runs. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static bool IsMabaTemporalSupported();

	/** True when the Frame Generation backend can run on this renderer. Check it before showing a Frame Generation option. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static bool IsMabaFrameGenerationSupported();

	/** Every preset with its render scale and the render resolution it gives for OutputSize: build a menu from this. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static TArray<FMabaModeInfo> GetMabaModeInfos(FIntPoint OutputSize);

	/** One preset's info. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static FMabaModeInfo GetMabaModeInfo(EMabaMode Mode, FIntPoint OutputSize);

	/** A starting preset for a screen size (the more pixels, the lower the render scale). A heuristic by size only; Dynamic is the one that adapts. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static EMabaMode GetMabaRecommendedMode(FIntPoint OutputSize);

	/** The current settings, read from the console variables. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static FMabaUserSettings GetMabaUserSettings();

	/** Applies a whole settings value (values are clamped). Use the MABA subsystem's ApplyUserSettings to also save it. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	static void ApplyMabaUserSettings(const FMabaUserSettings& Settings);

	/** The MABA subsystem of the game instance (the player's saved settings, change events). Null without a game instance. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler", meta = (WorldContext = "WorldContextObject", DisplayName = "Get MABA Subsystem"))
	static UMabaSubsystem* GetMabaSubsystem(UObject* WorldContextObject);

	/**
	 * Creates the ready-made MABA settings menu (preset, sharpness, Frame Generation, status) and adds it to the viewport.
	 * Returns the widget; remove it with its Close Menu node (or its Close button). With Capture Input (default) the mouse cursor is shown and input goes to the menu until it is closed. Needs a world and a local player.
	 */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler", meta = (WorldContext = "WorldContextObject", DisplayName = "Show MABA Settings Menu"))
	static UUserWidget* ShowMabaSettingsMenu(UObject* WorldContextObject, int32 ZOrder = 100, bool bCaptureInput = true);

	/** Snapshot of what MABA did on the last game-thread tick. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	static FMabaStatus GetMabaStatus();
};
