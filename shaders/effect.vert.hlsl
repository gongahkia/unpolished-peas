static const float2 _25[6] = { float2(-1.0f, 1.0f), 1.0f.xx, float2(1.0f, -1.0f), float2(-1.0f, 1.0f), float2(1.0f, -1.0f), (-1.0f).xx };
static const float2 _45[6] = { 0.0f.xx, float2(1.0f, 0.0f), 1.0f.xx, 0.0f.xx, 1.0f.xx, float2(0.0f, 1.0f) };

static float4 gl_Position;
static int gl_VertexIndex;
static float2 out_uv;

struct SPIRV_Cross_Input
{
    uint gl_VertexIndex : SV_VertexID;
};

struct SPIRV_Cross_Output
{
    float2 out_uv : TEXCOORD0;
    float4 gl_Position : SV_Position;
};

void vert_main()
{
    gl_Position = float4(_25[gl_VertexIndex], 0.0f, 1.0f);
    out_uv = _45[gl_VertexIndex];
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    gl_VertexIndex = int(stage_input.gl_VertexIndex);
    vert_main();
    SPIRV_Cross_Output stage_output;
    stage_output.gl_Position = gl_Position;
    stage_output.out_uv = out_uv;
    return stage_output;
}
