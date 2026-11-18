// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaSettingsWidget.h"
#include "MabaSubsystem.h"
#include "MabaBlueprintLibrary.h"
#include "MabaUpscalerModule.h"
#include "Blueprint/WidgetTree.h"
#include "Components/Border.h"
#include "Components/Button.h"
#include "GameFramework/PlayerController.h"
#include "Widgets/SWidget.h"
#include "Components/CheckBox.h"
#include "Components/ComboBoxString.h"
#include "Components/Slider.h"
#include "Components/TextBlock.h"
#include "Components/VerticalBox.h"
#include "Components/VerticalBoxSlot.h"
#include "Engine/GameInstance.h"

namespace
{
	const TCHAR* FrameGenerationLabel(EMabaFrameGeneration Mode)
	{
		switch (Mode)
		{
		case EMabaFrameGeneration::X2: return TEXT("2x");
		case EMabaFrameGeneration::X3: return TEXT("3x");
		default:                       return TEXT("Off");
		}
	}
}

UMabaSubsystem* UMabaSettingsWidget::GetMaba() const
{
	if (const UGameInstance* GI = GetGameInstance())
	{
		return GI->GetSubsystem<UMabaSubsystem>();
	}
	return nullptr;
}

void UMabaSettingsWidget::NativeOnInitialized()
{
	Super::NativeOnInitialized();
	if (WidgetTree != nullptr && WidgetTree->RootWidget == nullptr)
	{
		BuildTree();   // a Blueprint child that designed its own tree keeps it
	}
}

void UMabaSettingsWidget::NativeConstruct()
{
	Super::NativeConstruct();
	RefreshFromSettings();
}

void UMabaSettingsWidget::NativeDestruct()
{
	if (bCapturedInput)
	{
		// The menu is going away however it was removed: give the game its input back.
		bCapturedInput = false;
		if (APlayerController* PC = GetOwningPlayer())
		{
			PC->SetShowMouseCursor(bPreviousShowCursor);
			PC->SetInputMode(FInputModeGameOnly());
		}
	}
	Super::NativeDestruct();
}

void UMabaSettingsWidget::CaptureInput()
{
	APlayerController* PC = GetOwningPlayer();
	if (PC == nullptr || bCapturedInput)
	{
		return;
	}
	bPreviousShowCursor = PC->bShowMouseCursor;
	bCapturedInput = true;
	FInputModeGameAndUI Mode;
	Mode.SetWidgetToFocus(TakeWidget());
	Mode.SetLockMouseToViewportBehavior(EMouseLockMode::DoNotLock);
	PC->SetInputMode(Mode);
	PC->SetShowMouseCursor(true);
}

void UMabaSettingsWidget::CloseMenu()
{
	RemoveFromParent();   // NativeDestruct restores the input state
}

void UMabaSettingsWidget::HandleCloseClicked()
{
	CloseMenu();
}

void UMabaSettingsWidget::BuildTree()
{
	auto AddText = [this](UVerticalBox* Parent, const TCHAR* Text, UTextBlock** Out = nullptr) -> UTextBlock*
	{
		UTextBlock* Block = WidgetTree->ConstructWidget<UTextBlock>(UTextBlock::StaticClass());
		Block->SetText(FText::FromString(Text));
		if (UVerticalBoxSlot* Slot = Parent->AddChildToVerticalBox(Block))
		{
			Slot->SetPadding(FMargin(0.0f, 6.0f, 0.0f, 2.0f));
		}
		if (Out) { *Out = Block; }
		return Block;
	};

	UBorder* Border = WidgetTree->ConstructWidget<UBorder>(UBorder::StaticClass());
	Border->SetBrushColor(FLinearColor(0.02f, 0.03f, 0.05f, 0.82f));
	Border->SetPadding(FMargin(18.0f));
	UVerticalBox* Box = WidgetTree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass());
	Border->SetContent(Box);
	WidgetTree->RootWidget = Border;

	AddText(Box, TEXT("MABA Upscaler 3"));

	// Quality preset: one entry per preset, with its render scale.
	AddText(Box, TEXT("Quality preset"));
	ModeCombo = WidgetTree->ConstructWidget<UComboBoxString>(UComboBoxString::StaticClass());
	ModeOptions.Reset();
	for (const FMabaModeInfo& Info : UMabaBlueprintLibrary::GetMabaModeInfos(FIntPoint(1920, 1080)))
	{
		ModeOptions.Add(Info.bFixedScale
			? FString::Printf(TEXT("%s (%d%% render)"), *Info.DisplayName.ToString(), FMath::RoundToInt(Info.RenderScale * 100.0f))
			: FString::Printf(TEXT("%s (follows the target fps)"), *Info.DisplayName.ToString()));
	}
	// The enum order is Dynamic, Ultra Quality, Quality, Balanced, Performance; GetMabaModeInfos lists the same order.
	for (const FString& Option : ModeOptions)
	{
		ModeCombo->AddOption(Option);
	}
	ModeCombo->OnSelectionChanged.AddDynamic(this, &UMabaSettingsWidget::HandleModeChanged);
	Box->AddChildToVerticalBox(ModeCombo);

	AddText(Box, TEXT("Sharpness"), nullptr);
	SharpnessSlider = WidgetTree->ConstructWidget<USlider>(USlider::StaticClass());
	SharpnessSlider->SetMinValue(0.0f);
	SharpnessSlider->SetMaxValue(1.0f);
	SharpnessSlider->SetStepSize(0.01f);
	SharpnessSlider->OnValueChanged.AddDynamic(this, &UMabaSettingsWidget::HandleSharpnessChanged);
	Box->AddChildToVerticalBox(SharpnessSlider);
	AddText(Box, TEXT("0.50"), &SharpnessValue);

	DynamicBox = WidgetTree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass());
	{
		UTextBlock* Label = WidgetTree->ConstructWidget<UTextBlock>(UTextBlock::StaticClass());
		Label->SetText(FText::FromString(TEXT("Target frame rate (Dynamic preset)")));
		DynamicBox->AddChildToVerticalBox(Label);
		TargetFpsSlider = WidgetTree->ConstructWidget<USlider>(USlider::StaticClass());
		TargetFpsSlider->SetMinValue(15.0f);
		TargetFpsSlider->SetMaxValue(240.0f);
		TargetFpsSlider->SetStepSize(1.0f / 225.0f);
		TargetFpsSlider->OnValueChanged.AddDynamic(this, &UMabaSettingsWidget::HandleTargetFpsChanged);
		DynamicBox->AddChildToVerticalBox(TargetFpsSlider);
		TargetFpsValue = WidgetTree->ConstructWidget<UTextBlock>(UTextBlock::StaticClass());
		TargetFpsValue->SetText(FText::FromString(TEXT("60 fps")));
		DynamicBox->AddChildToVerticalBox(TargetFpsValue);
	}
	Box->AddChildToVerticalBox(DynamicBox);

	if (bShowFrameGeneration)
	{
		AddText(Box, TEXT("Frame Generation"));
		FrameGenerationCombo = WidgetTree->ConstructWidget<UComboBoxString>(UComboBoxString::StaticClass());
		FrameGenerationCombo->AddOption(FrameGenerationLabel(EMabaFrameGeneration::Off));
		FrameGenerationCombo->AddOption(FrameGenerationLabel(EMabaFrameGeneration::X2));
		FrameGenerationCombo->AddOption(FrameGenerationLabel(EMabaFrameGeneration::X3));
		FrameGenerationCombo->OnSelectionChanged.AddDynamic(this, &UMabaSettingsWidget::HandleFrameGenerationChanged);
		Box->AddChildToVerticalBox(FrameGenerationCombo);
		AutoPauseCheck = WidgetTree->ConstructWidget<UCheckBox>(UCheckBox::StaticClass());
		AutoPauseCheck->OnCheckStateChanged.AddDynamic(this, &UMabaSettingsWidget::HandleAutoPauseChanged);
		Box->AddChildToVerticalBox(AutoPauseCheck);
		AddText(Box, TEXT("Pause automatically when it would not help"));
	}

	if (bShowStatus)
	{
		AddText(Box, TEXT(""), &StatusText);
	}

	if (bShowCloseButton)
	{
		UButton* CloseButton = WidgetTree->ConstructWidget<UButton>(UButton::StaticClass());
		UTextBlock* CloseLabel = WidgetTree->ConstructWidget<UTextBlock>(UTextBlock::StaticClass());
		CloseLabel->SetText(FText::FromString(TEXT("Close")));
		CloseButton->SetContent(CloseLabel);
		CloseButton->OnClicked.AddDynamic(this, &UMabaSettingsWidget::HandleCloseClicked);
		if (UVerticalBoxSlot* CloseSlot = Box->AddChildToVerticalBox(CloseButton))
		{
			CloseSlot->SetPadding(FMargin(0.0f, 12.0f, 0.0f, 0.0f));
		}
	}
}

void UMabaSettingsWidget::RefreshFromSettings()
{
	if (ModeCombo == nullptr)
	{
		return;
	}
	const FMabaUserSettings S = UMabaBlueprintLibrary::GetMabaUserSettings();
	bUpdatingControls = true;
	const int32 ModeIndex = FMath::Clamp(static_cast<int32>(S.Mode), 0, ModeOptions.Num() - 1);
	ModeCombo->SetSelectedOption(ModeOptions[ModeIndex]);
	SharpnessSlider->SetValue(S.Sharpness);
	SharpnessValue->SetText(FText::FromString(FString::Printf(TEXT("%.2f"), S.Sharpness)));
	DynamicBox->SetVisibility(S.Mode == EMabaMode::Dynamic ? ESlateVisibility::Visible : ESlateVisibility::Collapsed);
	TargetFpsSlider->SetValue((S.TargetFps - 15.0f) / 225.0f);
	TargetFpsValue->SetText(FText::FromString(FString::Printf(TEXT("%d fps"), FMath::RoundToInt(S.TargetFps))));
	if (FrameGenerationCombo != nullptr)
	{
		FrameGenerationCombo->SetSelectedOption(FrameGenerationLabel(S.FrameGeneration));
		FrameGenerationCombo->SetIsEnabled(UMabaBlueprintLibrary::IsMabaFrameGenerationSupported());
		AutoPauseCheck->SetIsChecked(S.bFrameGenerationAutoPause);
	}
	bUpdatingControls = false;
}

void UMabaSettingsWidget::Commit(const FMabaUserSettings& Settings)
{
	if (UMabaSubsystem* Maba = GetMaba())
	{
		Maba->ApplyUserSettings(Settings, true);
	}
	else
	{
		UMabaBlueprintLibrary::ApplyMabaUserSettings(Settings);   // no game instance (a preview): apply without saving
	}
	OnSettingsApplied(Settings);
}

void UMabaSettingsWidget::HandleModeChanged(FString SelectedItem, ESelectInfo::Type SelectionType)
{
	if (bUpdatingControls)
	{
		return;
	}
	const int32 Index = ModeOptions.IndexOfByKey(SelectedItem);
	if (Index == INDEX_NONE)
	{
		return;
	}
	FMabaUserSettings S = UMabaBlueprintLibrary::GetMabaUserSettings();
	S.Mode = static_cast<EMabaMode>(Index);
	Commit(S);
	DynamicBox->SetVisibility(S.Mode == EMabaMode::Dynamic ? ESlateVisibility::Visible : ESlateVisibility::Collapsed);
}

void UMabaSettingsWidget::HandleSharpnessChanged(float Value)
{
	if (bUpdatingControls)
	{
		return;
	}
	FMabaUserSettings S = UMabaBlueprintLibrary::GetMabaUserSettings();
	S.Sharpness = Value;
	SharpnessValue->SetText(FText::FromString(FString::Printf(TEXT("%.2f"), Value)));
	Commit(S);
}

void UMabaSettingsWidget::HandleTargetFpsChanged(float Value)
{
	if (bUpdatingControls)
	{
		return;
	}
	FMabaUserSettings S = UMabaBlueprintLibrary::GetMabaUserSettings();
	S.TargetFps = 15.0f + Value * 225.0f;
	TargetFpsValue->SetText(FText::FromString(FString::Printf(TEXT("%d fps"), FMath::RoundToInt(S.TargetFps))));
	Commit(S);
}

void UMabaSettingsWidget::HandleFrameGenerationChanged(FString SelectedItem, ESelectInfo::Type SelectionType)
{
	if (bUpdatingControls)
	{
		return;
	}
	FMabaUserSettings S = UMabaBlueprintLibrary::GetMabaUserSettings();
	S.FrameGeneration = SelectedItem == FrameGenerationLabel(EMabaFrameGeneration::X2) ? EMabaFrameGeneration::X2
		: (SelectedItem == FrameGenerationLabel(EMabaFrameGeneration::X3) ? EMabaFrameGeneration::X3 : EMabaFrameGeneration::Off);
	Commit(S);
}

void UMabaSettingsWidget::HandleAutoPauseChanged(bool bIsChecked)
{
	if (bUpdatingControls)
	{
		return;
	}
	FMabaUserSettings S = UMabaBlueprintLibrary::GetMabaUserSettings();
	S.bFrameGenerationAutoPause = bIsChecked;
	Commit(S);
}

void UMabaSettingsWidget::NativeTick(const FGeometry& MyGeometry, float InDeltaTime)
{
	Super::NativeTick(MyGeometry, InDeltaTime);
	StatusTimer -= InDeltaTime;
	if (StatusText != nullptr && StatusTimer <= 0.0f)
	{
		StatusTimer = 0.4f;
		if (const UMabaSubsystem* Maba = GetMaba())
		{
			StatusText->SetText(Maba->GetStatusText());
		}
	}
}