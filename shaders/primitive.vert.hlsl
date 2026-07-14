static float4 gl_Position;
static float2 in_position;
static float4 out_color;
static float4 in_color;

struct SPIRV_Cross_Input
{
    float2 in_position : TEXCOORD0;
    float4 in_color : TEXCOORD1;
};

struct SPIRV_Cross_Output
{
    float4 out_color : TEXCOORD0;
    float4 gl_Position : SV_Position;
};

void vert_main()
{
    gl_Position = float4(in_position, 0.0f, 1.0f);
    out_color = in_color;
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    in_position = stage_input.in_position;
    in_color = stage_input.in_color;
    vert_main();
    SPIRV_Cross_Output stage_output;
    stage_output.gl_Position = gl_Position;
    stage_output.out_color = out_color;
    return stage_output;
}
