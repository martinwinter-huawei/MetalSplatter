#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

constant const int kMaxViewCount = 2;
constant static const half kBoundsRadius = 3;
constant static const half kBoundsRadiusSquared = kBoundsRadius * kBoundsRadius;

// Polynomial kernel coefficients (torch_linear approximation of the Gaussian)
constant static const float kPolyA = 3.5245553e-01f;
constant static const float kPolyB = 7.7293956e-01f;
// The smallest per-alpha-weighted contribution we care to render (1/255)
constant static const float kTightThreshold = 1.0f / 255.0f;

// When true, the per-splat bounding quad is shrunk to the area where the
// polynomial kernel contribution exceeds kTightThreshold. This reduces the
// number of fragments shaded for bright, opaque splats.
constant bool useTightestCulling [[function_constant(0)]];

// When true, the fragment alpha uses the fast polynomial (torch_linear)
// approximation of the Gaussian kernel instead of the exact exp() function.
// Mirrors the polynomial activation mode in vk_gaussian_splatting-polynomial.
constant bool usePolynomial [[function_constant(1)]];

enum BufferIndex : int32_t {
  BufferIndexUniforms = 0,
  BufferIndexSplat = 1,
  BufferIndexSplatIndex = 2,
};

typedef struct {
  matrix_float4x4 projectionMatrix;
  matrix_float4x4 viewMatrix;
  uint2 screenSize;

  /*
   The first N splats are represented as as 2N primitives and 4N vertex indices.
   The remained are represented as instanced of these first N. This allows us to
   limit the size of the indexed array (and associated memory), but also avoid
   the performance penalty of a very large number of instances.
   */
  uint splatCount;
  uint indexedSplatCount;
} Uniforms;

typedef struct {
  Uniforms uniforms[kMaxViewCount];
} UniformsArray;

typedef struct {
  packed_float3 position;
  packed_half4 color;
  packed_half3 covA;
  packed_half3 covB;
} Splat;

typedef uint SplatIndex;

typedef struct {
  float4 position [[position]];
  half2 relativePosition; // Ranges from -kBoundsRadius to +kBoundsRadius
  half4 color;
} FragmentIn;
