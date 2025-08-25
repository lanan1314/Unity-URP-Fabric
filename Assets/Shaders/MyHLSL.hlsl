#ifndef MY_FUNCTIONS_INCLUDED
#define MY_FUNCTIONS_INCLUDED

// 包含Unity核心着色器库
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"

// 各向异性法线分布函数
float DistributionAnisotropic(float roughness, float3 lightDir, float3 viewDir, float3 normalWS, float4 tangentWS, float anisotropy)
{
    float at = max(roughness * (1 + anisotropy), 0.001);
    float ab = max(roughness * (1 - anisotropy), 0.001);

    float3x3 tangentToWorld = float3x3(
        tangentWS.xyz,
        cross(normalWS, tangentWS.xyz) * tangentWS.w,
        normalWS
    );
                
    // 半角——>切线空间
    float3 H = normalize(lightDir + viewDir);
    float3 Ht = mul(tangentToWorld, H); 
    float3 Hn = normalize(Ht);
                
    float Hx = Hn.x;
    float Hy = Hn.y;
    float Hz = Hn.z;
                
    float denomAniso = Hx * Hx / (at * at) + Hy * Hy / (ab * ab) + Hz * Hz;
    return 1.0 / (PI * at * ab * denomAniso * denomAniso + 1e-5);
}

float D_GGX_TR(float3 N, float3 H, float a)
{
    float a2     = a*a;
    float NdotH  = max(dot(N, H), 0.0);
    float NdotH2 = NdotH*NdotH;

    float nom    = a2;
    float denom  = (NdotH2 * (a2 - 1.0) + 1.0);
    denom        = PI * denom * denom;

    return nom / denom;
}

// Smith几何遮蔽函数
float GeometrySmith(float NdotV, float NdotL, float roughness)
{
    half k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    half G1 = NdotV / (NdotV * (1 - k) + k);
    half G2 = NdotL / (NdotL * (1 - k) + k);
    return G1 * G2;
}

// Schlick菲涅尔近似
float3 Fresnel(half3 F0, float VdotH)
{
    return F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
}

// BRDF计算
half3 BRDF(float D, half G, float3 F, float NdotV, float NdotL)
{
    return (D * G * F) / (4.0 * NdotL * NdotV + 1e-5);
}


#endif
