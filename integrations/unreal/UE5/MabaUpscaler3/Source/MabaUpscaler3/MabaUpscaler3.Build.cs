// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
using System.IO;
using UnrealBuildTool;

public class MabaUpscaler3 : ModuleRules
{
	public MabaUpscaler3(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[] {
			"Core", "CoreUObject", "Engine", "RenderCore", "RHI", "Renderer", "Projects", "DeveloperSettings",
			"UMG", "Slate", "SlateCore"
		});

		PrivateIncludePaths.Add(Path.Combine(ModuleDirectory, "Private"));

		// The post-process callback types (PostProcess/PostProcessMaterial.h, SceneRendering.h)
		// are private / internal renderer headers, the same ones AMD's FSR plugins include.
		string RendererDir = Path.Combine(EngineDirectory, "Source", "Runtime", "Renderer");
		foreach (string Sub in new string[] { "Private", "Internal" })
		{
			string Dir = Path.Combine(RendererDir, Sub);
			if (Directory.Exists(Dir))
			{
				PrivateIncludePaths.Add(Dir);
			}
		}
	}
}
