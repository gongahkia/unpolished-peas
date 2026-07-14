Texture2D<float4> sprite_texture : register(t0, space2);
SamplerState _sprite_texture_sampler : register(s0, space2);

static float4 out_color;
static float2 in_uv;
static float4 in_tint;

struct SPIRV_Cross_Input
{
    float2 in_uv : TEXCOORD0;
    float4 in_tint : TEXCOORD1;
};

struct SPIRV_Cross_Output
{
    float4 out_color : SV_Target0;
};

void frag_main()
{
    out_color = sprite_texture.Sample(_sprite_texture_sampler, in_uv) * in_tint;
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    in_uv = stage_input.in_uv;
    in_tint = stage_input.in_tint;
    frag_main();
    SPIRV_Cross_Output stage_output;
    stage_output.out_color = out_color;
    return stage_output;
}
