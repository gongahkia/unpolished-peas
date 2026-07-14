static float4 gl_Position;
static float2 in_position;
static float2 out_uv;
static float2 in_uv;
static float4 out_tint;
static float4 in_tint;

struct SPIRV_Cross_Input
{
    float2 in_position : TEXCOORD0;
    float2 in_uv : TEXCOORD1;
    float4 in_tint : TEXCOORD2;
};

struct SPIRV_Cross_Output
{
    float2 out_uv : TEXCOORD0;
    float4 out_tint : TEXCOORD1;
    float4 gl_Position : SV_Position;
};

void vert_main()
{
    gl_Position = float4(in_position, 0.0f, 1.0f);
    out_uv = in_uv;
    out_tint = in_tint;
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    in_position = stage_input.in_position;
    in_uv = stage_input.in_uv;
    in_tint = stage_input.in_tint;
    vert_main();
    SPIRV_Cross_Output stage_output;
    stage_output.gl_Position = gl_Position;
    stage_output.out_uv = out_uv;
    stage_output.out_tint = out_tint;
    return stage_output;
}
