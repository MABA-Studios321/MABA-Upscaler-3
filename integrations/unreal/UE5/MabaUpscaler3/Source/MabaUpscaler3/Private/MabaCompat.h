// MABA Upscaler 3 - Unreal Engine 5 version compatibility (UE 5.0 - 5.8). Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
//
// This is the UE5 folder's copy. The UE4 plugin (integrations/unreal/UE4) has its own MabaCompat.h; every other source file is identical
// in both and reads these macros, so nothing else needs to know which engine it is built for.
//
// Verified by compiling AND running: UE 5.6 and 5.8. The 5.0 - 5.5 branches follow the engine's documented API history (checked against
// Epic's online API reference for 5.0, 5.4 and 5.5) and have NOT been compiled.
#pragma once

#include "CoreMinimal.h"
#include "Misc/CoreDelegates.h"
#include "Runtime/Launch/Resources/Version.h"

#if ENGINE_MAJOR_VERSION != 5
#error "This is the Unreal Engine 5 build of MABA Upscaler 3. For UE 4.26 / 4.27 use integrations/unreal/UE4/MabaUpscaler3."
#endif

// UE 5 split the vector and matrix types into float and double versions: GPU parameters are float.
using FMabaVec4 = FVector4f;
using FMabaMat4 = FMatrix44f;

// 5.4 replaced FScreenPassTexture inputs with slices in the post-process callback.
#define MABA_UE_INPUTS_ARE_SLICES (ENGINE_MINOR_VERSION >= 4)
// 5.5 added the FSceneView parameter to SubscribeToPostProcessingPass (the old overload stays, deprecated).
#define MABA_UE_HAS_VIEW_IN_SUBSCRIBE (ENGINE_MINOR_VERSION >= 5)
// 5.8 deprecated FViewMatrices::GetViewMatrix (now GetWorldToView) and the FCoreDelegates::OnPostEngineInit member
// (now GetOnPostEngineInit()). The engine warns that the old names stop compiling in the release after.
#define MABA_UE_HAS_5_8_NAMES (ENGINE_MINOR_VERSION >= 8)
// AAM_TSR (the engine's own temporal super resolution) exists.
#define MABA_UE_HAS_TSR 1
// FTSTicker replaced FTicker in UE 5.
#define MABA_UE_HAS_TSTICKER 1
// UE 5 renders through render graph hooks only: the legacy RHI pre-render hooks of UE 4 do not exist.
#define MABA_UE_RHI_PRERENDER 0
// Nanite, Lumen and Cloud show flags exist, and so does the Hair flag.
#define MABA_UE_HAS_NANITE_LUMEN_FLAGS 1
#define MABA_UE_HAS_HAIR_FLAG 1

using FMabaTicker = FTSTicker;
using FMabaTickerHandle = FTSTicker::FDelegateHandle;

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
#if MABA_UE_HAS_5_8_NAMES
		return Matrices.GetWorldToView();
#else
		return Matrices.GetViewMatrix();
#endif
	}

	inline FSimpleMulticastDelegate& PostEngineInit()
	{
#if MABA_UE_HAS_5_8_NAMES
		return FCoreDelegates::GetOnPostEngineInit();
#else
		return FCoreDelegates::OnPostEngineInit;
#endif
	}

	// The scene-depth texture of the post-process inputs. The container type differs between engine versions
	// (a render graph uniform buffer reference, or a struct holding one), so both shapes are accepted and the
	// right one is picked by overload resolution rather than by guessing the version.
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
