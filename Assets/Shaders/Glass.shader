Shader "Unlit/Glass"
{
	Properties
	{
		_MainTex("Main Tex", 2D) = "white" {}
		_BumpMap("Normal Map", 2D) = "bump" {}
		_Distortion("Distortion", Range(0, 100)) = 10
		_RefractAmount("Refract Amount", Range(0.0, 1.0)) = 1.0
		
		_MetallicGlossMap("Metallic (R) Smoothness (A)", 2D) = "white" {}
		_MetallicStrength("Metallic Strength", Range(0,1)) = 0
		_Smoothness("Smoothness", Range(0,1)) = 0.5
		_Occlusion("AO", Range(0,1)) = 1
		_Anisotropy("Anisotropy", Range(-1,1)) = 0
		
		[HDR]_EmissionColor("Emission Color", Color) = (0,0,0,1)
		_EmissionMap("Emission Map", 2D) = "black" {}
	}

	SubShader
	{
		Tags
		{
			"Queue" = "Transparent"
			"RenderType" = "Transparent"
			"RenderPipeline" = "UniversalPipeline"
		}

		ZWrite Off
		Blend SrcAlpha OneMinusSrcAlpha
		Cull Back

		Pass
		{
			Name "ForwardRefraction"

			HLSLPROGRAM
			#pragma vertex vert
			#pragma fragment frag
			#pragma multi_compile _ _MAIN_LIGHT_SHADOWS
			#pragma multi_compile_fog
			#pragma multi_compile _ _REFLECTION_PROBE_BLENDING

			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
			#include "MyHLSL.hlsl"

			TEXTURE2D(_MainTex);			SAMPLER(sampler_MainTex);
			TEXTURE2D(_BumpMap);			SAMPLER(sampler_BumpMap);
			TEXTURE2D(_MetallicGlossMap);   SAMPLER(sampler_MetallicGlossMap);
			TEXTURE2D(_EmissionMap);        SAMPLER(sampler_EmissionMap);
			TEXTURE2D(_BrdfLUT);            SAMPLER(sampler_BrdfLUT);

			float4 _MainTex_ST;
			float4 _BumpMap_ST;
			float4 _MetallicGlossMap_ST;
			float4 _EmissionMap_ST;
			float   _Distortion;
			float   _RefractAmount;
			float  _MetallicStrength;
			float  _Smoothness;
			float  _Occlusion;
			float  _Anisotropy;
			float4 _EmissionColor;

			struct Attributes
			{
				float4 positionOS : POSITION;
				float3 normalOS   : NORMAL;
				float4 tangentOS  : TANGENT;
				float2 uv         : TEXCOORD0;
			};

			struct Varyings
			{
				float4 positionCS : SV_POSITION;
				float2 uvMain     : TEXCOORD0;
				float2 uvBump     : TEXCOORD1;
				float2 uvMetallic : TEXCOORD2;
				float2 uvEmission : TEXCOORD3;
				float3 positonWS  : TEXCOORD4;
				float3 normalWS   : TEXCOORD5;
				float4 tangentWS  : TEXCOORD6;
				float3 viewDir    : TEXCOORD7;
				float4 screenPos  : TEXCOORD8;
				float4 shadowCoord: TEXCOORD9;
				float  fogFactor  : TEXCOORD10;
			};

			Varyings vert(Attributes v)
			{
				Varyings o;

				VertexPositionInputs vp = GetVertexPositionInputs(v.positionOS.xyz);
				o.positionCS = vp.positionCS;
				o.positonWS = vp.positionWS;

				VertexNormalInputs vn = GetVertexNormalInputs(v.normalOS, v.tangentOS);
				o.normalWS = vn.normalWS;
				o.tangentWS = float4(vn.tangentWS, v.tangentOS.w);

				o.viewDir = GetWorldSpaceNormalizeViewDir(vp.positionWS);
				o.shadowCoord = GetShadowCoord(vp);

				o.uvMain = TRANSFORM_TEX(v.uv, _MainTex);
				o.uvBump = TRANSFORM_TEX(v.uv, _BumpMap);
				o.uvMetallic = TRANSFORM_TEX(v.uv, _MetallicGlossMap);
				o.uvEmission = TRANSFORM_TEX(v.uv, _EmissionMap);

				// 与内置的 ComputeGrabScreenPos 对齐：用于屏幕空间采样
				o.screenPos = ComputeScreenPos(o.positionCS);
				
				// 雾效插值因子
				o.fogFactor = ComputeFogFactor(vp.positionCS.z);

				return o;
			}

			// PBR光照计算函数
			inline float3 ComputePBRDirectLighting(float3 N, float3 L, float3 V, float3 baseColor, float metallic, float roughness, float3 lightColor, float NdotL, float4 tangentWS, float anisotropy)
			{
				half3 halfDir = SafeNormalize(L + V);
				half NdotH = saturate(dot(N, halfDir));
				half NdotV = saturate(dot(N, V));
				half VdotH = saturate(dot(V, halfDir));
				
				// 法线分布函数 (GGX)
				float D = DistributionAnisotropic(roughness, L, V, N, tangentWS, anisotropy);
				half G = GeometrySmith(NdotV, NdotL, roughness);
				half3 F0 = lerp(0.04, baseColor, metallic);
				float3 F = Fresnel(F0, VdotH);
				
				// 组合BRDF
				half3 specularTerm = BRDF(D, G, F, NdotV, NdotL);
				specularTerm *= lightColor * NdotL;
				
				half3 kd = (1.0 - F) * (1.0 - metallic);
				half3 diffuseTerm = kd * baseColor * lightColor * NdotL;
				
				return diffuseTerm + specularTerm;
			}

			inline float3 ComputePBRIndirectLighting(float3 N, float3 V, float3 baseColor, float metallic, float roughness, float occlusion)
			{
				// 环境光镜面反射
				half3 reflectVec = reflect(-V, N);
				half mip = roughness * 6;
				half4 encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVec, mip);
				half3 irradiance = DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);

				// BRDF LUT采样
				half NdotV = saturate(dot(N, V));
				half2 envBRDF = SAMPLE_TEXTURE2D_LOD(_BrdfLUT, sampler_BrdfLUT, float2(NdotV, roughness), 0).rg;
				half3 F0 = lerp(0.04, baseColor, metallic);
				half3 F = Fresnel(F0, NdotV);
				half3 ambientSpecular = irradiance * (F * envBRDF.x + envBRDF.y);
				
				// 球谐光照（低频间接光）
				half3 ambientDiffuse = SampleSH(N) * baseColor * (1.0 - metallic);
				
				return (ambientDiffuse + ambientSpecular) * occlusion;
			}

			half4 frag(Varyings i) : SV_Target
			{
				float3 viewDirWS = i.viewDir;

				// 采样PBR相关纹理
				half4 metallicGloss = SAMPLE_TEXTURE2D(_MetallicGlossMap, sampler_MetallicGlossMap, i.uvMetallic);
				half metallic = metallicGloss.r * _MetallicStrength;
				half smoothness = metallicGloss.a * _Smoothness;
				half occlusion = metallicGloss.g * _Occlusion;
				half3 emission = SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, i.uvEmission).rgb * _EmissionColor.rgb;
				float roughness = saturate(1.0 - smoothness);
				roughness = max(roughness * roughness, 1e-4);

				// 法线贴图（切线空间）
				half3 normalTS = UnpackNormal(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, i.uvBump));

				// 屏幕 UV（0~1）
				float2 uvScreen = i.screenPos.xy / i.screenPos.w;

				// 像素级偏移（使用 _CameraOpaqueTexture 的 texel 尺寸）
				float2 offset = normalTS.xy * _Distortion * _CameraOpaqueTexture_TexelSize.xy;

				// 透视修正
				float2 refractUV = uvScreen + offset * i.screenPos.z;

				// 折射色（从 URP 的场景颜色纹理采样）
				half3 refrCol = SampleSceneColor(refractUV).rgb;

				// 将法线转为世界空间
				half3x3 TBN = half3x3(
					i.tangentWS.xyz,
					cross(i.normalWS, i.tangentWS.xyz) * i.tangentWS.w,
					i.normalWS);
				half3 normalWS = TransformTangentToWorld(normalTS, TBN);
				normalWS = NormalizeNormalPerPixel(normalWS);

				// 反射色（环境立方体贴图）
				half3 reflDir = reflect(-viewDirWS, normalWS);
				half3 baseCol = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uvMain).rgb;

				half mip = 0;
				half4 encodeIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflDir, mip);
				half3 probeRefl = DecodeHDREnvironment(encodeIrradiance, unity_SpecCube0_HDR);
				half3 reflCol = probeRefl * baseCol;
				
				// PBR直接光照
				half3 pbrDirect = 0;
				if (_MetallicStrength > 0 || _Smoothness > 0)
				{
					// 主光源
					Light mainLight = GetMainLight(i.shadowCoord);
					half3 L = mainLight.direction;
					half NdotL = saturate(dot(normalWS, L));
					
					if (NdotL > 0)
					{
						half3 lightColor = mainLight.color * mainLight.distanceAttenuation * mainLight.shadowAttenuation;
						pbrDirect = ComputePBRDirectLighting(normalWS, L, viewDirWS, baseCol, metallic, roughness, lightColor, NdotL, i.tangentWS, _Anisotropy);
					}
				}
				
				// PBR间接光照
				half3 pbrIndirect = 0;
				if (_MetallicStrength > 0 || _Smoothness > 0)
				{
					pbrIndirect = ComputePBRIndirectLighting(normalWS, viewDirWS, baseCol, metallic, roughness, occlusion);
				}
				
				// 折射/反射混合
				half3 finalRGB = lerp(reflCol, refrCol, saturate(_RefractAmount));
				
				// 添加PBR光照
				finalRGB += pbrDirect + pbrIndirect + emission;
				
				// 雾效
				finalRGB = MixFog(finalRGB, i.fogFactor);
				
				// 若需要透光度，可把 alpha 做成与折射量相关；这里保持 1
				return half4(finalRGB, 1);
			}
			ENDHLSL
		}
	}

	FallBack "Hidden/Universal Render Pipeline/Lit"
}