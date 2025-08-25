Shader "Scarecrow/MyPBR"
{
    Properties
    {
        [MainColor] _BaseColor("Color", Color) = (1,1,1,1)
        [MainTexture] _BaseMap("Albedo", 2D) = "white" {}
        _MetallicGlossMap("Metallic", 2D) = "white" {}
        _BumpMap("Normal Map", 2D) = "bump" {}
        _Occlusion("AO", Range(0,1)) = 0.5
        _MetallicStrength("Metallic Strength", Range(0,1)) = 1
        _Smoothness("Smoothness", Range(0,1)) = 0.5
        _BumpScale("Normal Scale", Float) = 1
        [HDR] _EmissionColor("Emission Color", Color) = (0,0,0,1)
        _EmissionMap("Emission Map", 2D) = "white" {}
        _Anisotropy("Anisotropy", Range(-1,1)) = 0
    }

    SubShader
    {
        Tags 
        { 
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Geometry"
        }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl"
        #include "MyHLSL.hlsl"

        TEXTURE2D(_BaseMap);            SAMPLER(sampler_BaseMap);
        TEXTURE2D(_MetallicGlossMap);   SAMPLER(sampler_MetallicGlossMap);
        TEXTURE2D(_BumpMap);            SAMPLER(sampler_BumpMap);
        TEXTURE2D(_EmissionMap);        SAMPLER(sampler_EmissionMap);
        TEXTURE2D(_BrdfLUT);            SAMPLER(sampler_BrdfLUT);

        CBUFFER_START(UnityPerMaterial)
        float4 _BaseMap_ST;
        float4 _BaseColor;
        float4 _EmissionColor;
        float _MetallicStrength;
        float _Smoothness;
        float _Occlusion;
        float _BumpScale;
        float _Anisotropy;
        CBUFFER_END
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _ADDITIONAL_LIGHTS
            #pragma multi_compile _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile _ _SHADOWS_SOFT
            #pragma multi_compile _ _REFLECTION_PROBE_BLENDING
            #pragma multi_compile_fog

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float4 tangentOS : TANGENT;
                float2 texcoord : TEXCOORD0;
                float2 lightmapUV : TEXCOORD1;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalWS : TEXCOORD2;
                float4 tangentWS : TEXCOORD3;
                float3 viewDirWS : TEXCOORD4;
                DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 5);
                float4 shadowCoord : TEXCOORD6;
                float fogFactor : TEXCOORD7;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;

                //MVP矩阵
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                output.positionCS = vertexInput.positionCS;
                output.positionWS = vertexInput.positionWS;

                // 法线计算
                VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);
                output.normalWS = normalInput.normalWS;
                output.tangentWS = float4(normalInput.tangentWS, input.tangentOS.w);
                
                output.viewDirWS = GetWorldSpaceNormalizeViewDir(output.positionWS);
                output.uv = TRANSFORM_TEX(input.texcoord, _BaseMap);

                // 输出用于光照图或球谐光照的 UV 和数据
                OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST, output.lightmapUV);
                OUTPUT_SH(output.normalWS.xyz, output.vertexSH);
                
                output.shadowCoord = GetShadowCoord(vertexInput);
                
                // 雾效插值因子（用于后续雾效混合）
                output.fogFactor = ComputeFogFactor(vertexInput.positionCS.z);
                return output;
            }
            

            half4 frag(Varyings input) : SV_Target
            {
                // 采样纹理
                half4 baseColor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv) * _BaseColor;
                half4 metallicGloss = SAMPLE_TEXTURE2D(_MetallicGlossMap, sampler_MetallicGlossMap, input.uv);
                half metallic = metallicGloss.r * _MetallicStrength;
                half smoothness = metallicGloss.a * _Smoothness;
                half occlusion = metallicGloss.g * _Occlusion;
                half3 emission = SAMPLE_TEXTURE2D(_EmissionMap, sampler_EmissionMap, input.uv).rgb * _EmissionColor.rgb;

                // 法线计算
                half3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv), _BumpScale);
                float3x3 tangentToWorld = float3x3(
                    input.tangentWS.xyz,
                    cross(input.normalWS, input.tangentWS.xyz) * input.tangentWS.w,
                    input.normalWS
                );
                half3 normalWS = TransformTangentToWorld(normalTS, tangentToWorld);
                normalWS = NormalizeNormalPerPixel(normalWS);

                // 光照计算
                float4 shadowCoord = TransformWorldToShadowCoord(input.positionWS);
                Light mainLight = GetMainLight(shadowCoord);
                half3 lightDir = mainLight.direction;
                half3 lightColor = mainLight.color * mainLight.distanceAttenuation * mainLight.shadowAttenuation;
                half3 viewDir = SafeNormalize(input.viewDirWS);
                
                // BRDF数据准备
                half3 specular = lerp(0.04, baseColor.rgb, metallic);
                half3 diffuse = baseColor.rgb * (1 - metallic);
                half roughness = 1.0 - smoothness;
                roughness = roughness * roughness;
                half3 F0 = specular;
                
                // 直接光照计算
                half NdotL = saturate(dot(normalWS, lightDir)) ;
                half3 halfDir = SafeNormalize(lightDir + viewDir);
                half NdotH = saturate(dot(normalWS, halfDir));
                half NdotV = saturate(dot(normalWS, viewDir));
                half VdotH = saturate(dot(viewDir, halfDir));
                
                // 法线分布函数 (GGX)
                float D = DistributionAnisotropic(roughness, lightDir, viewDir, normalWS, input.tangentWS, _Anisotropy);
                half G = GeometrySmith(NdotV, NdotL, roughness);
                float3 F = Fresnel(F0, VdotH);
                
                // 组合BRDF
                half3 specularTerm = BRDF(D, G, F, NdotV, NdotL);
                specularTerm *= lightColor * NdotL;
                half3 diffuseTerm = diffuse * lightColor * NdotL;
                
                // 环境光照
                // 球谐光照（低频间接光）
                half3 ambientDiffuse = SampleSH(normalWS) * diffuse;
                
                // 环境光镜面反射
                half3 reflectVec = reflect(-viewDir, normalWS);
                half mip = roughness * 6;
                half4 encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVec, mip);
                half3 irradiance = DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);

                // BRDF LUT采样
                half2 envBRDF = SAMPLE_TEXTURE2D_LOD(_BrdfLUT, sampler_BrdfLUT, float2(NdotV, roughness), 0).rg;
                half3 ambientSpecular = irradiance * (F * envBRDF.x + envBRDF.y);
                
                // 组合光照结果
                half3 color = (diffuseTerm + specularTerm) + (ambientDiffuse + ambientSpecular) * occlusion + emission;
                
                // 雾效
                color = MixFog(color, input.fogFactor);
                
                return half4(color, baseColor.a);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            HLSLPROGRAM
            #pragma vertex ShadowPassVertex
            #pragma fragment ShadowPassFragment

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 texcoord : TEXCOORD0;
            };

            struct Varyings
            {
                float2 uv : TEXCOORD0;
                float4 positionCS : SV_POSITION;
            };

            Varyings ShadowPassVertex(Attributes input)
            {
                Varyings output;
                output.uv = input.texcoord;
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                output.positionCS = vertexInput.positionCS;
                return output;
            }

            half4 ShadowPassFragment(Varyings input) : SV_TARGET
            {
                return 0;
            }
            ENDHLSL
        }
        
    }
    FallBack "Universal Render Pipeline/Lit"
    CustomEditor "UnityEditor.Rendering.Universal.ShaderGUI.PBRShaderGUI"
}