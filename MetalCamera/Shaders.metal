//
//  Shaders.metal
//  MetalCamera
//
//  Created by Maximilian Christ on 30/08/14.
//  Copyright (c) 2014 McZonk. All rights reserved.
//

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;


typedef struct {
    packed_float2 position;
    packed_float2 texcoord;
} Vertex;

typedef struct {
    float4 position [[position]];
    float2 texcoord;
} Varyings;

vertex Varyings vertexPassthrough(
	device Vertex* verticies [[ buffer(0) ]],
	unsigned int vid [[ vertex_id ]]
) {
    Varyings out;
	
	device Vertex& v = verticies[vid];
	
    out.position = float4(float2(v.position), 0.0, 1.0);
	
	out.texcoord = v.texcoord;
	
    return out;
}

fragment half4 fragmentColorConversion(
	Varyings in [[ stage_in ]]
) {
    return half4(half2(in.texcoord), 0.0, 1.0);
}
