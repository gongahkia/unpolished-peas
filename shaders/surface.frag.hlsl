cbuffer SurfaceParameters : register(b0, space3)
{
    int4 _12_destination : packoffset(c0);
    uint4 _12_sampling : packoffset(c1);
};

Texture2D<float4> sprite_texture : register(t0, space2);
SamplerState _sprite_texture_sampler : register(s0, space2);

static float4 gl_FragCoord;
static float2 in_uv;
static float4 in_tint;
static float4 out_color;

struct SPIRV_Cross_Input
{
    float2 in_uv : TEXCOORD0;
    float4 in_tint : TEXCOORD1;
    float4 gl_FragCoord : SV_Position;
};

struct SPIRV_Cross_Output
{
    float4 out_color : SV_Target0;
};

uint2 spvTextureSize(Texture2D<float4> Tex, uint Level, out uint Param)
{
    uint2 ret;
    Tex.GetDimensions(Level, ret.x, ret.y, Param);
    return ret;
}

void frag_main()
{
    float4 sample_color;
    if (_12_sampling.x == 0u)
    {
        int2 relative = int2(gl_FragCoord.xy) - _12_destination.xy;
        uint _46_dummy_parameter;
        int2 size = int2(spvTextureSize(sprite_texture, uint(0), _46_dummy_parameter));
        int2 coordinate = (relative * size) / _12_destination.zw;
        sample_color = sprite_texture.Load(int3(clamp(coordinate, int2(0, 0), size - int2(1, 1)), 0));
    }
    else
    {
        sample_color = sprite_texture.Sample(_sprite_texture_sampler, in_uv);
    }
    uint4 source = uint4(floor((clamp(sample_color, 0.0f.xxxx, 1.0f.xxxx) * 255.0f) + 0.5f.xxxx));
    uint4 tint = uint4(floor((clamp(in_tint, 0.0f.xxxx, 1.0f.xxxx) * 255.0f) + 0.5f.xxxx));
    out_color = float4((source * tint) / uint4(255u, 255u, 255u, 255u)) / 255.0f.xxxx;
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    gl_FragCoord = stage_input.gl_FragCoord;
    gl_FragCoord.w = 1.0 / gl_FragCoord.w;
    in_uv = stage_input.in_uv;
    in_tint = stage_input.in_tint;
    frag_main();
    SPIRV_Cross_Output stage_output;
    stage_output.out_color = out_color;
    return stage_output;
}
