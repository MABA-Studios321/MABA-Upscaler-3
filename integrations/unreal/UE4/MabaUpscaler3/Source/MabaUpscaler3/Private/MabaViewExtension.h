// MABA Upscaler - scene view extension: upscales the tonemapped scene color from render
// resolution (r.ScreenPercentage) to output resolution in one pixel-shader pass, optionally
// preceded by the MABA Upscaler 3 temporal super-resolution (output resolution).
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "GlobalShader.h"
#include "ShaderParameterStruct.h"
#include "SceneViewExtension.h"
#include "PostProcess/PostProcessMaterial.h"
#include "RenderGraphUtils.h"
#include "ScreenPass.h"
#include "MabaCompat.h"
#include <atomic>

// One pixel shader, two builds: the fast build and the MABA_QUALITY (12-tap) build are a bool
// permutation, the standard UE way to compile a define both ways.
class FMabaUpscalePS : public FGlobalShader
{
public:
	DECLARE_GLOBAL_SHADER(FMabaUpscalePS)
	SHADER_USE_PARAMETER_STRUCT(FMabaUpscalePS, FGlobalShader)

	class FQualityDim : SHADER_PERMUTATION_BOOL("MABA_QUALITY");
	using FPermutationDomain = TShaderPermutationDomain<FQualityDim>;

	BEGIN_SHADER_PARAMETER_STRUCT(FParameters, )
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaInput)
		SHADER_PARAMETER_SAMPLER(SamplerState, MabaInputSampler)
		SHADER_PARAMETER(FMabaVec4, MabaInputSize)    // xy = region size in texels, zw = 1 / texture extent
		SHADER_PARAMETER(FMabaVec4, MabaParams)       // x = sharpness
		SHADER_PARAMETER(FMabaVec4, MabaOutputRect)   // xy = output rect min in pixels, zw = 1 / output rect size
		RENDER_TARGET_BINDING_SLOTS()
	END_SHADER_PARAMETER_STRUCT()

	static bool ShouldCompilePermutation(const FGlobalShaderPermutationParameters& Parameters)
	{
		return IsFeatureLevelSupported(Parameters.Platform, ERHIFeatureLevel::ES3_1);
	}
};

// The temporal super-resolution resolve (MABA Upscaler 3): render-resolution colour + depth in,
// OUTPUT-resolution history + shown image + depth out (all three targets share the output size).
class FMabaTsrPS : public FGlobalShader
{
public:
	DECLARE_GLOBAL_SHADER(FMabaTsrPS)
	SHADER_USE_PARAMETER_STRUCT(FMabaTsrPS, FGlobalShader)

	BEGIN_SHADER_PARAMETER_STRUCT(FParameters, )
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaInput)
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaHistory)
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaDepth)
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaPrevDepth)
		SHADER_PARAMETER_SAMPLER(SamplerState, MabaLinearSampler)
		SHADER_PARAMETER(FMabaMat4, MabaCurToPrev)
		SHADER_PARAMETER(FMabaVec4, MabaParams)
		SHADER_PARAMETER(FMabaVec4, MabaRegion)
		SHADER_PARAMETER(FMabaVec4, MabaOutInfo)
		SHADER_PARAMETER(FMabaVec4, MabaJitter)
		SHADER_PARAMETER(FMabaVec4, MabaDepthRange)
		RENDER_TARGET_BINDING_SLOTS()
	END_SHADER_PARAMETER_STRUCT()

	static bool ShouldCompilePermutation(const FGlobalShaderPermutationParameters& Parameters)
	{
		return IsFeatureLevelSupported(Parameters.Platform, ERHIFeatureLevel::SM5);
	}
};

// Sharpens the temporal result into the view's output rectangle.
class FMabaTsrPresentPS : public FGlobalShader
{
public:
	DECLARE_GLOBAL_SHADER(FMabaTsrPresentPS)
	SHADER_USE_PARAMETER_STRUCT(FMabaTsrPresentPS, FGlobalShader)

	BEGIN_SHADER_PARAMETER_STRUCT(FParameters, )
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaShown)
		SHADER_PARAMETER(FMabaVec4, MabaOutInfo)
		SHADER_PARAMETER(FMabaVec4, MabaOutputRect)
		SHADER_PARAMETER(FMabaVec4, MabaPresent)
		RENDER_TARGET_BINDING_SLOTS()
	END_SHADER_PARAMETER_STRUCT()

	static bool ShouldCompilePermutation(const FGlobalShaderPermutationParameters& Parameters)
	{
		return IsFeatureLevelSupported(Parameters.Platform, ERHIFeatureLevel::SM5);
	}
};

// Frame Generation: draws a generated frame, the last real frame re-projected to this frame's camera pose.
class FMabaFgWarpPS : public FGlobalShader
{
public:
	DECLARE_GLOBAL_SHADER(FMabaFgWarpPS)
	SHADER_USE_PARAMETER_STRUCT(FMabaFgWarpPS, FGlobalShader)

	BEGIN_SHADER_PARAMETER_STRUCT(FParameters, )
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaShown)
		SHADER_PARAMETER_RDG_TEXTURE(Texture2D, MabaOutDepth)
		SHADER_PARAMETER_SAMPLER(SamplerState, MabaLinearSampler)
		SHADER_PARAMETER(FMabaMat4, MabaLastVP)
		SHADER_PARAMETER(FMabaMat4, MabaLastInvVP)
		SHADER_PARAMETER(FMabaMat4, MabaNewVP)
		SHADER_PARAMETER(FMabaMat4, MabaNewInvVP)
		SHADER_PARAMETER(FMabaVec4, MabaOutInfo)
		SHADER_PARAMETER(FMabaVec4, MabaOutputRect)
		SHADER_PARAMETER(FMabaVec4, MabaPresent)
		RENDER_TARGET_BINDING_SLOTS()
	END_SHADER_PARAMETER_STRUCT()

	static bool ShouldCompilePermutation(const FGlobalShaderPermutationParameters& Parameters)
	{
		return IsFeatureLevelSupported(Parameters.Platform, ERHIFeatureLevel::SM5);
	}
};

// What the temporal tier keeps between frames for one view (render thread only).
struct FMabaTemporalHistory
{
	TRefCountPtr<IPooledRenderTarget> Color;   // accumulated history, OUTPUT resolution, half float RGBA
	TRefCountPtr<IPooledRenderTarget> Depth;   // last frame's depth at OUTPUT resolution, R32F
	TRefCountPtr<IPooledRenderTarget> Shown;   // last frame's temporal result (before the present sharpen), the source of generated frames
	FIntPoint OutputSize = FIntPoint::ZeroValue;
	FIntPoint RenderSize = FIntPoint::ZeroValue;
	FMatrix PrevViewProj = FMatrix::Identity;  // last frame's UNJITTERED view-projection (double precision)
	uint32 LastFrame = 0;
	uint32 SeenResetToken = 0;                 // the FMabaViewExtension::ResetToken this history last honoured
	bool bValid = false;
};
class FMabaViewExtension : public FSceneViewExtensionBase
{
public:
	FMabaViewExtension(const FAutoRegister& AutoRegister);

	// Game thread: records this frame's real / generated decision and, for a generated frame, switches almost everything the
	// scene render does off (it costs next to nothing; the post-process pass replaces its image with the warp).
	virtual void SetupViewFamily(FSceneViewFamily& InViewFamily) override;
	// Game thread: applies the temporal tier's projection jitter (and, when the tier or the
	// spatial upscaler is on, takes the view out of the engine's own TAA / TSR).
	virtual void SetupView(FSceneViewFamily& InViewFamily, FSceneView& InView) override;
	virtual void BeginRenderViewFamily(FSceneViewFamily& InViewFamily) override {}

#if MABA_UE_RHI_PRERENDER
	// UE 4 only: these two are pure virtual in ISceneViewExtension there.
	virtual void PreRenderViewFamily_RenderThread(FRHICommandListImmediate& RHICmdList, FSceneViewFamily& InViewFamily) override {}
	virtual void PreRenderView_RenderThread(FRHICommandListImmediate& RHICmdList, FSceneView& InView) override {}
#endif
	// The FSceneView parameter was added to this hook in UE 5.5.
#if MABA_UE_HAS_VIEW_IN_SUBSCRIBE
	virtual void SubscribeToPostProcessingPass(EPostProcessingPass PassId, const FSceneView& View,
		FAfterPassCallbackDelegateArray& InOutPassCallbacks, bool bIsPassEnabled) override;
#else
	virtual void SubscribeToPostProcessingPass(EPostProcessingPass PassId,
		FAfterPassCallbackDelegateArray& InOutPassCallbacks, bool bIsPassEnabled) override;
#endif

	FScreenPassTexture UpscalePass(FRDGBuilder& GraphBuilder, const FSceneView& View,
		const FPostProcessMaterialInputs& Inputs);

	// Game-thread settings, read on the render thread. Plain scalars: a one-frame-stale read
	// is harmless.
	static bool bEnabled;
	static bool bQualityShader;   // quality (12-tap) build for the current rung
	static float Sharpness;
	static float RenderScale;     // r.ScreenPercentage / 100 as last set by this plugin (game thread)

	// Temporal tier.
	static bool bTemporal;
	static bool bOverrideAntiAliasing;   // take TAA / TSR off views MABA renders
	static float DepthTolerance;
	static float ClipGamma;
	// Last frame's outcome, for the stats overlay and Blueprint (render thread writes).
	static bool bTemporalRanLastFrame;
	// Game ticks since start. The history's age is measured in THESE, not in the engine's frame number: the scene's frame number also
	// advances for every scene capture (a real-time sky capture adds one per tick in a lit scene), which made the history look stale and
	// reset it on every real frame once Frame Generation spaced them out. Written on the game thread, read on the render thread.
	static std::atomic<uint32> TickCounter;
	// Bumped by ResetMabaHistory(): every view drops its history the next time it renders (game thread
	// writes, render thread reads; a stale read only delays the reset by a frame).
	static std::atomic<uint32> ResetToken;

private:
	TMap<const void*, TSharedPtr<FMabaTemporalHistory>> Histories;   // render thread
	TMap<const void*, uint32> JitterPhase;                           // game thread
};
