struct ParticleInput {
    float4 color : TEXCOORD0;
};

float4 main(ParticleInput input) : SV_Target0 {
    return input.color;
}
