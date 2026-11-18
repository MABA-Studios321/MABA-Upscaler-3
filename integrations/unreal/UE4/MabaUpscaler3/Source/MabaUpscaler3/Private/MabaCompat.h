// MABA Upscaler 3 - Unreal Engine 4 version compatibility (UE 4.26 - 4.27). Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
//
// This is the UE4 folder's copy. The UE5 plugin (integrations/unreal/UE5) has its own MabaCompat.h; every other source file is identical
// in both and reads these macros, so nothing else needs to know which engine it is built for.
//
// NOT COMPILED: no UE4 engine could be installed on the development machine, so this folder has never been built against UE 4.26 / 4.27.
// It is the UE5 plugin (compiled and run on 5.6 and 5.8) with the UE4 differences written from the engine's API history: float
// vector/matrix types, FTicker, no AAM_TSR, the old SubscribeToPostProcessingPass signature, FScreenPassTexture inputs, and the RHI
// pre-render hooks that ISceneViewExtension still requires in UE4.
#pragma once

#include "CoreMinimal.h"
#include "Misc/CoreDelegates.h"
#include "Runtime/Launch/Resources/Version.h"

#if ENGINE_MAJOR_VERSION != 4
#error "This is the Unreal Engine 4 build of MABA Upscaler 3. For UE 5 use integrations/unreal/UE5/MabaUpscaler3."
#endif

// UE 4 has one float version of the vector and matrix types.
using FMabaVec4 = FVector4;
using FMabaMat4 = FMatrix;

#define MABA_UE_INPUTS_ARE_SLICES 0
#define MABA_UE_HAS_VIEW_IN_SUBSCRIBE 0
#define MABA_UE_HAS_5_8_NAMES 0
// AAM_TSR (the engine's own temporal super resolution) is UE 5 only.
#define MABA_UE_HAS_TSR 0
// FTSTicker is UE 5; UE 4 has FTicker.
#define MABA_UE_HAS_TSTICKER 0
// ISceneViewExtension in UE 4 declares the two RHI pre-render hooks pure virtual: they must be overridden (empty) or the class is abstract.
#define MABA_UE_RHI_PRERENDER 1
// No Nanite / Lumen show flags in UE 4; the Cloud flag (volumetric clouds, late UE 4) and the Hair flag (renamed during UE 4's hair work) are left alone.
#define MABA_UE_HAS_NANITE_LUMEN_FLAGS 0
#define MABA_UE_HAS_HAIR_FLAG 0

using FMabaTicker = FTicker;
using FMabaTickerHandle = FDelegateHandle;

namespace MabaCompat
{
	// Freezes the time of a view family (a generated frame): the engine's automatic exposure adapts by 1 - exp(-deltaTime * speed), so
	// with a zero delta an (almost empty) generated frame cannot move it. The view family keeps its time in different shapes: plain
	// floats in UE 4 (DeltaWorldTime), an FGameTime in newer engines. Overload resolution picks whichever the engine has, so neither
	// engine needs a version number here.
	template <typename TFamily>
	auto FreezeTime(TFamily& Family, int) -> decltype(Family.DeltaWorldTime = 0.0f, void())
	{
		Family.DeltaWorldTime = 0.0f;
	}

	template <typename TFamily>
	auto FreezeTime(TFamily& Family, long) -> decltype(Family.Time = decltype(Family.Time)::CreateDilated(Family.Time.GetRealTimeSeconds(), 0.0f, Family.Time.GetWorldTimeSeconds(), 0.0f), void())
	{
		Family.Time = decltype(Family.Time)::CreateDilated(Family.Time.GetRealTimeSeconds(), 0.0f, Family.Time.GetWorldTimeSeconds(), 0.0f);
	}
	// World -> view matrix of an FViewMatrices (a template so this header needs no SceneView.h).
	template <typename TViewMatrices>
	const FMatrix& WorldToView(const TViewMatrices& Matrices)
	{
		return Matrices.GetViewMatrix();
	}

	inline FSimpleMulticastDelegate& PostEngineInit()
	{
		return FCoreDelegates::OnPostEngineInit;
	}

	// The scene-depth texture of the post-process inputs: a render graph uniform buffer reference, or a struct holding one.
	// Both shapes are accepted and the right one is picked by overload resolution rather than by guessing the version.
	template <typename TBufferRef>
	auto SceneDepthFromBuffer(const TBufferRef& Buffer, int) -> decltype(Buffer->GetParameters()->SceneDepthTexture)
	{
		return Buffer ? Buffer->GetParameters()->SceneDepthTexture : nullptr;
	}

	template <typename TShaderParams>
	auto SceneDepthFromBuffer(const TShaderParams& Params, long) -> decltype(Params.SceneTextures->GetParameters()->SceneDepthTexture)
	{
		return Params.SceneTextures ? Params.SceneTextures->GetParameters()->SceneDepthTexture : nullptr;
	}

	template <typename TSceneTextures>
	FRDGTextureRef GetSceneDepth(const TSceneTextures& SceneTextures)
	{
		return SceneDepthFromBuffer(SceneTextures, 0);
	}
}