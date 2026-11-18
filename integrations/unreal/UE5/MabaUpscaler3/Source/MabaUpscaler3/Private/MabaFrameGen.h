// MABA Frame Generation (Unreal): the game-thread scheduler. The game keeps ticking every frame; the world is rendered every
// second (third) one ("real" frames) and the others are "generated": the scene is rendered with almost everything switched off
// (so it costs next to nothing) and the post-process pass replaces its image with the last real frame re-projected to this
// frame's camera pose (Shaders/MabaFgWarp.usf). Same design as the Godot addon, where it is measured.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
#pragma once

#include "CoreMinimal.h"

struct FEngineShowFlags;

namespace MabaFg
{
	/** True when Frame Generation can run on this renderer (SM5 scene textures, a real game, not a commandlet). */
	bool IsSupported();

	/**
	 * Game thread, once per tick before the frame is rendered. Decides whether THIS tick is generated.
	 * @param RequestedMode 0 off, 1 = 2x, 2 = 3x (r.Maba.FrameGeneration)
	 * @param bAutoPause    pause while it would not show more frames per second than leaving it off
	 * @param DeltaSeconds  the time this tick took (the governor measures the ms per displayed frame)
	 */
	void BeginTick(int32 RequestedMode, bool bAutoPause, float DeltaSeconds);

	/** This tick is a generated one (game thread). */
	bool IsGeneratingThisTick();

	/** Frame Generation was asked for, would run, but the governor paused it. */
	bool IsPaused();

	/** Render thread: a real frame has left its history behind, so a generated frame can be made from it. */
	void SetRealFrameReady(bool bReady);

	/** Render thread: the view family was set up as a generated frame (the cheap show flags are the marker: it is the one thing that
	 *  travels with the family from the game thread to the render thread, and no frame renders with all of them off). */
	bool HasGeneratedMarker(const FEngineShowFlags& Flags);

	/** Show flags that make a generated frame's scene render nearly free (everything the warp does not need is off). */
	void ApplyCheapShowFlags(FEngineShowFlags& Flags);
}