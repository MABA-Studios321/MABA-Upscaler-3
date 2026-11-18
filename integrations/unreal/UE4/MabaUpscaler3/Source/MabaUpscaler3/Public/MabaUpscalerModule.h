// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"
#include "Modules/ModuleManager.h"

class FMabaUpscalerModule : public IModuleInterface
{
public:
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;

	/** What the plugin did on the last game-thread tick (read-only snapshot, game thread). */
	struct FStatus
	{
		bool bActive = false;              // false when r.Maba.Enable is 0
		int32 Mode = 0;                    // 0 Dynamic, 1 Ultra Quality, 2 Quality, 3 Balanced, 4 Performance
		int32 Rung = 0;                    // -15 .. 51 on the 1% render-scale ladder (51 = native)
		float Scale = 1.0f;                // render scale, 0.35 .. 1.0
		bool bQualityShader = false;       // 12-tap kernel (true) or the fast kernel
		bool bTemporalRequested = false;   // r.Maba.Temporal
		bool bTemporalRunning = false;     // the resolve pass ran on the last frame
		int32 FrameGeneration = 0;         // r.Maba.FrameGeneration: 0 off, 1 2x, 2 3x
		bool bFrameGenerationSupported = false;   // the Frame Generation backend is available on this renderer
		bool bFrameGenerationActive = false;      // frames are being generated right now
		bool bFrameGenerationPaused = false;      // asked for, but the governor paused it
	};
	static FStatus GetStatus();

	/** True when the Frame Generation backend can run on this renderer (SM5, a game viewport, a perspective camera). */
	static bool IsFrameGenerationSupported();
};
