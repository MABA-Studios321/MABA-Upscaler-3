// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#include "MabaViewExtension.h"
#include "MabaTemporal.h"          // the real C header (maba_temporal.h), synced into this plugin
#include "RenderGraphBuilder.h"
#include "PixelShaderUtils.h"
#include "SceneRendering.h"
#include "SceneRenderTargetParameters.h"
#include "MabaCompat.h"
#include "MabaFrameGen.h"
#include "Engine/Engine.h"
#include "Engine/GameViewportClient.h"
#include "HAL/CriticalSection.h"
#include "Misc/ScopeLock.h"

IMPLEMENT_GLOBAL_SHADER(FMabaUpscalePS, "/Plugin/MabaUpscaler3/MabaUpscale.usf", "MainPS", SF_Pixel);
IMPLEMENT_GLOBAL_SHADER(FMabaTsrPS, "/Plugin/MabaUpscaler3/MabaTsr.usf", "MainPS", SF_Pixel);
IMPLEMENT_GLOBAL_SHADER(FMabaTsrPresentPS, "/Plugin/MabaUpscaler3/MabaTsrPresent.usf", "MainPS", SF_Pixel);
IMPLEMENT_GLOBAL_SHADER(FMabaFgWarpPS, "/Plugin/MabaUpscaler3/MabaFgWarp.usf", "MainPS", SF_Pixel);

bool FMabaViewExtension::bEnabled = true;
bool FMabaViewExtension::bQualityShader = true;
float FMabaViewExtension::Sharpness = 0.5f;
float FMabaViewExtension::RenderScale = 1.0f;
bool FMabaViewExtension::bTemporal = true;
bool FMabaViewExtension::bOverrideAntiAliasing = true;
float FMabaViewExtension::DepthTolerance = 0.01f;
float FMabaViewExtension::ClipGamma = 1.25f;
bool FMabaViewExtension::bTemporalRanLastFrame = false;
std::atomic<uint32> FMabaViewExtension::TickCounter{ 0 };
std::atomic<uint32> FMabaViewExtension::ResetToken{ 1 };

namespace
{
	// The game viewport's own view family: scene captures, editor viewports and previews are left alone.
	bool IsGameViewportFamily(const FSceneViewFamily& Family)
	{
		return Family.Scene != nullptr && GEngine != nullptr && GEngine->GameViewport != nullptr
			&& Family.RenderTarget == static_cast<const FRenderTarget*>(GEngine->GameViewport->Viewport);
	}
}

void FMabaViewExtension::SetupViewFamily(FSceneViewFamily& InViewFamily)
{
	if (bEnabled && IsGameViewportFamily(InViewFamily) && MabaFg::IsGeneratingThisTick())
	{
		MabaFg::ApplyCheapShowFlags(InViewFamily.EngineShowFlags);
		// Automatic exposure adapts by 1 - exp(-deltaTime * speed): with a zero delta this (almost empty) frame cannot move it.
		// Found in a lit scene: without this the real frames pulsed in brightness while Frame Generation ran (unlit scenes have no exposure).
		MabaCompat::FreezeTime(InViewFamily, 0);
	}
}

FMabaViewExtension::FMabaViewExtension(const FAutoRegister& AutoRegister)
	: FSceneViewExtensionBase(AutoRegister)
{
}

namespace
{
	bool IsTemporalAAMethod(EAntiAliasingMethod Method)
	{
#if MABA_UE_HAS_TSR
		return Method == AAM_TemporalAA || Method == AAM_TSR;
#else
		return Method == AAM_TemporalAA;
#endif
	}

	// Views MABA leaves alone: captures, reflection probes and anything that is not a normal
	// scene view.
	bool IsAuxiliaryView(const FSceneView& View)
	{
		return View.bIsSceneCapture || View.bIsReflectionCapture || View.bIsPlanarReflection;
	}
}

void FMabaViewExtension::SetupView(FSceneViewFamily& InViewFamily, FSceneView& InView)
{
	// A generated frame renders (almost) nothing and is not jittered: the warp needs the plain camera.
	if (bEnabled && IsGameViewportFamily(InViewFamily) && MabaFg::IsGeneratingThisTick())
	{
		return;
	}

	// Nothing is upscaled at 100%: leave the project's own anti-aliasing alone.
	if (!bEnabled || RenderScale >= 0.999f || IsAuxiliaryView(InView))
	{
		return;
	}

	// MABA upscales AFTER the tonemapper. The engine's TAA / TSR would upscale before it (and
	// jitter the view themselves), so while MABA is rendering the view it is taken out of them.
	if (bOverrideAntiAliasing)
	{
		if (IsTemporalAAMethod(InView.AntiAliasingMethod))
		{
			InView.AntiAliasingMethod = AAM_None;
		}
		if (InView.PrimaryScreenPercentageMethod == EPrimaryScreenPercentageMethod::TemporalUpscale)
		{
			InView.PrimaryScreenPercentageMethod = EPrimaryScreenPercentageMethod::SpatialUpscale;
		}
	}

	// The temporal tier needs the SM5 scene textures (depth), a view state to key its history by,
	// and a view nobody else is already jittering.
	if (!bTemporal || InView.State == nullptr || InView.GetFeatureLevel() < ERHIFeatureLevel::SM5
		|| IsTemporalAAMethod(InView.AntiAliasingMethod)
		|| !InView.ViewMatrices.GetTemporalAAJitter().IsZero())
	{
		return;
	}

	if (JitterPhase.Num() > 64)
	{
		JitterPhase.Reset();   // views come and go in the editor; the phase is cosmetic
	}
	uint32& Phase = JitterPhase.FindOrAdd(InView.State);
	// Halton(2,3), 16 phases, centred to [-0.5, 0.5] render texel (maba_temporal.h).
	const float JitterX = MabaHalton((int)Phase + 1, 2) - 0.5f;
	const float JitterY = MabaHalton((int)Phase + 1, 3) - 0.5f;
	Phase = (Phase + 1) % MABA_TEMPORAL_PHASES;

	// The render size is not final yet (the screen percentage is applied later): predict it from
	// the scale this plugin set. A one-pixel error changes the jitter by well under 0.1%.
	const float RenderW = FMath::Max(2.0f, FMath::CeilToFloat(InView.UnscaledViewRect.Width() * RenderScale));
	const float RenderH = FMath::Max(2.0f, FMath::CeilToFloat(InView.UnscaledViewRect.Height() * RenderScale));
	// Content moves BY (+JitterX, +JitterY) texels, y down (the engine's own TAA uses the same
	// convention: x * 2 / width, y * -2 / height in NDC).
	InView.ViewMatrices.HackAddTemporalAAProjectionJitter(
		FVector2D(JitterX * 2.0 / RenderW, -JitterY * 2.0 / RenderH));
}

#if MABA_UE_HAS_VIEW_IN_SUBSCRIBE
void FMabaViewExtension::SubscribeToPostProcessingPass(EPostProcessingPass PassId, const FSceneView& View,
	FAfterPassCallbackDelegateArray& InOutPassCallbacks, bool bIsPassEnabled)
#else
void FMabaViewExtension::SubscribeToPostProcessingPass(EPostProcessingPass PassId,
	FAfterPassCallbackDelegateArray& InOutPassCallbacks, bool bIsPassEnabled)
#endif
{
	// After tonemap: the input is finished LDR gamma-space color, which is MABA's contract.
	if (PassId == EPostProcessingPass::Tonemap && bIsPassEnabled && bEnabled)
	{
#if MABA_UE_HAS_VIEW_IN_SUBSCRIBE
		// A generated frame always needs the pass (it is where the image is made).
		const bool bGeneratedFrame = View.Family != nullptr && MabaFg::HasGeneratedMarker(View.Family->EngineShowFlags);
		// At 100% (the controller reached native) there is nothing to upscale. Not subscribing
		// also spares the full-screen copy the engine would otherwise require from this pass when
		// it is the last one in the chain. (Before UE 5.5 the hook has no view, so there the pass
		// subscribes and UpscalePass copies at native.)
		// The scaled view rectangle lives on the renderer's FViewInfo, not on FSceneView.
		if (!bGeneratedFrame && View.bIsViewInfo)
		{
			const FIntRect& RenderRect = static_cast<const FViewInfo&>(View).ViewRect;
			if (RenderRect.Width() >= View.UnscaledViewRect.Width()
				&& RenderRect.Height() >= View.UnscaledViewRect.Height())
			{
				// Nothing is upscaled this frame, so there is no fresh history: Frame Generation must not warp an old one.
					bTemporalRanLastFrame = false;
					MabaFg::SetRealFrameReady(false);
					return;
			}
		}
#endif
		InOutPassCallbacks.Add(FAfterPassCallbackDelegate::CreateRaw(this, &FMabaViewExtension::UpscalePass));
	}
}

namespace
{
	void AddMabaPass(FRDGBuilder& GraphBuilder, FGlobalShaderMap* ShaderMap, bool bQuality,
		const FScreenPassTexture& Input, const FScreenPassRenderTarget& Output, float Sharpness)
	{
		const FIntPoint RenderSize = Input.ViewRect.Size();
		const FIntPoint Extent = Input.Texture->Desc.Extent;
		const FIntPoint OutputSize = Output.ViewRect.Size();

		FMabaUpscalePS::FPermutationDomain Permutation;
		Permutation.Set<FMabaUpscalePS::FQualityDim>(bQuality);
		TShaderMapRef<FMabaUpscalePS> Shader(ShaderMap, Permutation);
		FMabaUpscalePS::FParameters* Params = GraphBuilder.AllocParameters<FMabaUpscalePS::FParameters>();
		Params->MabaInput = Input.Texture;
		Params->MabaInputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();
		// zw is 1 / ALLOCATED texture size: the scene color texture can be larger than the view.
		Params->MabaInputSize = FMabaVec4(RenderSize.X, RenderSize.Y, 1.0f / Extent.X, 1.0f / Extent.Y);
		Params->MabaParams = FMabaVec4(Sharpness, 0.0f, 0.0f, 0.0f);
		Params->MabaOutputRect = FMabaVec4(Output.ViewRect.Min.X, Output.ViewRect.Min.Y,
			1.0f / OutputSize.X, 1.0f / OutputSize.Y);
		Params->RenderTargets[0] = Output.GetRenderTargetBinding();

		FPixelShaderUtils::AddFullscreenPass(GraphBuilder, ShaderMap,
			RDG_EVENT_NAME("MABA Upscale %s %dx%d -> %dx%d", bQuality ? TEXT("Quality") : TEXT("Fast"),
				RenderSize.X, RenderSize.Y, OutputSize.X, OutputSize.Y),
			Shader, Params, Output.ViewRect);
	}

	// MABA Upscaler 3 temporal super-resolution: render-resolution colour -> output-resolution image.
	// Returns the shown image (output extent); refreshes the history and the depth history.
	FRDGTextureRef AddMabaTsrPass(FRDGBuilder& GraphBuilder, FGlobalShaderMap* ShaderMap,
		const FSceneView& View, const FScreenPassTexture& SceneColor, FRDGTextureRef SceneDepth,
		FMabaTemporalHistory& History, const FVector2D& JitterNdc, const FIntPoint& OutputSize,
		float DepthTolerance, float ClipGamma)
	{
		const FIntPoint RenderSize = SceneColor.ViewRect.Size();
		const uint32 Frame = FMabaViewExtension::TickCounter.load();

		// History is dropped on a camera cut, a size change, or a gap in frames.
		const bool bReset = View.bCameraCut || !History.bValid || !History.Color.IsValid()
			|| !History.Depth.IsValid() || History.OutputSize != OutputSize || History.RenderSize != RenderSize
			|| (Frame - History.LastFrame) > 6u
			|| History.SeenResetToken != FMabaViewExtension::ResetToken.load();

		FRDGTextureDesc HistDesc = FRDGTextureDesc::Create2D(OutputSize, PF_FloatRGBA,
			FClearValueBinding::Black, TexCreate_RenderTargetable | TexCreate_ShaderResource);
		FRDGTextureDesc DepthDesc = FRDGTextureDesc::Create2D(OutputSize, PF_R32_FLOAT,
			FClearValueBinding::Black, TexCreate_RenderTargetable | TexCreate_ShaderResource);
		FRDGTextureRef NewHist = GraphBuilder.CreateTexture(HistDesc, TEXT("MABA TSR History"));
		FRDGTextureRef Shown = GraphBuilder.CreateTexture(HistDesc, TEXT("MABA TSR Shown"));
		FRDGTextureRef NewDepth = GraphBuilder.CreateTexture(DepthDesc, TEXT("MABA TSR Depth"));
		// On a reset the previous textures are not read (the shader returns before touching them), but
		// the bindings must still be valid: bind the new targets' siblings of the right size.
		FRDGTextureRef PrevHist = bReset ? Shown : GraphBuilder.RegisterExternalTexture(History.Color);
		FRDGTextureRef PrevDepth = bReset ? NewDepth : GraphBuilder.RegisterExternalTexture(History.Depth);
		if (bReset)
		{
			// A texture cannot be both read and written in one pass: use dummy reads instead.
			PrevHist = GraphBuilder.CreateTexture(HistDesc, TEXT("MABA TSR Dummy History"));
			PrevDepth = GraphBuilder.CreateTexture(DepthDesc, TEXT("MABA TSR Dummy Depth"));
			AddClearRenderTargetPass(GraphBuilder, PrevHist);
			AddClearRenderTargetPass(GraphBuilder, PrevDepth);
		}

		// Unjittered view-projection, in double precision. Reprojection uses one matrix that goes
		// straight from current clip space to previous clip space: the huge world offsets cancel
		// in double precision on the CPU instead of costing float precision on the GPU.
		const FMatrix ProjNoAA = View.ViewMatrices.ComputeProjectionNoAAMatrix();
		const FMatrix CurViewProj = MabaCompat::WorldToView(View.ViewMatrices) * ProjNoAA;
		const FMatrix CurToPrev = CurViewProj.Inverse() * History.PrevViewProj;

		FMabaTsrPS::FParameters* Params = GraphBuilder.AllocParameters<FMabaTsrPS::FParameters>();
		Params->MabaInput = SceneColor.Texture;
		Params->MabaHistory = PrevHist;
		Params->MabaDepth = SceneDepth;
		Params->MabaPrevDepth = PrevDepth;
		Params->MabaLinearSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();
		// UE matrices are row-vector (v * M); the shared HLSL core multiplies column vectors.
		Params->MabaCurToPrev = FMabaMat4(CurToPrev.GetTransposed());
		Params->MabaParams = FMabaVec4(0.0f, DepthTolerance, bReset ? 1.0f : 0.0f, ClipGamma);
		Params->MabaRegion = FMabaVec4(RenderSize.X, RenderSize.Y, 0.0f, 0.0f);
		Params->MabaOutInfo = FMabaVec4(OutputSize.X, OutputSize.Y, 1.0f / OutputSize.X, 1.0f / OutputSize.Y);
		// Engine NDC jitter back to texels: x * W / 2, and y flipped to screen rows (down).
		Params->MabaJitter = FMabaVec4(JitterNdc.X * RenderSize.X * 0.5, -JitterNdc.Y * RenderSize.Y * 0.5, 0.0f, 0.0f);
		// Reversed-Z infinite far projection: M[3][2] is the near plane distance.
		Params->MabaDepthRange = FMabaVec4(FMath::Max(static_cast<float>(ProjNoAA.M[3][2]), 1e-3f), 0.0f, 0.0f, 0.0f);
		Params->RenderTargets[0] = FRenderTargetBinding(NewHist, ERenderTargetLoadAction::ENoAction);
		Params->RenderTargets[1] = FRenderTargetBinding(Shown, ERenderTargetLoadAction::ENoAction);
		Params->RenderTargets[2] = FRenderTargetBinding(NewDepth, ERenderTargetLoadAction::ENoAction);

		TShaderMapRef<FMabaTsrPS> Shader(ShaderMap);
		FPixelShaderUtils::AddFullscreenPass(GraphBuilder, ShaderMap,
			RDG_EVENT_NAME("MABA TSR %dx%d -> %dx%d%s", RenderSize.X, RenderSize.Y, OutputSize.X, OutputSize.Y,
				bReset ? TEXT(" (reset)") : TEXT("")),
			Shader, Params, FIntRect(FIntPoint::ZeroValue, OutputSize));

		GraphBuilder.QueueTextureExtraction(NewHist, &History.Color);
		GraphBuilder.QueueTextureExtraction(NewDepth, &History.Depth);
		GraphBuilder.QueueTextureExtraction(Shown, &History.Shown);
		History.OutputSize = OutputSize;
		History.RenderSize = RenderSize;
		History.PrevViewProj = CurViewProj;
		History.LastFrame = Frame;
		History.SeenResetToken = FMabaViewExtension::ResetToken.load();
		History.bValid = true;
		return Shown;
	}

	// A generated frame: the last real frame re-projected to this frame's camera pose. The matrices are built relative to THIS frame's
	// camera position (computed in double precision, then cast), so large world coordinates cost no precision on the GPU.
	void AddMabaFgWarpPass(FRDGBuilder& GraphBuilder, FGlobalShaderMap* ShaderMap, const FSceneView& View,
		FMabaTemporalHistory& History, const FScreenPassRenderTarget& Output, float InSharpness)
	{
		const FIntPoint OutputSize = Output.ViewRect.Size();
		const FMatrix Proj = View.ViewMatrices.ComputeProjectionNoAAMatrix();
		const FMatrix NewVP = MabaCompat::WorldToView(View.ViewMatrices).RemoveTranslation() * Proj;
		const FMatrix LastVP = FTranslationMatrix(View.ViewMatrices.GetViewOrigin()) * History.PrevViewProj;
		// UE matrices are row-vector (v * M); the shared HLSL core multiplies column vectors.
		auto ToGpu = [](const FMatrix& M) { return FMabaMat4(M.GetTransposed()); };

		FMabaFgWarpPS::FParameters* Params = GraphBuilder.AllocParameters<FMabaFgWarpPS::FParameters>();
		Params->MabaShown = GraphBuilder.RegisterExternalTexture(History.Shown);
		Params->MabaOutDepth = GraphBuilder.RegisterExternalTexture(History.Depth);
		Params->MabaLinearSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();
		Params->MabaLastVP = ToGpu(LastVP);
		Params->MabaLastInvVP = ToGpu(LastVP.Inverse());
		Params->MabaNewVP = ToGpu(NewVP);
		Params->MabaNewInvVP = ToGpu(NewVP.Inverse());
		Params->MabaOutInfo = FMabaVec4(OutputSize.X, OutputSize.Y, 1.0f / OutputSize.X, 1.0f / OutputSize.Y);
		Params->MabaOutputRect = FMabaVec4(Output.ViewRect.Min.X, Output.ViewRect.Min.Y, 0.0f, 0.0f);
		Params->MabaPresent = FMabaVec4(InSharpness * 0.12f, 0.0f, 0.0f, 0.0f);
		Params->RenderTargets[0] = Output.GetRenderTargetBinding();
		TShaderMapRef<FMabaFgWarpPS> Shader(ShaderMap);
		FPixelShaderUtils::AddFullscreenPass(GraphBuilder, ShaderMap,
			RDG_EVENT_NAME("MABA Frame Generation warp %dx%d", OutputSize.X, OutputSize.Y), Shader, Params, Output.ViewRect);
	}

	// The output target of the pass when the engine did not hand one over (the pass is not the last in the chain).
	void EnsureOutput(FRDGBuilder& GraphBuilder, const FScreenPassTexture& SceneColor, const FIntPoint& OutputSize, FScreenPassRenderTarget& Output)
	{
		if (Output.IsValid())
		{
			return;
		}
		FRDGTextureDesc OutputDesc = SceneColor.Texture->Desc;
		OutputDesc.Reset();
		OutputDesc.Extent = OutputSize;
		OutputDesc.Flags &= ~TexCreate_UAV;
		OutputDesc.Flags |= TexCreate_RenderTargetable | TexCreate_ShaderResource;
		OutputDesc.ClearValue = FClearValueBinding(FLinearColor::Black);
		FRDGTextureRef OutputTexture = GraphBuilder.CreateTexture(OutputDesc, TEXT("MABA Upscaled"));
		Output = FScreenPassRenderTarget(OutputTexture, FIntRect(FIntPoint::ZeroValue, OutputSize),
			ERenderTargetLoadAction::ENoAction);
	}

	void AddMabaPresentPass(FRDGBuilder& GraphBuilder, FGlobalShaderMap* ShaderMap, FRDGTextureRef Shown,
		const FScreenPassRenderTarget& Output, float Sharpness)
	{
		const FIntPoint OutputSize = Output.ViewRect.Size();
		FMabaTsrPresentPS::FParameters* Params = GraphBuilder.AllocParameters<FMabaTsrPresentPS::FParameters>();
		Params->MabaShown = Shown;
		Params->MabaOutInfo = FMabaVec4(OutputSize.X, OutputSize.Y, 1.0f / OutputSize.X, 1.0f / OutputSize.Y);
		Params->MabaOutputRect = FMabaVec4(Output.ViewRect.Min.X, Output.ViewRect.Min.Y, 0.0f, 0.0f);
		Params->MabaPresent = FMabaVec4(Sharpness * 0.12f, 0.0f, 0.0f, 0.0f);   // the app's default 0.5 -> 0.06
		Params->RenderTargets[0] = Output.GetRenderTargetBinding();
		TShaderMapRef<FMabaTsrPresentPS> Shader(ShaderMap);
		FPixelShaderUtils::AddFullscreenPass(GraphBuilder, ShaderMap,
			RDG_EVENT_NAME("MABA Present %dx%d", OutputSize.X, OutputSize.Y), Shader, Params, Output.ViewRect);
	}
}
FScreenPassTexture FMabaViewExtension::UpscalePass(FRDGBuilder& GraphBuilder, const FSceneView& View,
	const FPostProcessMaterialInputs& Inputs)
{
#if MABA_UE_INPUTS_ARE_SLICES
	// 5.4+: inputs are texture slices.
	const FScreenPassTexture SceneColor = FScreenPassTexture::CopyFromSlice(GraphBuilder,
		Inputs.GetInput(EPostProcessMaterialInput::SceneColor));
#else
	const FScreenPassTexture SceneColor = Inputs.GetInput(EPostProcessMaterialInput::SceneColor);
#endif
	if (!SceneColor.IsValid())
	{
		return SceneColor;
	}

	// If the engine asked this pass to write a specific target (it is the last pass in the
	// chain), that target must be filled even when MABA has nothing to do.
	FScreenPassRenderTarget Output = Inputs.OverrideOutput;
	const FIntPoint RenderSize = SceneColor.ViewRect.Size();
	const FIntPoint OutputSize = Output.IsValid() ? Output.ViewRect.Size() : View.UnscaledViewRect.Size();

	// Frame Generation: a generated frame did not render the scene (see SetupViewFamily). The image is the last real frame
	// re-projected to this frame's camera pose; this pass is where it is made.
	const bool bGeneratedFrame = View.Family != nullptr && MabaFg::HasGeneratedMarker(View.Family->EngineShowFlags);
	if (bEnabled && bGeneratedFrame)
	{
		RDG_EVENT_SCOPE(GraphBuilder, "MABA Frame Generation");
		EnsureOutput(GraphBuilder, SceneColor, OutputSize, Output);
		TSharedPtr<FMabaTemporalHistory>* Found = View.State != nullptr ? Histories.Find(View.State) : nullptr;
		FMabaTemporalHistory* Last = (Found != nullptr && Found->IsValid()) ? Found->Get() : nullptr;
		if (Last != nullptr && Last->bValid && Last->Shown.IsValid() && Last->Depth.IsValid() && Last->OutputSize == OutputSize)
		{
			AddMabaFgWarpPass(GraphBuilder, GetGlobalShaderMap(View.GetFeatureLevel()), View, *Last, Output, Sharpness);
		}
		else
		{
			// Nothing to warp from (the size changed, the history was reset): show black for this one frame and stop generating
			// until a real frame has rebuilt the history.
			AddClearRenderTargetPass(GraphBuilder, Output.Texture);
			MabaFg::SetRealFrameReady(false);
		}
		return FScreenPassTexture(Output.Texture, Output.ViewRect);
	}

	// The MABA core reads an image region that starts at texel (0,0).
	const bool bCanUpscale = bEnabled
		&& SceneColor.ViewRect.Min == FIntPoint::ZeroValue
		&& RenderSize.X >= 2 && RenderSize.Y >= 2
		&& OutputSize.X > RenderSize.X && OutputSize.Y > RenderSize.Y;
	if (!bCanUpscale)
	{
		bTemporalRanLastFrame = false;
		MabaFg::SetRealFrameReady(false);
		if (Output.IsValid())
		{
			// The post-process callback always receives the renderer's FViewInfo.
			check(View.bIsViewInfo);
			AddDrawTexturePass(GraphBuilder, static_cast<const FViewInfo&>(View), SceneColor, Output);
			return FScreenPassTexture(Output.Texture, Output.ViewRect);
		}
		return SceneColor;
	}

	RDG_EVENT_SCOPE(GraphBuilder, "MABA Upscaler");

	EnsureOutput(GraphBuilder, SceneColor, OutputSize, Output);

	FGlobalShaderMap* ShaderMap = GetGlobalShaderMap(View.GetFeatureLevel());

	// Temporal super-resolution: only when SetupView jittered this view (so the resolve can undo the
	// jitter), the scene depth exists, and the view has a state to key the history by. Otherwise the
	// spatial pass below upscales (a mobile or depth-less renderer still gets an upscaled image).
	const FVector2D JitterNdc = View.ViewMatrices.GetTemporalAAJitter();
	const bool bJittered = !JitterNdc.IsZero();
	FRDGTextureRef SceneDepth = MabaCompat::GetSceneDepth(Inputs.SceneTextures);
	bool bRanTemporal = false;
	if (bTemporal && bJittered && SceneDepth != nullptr && View.State != nullptr && View.GetFeatureLevel() >= ERHIFeatureLevel::SM5)
	{
		TSharedPtr<FMabaTemporalHistory> History = Histories.FindOrAdd(View.State);
		if (!History.IsValid())
		{
			History = MakeShared<FMabaTemporalHistory>();
			Histories[View.State] = History;
		}
		FRDGTextureRef Shown = AddMabaTsrPass(GraphBuilder, ShaderMap, View, SceneColor, SceneDepth, *History,
			JitterNdc, OutputSize, DepthTolerance, ClipGamma);
		AddMabaPresentPass(GraphBuilder, ShaderMap, Shown, Output, Sharpness);
		bRanTemporal = true;

		// Forget views that stopped rendering (closed viewports, destroyed players).
		const uint32 Frame = TickCounter.load();
		for (auto It = Histories.CreateIterator(); It; ++It)
		{
			if (It.Value().IsValid() && (Frame - It.Value()->LastFrame) > 120u)
			{
				It.RemoveCurrent();
			}
		}
	}
	bTemporalRanLastFrame = bRanTemporal;
	MabaFg::SetRealFrameReady(bRanTemporal);

	if (!bRanTemporal)
	{
		AddMabaPass(GraphBuilder, ShaderMap, bQualityShader, SceneColor, Output, Sharpness);
	}
	return FScreenPassTexture(Output.Texture, Output.ViewRect);
}
