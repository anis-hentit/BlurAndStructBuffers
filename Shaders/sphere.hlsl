//***************************************************************************************
// Default.hlsl by Frank Luna (C) 2015 All Rights Reserved.
//
// Default shader, currently supports lighting.
//***************************************************************************************

// Defaults for number of lights.
#ifndef NUM_DIR_LIGHTS
#define NUM_DIR_LIGHTS 3
#endif

#ifndef NUM_POINT_LIGHTS
#define NUM_POINT_LIGHTS 0
#endif

#ifndef NUM_SPOT_LIGHTS
#define NUM_SPOT_LIGHTS 0
#endif

// Include structures and functions for lighting.
#include "LightingUtil.hlsl"

Texture2D    gDiffuseMap : register(t0);


SamplerState gsamPointWrap        : register(s0);
SamplerState gsamPointClamp       : register(s1);
SamplerState gsamLinearWrap       : register(s2);
SamplerState gsamLinearClamp      : register(s3);
SamplerState gsamAnisotropicWrap  : register(s4);
SamplerState gsamAnisotropicClamp : register(s5);

// Constant data that varies per frame.
cbuffer cbPerObject : register(b0)
{
    float4x4 gWorld;
    float4x4 gTexTransform;
};

// Constant data that varies per material.
cbuffer cbPass : register(b1)
{
    float4x4 gView;
    float4x4 gInvView;
    float4x4 gProj;
    float4x4 gInvProj;
    float4x4 gViewProj;
    float4x4 gInvViewProj;
    float3 gEyePosW;
    float cbPerObjectPad1;
    float2 gRenderTargetSize;
    float2 gInvRenderTargetSize;
    float gNearZ;
    float gFarZ;
    float gTotalTime;
    float gDeltaTime;
    float4 gAmbientLight;

    float4 gFogColor;
    float gFogStart;
    float gFogRange;
    float2 cbPerObjectPad2;

    // Indices [0, NUM_DIR_LIGHTS) are directional lights;
    // indices [NUM_DIR_LIGHTS, NUM_DIR_LIGHTS+NUM_POINT_LIGHTS) are point lights;
    // indices [NUM_DIR_LIGHTS+NUM_POINT_LIGHTS, NUM_DIR_LIGHTS+NUM_POINT_LIGHT+NUM_SPOT_LIGHTS)
    // are spot lights for a maximum of MaxLights per object.
    Light gLights[MaxLights];
};

cbuffer cbMaterial : register(b2)
{
    float4   gDiffuseAlbedo;
    float3   gFresnelR0;
    float    gRoughness;
    float4x4 gMatTransform;
};

struct VertexIn
{
    float3 PosL    : POSITION;
    float3 NormalL : NORMAL;
    float2 TexC    : TEXCOORD;
};

struct VertexOut
{
    float4 PosH    : POSITION;
    float3 PosW    : POSITIONW;
    float3 NormalW : NORMAL;
    float2 TexC    : TEXCOORD;
};



struct GeoOut
{
    float4 PosH    : SV_POSITION;
    float3 PosW    : POSITIONW;
    float3 NormalW : NORMAL;
    float2 TexC    : TEXCOORD;

};


VertexOut VS(VertexIn vin)
{
    VertexOut vout = (VertexOut)0.0f;

    // Transform to world space.
    float4 posW = float4(vin.PosL, 1.0f);
    vout.PosW = posW.xyz;

    // Assumes nonuniform scaling; otherwise, need to use inverse-transpose of world matrix.
    vout.NormalW = vin.NormalL;

    // Output vertex attributes for interpolation across triangle.
    float4 texC = mul(float4(vin.TexC, 0.0f, 1.0f), gTexTransform);
    vout.TexC = mul(texC, gMatTransform).xy;

    return vout;
}




void Subdivide(VertexOut inVerts[3], out VertexOut outVerts[6])
{
    //       1
    //       *
    //      / \
	//     /   \
	//  m0*-----*m1
    //   / \   / \
	//  /   \ /   \
	// *-----*-----*
    // 0    m2     2

    VertexOut m[3];

    // Compute edge midpoints.
    m[0].PosW = 0.5f * (inVerts[0].PosW + inVerts[1].PosW);
    m[1].PosW = 0.5f * (inVerts[1].PosW + inVerts[2].PosW);
    m[2].PosW = 0.5f * (inVerts[2].PosW + inVerts[0].PosW);

    // Project onto unit sphere
    m[0].PosW = normalize(m[0].PosW)*4;
    m[1].PosW = normalize(m[1].PosW)*4;
    m[2].PosW = normalize(m[2].PosW)*4;

    // Derive normals.
    m[0].NormalW = normalize(m[0].PosW);
    m[1].NormalW = normalize(m[1].PosW);
    m[2].NormalW = normalize(m[2].PosW);

    // Interpolate texture coordinates.
    m[0].TexC= 0.5f * (inVerts[0].TexC + inVerts[1].TexC);
    m[1].TexC= 0.5f * (inVerts[1].TexC + inVerts[2].TexC);
    m[2].TexC= 0.5f * (inVerts[2].TexC + inVerts[0].TexC);

    outVerts[0] = inVerts[0];
    outVerts[1] = m[0];
    outVerts[2] = m[2];
    outVerts[3] = m[1];
    outVerts[4] = inVerts[2];
    outVerts[5] = inVerts[1];
};

void OutputSubdivision(VertexOut v[6], inout TriangleStream<GeoOut> triStream)
{
    GeoOut gout[6];

    [unroll]
    for (int i = 0; i < 6; ++i)
    {
        //Transform to world space space. 
        gout[i].PosW = v[i].PosW;
        gout[i].NormalW = v[i].NormalW;

        // Transform to homogeneous clip space.
        gout[i].PosH = mul(float4(v[i].PosW, 1.0f), gViewProj);

        gout[i].TexC = v[i].TexC;
    }

    //       1
    //       *
    //      / \
	//     /   \
	//  m0*-----*m1
    //   / \   / \
	//  /   \ /   \
	// *-----*-----*
    // 0    m2     2
    //
    // We can draw the subdivision in two strips:
    //     Strip 1: bottom three triangles
    //     Strip 2: top triangle

    [unroll]
    for (int j = 0; j < 5; ++j)
    {
        triStream.Append(gout[j]);
    }
    triStream.RestartStrip();

    triStream.Append(gout[1]);
    triStream.Append(gout[5]);
    triStream.Append(gout[3]);
}



[maxvertexcount(32)]
void GS(triangle VertexOut gin[3], inout TriangleStream<GeoOut> triStream)
{
    
    float d = distance(gEyePosW, float3(0.0f,0.0f,0.0f));

    if (d < 15) // Subdivide twice.
    {
        VertexOut v[6];
        

        Subdivide(gin, v);
        
        // Subdivide each triangle from the previous subdivision.
        VertexOut tri0[3] = { v[0], v[1], v[2] };
        VertexOut tri1[3] = { v[1], v[3], v[2] };
        VertexOut tri2[3] = { v[2], v[3], v[4] };
        VertexOut tri3[3] = { v[1], v[5], v[3] };

        Subdivide(tri0, v);
        OutputSubdivision(v, triStream);
        triStream.RestartStrip();

        Subdivide(tri1, v);
        OutputSubdivision(v, triStream);
        triStream.RestartStrip();

        Subdivide(tri2, v);
        OutputSubdivision(v, triStream);
        triStream.RestartStrip();

        Subdivide(tri3, v);
        OutputSubdivision(v, triStream);
        triStream.RestartStrip();

       
    }
    else if (d < 30.0f) // Subdivide once.
    {
        VertexOut v[6];
        Subdivide(gin, v);
        OutputSubdivision(v, triStream);
    }
    else // No subdivision
    {
        GeoOut gout[3];
        [unroll]
        for (int i = 0; i < 3; ++i)
        {
            
            gout[i].PosW = gin[i].PosW;
            gout[i].NormalW = gin[i].NormalW;

            // Transform to homogeneous clip space.
            gout[i].PosH = mul(float4(gin[i].PosW, 1.0f), gViewProj);

            gout[i].TexC = gin[i].TexC;

            triStream.Append(gout[i]);
        }
    }

}





float4 PS(GeoOut pin) : SV_Target
{
    float4 diffuseAlbedo = gDiffuseMap.Sample(gsamAnisotropicWrap, pin.TexC) * gDiffuseAlbedo;

#ifdef ALPHA_TEST
    // Discard pixel if texture alpha < 0.1.  We do this test as soon 
    // as possible in the shader so that we can potentially exit the
    // shader early, thereby skipping the rest of the shader code.
    clip(diffuseAlbedo.a - 0.1f);
#endif

    // Interpolating normal can unnormalize it, so renormalize it.
    pin.NormalW = normalize(pin.NormalW);

    // Vector from point being lit to eye. 
    float3 toEyeW = gEyePosW - pin.PosW;
    float distToEye = length(toEyeW);
    toEyeW /= distToEye; // normalize

    // Light terms.
    float4 ambient = gAmbientLight * diffuseAlbedo;

    const float shininess = 1.0f - gRoughness;
    Material mat = { diffuseAlbedo, gFresnelR0, shininess };
    float3 shadowFactor = 1.0f;
    float4 directLight = ComputeLighting(gLights, mat, pin.PosW,
        pin.NormalW, toEyeW, shadowFactor);

    float4 litColor = ambient + directLight;

#ifdef FOG
    //float fogAmount = saturate((distToEye - gFogStart) / gFogRange);
    //litColor = lerp(litColor, gFogColor, fogAmount);
#endif

    // Common convention to take alpha from diffuse albedo.
    litColor.a = diffuseAlbedo.a;

    return litColor;
}


