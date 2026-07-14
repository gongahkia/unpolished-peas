cbuffer Parameters : register(b0, space3)
{
    float params_amount : packoffset(c0);
};

Texture2D<float4> source_texture : register(t0, space2);
SamplerState _source_texture_sampler : register(s0, space2);

static float2 in_uv;
static float4 out_color;

struct SPIRV_Cross_Input
{
    float2 in_uv : TEXCOORD0;
};

struct SPIRV_Cross_Output
{
    float4 out_color : SV_Target0;
};

void frag_main()
{
    float4 color = source_texture.Sample(_source_texture_sampler, in_uv);
    out_color = float4(lerp(color.xyz, 1.0f.xxx - color.xyz, params_amount.xxx), color.w);
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    in_uv = stage_input.in_uv;
    frag_main();
    SPIRV_Cross_Output stage_output;
    stage_output.out_color = out_color;
    return stage_output;
}
