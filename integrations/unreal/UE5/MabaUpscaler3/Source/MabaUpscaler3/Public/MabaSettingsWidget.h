// MABA Upscaler 3 - a ready-made settings menu as a UMG widget, built in C++ (no Widget Blueprint needed): quality preset,
// sharpness, Dynamic target frame rate, Frame Generation and a status line. Create it with "Create Widget" (class
// MABA Settings Menu) and "Add to Viewport", or place it in your own Widget Blueprint. Everything it does goes through the MABA
// subsystem, so the choices are applied, saved and restored like any other setting. Blueprint classes derived from it can
// add their own controls and react to OnSettingsApplied.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "MabaSettings.h"
#include "MabaSettingsWidget.generated.h"

class UComboBoxString;
class USlider;
class UCheckBox;
class UTextBlock;
class UVerticalBox;
class UMabaSubsystem;

UCLASS(Blueprintable, meta = (DisplayName = "MABA Settings Menu"))
class MABAUPSCALER3_API UMabaSettingsWidget : public UUserWidget
{
	GENERATED_BODY()

public:
	/** Reads the settings in force and shows them in the controls. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	void RefreshFromSettings();

	/** Called after the player changed a setting through this menu (it was applied and saved). */
	UFUNCTION(BlueprintImplementableEvent, Category = "MABA Upscaler")
	void OnSettingsApplied(const FMabaUserSettings& Settings);

	/** Show the mouse cursor and send input to this menu (the game stops receiving it) until the menu is closed. Called for you by
	 *  Show MABA Settings Menu; call it yourself when you add the widget some other way. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	void CaptureInput();

	/** Remove the menu and give the game its input and cursor state back. */
	UFUNCTION(BlueprintCallable, Category = "MABA Upscaler")
	void CloseMenu();

	/** Show a Close button at the bottom of the menu. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA Upscaler")
	bool bShowCloseButton = true;

	/** Hide the Frame Generation controls (for games that do not use it). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA Upscaler")
	bool bShowFrameGeneration = true;

	/** Show the live status line. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "MABA Upscaler")
	bool bShowStatus = true;

protected:
	virtual void NativeOnInitialized() override;
	virtual void NativeConstruct() override;
	virtual void NativeDestruct() override;
	virtual void NativeTick(const FGeometry& MyGeometry, float InDeltaTime) override;

private:
	UFUNCTION() void HandleModeChanged(FString SelectedItem, ESelectInfo::Type SelectionType);
	UFUNCTION() void HandleSharpnessChanged(float Value);
	UFUNCTION() void HandleTargetFpsChanged(float Value);
	UFUNCTION() void HandleFrameGenerationChanged(FString SelectedItem, ESelectInfo::Type SelectionType);
	UFUNCTION() void HandleAutoPauseChanged(bool bIsChecked);
	UFUNCTION() void HandleCloseClicked();

	void BuildTree();
	UMabaSubsystem* GetMaba() const;
	void Commit(const FMabaUserSettings& Settings);

	UPROPERTY(Transient) UComboBoxString* ModeCombo = nullptr;
	UPROPERTY(Transient) USlider* SharpnessSlider = nullptr;
	UPROPERTY(Transient) UTextBlock* SharpnessValue = nullptr;
	UPROPERTY(Transient) UVerticalBox* DynamicBox = nullptr;
	UPROPERTY(Transient) USlider* TargetFpsSlider = nullptr;
	UPROPERTY(Transient) UTextBlock* TargetFpsValue = nullptr;
	UPROPERTY(Transient) UComboBoxString* FrameGenerationCombo = nullptr;
	UPROPERTY(Transient) UCheckBox* AutoPauseCheck = nullptr;
	UPROPERTY(Transient) UTextBlock* StatusText = nullptr;

	TArray<FString> ModeOptions;
	bool bUpdatingControls = false;
	bool bCapturedInput = false;
	bool bPreviousShowCursor = false;
	float StatusTimer = 0.0f;
};