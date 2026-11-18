//==============================================================================================
// MABA Upscaler 2 - full-screen triangle vertex shader
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// No vertex buffer needed: bind an empty VAO and draw 3 vertices.
// Prepend the same header as the fragment shader ("#version 310 es\n", "#version 300 es\n",
// or "#version 450\n#define MABA_VULKAN 1\n").
//==============================================================================================

#ifndef MABA_VULKAN
#define MABA_VULKAN 0
#endif

#if MABA_VULKAN
layout(location = 0) out highp vec2 vMabaUV;
#define MABA_VERTEX_ID gl_VertexIndex
#else
out highp vec2 vMabaUV;
#define MABA_VERTEX_ID gl_VertexID
#endif

void main()
{
    highp vec2 p = vec2(float((MABA_VERTEX_ID << 1) & 2), float(MABA_VERTEX_ID & 2));
    vMabaUV = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
