// MABA Upscaler 3 - game instance subsystem: the player's settings in one place. It loads what the player saved
// (GameUserSettings.ini), applies it to the r.Maba.* console variables, saves changes, and tells your UI when anything
// changed. Reach it from Blueprint with "Get Game Instance Subsystem" (class MABA Subsystem) or from C++:
//     UMabaSubsystem* Maba = GetGameInstance()->GetSubsystem<UMabaSubsystem>();
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "MabaSettings.h"
#include "MabaBlueprintLibrary.h"
#include "MabaSubsystem.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FMabaSettingsChangedDelegate, const FMabaUserSettings&, Settings);

UCLASS(BlueprintType, meta = (DisplayName = "MABA Subsystem"))
class MABAUPSCALER3_API UMabaSubsystem : public UGameInstanceSubsystem
{
	GENERATED_BODY()

public:
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;

	/** Broadcast after the settings changed through this subsystem (applied and, by default, saved). */
	UPROPERTY(BlueprintAssignable, Category = "MABA Upscaler")
	FMabaSettingsChangedDelegate OnSettingsChanged;

	/** The settings in force now. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	FMabaUserSettings GetUserSettings() const;

	/** Applies the settings (values are clamped) and, when bSave is true, stores them in GameUserSettings.ini. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	void ApplyUserSettings(const FMabaUserSettings& Settings, bool bSave = true);

	/** Stores the settings in force now in GameUserSettings.ini. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	void SaveUserSettings();

	/** Loads and applies what the player saved. Returns false when nothing was saved. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	bool LoadUserSettings();

	/** Back to the Project Settings defaults (and saves them unless bSave is false). */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	void ResetToProjectDefaults(bool bSave = true);

	/** Convenience: a fixed preset for the current game viewport size, e.g. on first launch. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	void ApplyRecommendedMode(bool bSave = true);

	/** Size of the game viewport in pixels (0,0 when there is none yet). */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	FIntPoint GetOutputSize() const;

	/** A one-line description of what MABA is doing, for a status label. */
	UFUNCTION(BlueprintPure, Category = "MABA Upscaler")
	FText GetStatusText() const;

private:
	static const TCHAR* Section();
};