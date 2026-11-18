// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaFrameGen.h"
#include "MabaViewExtension.h"
#include "Engine/Engine.h"
#include "Engine/GameViewportClient.h"
#include "EngineGlobals.h"
#include "RHI.h"
#include "ShowFlags.h"
#include <atomic>

namespace
{
	std::atomic<bool> GRealReady{ false };
	bool GGenerating = false;
	int32 GPhase = 0;

	// Governor state: 0 measuring with Frame Generation on, 1 probing with it off, 2 paused.
	int32 GGovState = 0;
	int32 GGovSamples = 0;
	float GGovSumMs = 0.0f;
	float GGovOnMs = 0.0f;
	float GGovTimer = 12.0f;
	constexpr int32 GGovProbeFrames = 14;
	constexpr float GGovPeriodS = 12.0f;
	constexpr float GGovPauseS = 20.0f;
	constexpr float GGovMargin = 0.92f;   // generating must cut the ms per displayed frame below 92% of a real frame

	int32 FactorOf(int32 Mode)
	{
		return Mode <= 0 ? 1 : (Mode == 1 ? 2 : 3);
	}

	// Governor: Frame Generation must never show fewer frames per second than leaving it off. While it runs it measures the ms per
	// displayed frame; every GGovPeriodS it renders every frame for a few frames to measure a real frame alone, and pauses itself when
	// generating would not cut the ms per displayed frame by at least 8%.
	void GovernorUpdate(int32 Factor, bool bAutoPause, float FrameMs, float DeltaSeconds)
	{
		if (Factor <= 1 || !bAutoPause)
		{
			GGovState = 0; GGovTimer = GGovPeriodS; GGovSamples = 0; GGovSumMs = 0.0f;
			return;
		}
		switch (GGovState)
		{
		case 0:
			if (GRealReady.load())
			{
				GGovSumMs += FrameMs;
				++GGovSamples;
			}
			GGovTimer -= DeltaSeconds;
			if (GGovTimer <= 0.0f && GGovSamples > 60)
			{
				GGovOnMs = GGovSumMs / GGovSamples;
				GGovState = 1; GGovSamples = 0; GGovSumMs = 0.0f;
			}
			break;
		case 1:
			++GGovSamples;
			if (GGovSamples > 3)
			{
				GGovSumMs += FrameMs;   // the first frames of the probe are transition frames
			}
			if (GGovSamples >= GGovProbeFrames)
			{
				const float OffMs = GGovSumMs / static_cast<float>(GGovProbeFrames - 3);
				GGovSamples = 0; GGovSumMs = 0.0f;
				if (GGovOnMs < OffMs * GGovMargin) { GGovState = 0; GGovTimer = GGovPeriodS; }
				else { GGovState = 2; GGovTimer = GGovPauseS; }
			}
			break;
		default:
			GGovTimer -= DeltaSeconds;
			if (GGovTimer <= 0.0f) { GGovState = 0; GGovTimer = 6.0f; GGovSamples = 0; GGovSumMs = 0.0f; }
			break;
		}
	}
}

namespace MabaFg
{
	bool IsSupported()
	{
		return GMaxRHIFeatureLevel >= ERHIFeatureLevel::SM5 && GEngine != nullptr && !IsRunningCommandlet();
	}

	void BeginTick(int32 RequestedMode, bool bAutoPause, float DeltaSeconds)
	{
		GGenerating = false;
		const int32 Factor = FactorOf(RequestedMode);
		GovernorUpdate(Factor, bAutoPause, DeltaSeconds * 1000.0f, DeltaSeconds);

		const bool bOnePlayer = GEngine != nullptr && GEngine->GameViewport != nullptr && GEngine->GetNumGamePlayers(GEngine->GameViewport) <= 1;
		const bool bCanRun = Factor > 1 && IsSupported() && bOnePlayer && FMabaViewExtension::bTemporal
			&& FMabaViewExtension::bTemporalRanLastFrame && GRealReady.load() && !(bAutoPause && GGovState != 0);
		if (!bCanRun)
		{
			GPhase = Factor > 1 ? 1 % Factor : 0;   // when it can run again the next tick is generated, after one real frame
			return;
		}
		GGenerating = GPhase != 0;
		GPhase = (GPhase + 1) % Factor;
	}

	bool IsGeneratingThisTick() { return GGenerating; }

	bool IsPaused() { return GGovState == 2; }

	void SetRealFrameReady(bool bReady) { GRealReady.store(bReady); }

	bool HasGeneratedMarker(const FEngineShowFlags& F)
	{
		return !F.StaticMeshes && !F.SkeletalMeshes && !F.Landscape && !F.Particles && !F.Translucency && !F.Decals && !F.Fog
			&& !F.Atmosphere && !F.Lighting && !F.GlobalIllumination && !F.Bloom && !F.AntiAliasing && !F.DynamicShadows && !F.AmbientOcclusion;
	}

	void ApplyCheapShowFlags(FEngineShowFlags& F)
	{
		F.SetStaticMeshes(false);
		F.SetSkeletalMeshes(false);
		F.SetLandscape(false);
		F.SetInstancedStaticMeshes(false);
		F.SetInstancedFoliage(false);
		F.SetInstancedGrass(false);
		F.SetParticles(false);
		F.SetTranslucency(false);
		F.SetSeparateTranslucency(false);
		F.SetDecals(false);
		F.SetFog(false);
		F.SetAtmosphere(false);
#if MABA_UE_HAS_NANITE_LUMEN_FLAGS
		F.SetCloud(false);
#endif
		F.SetVolumetricFog(false);
#if MABA_UE_HAS_HAIR_FLAG
		F.SetHair(false);
#endif
		F.SetBSP(false);
		F.SetLighting(false);
		F.SetDynamicShadows(false);
		F.SetContactShadows(false);
		F.SetLightFunctions(false);
		F.SetLightShafts(false);
		F.SetSkyLighting(false);
		F.SetAmbientOcclusion(false);
		F.SetScreenSpaceReflections(false);
		F.SetReflectionEnvironment(false);
		F.SetGlobalIllumination(false);
		F.SetBloom(false);
		F.SetMotionBlur(false);
		F.SetDepthOfField(false);
		F.SetAntiAliasing(false);
		F.SetTemporalAA(false);
#if MABA_UE_HAS_NANITE_LUMEN_FLAGS
		F.SetNaniteMeshes(false);
		F.SetLumenGlobalIllumination(false);
		F.SetLumenReflections(false);
#endif
	}
}