struct ParticleVertex {
    float2 corner : TEXCOORD0;
    float2 center : TEXCOORD1;
    float2 extent : TEXCOORD2;
    float4 color : TEXCOORD3;
};

struct ParticleOutput {
    float4 position : SV_Position;
    float4 color : TEXCOORD0;
};

ParticleOutput main(ParticleVertex input) {
    ParticleOutput output;
    output.position = float4(input.center + input.corner * input.extent, 0.0f, 1.0f);
    output.color = input.color;
    return output;
}
