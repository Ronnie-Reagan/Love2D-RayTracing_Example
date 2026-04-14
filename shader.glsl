extern vec2 iResolution;
extern vec3 camPos;
extern float yaw;
extern float pitch;
extern float camFov;
extern int iFrame;
extern int uPassType;
uniform Image tex;

extern int uMaxBounces;
extern int uMaxSteps;
extern int uEnableShadows;
extern int uEnableReflections;
extern int uSceneVariant;
extern int uTracingMode;
extern int uMeshTriCount;
extern int uImportedObjectCount;
extern int uImportedMeshCount;
extern int uImportedBvhNodeCount;
extern vec2 uMeshTexSize;
extern vec2 uObjectNodeTexSize;
extern vec2 uMeshNodeTexSize;
extern vec2 uImportedBvhTexSize;
uniform Image meshVerts;
uniform Image meshNormals;
uniform Image meshMatA;
uniform Image meshMatB;
uniform Image meshMatC;
uniform Image meshMatD;
uniform Image objectNodeA;
uniform Image objectNodeB;
uniform Image meshNodeA;
uniform Image meshNodeB;
uniform Image meshNodeC;
uniform Image importedBvhNodeA;
uniform Image importedBvhNodeB;
uniform Image importedBvhNodeC;

const int HARD_MAX_IMPORTED_OBJECTS = 4096;
const int HARD_MAX_IMPORTED_MESHES = 16384;
const int HARD_MAX_MESH_TRIS = 81920;
const int HARD_MAX_IMPORTED_BVH_STEPS = 2048;
const int HARD_MAX_IMPORTED_BVH_STACK = 64;
const int HARD_MAX_IMPORTED_BVH_LEAF_TRIS = 16;
const int IMPORTED_MAT_ID = 1000;

vec4 gImportedMatA = vec4(0.8, 0.8, 0.8, 1.0);
vec4 gImportedMatB = vec4(0.0, 0.0, 0.0, 0.0);
vec4 gImportedMatC = vec4(1.0, 1.0, 1.0, 0.0);
vec4 gImportedMatD = vec4(1.45, 0.0, 0.2, 0.5);

const float PI = 3.1415926535;
const float TWO_PI = 6.28318530718;
const float INV_PI = 0.31830988618;
const float INV_TWO_PI = 0.15915494309;
const int HARD_MAX_STEPS = 999 * 999;
const int HARD_MAX_BOUNCES = 999 * 999;
const int lightCount = 3;

const float HIT_EPS = 0.0015;
const float NORMAL_EPS = 0.0025;
const float RAY_BIAS = 0.02;
const float SHADOW_BIAS = 0.02;
const float SHADOW_MIN_STEP = 0.01;
const float MARCH_MIN_STEP = 0.001;
const float MAX_TRACE_DIST = 6000.0;
const float LIGHT_RADIUS = 0.16;
const float RADIANCE_CACHE_HISTORY = 128.0;
const float LAMBDA_MIN = 400.0;
const float LAMBDA_MAX = 700.0;
const int RADIANCE_CACHE_SPP = 2;
const float REPROJECT_NORMAL_DOT_MIN = 0.965;
const float CIE_Y_INTEGRAL = 106.856895;
const int MAX_SPECTRAL_LANES = 12;
const int COHERENT_FIELD_SPP = 2;
const float SCENE_PHASE_SCALE = 3200.0;
const float CLEARCOAT_FILM_MIN_NM = 60.0;
const float CLEARCOAT_FILM_MAX_NM = 720.0;
const float SPECTRAL_LIGHT_RADIANCE_SCALE = 3.25;
const float PATH_MODE_DISPLAY_EXPOSURE = 2.5;

struct Hit {
    float dist;
    int mat;
};

struct Material {
    vec3 albedo;
    vec3 emission;
    vec3 transmissionColor;
    float metallic;
    float roughness;
    float transmission;
    float ior;
    float clearcoat;
    float clearcoatRoughness;
    float specular;
};

vec3 saturate(vec3 v) {
    return clamp(v, vec3(0.0), vec3(1.0));
}

float saturate1(float v) {
    return clamp(v, 0.0, 1.0);
}

float safeRcp(float v) {
    if (abs(v) < 0.0000001) {
        return (v >= 0.0) ? 1e20 : -1e20;
    }
    return 1.0 / v;
}

int decodeIndex(float v) {
    return int(floor(v + 0.5));
}

int maxInt(int a, int b) {
    return (a > b) ? a : b;
}

float cameraFocalLength(float fov) {
    float clampedFov = clamp(fov, 0.25, PI - 0.25);
    return 1.0 / tan(clampedFov * 0.5);
}

void getCameraBasisForAngles(float yawValue, float pitchValue, out vec3 forward, out vec3 right, out vec3 up) {
    float cp = cos(pitchValue);
    float sp = sin(pitchValue);
    float cy = cos(yawValue);
    float sy = sin(yawValue);

    forward = normalize(vec3(cp * sy, sp, cp * cy));
    right = cross(vec3(0.0, 1.0, 0.0), forward);

    if (dot(right, right) < 0.000001) {
        right = vec3(1.0, 0.0, 0.0);
    } else {
        right = normalize(right);
    }

    up = normalize(cross(forward, right));
}

vec3 getRayForCamera(vec2 fragCoord, float yawValue, float pitchValue, float fovValue) {
    vec2 uv = (fragCoord - 0.5 * iResolution) / iResolution.y;
    vec3 forward, right, up;
    getCameraBasisForAngles(yawValue, pitchValue, forward, right, up);
    float focal = cameraFocalLength(fovValue);
    return normalize(forward * focal + uv.x * right - uv.y * up);
}

vec3 getRay(vec2 fragCoord) {
    return getRayForCamera(fragCoord, yaw, pitch, camFov);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec2 hash22(vec2 p) {
    return vec2(
        hash21(p + vec2(17.13, 91.7)),
        hash21(p + vec2(41.71, 28.3))
    );
}

float gaussian(float x, float mean, float sigma) {
    float d = (x - mean) / max(sigma, 0.0001);
    return exp(-0.5 * d * d);
}

float min3v(vec3 v) {
    return min(v.r, min(v.g, v.b));
}

float cieXBar(float lambda) {
    float t1 = (lambda - 442.0) * ((lambda < 442.0) ? 0.0624 : 0.0374);
    float t2 = (lambda - 599.8) * ((lambda < 599.8) ? 0.0264 : 0.0323);
    float t3 = (lambda - 501.1) * ((lambda < 501.1) ? 0.0490 : 0.0382);
    return 0.362 * exp(-0.5 * t1 * t1) + 1.056 * exp(-0.5 * t2 * t2) - 0.065 * exp(-0.5 * t3 * t3);
}

float cieYBar(float lambda) {
    float t1 = (lambda - 568.8) * ((lambda < 568.8) ? 0.0213 : 0.0247);
    float t2 = (lambda - 530.9) * ((lambda < 530.9) ? 0.0613 : 0.0322);
    return 0.821 * exp(-0.5 * t1 * t1) + 0.286 * exp(-0.5 * t2 * t2);
}

float cieZBar(float lambda) {
    float t1 = (lambda - 437.0) * ((lambda < 437.0) ? 0.0845 : 0.0278);
    float t2 = (lambda - 459.0) * ((lambda < 459.0) ? 0.0385 : 0.0725);
    return 1.217 * exp(-0.5 * t1 * t1) + 0.681 * exp(-0.5 * t2 * t2);
}

vec3 spectrumXYZWeight(float lambda) {
    return vec3(cieXBar(lambda), cieYBar(lambda), cieZBar(lambda));
}

vec3 xyzToLinearSRGB(vec3 xyz) {
    mat3 xyzToRgb = mat3(
         3.2406, -0.9689,  0.0557,
        -1.5372,  1.8758, -0.2040,
        -0.4986,  0.0415,  1.0570
    );
    return max(xyzToRgb * xyz, vec3(0.0));
}

vec3 spectrumContributionToRGB(float lambda, float value) {
    float lambdaScale = (LAMBDA_MAX - LAMBDA_MIN) / CIE_Y_INTEGRAL;
    return xyzToLinearSRGB(spectrumXYZWeight(lambda) * value * lambdaScale);
}

float spectralBasisWhite(float lambda) {
    return 0.72 + 0.18 * gaussian(lambda, 545.0, 135.0) + 0.14 * gaussian(lambda, 460.0, 115.0);
}

float spectralBasisRed(float lambda) {
    return 1.08 * gaussian(lambda, 611.0, 34.0) + 0.42 * gaussian(lambda, 676.0, 58.0);
}

float spectralBasisGreen(float lambda) {
    return 1.04 * gaussian(lambda, 545.0, 28.0) + 0.16 * gaussian(lambda, 505.0, 46.0);
}

float spectralBasisBlue(float lambda) {
    return 1.16 * gaussian(lambda, 452.0, 20.0) + 0.24 * gaussian(lambda, 492.0, 36.0);
}

float spectralBasisYellow(float lambda) {
    return 0.95 * gaussian(lambda, 578.0, 42.0) + 0.32 * gaussian(lambda, 532.0, 58.0);
}

float spectralBasisCyan(float lambda) {
    return 0.74 * gaussian(lambda, 495.0, 34.0) + 0.66 * gaussian(lambda, 535.0, 44.0);
}

float spectralBasisMagenta(float lambda) {
    return 0.58 * gaussian(lambda, 611.0, 39.0) + 0.60 * gaussian(lambda, 449.0, 24.0);
}

float rgbToSpectrumPositive(vec3 rgb, float lambda) {
    rgb = saturate(rgb);
    float w = min3v(rgb);
    rgb -= vec3(w);

    float c = min(rgb.g, rgb.b);
    rgb.g -= c;
    rgb.b -= c;

    float m = min(rgb.r, rgb.b);
    rgb.r -= m;
    rgb.b -= m;

    float y = min(rgb.r, rgb.g);
    rgb.r -= y;
    rgb.g -= y;

    return max(
        w * spectralBasisWhite(lambda)
        + c * spectralBasisCyan(lambda)
        + m * spectralBasisMagenta(lambda)
        + y * spectralBasisYellow(lambda)
        + rgb.r * spectralBasisRed(lambda)
        + rgb.g * spectralBasisGreen(lambda)
        + rgb.b * spectralBasisBlue(lambda),
        0.0
    );
}

float blackbodyNormalized(float lambda, float temperatureK) {
    float temp = max(temperatureK, 1000.0);
    float c2 = 14387769.0;
    float refExponent = exp(clamp(c2 / (560.0 * temp), 0.0, 80.0)) - 1.0;
    float lambdaExponent = exp(clamp(c2 / (max(lambda, 1.0) * temp), 0.0, 80.0)) - 1.0;
    return pow(560.0 / max(lambda, 1.0), 5.0) * refExponent / max(lambdaExponent, 0.000001);
}

vec3 cosineSampleHemisphere(vec3 n, vec2 r) {
    float phi = 2.0 * PI * r.x;
    float r2 = sqrt(r.y);
    vec3 local = vec3(r2 * cos(phi), r2 * sin(phi), sqrt(max(0.0, 1.0 - r.y)));

    vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    vec3 t = normalize(cross(up, n));
    vec3 b = cross(n, t);

    return normalize(local.x * t + local.y * b + local.z * n);
}

vec3 sampleAroundDirection(vec3 dir, vec3 n, vec2 r, float roughness) {
    vec3 hemi = cosineSampleHemisphere(dir, r);
    vec3 blended = normalize(mix(dir, hemi, clamp(roughness * roughness, 0.0, 1.0)));
    if (dot(blended, n) < 0.0) {
        blended = normalize(reflect(-blended, n));
    }
    return blended;
}

float sdSphere(vec3 p, float r) {
    return length(p) - r;
}

float sdBox(vec3 p, vec3 b) {
    vec3 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

float sdRoundedBox(vec3 p, vec3 b, float r) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

float sdCappedCylinderZ(vec3 p, float halfHeight, float radius) {
    vec2 d = abs(vec2(length(p.xy), p.z)) - vec2(radius, halfHeight);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

Hit opUnion(Hit a, Hit b) {
    return (a.dist < b.dist) ? a : b;
}

vec2 getMeshVertexUV(int col, int row) {
    int triColumns = maxInt(decodeIndex(uMeshTexSize.x), 1);
    int triY = row / triColumns;
    int triX = row - triY * triColumns;
    float texWidth = float(triColumns * 3);
    float texHeight = max(uMeshTexSize.y, 1.0);
    return vec2((float(triX * 3 + col) + 0.5) / texWidth, (float(triY) + 0.5) / texHeight);
}

vec2 getMeshMaterialUV(int row) {
    vec2 texSize = max(uMeshTexSize, vec2(1.0));
    int triColumns = maxInt(decodeIndex(texSize.x), 1);
    int triY = row / triColumns;
    int triX = row - triY * triColumns;
    return vec2((float(triX) + 0.5) / texSize.x, (float(triY) + 0.5) / texSize.y);
}

vec2 getNodeUV(int row, vec2 texSize) {
    texSize = max(texSize, vec2(1.0));
    int columns = maxInt(decodeIndex(texSize.x), 1);
    int y = row / columns;
    int x = row - y * columns;
    return vec2((float(x) + 0.5) / texSize.x, (float(y) + 0.5) / texSize.y);
}

vec4 readMeshPosTexel(int col, int row) {
    return Texel(meshVerts, getMeshVertexUV(col, row));
}

vec4 readMeshNormalTexel(int col, int row) {
    return Texel(meshNormals, getMeshVertexUV(col, row));
}

vec4 readMeshMaterialATexel(int row) {
    return Texel(meshMatA, getMeshMaterialUV(row));
}

vec4 readMeshMaterialBTexel(int row) {
    return Texel(meshMatB, getMeshMaterialUV(row));
}

vec4 readMeshMaterialCTexel(int row) {
    return Texel(meshMatC, getMeshMaterialUV(row));
}

vec4 readMeshMaterialDTexel(int row) {
    return Texel(meshMatD, getMeshMaterialUV(row));
}

vec4 readObjectNodeATexel(int row) {
    return Texel(objectNodeA, getNodeUV(row, uObjectNodeTexSize));
}

vec4 readObjectNodeBTexel(int row) {
    return Texel(objectNodeB, getNodeUV(row, uObjectNodeTexSize));
}

vec4 readMeshNodeATexel(int row) {
    return Texel(meshNodeA, getNodeUV(row, uMeshNodeTexSize));
}

vec4 readMeshNodeBTexel(int row) {
    return Texel(meshNodeB, getNodeUV(row, uMeshNodeTexSize));
}

vec4 readMeshNodeCTexel(int row) {
    return Texel(meshNodeC, getNodeUV(row, uMeshNodeTexSize));
}

vec4 readImportedBvhNodeATexel(int row) {
    return Texel(importedBvhNodeA, getNodeUV(row, uImportedBvhTexSize));
}

vec4 readImportedBvhNodeBTexel(int row) {
    return Texel(importedBvhNodeB, getNodeUV(row, uImportedBvhTexSize));
}

vec4 readImportedBvhNodeCTexel(int row) {
    return Texel(importedBvhNodeC, getNodeUV(row, uImportedBvhTexSize));
}

Material getMaterial(int mat) {
    Material m;
    m.albedo = vec3(0.8);
    m.emission = vec3(0.0);
    m.transmissionColor = vec3(1.0);
    m.metallic = 0.0;
    m.roughness = 1.0;
    m.transmission = 0.0;
    m.ior = 1.45;
    m.clearcoat = 0.0;
    m.clearcoatRoughness = 0.2;
    m.specular = 0.5;

    if (mat == IMPORTED_MAT_ID) {
        m.albedo = saturate(gImportedMatA.rgb);
        m.emission = max(gImportedMatB.rgb, vec3(0.0));
        m.transmissionColor = saturate(gImportedMatC.rgb);
        m.metallic = clamp(gImportedMatB.a, 0.0, 1.0);
        m.roughness = clamp(gImportedMatA.a, 0.02, 1.0);
        m.transmission = clamp(gImportedMatC.a, 0.0, 1.0);
        m.ior = max(gImportedMatD.r, 1.0);
        m.clearcoat = clamp(gImportedMatD.g, 0.0, 1.0);
        m.clearcoatRoughness = clamp(gImportedMatD.b, 0.02, 1.0);
        m.specular = clamp(gImportedMatD.a, 0.0, 1.0);
        return m;
    }

    if (mat == 0) {
        m.albedo = vec3(0.78, 0.76, 0.72);
        m.roughness = 0.92;
    } else if (mat == 1) {
        m.albedo = vec3(0.95, 0.22, 0.18);
        m.roughness = 0.95;
    } else if (mat == 2) {
        m.albedo = vec3(0.18, 0.45, 1.0);
        m.roughness = 0.95;
    } else if (mat == 3) {
        m.albedo = vec3(0.98);
        m.metallic = 1.0;
        m.roughness = 0.04;
    } else if (mat == 4) {
        m.albedo = vec3(0.95, 0.78, 0.18);
        m.metallic = 1.0;
        m.roughness = 0.18;
    } else if (mat == 5) {
        m.albedo = vec3(0.35, 1.0, 0.55);
        m.emission = vec3(0.8, 2.0, 1.0);
        m.roughness = 1.0;
    } else if (mat == 6) {
        m.albedo = vec3(1.0, 0.3, 0.35);
        m.emission = vec3(2.2, 0.4, 0.4);
        m.roughness = 1.0;
    } else if (mat == 7) {
        m.albedo = vec3(0.2, 0.55, 1.0);
        m.emission = vec3(0.4, 0.9, 2.2);
        m.roughness = 1.0;
    } else if (mat == 8) {
        m.albedo = vec3(0.07, 0.075, 0.08);
        m.roughness = 0.82;
    } else if (mat == 9) {
        m.albedo = vec3(0.96, 0.975, 1.0);
        m.transmissionColor = vec3(0.96, 0.985, 1.0);
        m.transmission = 0.97;
        m.ior = 1.52;
        m.specular = 0.8;
        m.roughness = 0.015;
    } else if (mat == 10) {
        m.albedo = vec3(0.22, 0.23, 0.25);
        m.metallic = 1.0;
        m.roughness = 0.18;
    } else if (mat == 11) {
        m.albedo = vec3(1.0, 0.2, 0.15);
        m.emission = vec3(4.0, 0.5, 0.3);
        m.roughness = 0.35;
    } else if (mat == 12) {
        m.albedo = vec3(0.985, 0.99, 1.0);
        m.metallic = 1.0;
        m.roughness = 0.002;
    } else if (mat == 13) {
        m.albedo = vec3(0.14, 0.145, 0.16);
        m.metallic = 1.0;
        m.roughness = 0.08;
    }

    return m;
}

vec3 getLightPos(int i) {
    if (uSceneVariant == 3) {
        if (i == 0) return vec3(-2.8, 3.8, -2.0);
        if (i == 1) return vec3(0.0, 4.2, -5.0);
        return vec3(2.8, 3.8, -2.0);
    }

    if (uSceneVariant == 2) {
        if (i == 0) return vec3(-10.5, 6.0, -8.0);
        if (i == 1) return vec3(0.0, 6.8, -17.0);
        return vec3(10.5, 6.0, -8.0);
    }

    if (uSceneVariant == 1) {
        if (i == 0) return vec3(-2.4, 2.0, -2.2);
        if (i == 1) return vec3(0.0, 2.7, -5.3);
        return vec3(2.4, 2.0, -2.2);
    }

    if (i == 0) return vec3(-1.8, 2.0, -2.2);
    if (i == 1) return vec3(0.0, 2.4, -4.4);
    return vec3(1.8, 2.0, -2.2);
}

vec3 getLightColor(int i) {
    if (uSceneVariant == 3) {
        if (i == 0) return vec3(7.0, 6.0, 5.0);
        if (i == 1) return vec3(9.0, 9.0, 9.0);
        return vec3(5.0, 6.0, 7.0);
    }

    if (uSceneVariant == 2) {
        if (i == 0) return vec3(22.0, 18.0, 16.0);
        if (i == 1) return vec3(28.0, 28.0, 28.0);
        return vec3(16.0, 18.0, 22.0);
    }

    if (uSceneVariant == 1) {
        if (i == 0) return vec3(8.0, 2.0, 2.0);
        if (i == 1) return vec3(6.5, 6.5, 6.5);
        return vec3(2.0, 2.0, 8.0);
    }

    if (i == 0) return vec3(6.0, 1.4, 1.4);
    if (i == 1) return vec3(5.5, 5.5, 5.5);
    return vec3(1.4, 1.4, 6.0);
}

void getCameraBasis(out vec3 forward, out vec3 right, out vec3 up) {
    getCameraBasisForAngles(yaw, pitch, forward, right, up);
}

vec3 toCameraLocal(vec3 p, vec3 cameraPosition, float yawValue, float pitchValue) {
    vec3 forward, right, up;
    getCameraBasisForAngles(yawValue, pitchValue, forward, right, up);

    vec3 d = p - cameraPosition;
    return vec3(dot(d, right), dot(d, up), dot(d, forward));
}

bool projectToScreenUV(vec3 p, vec3 cameraPosition, float yawValue, float pitchValue, float fovValue, out vec2 uv) {
    vec3 local = toCameraLocal(p, cameraPosition, yawValue, pitchValue);
    if (local.z <= RAY_BIAS) {
        uv = vec2(-1.0);
        return false;
    }

    float focal = cameraFocalLength(fovValue);
    vec2 film = vec2((local.x * focal) / local.z, -(local.y * focal) / local.z);
    vec2 fragCoord = film * iResolution.y + 0.5 * iResolution;
    uv = fragCoord / iResolution;

    vec2 edgePad = vec2(1.5) / max(iResolution, vec2(1.0));
    return all(greaterThanEqual(uv, edgePad)) && all(lessThanEqual(uv, vec2(1.0) - edgePad));
}

vec3 toViewCameraLocal(vec3 p) {
    return toCameraLocal(p, camPos, yaw, pitch);
}

bool intersectTriangle(
    vec3 ro,
    vec3 rd,
    vec3 v0,
    vec3 v1,
    vec3 v2,
    out float t,
    out vec3 bary,
    out vec3 faceNormal
) {
    vec3 e1 = v1 - v0;
    vec3 e2 = v2 - v0;
    vec3 pvec = cross(rd, e2);
    float det = dot(e1, pvec);

    if (abs(det) < 0.000001) {
        t = 0.0;
        bary = vec3(0.0);
        faceNormal = vec3(0.0, 1.0, 0.0);
        return false;
    }

    float invDet = 1.0 / det;
    vec3 tvec = ro - v0;
    float u = dot(tvec, pvec) * invDet;
    if (u < 0.0 || u > 1.0) {
        t = 0.0;
        bary = vec3(0.0);
        faceNormal = vec3(0.0, 1.0, 0.0);
        return false;
    }

    vec3 qvec = cross(tvec, e1);
    float v = dot(rd, qvec) * invDet;
    if (v < 0.0 || (u + v) > 1.0) {
        t = 0.0;
        bary = vec3(0.0);
        faceNormal = vec3(0.0, 1.0, 0.0);
        return false;
    }

    t = dot(e2, qvec) * invDet;
    if (t <= HIT_EPS) {
        bary = vec3(0.0);
        faceNormal = vec3(0.0, 1.0, 0.0);
        return false;
    }

    bary = vec3(1.0 - u - v, u, v);
    faceNormal = normalize(cross(e1, e2));
    return true;
}

bool intersectAABB(vec3 ro, vec3 rd, vec3 bmin, vec3 bmax, float maxLimit, out float tEnter, out float tExit) {
    vec3 invRd = vec3(safeRcp(rd.x), safeRcp(rd.y), safeRcp(rd.z));
    vec3 t0 = (bmin - ro) * invRd;
    vec3 t1 = (bmax - ro) * invRd;
    vec3 tMin = min(t0, t1);
    vec3 tMax = max(t0, t1);

    tEnter = max(max(tMin.x, tMin.y), max(tMin.z, 0.0));
    tExit = min(min(tMax.x, tMax.y), min(tMax.z, maxLimit));
    return tExit >= tEnter;
}

Hit traceImportedMeshLinear(vec3 ro, vec3 rd, out vec3 pos, out vec3 normal) {
    float bestT = 1e20;
    int bestMat = -1;
    vec3 bestNormal = vec3(0.0);
    vec4 bestMatA = vec4(0.8, 0.8, 0.8, 1.0);
    vec4 bestMatB = vec4(0.0);
    vec4 bestMatC = vec4(1.0, 1.0, 1.0, 0.0);
    vec4 bestMatD = vec4(1.45, 0.0, 0.2, 0.5);

    for (int objectIndex = 0; objectIndex < HARD_MAX_IMPORTED_OBJECTS; ++objectIndex) {
        if (objectIndex >= uImportedObjectCount) break;

        vec4 objectA = readObjectNodeATexel(objectIndex);
        vec4 objectB = readObjectNodeBTexel(objectIndex);
        float objectEnter, objectExit;
        if (!intersectAABB(ro, rd, objectA.xyz, objectB.xyz, bestT, objectEnter, objectExit)) continue;

        int meshStart = decodeIndex(objectA.a);
        int meshCount = maxInt(decodeIndex(objectB.a), 0);

        for (int localMesh = 0; localMesh < HARD_MAX_IMPORTED_MESHES; ++localMesh) {
            if (localMesh >= meshCount) break;

            int meshIndex = meshStart + localMesh;
            if (meshIndex >= uImportedMeshCount) break;

            vec4 meshA = readMeshNodeATexel(meshIndex);
            vec4 meshB = readMeshNodeBTexel(meshIndex);
            vec4 meshC = readMeshNodeCTexel(meshIndex);
            if (decodeIndex(meshC.x) != objectIndex) continue;

            float meshEnter, meshExit;
            if (!intersectAABB(ro, rd, meshA.xyz, meshB.xyz, bestT, meshEnter, meshExit)) continue;

            int triangleStart = decodeIndex(meshA.a);
            int triangleCount = maxInt(decodeIndex(meshB.a), 0);

            for (int localTri = 0; localTri < HARD_MAX_MESH_TRIS; ++localTri) {
                if (localTri >= triangleCount) break;

                int triangleIndex = triangleStart + localTri;
                if (triangleIndex >= uMeshTriCount) break;

                vec3 v0 = readMeshPosTexel(0, triangleIndex).xyz;
                vec3 v1 = readMeshPosTexel(1, triangleIndex).xyz;
                vec3 v2 = readMeshPosTexel(2, triangleIndex).xyz;
                vec3 n0 = readMeshNormalTexel(0, triangleIndex).xyz;
                vec3 n1 = readMeshNormalTexel(1, triangleIndex).xyz;
                vec3 n2 = readMeshNormalTexel(2, triangleIndex).xyz;

                float t;
                vec3 bary;
                vec3 faceNormal;

                if (intersectTriangle(ro, rd, v0, v1, v2, t, bary, faceNormal) && t < bestT) {
                    bestT = t;
                    vec3 interpNormal = normalize(n0 * bary.x + n1 * bary.y + n2 * bary.z);
                    if (length(interpNormal) < 0.0001) interpNormal = faceNormal;

                    bestNormal = interpNormal;
                    bestMatA = readMeshMaterialATexel(triangleIndex);
                    bestMatB = readMeshMaterialBTexel(triangleIndex);
                    bestMatC = readMeshMaterialCTexel(triangleIndex);
                    bestMatD = readMeshMaterialDTexel(triangleIndex);
                    bestMat = IMPORTED_MAT_ID;
                }
            }
        }
    }

    if (bestMat >= 0) {
        gImportedMatA = bestMatA;
        gImportedMatB = bestMatB;
        gImportedMatC = bestMatC;
        gImportedMatD = bestMatD;
        pos = ro + rd * bestT;
        normal = bestNormal;
        return Hit(bestT, bestMat);
    }

    pos = ro + rd * MAX_TRACE_DIST;
    normal = vec3(0.0);
    return Hit(1e5, -1);
}

float shadowTraceImportedMeshLinear(vec3 ro, vec3 rd, float maxDist) {
    for (int objectIndex = 0; objectIndex < HARD_MAX_IMPORTED_OBJECTS; ++objectIndex) {
        if (objectIndex >= uImportedObjectCount) break;

        vec4 objectA = readObjectNodeATexel(objectIndex);
        vec4 objectB = readObjectNodeBTexel(objectIndex);
        float objectEnter, objectExit;
        if (!intersectAABB(ro, rd, objectA.xyz, objectB.xyz, maxDist, objectEnter, objectExit)) continue;

        int meshStart = decodeIndex(objectA.a);
        int meshCount = maxInt(decodeIndex(objectB.a), 0);

        for (int localMesh = 0; localMesh < HARD_MAX_IMPORTED_MESHES; ++localMesh) {
            if (localMesh >= meshCount) break;

            int meshIndex = meshStart + localMesh;
            if (meshIndex >= uImportedMeshCount) break;

            vec4 meshA = readMeshNodeATexel(meshIndex);
            vec4 meshB = readMeshNodeBTexel(meshIndex);
            vec4 meshC = readMeshNodeCTexel(meshIndex);
            if (decodeIndex(meshC.x) != objectIndex) continue;

            float meshEnter, meshExit;
            if (!intersectAABB(ro, rd, meshA.xyz, meshB.xyz, maxDist, meshEnter, meshExit)) continue;

            int triangleStart = decodeIndex(meshA.a);
            int triangleCount = maxInt(decodeIndex(meshB.a), 0);

            for (int localTri = 0; localTri < HARD_MAX_MESH_TRIS; ++localTri) {
                if (localTri >= triangleCount) break;

                int triangleIndex = triangleStart + localTri;
                if (triangleIndex >= uMeshTriCount) break;

                vec3 v0 = readMeshPosTexel(0, triangleIndex).xyz;
                vec3 v1 = readMeshPosTexel(1, triangleIndex).xyz;
                vec3 v2 = readMeshPosTexel(2, triangleIndex).xyz;

                float t;
                vec3 bary;
                vec3 faceNormal;
                if (intersectTriangle(ro, rd, v0, v1, v2, t, bary, faceNormal) && t < maxDist) {
                    return 0.0;
                }
            }
        }
    }

    return 1.0;
}

Hit traceImportedMesh(vec3 ro, vec3 rd, out vec3 pos, out vec3 normal) {
    if (uImportedBvhNodeCount <= 0) {
        return traceImportedMeshLinear(ro, rd, pos, normal);
    }

    float bestT = 1e20;
    int bestMat = -1;
    vec3 bestNormal = vec3(0.0, 1.0, 0.0);
    vec4 bestMatA = vec4(0.8, 0.8, 0.8, 1.0);
    vec4 bestMatB = vec4(0.0);
    vec4 bestMatC = vec4(1.0, 1.0, 1.0, 0.0);
    vec4 bestMatD = vec4(1.45, 0.0, 0.2, 0.5);

    int stack[HARD_MAX_IMPORTED_BVH_STACK];
    int stackSize = 1;
    stack[0] = 0;

    for (int step = 0; step < HARD_MAX_IMPORTED_BVH_STEPS; ++step) {
        if (stackSize <= 0) break;

        int nodeIndex = stack[stackSize - 1];
        stackSize -= 1;
        if (nodeIndex < 0 || nodeIndex >= uImportedBvhNodeCount) continue;

        vec4 nodeA = readImportedBvhNodeATexel(nodeIndex);
        vec4 nodeB = readImportedBvhNodeBTexel(nodeIndex);
        vec4 nodeC = readImportedBvhNodeCTexel(nodeIndex);

        float nodeEnter, nodeExit;
        if (!intersectAABB(ro, rd, nodeA.xyz, nodeB.xyz, bestT, nodeEnter, nodeExit)) continue;

        bool isLeaf = nodeC.x > 0.5;
        if (isLeaf) {
            int triangleStart = decodeIndex(nodeA.a);
            int triangleCount = maxInt(decodeIndex(nodeB.a), 0);

            for (int localTri = 0; localTri < HARD_MAX_IMPORTED_BVH_LEAF_TRIS; ++localTri) {
                if (localTri >= triangleCount) break;

                int triangleIndex = triangleStart + localTri;
                if (triangleIndex < 0 || triangleIndex >= uMeshTriCount) break;

                vec3 v0 = readMeshPosTexel(0, triangleIndex).xyz;
                vec3 v1 = readMeshPosTexel(1, triangleIndex).xyz;
                vec3 v2 = readMeshPosTexel(2, triangleIndex).xyz;
                vec3 n0 = readMeshNormalTexel(0, triangleIndex).xyz;
                vec3 n1 = readMeshNormalTexel(1, triangleIndex).xyz;
                vec3 n2 = readMeshNormalTexel(2, triangleIndex).xyz;

                float t;
                vec3 bary;
                vec3 faceNormal;
                if (intersectTriangle(ro, rd, v0, v1, v2, t, bary, faceNormal) && t < bestT) {
                    bestT = t;
                    vec3 interpNormal = normalize(n0 * bary.x + n1 * bary.y + n2 * bary.z);
                    if (length(interpNormal) < 0.0001) interpNormal = faceNormal;

                    bestNormal = interpNormal;
                    bestMatA = readMeshMaterialATexel(triangleIndex);
                    bestMatB = readMeshMaterialBTexel(triangleIndex);
                    bestMatC = readMeshMaterialCTexel(triangleIndex);
                    bestMatD = readMeshMaterialDTexel(triangleIndex);
                    bestMat = IMPORTED_MAT_ID;
                }
            }
        } else {
            int leftIndex = decodeIndex(nodeA.a);
            int rightIndex = decodeIndex(nodeB.a);

            bool hitLeft = false;
            bool hitRight = false;
            float leftEnter = 0.0;
            float leftExit = 0.0;
            float rightEnter = 0.0;
            float rightExit = 0.0;

            if (leftIndex >= 0 && leftIndex < uImportedBvhNodeCount) {
                vec4 leftA = readImportedBvhNodeATexel(leftIndex);
                vec4 leftB = readImportedBvhNodeBTexel(leftIndex);
                hitLeft = intersectAABB(ro, rd, leftA.xyz, leftB.xyz, bestT, leftEnter, leftExit);
            }

            if (rightIndex >= 0 && rightIndex < uImportedBvhNodeCount) {
                vec4 rightA = readImportedBvhNodeATexel(rightIndex);
                vec4 rightB = readImportedBvhNodeBTexel(rightIndex);
                hitRight = intersectAABB(ro, rd, rightA.xyz, rightB.xyz, bestT, rightEnter, rightExit);
            }

            if (hitLeft && hitRight) {
                bool leftFirst = leftEnter <= rightEnter;
                int nearIndex = leftFirst ? leftIndex : rightIndex;
                int farIndex = leftFirst ? rightIndex : leftIndex;

                if (stackSize < HARD_MAX_IMPORTED_BVH_STACK) {
                    stack[stackSize] = farIndex;
                    stackSize += 1;
                }
                if (stackSize < HARD_MAX_IMPORTED_BVH_STACK) {
                    stack[stackSize] = nearIndex;
                    stackSize += 1;
                }
            } else if (hitLeft) {
                if (stackSize < HARD_MAX_IMPORTED_BVH_STACK) {
                    stack[stackSize] = leftIndex;
                    stackSize += 1;
                }
            } else if (hitRight) {
                if (stackSize < HARD_MAX_IMPORTED_BVH_STACK) {
                    stack[stackSize] = rightIndex;
                    stackSize += 1;
                }
            }
        }
    }

    if (bestMat >= 0) {
        gImportedMatA = bestMatA;
        gImportedMatB = bestMatB;
        gImportedMatC = bestMatC;
        gImportedMatD = bestMatD;
        pos = ro + rd * bestT;
        normal = bestNormal;
        return Hit(bestT, bestMat);
    }

    pos = ro + rd * MAX_TRACE_DIST;
    normal = vec3(0.0);
    return Hit(1e5, -1);
}

float shadowTraceImportedMesh(vec3 ro, vec3 rd, float maxDist) {
    if (uImportedBvhNodeCount <= 0) {
        return shadowTraceImportedMeshLinear(ro, rd, maxDist);
    }

    int stack[HARD_MAX_IMPORTED_BVH_STACK];
    int stackSize = 1;
    stack[0] = 0;

    for (int step = 0; step < HARD_MAX_IMPORTED_BVH_STEPS; ++step) {
        if (stackSize <= 0) break;

        int nodeIndex = stack[stackSize - 1];
        stackSize -= 1;
        if (nodeIndex < 0 || nodeIndex >= uImportedBvhNodeCount) continue;

        vec4 nodeA = readImportedBvhNodeATexel(nodeIndex);
        vec4 nodeB = readImportedBvhNodeBTexel(nodeIndex);
        vec4 nodeC = readImportedBvhNodeCTexel(nodeIndex);

        float nodeEnter, nodeExit;
        if (!intersectAABB(ro, rd, nodeA.xyz, nodeB.xyz, maxDist, nodeEnter, nodeExit)) continue;

        bool isLeaf = nodeC.x > 0.5;
        if (isLeaf) {
            int triangleStart = decodeIndex(nodeA.a);
            int triangleCount = maxInt(decodeIndex(nodeB.a), 0);

            for (int localTri = 0; localTri < HARD_MAX_IMPORTED_BVH_LEAF_TRIS; ++localTri) {
                if (localTri >= triangleCount) break;

                int triangleIndex = triangleStart + localTri;
                if (triangleIndex < 0 || triangleIndex >= uMeshTriCount) break;

                vec3 v0 = readMeshPosTexel(0, triangleIndex).xyz;
                vec3 v1 = readMeshPosTexel(1, triangleIndex).xyz;
                vec3 v2 = readMeshPosTexel(2, triangleIndex).xyz;

                float t;
                vec3 bary;
                vec3 faceNormal;
                if (intersectTriangle(ro, rd, v0, v1, v2, t, bary, faceNormal) && t < maxDist) {
                    return 0.0;
                }
            }
        } else {
            int leftIndex = decodeIndex(nodeA.a);
            int rightIndex = decodeIndex(nodeB.a);

            bool hitLeft = false;
            bool hitRight = false;
            float leftEnter = 0.0;
            float leftExit = 0.0;
            float rightEnter = 0.0;
            float rightExit = 0.0;

            if (leftIndex >= 0 && leftIndex < uImportedBvhNodeCount) {
                vec4 leftA = readImportedBvhNodeATexel(leftIndex);
                vec4 leftB = readImportedBvhNodeBTexel(leftIndex);
                hitLeft = intersectAABB(ro, rd, leftA.xyz, leftB.xyz, maxDist, leftEnter, leftExit);
            }

            if (rightIndex >= 0 && rightIndex < uImportedBvhNodeCount) {
                vec4 rightA = readImportedBvhNodeATexel(rightIndex);
                vec4 rightB = readImportedBvhNodeBTexel(rightIndex);
                hitRight = intersectAABB(ro, rd, rightA.xyz, rightB.xyz, maxDist, rightEnter, rightExit);
            }

            if (hitLeft && hitRight) {
                bool leftFirst = leftEnter <= rightEnter;
                int nearIndex = leftFirst ? leftIndex : rightIndex;
                int farIndex = leftFirst ? rightIndex : leftIndex;

                if (stackSize < HARD_MAX_IMPORTED_BVH_STACK) {
                    stack[stackSize] = farIndex;
                    stackSize += 1;
                }
                if (stackSize < HARD_MAX_IMPORTED_BVH_STACK) {
                    stack[stackSize] = nearIndex;
                    stackSize += 1;
                }
            } else if (hitLeft) {
                if (stackSize < HARD_MAX_IMPORTED_BVH_STACK) {
                    stack[stackSize] = leftIndex;
                    stackSize += 1;
                }
            } else if (hitRight) {
                if (stackSize < HARD_MAX_IMPORTED_BVH_STACK) {
                    stack[stackSize] = rightIndex;
                    stackSize += 1;
                }
            }
        }
    }

    return 1.0;
}

Hit mapReflectionCamera(vec3 p) {
    vec3 q = toViewCameraLocal(p);

    float body = sdRoundedBox(q - vec3(0.00, 0.00, -0.22), vec3(0.18, 0.12, 0.10), 0.03);
    float rearBody = sdRoundedBox(q - vec3(-0.10, 0.00, -0.29), vec3(0.08, 0.09, 0.05), 0.02);
    float sideGrip = sdRoundedBox(q - vec3(0.13, -0.01, -0.23), vec3(0.05, 0.08, 0.07), 0.02);
    float topHandle = sdRoundedBox(q - vec3(0.02, 0.13, -0.21), vec3(0.10, 0.025, 0.06), 0.015);

    float lensOuter = sdCappedCylinderZ(q - vec3(0.00, 0.00, 0.02), 0.11, 0.07);
    float lensInner = sdCappedCylinderZ(q - vec3(0.00, 0.00, 0.10), 0.05, 0.05);
    float lensGlass = sdCappedCylinderZ(q - vec3(0.00, 0.00, 0.145), 0.01, 0.045);

    float micPod = sdSphere(q - vec3(0.10, 0.11, -0.02), 0.025);
    float tallyLamp = sdSphere(q - vec3(-0.08, 0.05, 0.08), 0.012);

    Hit h = Hit(body, 8);
    h = opUnion(h, Hit(rearBody, 8));
    h = opUnion(h, Hit(sideGrip, 8));
    h = opUnion(h, Hit(topHandle, 8));
    h = opUnion(h, Hit(lensOuter, 10));
    h = opUnion(h, Hit(lensInner, 10));
    h = opUnion(h, Hit(lensGlass, 9));
    h = opUnion(h, Hit(micPod, 10));
    h = opUnion(h, Hit(tallyLamp, 11));

    return h;
}

Hit mapMirrorHall(vec3 p) {
    Hit h = Hit(1e5, -1);

    const vec3 roomCenter = vec3(0.0, 3.8, -16.0);
    const vec3 roomHalf = vec3(22.0, 4.0, 24.0);
    const float wallThickness = 0.18;

    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x, roomCenter.y - roomHalf.y - wallThickness, roomCenter.z), vec3(roomHalf.x, wallThickness, roomHalf.z)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x, roomCenter.y + roomHalf.y + wallThickness, roomCenter.z), vec3(roomHalf.x, wallThickness, roomHalf.z)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x - roomHalf.x - wallThickness, roomCenter.y, roomCenter.z), vec3(wallThickness, roomHalf.y, roomHalf.z)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x + roomHalf.x + wallThickness, roomCenter.y, roomCenter.z), vec3(wallThickness, roomHalf.y, roomHalf.z)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x, roomCenter.y, roomCenter.z - roomHalf.z - wallThickness), vec3(roomHalf.x, roomHalf.y, wallThickness)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x, roomCenter.y, roomCenter.z + roomHalf.z + wallThickness), vec3(roomHalf.x, roomHalf.y, wallThickness)), 0));

    h = opUnion(h, Hit(sdRoundedBox(p - vec3(0.0, 0.40, -16.0), vec3(2.8, 0.22, 20.0), 0.08), 13));

    const float panelHalfW = 1.6;
    const float panelHalfH = 1.05;
    const float panelHalfT = 0.035;
    const float frameInset = 0.14;
    const float mirrorInset = 0.06;

    for (int xi = 0; xi < 4; ++xi) {
        float x = -14.4 + float(xi) * 9.6;
        for (int yi = 0; yi < 4; ++yi) {
            float y = 1.0 + float(yi) * 1.9;

            vec3 leftFrameCenter = vec3(-21.72, y, x - 1.2);
            vec3 leftMirrorCenter = vec3(-21.55, y, x - 1.2);
            vec3 rightFrameCenter = vec3(21.72, y, x - 1.2);
            vec3 rightMirrorCenter = vec3(21.55, y, x - 1.2);

            h = opUnion(h, Hit(sdBox(p - leftFrameCenter, vec3(panelHalfT, panelHalfH + frameInset, panelHalfW + frameInset)), 13));
            h = opUnion(h, Hit(sdBox(p - leftMirrorCenter, vec3(panelHalfT, panelHalfH, panelHalfW)), 12));
            h = opUnion(h, Hit(sdBox(p - rightFrameCenter, vec3(panelHalfT, panelHalfH + frameInset, panelHalfW + frameInset)), 13));
            h = opUnion(h, Hit(sdBox(p - rightMirrorCenter, vec3(panelHalfT, panelHalfH, panelHalfW)), 12));
        }
    }

    for (int xi = 0; xi < 4; ++xi) {
        float x = -14.0 + float(xi) * 9.33;
        for (int yi = 0; yi < 2; ++yi) {
            float y = 1.6 + float(yi) * 3.0;
            vec3 backFrameCenter = vec3(x, y, -39.72);
            vec3 backMirrorCenter = vec3(x, y, -39.55);

            h = opUnion(h, Hit(sdBox(p - backFrameCenter, vec3(panelHalfW + frameInset, panelHalfH + 0.18, panelHalfT)), 13));
            h = opUnion(h, Hit(sdBox(p - backMirrorCenter, vec3(panelHalfW, panelHalfH + mirrorInset, panelHalfT)), 12));
        }
    }

    for (int i = 0; i < 3; ++i) {
        float z = -10.0 - float(i) * 8.0;
        h = opUnion(h, Hit(sdRoundedBox(p - vec3(-6.0, 1.7, z), vec3(0.22, 1.7, 2.8), 0.03), 12));
        h = opUnion(h, Hit(sdRoundedBox(p - vec3(6.0, 1.7, z - 2.0), vec3(0.22, 1.7, 2.8), 0.03), 12));
    }

    return h;
}

Hit map(vec3 p, int traceMode) {
    Hit h = Hit(1e5, -1);

    if (uSceneVariant == 0) {
        h = opUnion(h, Hit(sdBox(p - vec3(0.0, -0.15, -4.5), vec3(5.5, 0.15, 5.5)), 0));
        h = opUnion(h, Hit(sdBox(p - vec3(0.0, 4.15, -4.5), vec3(5.5, 0.15, 5.5)), 0));
        h = opUnion(h, Hit(sdBox(p - vec3(-5.35, 2.0, -4.5), vec3(0.15, 2.0, 5.5)), 1));
        h = opUnion(h, Hit(sdBox(p - vec3(5.35, 2.0, -4.5), vec3(0.15, 2.0, 5.5)), 2));
        h = opUnion(h, Hit(sdBox(p - vec3(0.0, 2.0, -9.85), vec3(5.5, 2.0, 0.15)), 4));
        h = opUnion(h, Hit(sdSphere(p - vec3(-1.6, 1.0, -3.4), 1.0), 3));
        h = opUnion(h, Hit(sdSphere(p - vec3(1.5, 0.8, -4.8), 0.8), 1));
        h = opUnion(h, Hit(sdBox(p - vec3(0.1, 0.75, -2.3), vec3(0.7, 0.7, 0.7)), 2));
        h = opUnion(h, Hit(sdBox(p - vec3(2.6, 0.65, -6.1), vec3(0.65, 0.65, 0.65)), 4));
    } else if (uSceneVariant == 1) {
        h = opUnion(h, Hit(sdBox(p - vec3(0.0, -0.15, -4.8), vec3(6.5, 0.15, 6.5)), 0));
        h = opUnion(h, Hit(sdBox(p - vec3(0.0, 4.75, -4.8), vec3(6.5, 0.15, 6.5)), 0));
        h = opUnion(h, Hit(sdBox(p - vec3(-6.35, 2.3, -4.8), vec3(0.15, 2.3, 6.5)), 1));
        h = opUnion(h, Hit(sdBox(p - vec3(6.35, 2.3, -4.8), vec3(0.15, 2.3, 6.5)), 1));
        h = opUnion(h, Hit(sdBox(p - vec3(0.0, 2.3, -11.15), vec3(6.5, 2.3, 0.15)), 2));
        h = opUnion(h, Hit(sdBox(p - vec3(-4.0, 1.1, -8.8), vec3(0.45, 1.1, 0.45)), 4));
        h = opUnion(h, Hit(sdBox(p - vec3(4.0, 1.1, -8.8), vec3(0.45, 1.1, 0.45)), 4));
        h = opUnion(h, Hit(sdSphere(p - vec3(-2.1, 1.1, -3.0), 1.1), 3));
        h = opUnion(h, Hit(sdSphere(p - vec3(0.2, 0.7, -3.2), 0.7), 4));
        h = opUnion(h, Hit(sdSphere(p - vec3(2.0, 0.9, -4.7), 0.9), 2));
        h = opUnion(h, Hit(sdBox(p - vec3(-0.8, 0.6, -5.5), vec3(0.6, 0.6, 0.6)), 1));
        h = opUnion(h, Hit(sdBox(p - vec3(2.8, 0.5, -2.6), vec3(0.5, 0.5, 0.5)), 0));
    } else if (uSceneVariant == 2) {
        h = opUnion(h, mapMirrorHall(p));
    }

    if (traceMode == 1) {
        h = opUnion(h, mapReflectionCamera(p));
    }

    return h;
}

vec3 estimateNormal(vec3 p, int traceMode) {
    return normalize(vec3(
        map(p + vec3(NORMAL_EPS, 0.0, 0.0), traceMode).dist - map(p - vec3(NORMAL_EPS, 0.0, 0.0), traceMode).dist,
        map(p + vec3(0.0, NORMAL_EPS, 0.0), traceMode).dist - map(p - vec3(0.0, NORMAL_EPS, 0.0), traceMode).dist,
        map(p + vec3(0.0, 0.0, NORMAL_EPS), traceMode).dist - map(p - vec3(0.0, 0.0, NORMAL_EPS), traceMode).dist
    ));
}

float shadowTrace(vec3 ro, vec3 rd, float maxDist) {
    if (uSceneVariant == 3) {
        return shadowTraceImportedMesh(ro, rd, maxDist);
    }

    float t = SHADOW_BIAS;
    for (int i = 0; i < HARD_MAX_STEPS; ++i) {
        if (i >= uMaxSteps) break;
        if (t >= maxDist) return 1.0;

        vec3 p = ro + rd * t;
        float d = map(p, 0).dist;
        if (d < HIT_EPS) return 0.0;
        t += max(d, SHADOW_MIN_STEP);
    }

    return 1.0;
}

Hit marchSDF(vec3 ro, vec3 rd, out vec3 pos, out vec3 normal, int traceMode) {
    float t = 0.0;

    for (int i = 0; i < HARD_MAX_STEPS; ++i) {
        if (i >= uMaxSteps) break;

        vec3 p = ro + rd * t;
        Hit h = map(p, traceMode);

        if (h.dist < HIT_EPS) {
            pos = p;
            normal = estimateNormal(p, traceMode);
            return h;
        }

        t += max(h.dist, MARCH_MIN_STEP);
        if (t > MAX_TRACE_DIST) break;
    }

    pos = ro + rd * t;
    normal = vec3(0.0);
    return Hit(1e5, -1);
}

Hit march(vec3 ro, vec3 rd, out vec3 pos, out vec3 normal, int traceMode) {
    if (uSceneVariant == 3) {
        vec3 meshPos, meshNormal;
        Hit meshHit = traceImportedMesh(ro, rd, meshPos, meshNormal);

        if (traceMode == 1) {
            vec3 camPosHit, camNormal;
            Hit camHit = marchSDF(ro, rd, camPosHit, camNormal, 1);

            if (camHit.mat >= 0 && camHit.dist < meshHit.dist) {
                pos = camPosHit;
                normal = camNormal;
                return camHit;
            }
        }

        pos = meshPos;
        normal = meshNormal;
        return meshHit;
    }

    return marchSDF(ro, rd, pos, normal, traceMode);
}

float surfacePositionTolerance(vec3 surfacePos, vec3 cameraPosition) {
    return 0.04 + 0.0025 * length(surfacePos - cameraPosition);
}

bool surfacesMatch(int expectedMat, vec3 expectedPos, vec3 expectedNormal, Hit actualHit, vec3 actualPos, vec3 actualNormal, vec3 cameraPosition) {
    if (actualHit.mat < 0 || actualHit.mat != expectedMat) {
        return false;
    }

    if (dot(expectedNormal, actualNormal) < REPROJECT_NORMAL_DOT_MIN) {
        return false;
    }

    return length(actualPos - expectedPos) <= surfacePositionTolerance(expectedPos, cameraPosition);
}

bool reprojectSurfaceToCamera(
    vec3 surfacePos,
    vec3 surfaceNormal,
    int surfaceMat,
    vec3 cameraPosition,
    float yawValue,
    float pitchValue,
    float fovValue,
    out vec2 cacheUV
) {
    if (!projectToScreenUV(surfacePos, cameraPosition, yawValue, pitchValue, fovValue, cacheUV)) {
        return false;
    }

    vec3 reprojPos, reprojNormal;
    Hit reprojHit = march(
        cameraPosition,
        getRayForCamera(cacheUV * iResolution, yawValue, pitchValue, fovValue),
        reprojPos,
        reprojNormal,
        0
    );

    if (!surfacesMatch(surfaceMat, surfacePos, surfaceNormal, reprojHit, reprojPos, reprojNormal, cameraPosition)) {
        return false;
    }

    return true;
}

float fresnelSchlick1(float cosTheta, float F0) {
    float f = pow(1.0 - clamp(cosTheta, 0.0, 1.0), 5.0);
    return F0 + (1.0 - F0) * f;
}

vec3 orientNormalToRay(vec3 normal, vec3 rd) {
    return (dot(normal, rd) < 0.0) ? normal : -normal;
}

float dielectricF0(float eta) {
    float f = (eta - 1.0) / max(eta + 1.0, 0.0001);
    return f * f;
}

float materialDispersion(Material mat) {
    return clamp(mat.transmission * max(mat.ior - 1.0, 0.0) * (1.0 - mat.roughness) * 0.035, 0.0, 0.06);
}

float wavelengthIor(Material mat, float lambda) {
    float invLambda2 = 1.0 / max(lambda * lambda, 1.0);
    float invRef2 = 1.0 / (550.0 * 550.0);
    return max(1.0, mat.ior + materialDispersion(mat) * (invLambda2 - invRef2) * 120000.0);
}

float builtinMaterialReflectanceSpectrum(int matId, float lambda) {
    if (matId == 0) return clamp(0.72 + 0.05 * gaussian(lambda, 592.0, 125.0) - 0.02 * gaussian(lambda, 435.0, 55.0), 0.02, 0.92);
    if (matId == 1) return clamp(0.03 + 0.76 * gaussian(lambda, 615.0, 38.0) + 0.16 * gaussian(lambda, 675.0, 68.0), 0.0, 0.92);
    if (matId == 2) return clamp(0.02 + 0.74 * gaussian(lambda, 455.0, 22.0) + 0.18 * gaussian(lambda, 505.0, 44.0), 0.0, 0.95);
    if (matId == 3) return clamp(0.92 - 0.03 * gaussian(lambda, 445.0, 48.0), 0.70, 0.99);
    if (matId == 4) return clamp(0.07 + 0.92 * gaussian(lambda, 590.0, 46.0) + 0.46 * gaussian(lambda, 650.0, 62.0), 0.02, 0.99);
    if (matId == 8) return clamp(0.045 + 0.01 * gaussian(lambda, 560.0, 90.0), 0.01, 0.12);
    if (matId == 9) return 0.96;
    if (matId == 10) return clamp(0.20 + 0.03 * gaussian(lambda, 610.0, 70.0), 0.12, 0.32);
    if (matId == 12) return 0.97;
    if (matId == 13) return clamp(0.12 + 0.02 * gaussian(lambda, 520.0, 55.0), 0.08, 0.22);
    return -1.0;
}

float builtinMaterialEmissionSpectrum(int matId, float lambda) {
    if (matId == 5) return 5.0 * gaussian(lambda, 532.0, 16.0) + 1.8 * gaussian(lambda, 558.0, 32.0);
    if (matId == 6) return 7.2 * gaussian(lambda, 625.0, 14.0) + 1.6 * gaussian(lambda, 667.0, 24.0);
    if (matId == 7) return 6.2 * gaussian(lambda, 456.0, 14.0) + 2.1 * gaussian(lambda, 486.0, 20.0);
    if (matId == 11) return 8.0 * gaussian(lambda, 614.0, 18.0) + 1.4 * gaussian(lambda, 675.0, 34.0);
    return -1.0;
}

float builtinMaterialTransmissionSpectrum(int matId, float lambda) {
    if (matId == 9) {
        return clamp(0.985 - 0.055 * gaussian(lambda, 430.0, 26.0) + 0.01 * gaussian(lambda, 610.0, 120.0), 0.88, 0.995);
    }
    return -1.0;
}

float materialReflectanceSpectrum(Material mat, int matId, float lambda) {
    float builtin = builtinMaterialReflectanceSpectrum(matId, lambda);
    if (builtin >= 0.0) return builtin;
    return clamp(rgbToSpectrumPositive(mat.albedo, lambda), 0.0, 0.99);
}

float materialEmissionSpectrum(Material mat, int matId, float lambda) {
    float builtin = builtinMaterialEmissionSpectrum(matId, lambda);
    if (builtin >= 0.0) return builtin;
    return max(rgbToSpectrumPositive(max(mat.emission, vec3(0.0)), lambda), 0.0);
}

float materialTransmissionSpectrum(Material mat, int matId, float lambda) {
    float builtin = builtinMaterialTransmissionSpectrum(matId, lambda);
    if (builtin >= 0.0) return builtin;
    return clamp(rgbToSpectrumPositive(mat.transmissionColor, lambda), 0.0, 1.0);
}

float materialSpecularF0(Material mat, float spectralAlbedo, float lambda) {
    float dielectric = dielectricF0(wavelengthIor(mat, lambda)) * mix(0.5, 1.5, mat.specular);
    dielectric = clamp(dielectric, 0.0, 0.98);
    return mix(dielectric, spectralAlbedo, mat.metallic);
}

float transmissionTint(Material mat, int matId, float lambda) {
    return mix(1.0, materialTransmissionSpectrum(mat, matId, lambda), clamp(mat.transmission, 0.0, 1.0));
}

bool refractRay(vec3 rd, vec3 geomNormal, Material mat, float lambda, out vec3 refractedDir) {
    bool entering = dot(rd, geomNormal) < 0.0;
    vec3 n = entering ? geomNormal : -geomNormal;
    float etaSurface = wavelengthIor(mat, lambda);
    float etaI = entering ? 1.0 : etaSurface;
    float etaT = entering ? etaSurface : 1.0;
    refractedDir = refract(rd, n, etaI / max(etaT, 0.0001));
    return dot(refractedDir, refractedDir) > 0.000001;
}

float D_GGX(float NdotH, float alpha) {
    float a2 = alpha * alpha;
    float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / max(PI * d * d, 0.0001);
}

float G1_SchlickGGX(float NdotV, float k) {
    return NdotV / max(NdotV * (1.0 - k) + k, 0.0001);
}

float G_Smith(float NdotV, float NdotL, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) * 0.125;
    return G1_SchlickGGX(NdotV, k) * G1_SchlickGGX(NdotL, k);
}

void buildBasis(vec3 n, out vec3 t, out vec3 b) {
    vec3 up = (abs(n.y) < 0.999) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
    t = normalize(cross(up, n));
    b = cross(n, t);
}

vec3 sampleGGXHalfVector(vec3 n, float alpha, vec2 u) {
    float a2 = max(alpha * alpha, 0.0004);
    float phi = TWO_PI * u.x;
    float cosTheta = sqrt((1.0 - u.y) / max(1.0 + (a2 - 1.0) * u.y, 0.000001));
    float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
    vec3 t, b;
    buildBasis(n, t, b);
    return normalize((cos(phi) * sinTheta) * t + (sin(phi) * sinTheta) * b + cosTheta * n);
}

float ggxPdfReflection(vec3 n, vec3 v, vec3 l, float alpha) {
    if (dot(n, v) <= 0.0 || dot(n, l) <= 0.0) return 0.0;
    vec3 h = normalize(v + l);
    float NdotH = max(dot(n, h), 0.0);
    float VdotH = max(dot(v, h), 0.0);
    float D = D_GGX(NdotH, max(alpha, 0.02));
    return D * NdotH / max(4.0 * VdotH, 0.0001);
}

float powerHeuristic(float a, float b) {
    float aa = a * a;
    float bb = b * b;
    return aa / max(aa + bb, 0.000001);
}

bool fresnelAmplitudeDielectric(float etaI, float etaT, float cosI, out float rs, out float rp, out float ts, out float tp, out float cosT) {
    float eta = etaI / max(etaT, 0.0001);
    float sinT2 = eta * eta * max(0.0, 1.0 - cosI * cosI);
    if (sinT2 > 1.0) {
        rs = 1.0; rp = 1.0; ts = 0.0; tp = 0.0; cosT = 0.0;
        return false;
    }
    cosT = sqrt(max(0.0, 1.0 - sinT2));
    float denomS = etaI * cosI + etaT * cosT;
    float denomP = etaT * cosI + etaI * cosT;
    rs = (etaI * cosI - etaT * cosT) / max(denomS, 0.0001);
    rp = (etaT * cosI - etaI * cosT) / max(denomP, 0.0001);
    ts = (2.0 * etaI * cosI) / max(denomS, 0.0001);
    tp = (2.0 * etaI * cosI) / max(denomP, 0.0001);
    return true;
}

float thinFilmPhase(Material mat, float lambda, float cosThetaI) {
    if (mat.clearcoat <= 0.0001) return 0.0;
    float thickness = mix(CLEARCOAT_FILM_MIN_NM, CLEARCOAT_FILM_MAX_NM, clamp(mat.clearcoat, 0.0, 1.0));
    float etaFilm = 1.38;
    float sinThetaT2 = max(0.0, 1.0 - cosThetaI * cosThetaI) / (etaFilm * etaFilm);
    float cosThetaT = sqrt(max(0.0, 1.0 - sinThetaT2));
    return TWO_PI * (2.0 * etaFilm * thickness * cosThetaT) / max(lambda, 1.0);
}

float lightTemperature(int i) {
    if (i == 0) return 3200.0;
    if (i == 1) return 5600.0;
    return 9200.0;
}

float lightEmissionSpectrum(int i, float lambda) {
    vec3 lightColor = getLightColor(i);
    float radiantPower = max(max(lightColor.r, lightColor.g), lightColor.b);
    return radiantPower * SPECTRAL_LIGHT_RADIANCE_SCALE * blackbodyNormalized(lambda, lightTemperature(i));
}

bool intersectSphere(vec3 ro, vec3 rd, vec3 center, float radius, out float t, out vec3 normal) {
    vec3 oc = ro - center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - radius * radius;
    float h = b * b - c;
    if (h < 0.0) {
        t = -1.0;
        normal = vec3(0.0, 1.0, 0.0);
        return false;
    }
    h = sqrt(h);
    float t0 = -b - h;
    float t1 = -b + h;
    t = (t0 > HIT_EPS) ? t0 : ((t1 > HIT_EPS) ? t1 : -1.0);
    if (t <= 0.0) {
        normal = vec3(0.0, 1.0, 0.0);
        return false;
    }
    normal = normalize((ro + rd * t) - center);
    return true;
}

const int HIT_NONE = 0;
const int HIT_SURFACE = 1;
const int HIT_LIGHT = 2;

struct SceneHit {
    float dist;
    vec3 pos;
    vec3 normal;
    int mat;
    int kind;
    int lightIndex;
};

struct LightSample {
    vec3 pos;
    vec3 normal;
    vec3 wi;
    float dist;
    float pdf;
    int index;
};

struct SpectralBsdfSample {
    vec3 wi;
    float weight;
    float pdf;
    int isDelta;
    int nextTraceMode;
    vec2 ampS;
    vec2 ampP;
};

SceneHit traceScene(vec3 ro, vec3 rd, int traceMode, int includeLights) {
    SceneHit result;
    result.dist = MAX_TRACE_DIST;
    result.pos = ro + rd * MAX_TRACE_DIST;
    result.normal = vec3(0.0, 1.0, 0.0);
    result.mat = -1;
    result.kind = HIT_NONE;
    result.lightIndex = -1;

    vec3 pos, normal;
    Hit surfaceHit = march(ro, rd, pos, normal, traceMode);
    if (surfaceHit.mat >= 0) {
        result.dist = surfaceHit.dist;
        result.pos = pos;
        result.normal = normal;
        result.mat = surfaceHit.mat;
        result.kind = HIT_SURFACE;
    }

    if (includeLights != 0) {
        for (int i = 0; i < lightCount; ++i) {
            float t;
            vec3 lightNormal;
            if (intersectSphere(ro, rd, getLightPos(i), LIGHT_RADIUS, t, lightNormal) && t < result.dist) {
                result.dist = t;
                result.pos = ro + rd * t;
                result.normal = lightNormal;
                result.mat = -1;
                result.kind = HIT_LIGHT;
                result.lightIndex = i;
            }
        }
    }

    return result;
}

float environmentSpectrum(vec3 rd, float lambda) {
    float skyBlend = clamp(0.5 * (rd.y + 1.0), 0.0, 1.0);
    float rayleigh = pow(440.0 / max(lambda, 1.0), 4.0);
    float mie = pow(560.0 / max(lambda, 1.0), 0.8);
    float horizonGlow = exp(-8.0 * max(rd.y, 0.0));
    vec3 sunDir = normalize(vec3(0.25, 0.85, -0.45));
    float sunGlow = pow(max(dot(rd, sunDir), 0.0), 160.0);
    float baseSky = mix(0.018, 0.085, skyBlend) * mix(0.7 * mie, rayleigh, 0.65);
    float horizon = horizonGlow * 0.035 * blackbodyNormalized(lambda, 4200.0);
    float sun = sunGlow * 0.18 * blackbodyNormalized(lambda, 5800.0);
    return baseSky + horizon + sun;
}

void getMediumProperties(float lambda, out float sigmaS, out float sigmaA, out float g) {
    if (uTracingMode < 3) {
        sigmaS = 0.0;
        sigmaA = 0.0;
        g = 0.0;
        return;
    }

    float density = 0.0075;
    if (uSceneVariant == 1) density = 0.0095;
    if (uSceneVariant == 2) density = 0.0165;
    if (uSceneVariant == 3) density = 0.0065;

    float rayleigh = pow(550.0 / max(lambda, 1.0), 4.0);
    float mie = pow(550.0 / max(lambda, 1.0), 0.6);
    sigmaS = density * (0.16 * mie + 0.30 * rayleigh);
    sigmaA = density * 0.018 * ((uSceneVariant == 2) ? 1.35 : 0.8);
    g = 0.18 + ((uSceneVariant == 2) ? 0.22 : 0.0);
}

float mediumTransmittance(float lambda, float dist) {
    float sigmaS, sigmaA, g;
    getMediumProperties(lambda, sigmaS, sigmaA, g);
    return exp(-(sigmaS + sigmaA) * max(dist, 0.0));
}

float visibilityTransmittance(vec3 origin, vec3 dir, float maxDist, float lambda) {
    float travel = max(maxDist, 0.0);
    if (uEnableShadows != 0) {
        float shadowLimit = max(travel - SHADOW_BIAS * 2.0, 0.0);
        if (shadowTrace(origin, dir, shadowLimit) <= 0.0) {
            return 0.0;
        }
    }
    return mediumTransmittance(lambda, travel);
}

float phaseHG(float cosTheta, float g) {
    float gg = g * g;
    float denom = 1.0 + gg - 2.0 * g * cosTheta;
    return INV_PI * 0.25 * (1.0 - gg) / max(denom * sqrt(denom), 0.0001);
}

vec3 samplePhaseDirection(vec3 forward, float g, vec2 u) {
    float cosTheta = 1.0 - 2.0 * u.x;
    if (abs(g) > 0.0001) {
        float s = (1.0 - g * g) / max(1.0 - g + 2.0 * g * u.x, 0.0001);
        cosTheta = clamp((1.0 + g * g - s * s) / (2.0 * g), -1.0, 1.0);
    }
    float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));
    float phi = TWO_PI * u.y;
    vec3 t, b;
    buildBasis(forward, t, b);
    return normalize((cos(phi) * sinTheta) * t + (sin(phi) * sinTheta) * b + cosTheta * forward);
}

vec3 uniformSampleSphere(vec2 u) {
    float z = 1.0 - 2.0 * u.x;
    float r = sqrt(max(0.0, 1.0 - z * z));
    float phi = TWO_PI * u.y;
    return vec3(r * cos(phi), r * sin(phi), z);
}

LightSample sampleLightConnection(vec3 refPos, float uSel, vec2 uSphere) {
    LightSample sample;
    sample.index = clamp(int(floor(uSel * float(lightCount))), 0, lightCount - 1);
    sample.normal = uniformSampleSphere(uSphere);
    sample.pos = getLightPos(sample.index) + sample.normal * LIGHT_RADIUS;
    vec3 toLight = sample.pos - refPos;
    sample.dist = length(toLight);
    sample.wi = toLight / max(sample.dist, 0.0001);
    float cosOnLight = max(dot(sample.normal, -sample.wi), 0.0);
    float areaPdf = 1.0 / max(4.0 * PI * LIGHT_RADIUS * LIGHT_RADIUS, 0.0001);
    sample.pdf = (cosOnLight > 0.0) ? (areaPdf / float(lightCount)) * (sample.dist * sample.dist) / cosOnLight : 0.0;
    return sample;
}

float lightPdfFromPoint(vec3 refPos, vec3 lightPos, vec3 lightNormal, int lightIndex) {
    if (lightIndex < 0) return 0.0;
    vec3 toLight = lightPos - refPos;
    float dist = length(toLight);
    vec3 wi = toLight / max(dist, 0.0001);
    float cosOnLight = max(dot(lightNormal, -wi), 0.0);
    if (cosOnLight <= 0.0) return 0.0;
    float areaPdf = 1.0 / max(4.0 * PI * LIGHT_RADIUS * LIGHT_RADIUS, 0.0001);
    return (areaPdf / float(lightCount)) * (dist * dist) / cosOnLight;
}

vec2 complexMul(vec2 a, vec2 b) {
    return vec2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

vec2 complexConj(vec2 a) {
    return vec2(a.x, -a.y);
}

float complexDotReal(vec2 a, vec2 b) {
    return a.x * b.x + a.y * b.y;
}

float evalSurfaceBsdfSpectral(vec3 n, vec3 v, vec3 l, Material mat, int matId, float lambda, out float pdf) {
    float NdotV = max(dot(n, v), 0.0);
    float NdotL = max(dot(n, l), 0.0);
    if (NdotV <= 0.0 || NdotL <= 0.0) {
        pdf = 0.0;
        return 0.0;
    }

    float spectralAlbedo = materialReflectanceSpectrum(mat, matId, lambda);
    float F0 = materialSpecularF0(mat, spectralAlbedo, lambda);
    vec3 h = normalize(v + l);
    float NdotH = max(dot(n, h), 0.0);
    float VdotH = max(dot(v, h), 0.0);
    float F = fresnelSchlick1(VdotH, F0);

    float alpha = max(0.02, mat.roughness * mat.roughness);
    float D = D_GGX(NdotH, alpha);
    float G = G_Smith(NdotV, NdotL, mat.roughness);
    float spec = (D * G * F) / max(4.0 * NdotV * NdotL, 0.0001);

    float coatSpec = 0.0;
    if (mat.clearcoat > 0.0001) {
        float coatAlpha = max(0.015, mat.clearcoatRoughness * mat.clearcoatRoughness);
        float coatD = D_GGX(NdotH, coatAlpha);
        float coatG = G_Smith(NdotV, NdotL, mat.clearcoatRoughness);
        float coatF = fresnelSchlick1(VdotH, 0.04);
        coatSpec = mat.clearcoat * (coatD * coatG * coatF) / max(4.0 * NdotV * NdotL, 0.0001);
    }

    float kd = (1.0 - mat.metallic) * (1.0 - mat.transmission);
    float diff = (1.0 - F) * kd * spectralAlbedo * INV_PI;

    float diffuseProb = max(kd * spectralAlbedo, 0.0);
    float specProb = max(F + 0.08 * mat.specular + 0.06 * mat.metallic, 0.0);
    float coatProb = max(mat.clearcoat * 0.28, 0.0);
    float sum = max(diffuseProb + specProb + coatProb, 0.0001);
    diffuseProb /= sum;
    specProb /= sum;
    coatProb /= sum;

    float diffusePdf = NdotL * INV_PI;
    float specPdf = ggxPdfReflection(n, v, l, alpha);
    float coatPdf = ggxPdfReflection(n, v, l, max(0.015, mat.clearcoatRoughness * mat.clearcoatRoughness));
    pdf = diffuseProb * diffusePdf + specProb * specPdf + coatProb * coatPdf;
    return diff + spec + coatSpec;
}

SpectralBsdfSample sampleSurfaceBsdfSpectral(vec3 n, vec3 geomNormal, vec3 v, Material mat, int matId, float lambda, vec2 uChoice, vec2 uDir) {
    SpectralBsdfSample sample;
    sample.wi = vec3(0.0, 1.0, 0.0);
    sample.weight = 0.0;
    sample.pdf = 0.0;
    sample.isDelta = 0;
    sample.nextTraceMode = 0;
    sample.ampS = vec2(1.0, 0.0);
    sample.ampP = vec2(1.0, 0.0);

    float spectralAlbedo = materialReflectanceSpectrum(mat, matId, lambda);
    float F0 = materialSpecularF0(mat, spectralAlbedo, lambda);
    float cosNV = max(dot(n, v), 0.0);
    float F = fresnelSchlick1(cosNV, F0);
    float transmissionBase = clamp(mat.transmission * (1.0 - mat.metallic), 0.0, 0.98);

    float diffuseProb = max((1.0 - mat.metallic) * (1.0 - mat.transmission) * spectralAlbedo, 0.0);
    float specProb = (uEnableReflections != 0) ? max(F + 0.08 * mat.specular + 0.06 * mat.metallic, 0.0) : 0.0;
    float coatProb = (uEnableReflections != 0) ? max(mat.clearcoat * 0.28, 0.0) : 0.0;
    float transmitProb = (uEnableReflections != 0) ? max(transmissionBase * transmissionTint(mat, matId, lambda), 0.0) : 0.0;
    float total = max(diffuseProb + specProb + coatProb + transmitProb, 0.0001);
    diffuseProb /= total;
    specProb /= total;
    coatProb /= total;
    transmitProb /= total;

    float selector = uChoice.x;
    if (selector < transmitProb && transmitProb > 0.00001) {
        vec3 refractedDir;
        float etaSurface = wavelengthIor(mat, lambda);
        float etaI = (dot(v, geomNormal) > 0.0) ? 1.0 : etaSurface;
        float etaT = (dot(v, geomNormal) > 0.0) ? etaSurface : 1.0;
        float rs, rp, ts, tp, cosT;
        bool refracted = fresnelAmplitudeDielectric(etaI, etaT, abs(dot(geomNormal, v)), rs, rp, ts, tp, cosT);
        if (refracted && refractRay(-v, geomNormal, mat, lambda, refractedDir)) {
            sample.wi = normalize(refractedDir);
            sample.weight = ((1.0 - F) * transmissionBase * transmissionTint(mat, matId, lambda)) / max(transmitProb, 0.001);
            sample.pdf = max(transmitProb, 0.001);
            sample.isDelta = 1;
            sample.nextTraceMode = 0;
            float norm = sqrt(2.0 / max(ts * ts + tp * tp, 0.0001));
            sample.ampS = vec2(ts * norm, 0.0);
            sample.ampP = vec2(tp * norm, 0.0);
            return sample;
        }

        sample.wi = reflect(-v, n);
        sample.weight = 1.0 / max(transmitProb, 0.001);
        sample.pdf = max(transmitProb, 0.001);
        sample.isDelta = 1;
        sample.nextTraceMode = 1;
        sample.ampS = vec2(1.0, 0.0);
        sample.ampP = vec2(1.0, 0.0);
        return sample;
    }

    bool diffuseEvent = selector < transmitProb + diffuseProb;
    bool coatEvent = selector >= (transmitProb + diffuseProb + specProb);
    if (diffuseEvent) {
        sample.wi = cosineSampleHemisphere(n, uDir);
        sample.nextTraceMode = 0;
        vec2 phase = vec2(cos(TWO_PI * uChoice.y), sin(TWO_PI * uChoice.y));
        sample.ampS = phase;
        sample.ampP = phase;
    } else {
        float alpha = coatEvent ? max(0.015, mat.clearcoatRoughness * mat.clearcoatRoughness) : max(0.02, mat.roughness * mat.roughness);
        vec3 halfVector = sampleGGXHalfVector(n, alpha, uDir);
        sample.wi = reflect(-v, halfVector);
        sample.nextTraceMode = 1;
        float eta = wavelengthIor(mat, lambda);
        float rs, rp, ts, tp, cosT;
        fresnelAmplitudeDielectric(1.0, eta, cosNV, rs, rp, ts, tp, cosT);
        float norm = sqrt(2.0 / max(rs * rs + rp * rp, 0.0001));
        sample.ampS = vec2(rs * norm, 0.0);
        sample.ampP = vec2(rp * norm, 0.0);
        if (coatEvent) {
            vec2 phase = vec2(cos(thinFilmPhase(mat, lambda, cosNV)), sin(thinFilmPhase(mat, lambda, cosNV)));
            sample.ampS = complexMul(sample.ampS, phase);
            sample.ampP = complexMul(sample.ampP, phase);
        }
    }

    if (dot(n, sample.wi) <= 0.0) {
        return sample;
    }

    float pdf;
    float f = evalSurfaceBsdfSpectral(n, v, sample.wi, mat, matId, lambda, pdf);
    float NdotL = max(dot(n, sample.wi), 0.0);
    if (pdf > 0.00001 && NdotL > 0.0) {
        sample.weight = f * NdotL / pdf;
        sample.pdf = pdf;
    }

    return sample;
}

float directLightingSurfaceSpectralDeterministic(vec3 pos, vec3 n, vec3 v, Material mat, int matId, float lambda) {
    float accum = 0.0;
    for (int i = 0; i < lightCount; ++i) {
        vec3 toLight = getLightPos(i) - pos;
        float dist = length(toLight);
        vec3 wi = toLight / max(dist, 0.0001);
        float NdotL = max(dot(n, wi), 0.0);
        if (NdotL <= 0.0) continue;
        float visibility = visibilityTransmittance(pos + n * SHADOW_BIAS, wi, max(dist - LIGHT_RADIUS, 0.0), lambda);
        if (visibility <= 0.0) continue;
        float pdf;
        float f = evalSurfaceBsdfSpectral(n, v, wi, mat, matId, lambda, pdf);
        accum += f * lightEmissionSpectrum(i, lambda) * NdotL * visibility / (dist * dist + 1.0);
    }
    return accum;
}

float directLightingSurfaceSpectralMIS(vec3 pos, vec3 n, vec3 v, Material mat, int matId, float lambda, int bounce) {
    vec2 seed0 = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 1.37, float(bounce) * 17.0 + lambda * 0.019));
    vec2 seed1 = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 3.91 + 12.4, float(bounce) * 7.0 + lambda * 0.011));
    LightSample light = sampleLightConnection(pos, seed0.x, vec2(seed0.y, seed1.x));
    if (light.pdf <= 0.0) return 0.0;
    float NdotL = max(dot(n, light.wi), 0.0);
    if (NdotL <= 0.0) return 0.0;
    float visibility = visibilityTransmittance(pos + n * SHADOW_BIAS, light.wi, light.dist, lambda);
    if (visibility <= 0.0) return 0.0;
    float bsdfPdf;
    float f = evalSurfaceBsdfSpectral(n, v, light.wi, mat, matId, lambda, bsdfPdf);
    if (f <= 0.0) return 0.0;
    float mis = powerHeuristic(light.pdf, bsdfPdf);
    return f * lightEmissionSpectrum(light.index, lambda) * NdotL * visibility * mis / light.pdf;
}

float directLightingMediumSpectralMIS(vec3 pos, vec3 forward, float lambda, float g, int bounce) {
    vec2 seed0 = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 2.73 + 5.0, float(bounce) * 11.0 + lambda * 0.017));
    vec2 seed1 = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 5.13 + 9.1, float(bounce) * 5.0 + lambda * 0.013));
    LightSample light = sampleLightConnection(pos, seed0.x, vec2(seed0.y, seed1.x));
    if (light.pdf <= 0.0) return 0.0;
    float visibility = visibilityTransmittance(pos + light.wi * SHADOW_BIAS, light.wi, light.dist, lambda);
    if (visibility <= 0.0) return 0.0;
    float phase = phaseHG(dot(forward, light.wi), g);
    float mis = powerHeuristic(light.pdf, phase);
    return phase * lightEmissionSpectrum(light.index, lambda) * visibility * mis / light.pdf;
}

vec4 renderRadianceCache(vec2 fragCoord) {
    return vec4(0.0);
}

float traceSpectralRaySingle(vec3 ro, vec3 rd, float lambda) {
    float accum = 0.0;
    float throughput = 1.0;
    int traceMode = 0;

    for (int bounce = 0; bounce < 2; ++bounce) {
        if (bounce >= uMaxBounces) break;

        SceneHit hit = traceScene(ro, rd, traceMode, 1);
        if (hit.kind == HIT_NONE) {
            accum += throughput * environmentSpectrum(rd, lambda);
            break;
        }
        if (hit.kind == HIT_LIGHT) {
            accum += throughput * lightEmissionSpectrum(hit.lightIndex, lambda);
            break;
        }

        Material mat = getMaterial(hit.mat);
        vec3 geomNormal = normalize(hit.normal);
        vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
        vec3 viewDir = normalize(-rd);

        accum += throughput * materialEmissionSpectrum(mat, hit.mat, lambda);
        accum += throughput * directLightingSurfaceSpectralDeterministic(hit.pos, shadingNormal, viewDir, mat, hit.mat, lambda);

        if (uEnableReflections == 0 || bounce >= 1) break;

        float spectralAlbedo = materialReflectanceSpectrum(mat, hit.mat, lambda);
        float cosNV = max(dot(shadingNormal, viewDir), 0.0);
        float F = fresnelSchlick1(cosNV, materialSpecularF0(mat, spectralAlbedo, lambda));
        float transmissionBase = clamp(mat.transmission * (1.0 - mat.metallic), 0.0, 0.98);

        if (transmissionBase > F && transmissionBase > 0.02) {
            vec3 refractedDir;
            if (refractRay(rd, geomNormal, mat, lambda, refractedDir)) {
                throughput *= transmissionTint(mat, hit.mat, lambda);
                rd = normalize(refractedDir);
                ro = hit.pos + rd * (RAY_BIAS * 2.0);
                traceMode = 0;
                continue;
            }
        }

        if (F > 0.02) {
            rd = reflect(rd, shadingNormal);
            ro = hit.pos + shadingNormal * RAY_BIAS;
            throughput *= F;
            traceMode = 1;
            continue;
        }

        break;
    }

    return accum;
}

float traceSpectralPathSingle(vec3 ro, vec3 rd, float lambda, int includeExplicitLights) {
    float accum = 0.0;
    float throughput = 1.0;
    int traceMode = 0;
    float lastScatterPdf = 1.0;
    int lastWasDelta = 1;

    for (int bounce = 0; bounce < HARD_MAX_BOUNCES; ++bounce) {
        if (bounce >= uMaxBounces) break;

        SceneHit hit = traceScene(ro, rd, traceMode, includeExplicitLights);
        float surfaceDist = (hit.kind == HIT_NONE) ? MAX_TRACE_DIST : hit.dist;

        float sigmaS, sigmaA, g;
        getMediumProperties(lambda, sigmaS, sigmaA, g);
        float sigmaT = sigmaS + sigmaA;
        if (sigmaT > 0.0) {
            float xi = hash21(gl_FragCoord.xy + vec2(float(iFrame) * 1.71 + lambda * 0.013, float(bounce) * 19.7 + 2.4));
            float mediumDist = -log(max(1.0 - xi, 0.000001)) / sigmaT;
            if (mediumDist < surfaceDist) {
                throughput *= exp(-sigmaT * mediumDist) * (sigmaS / max(sigmaT, 0.0001));
                vec3 mediumPos = ro + rd * mediumDist;
                if (includeExplicitLights != 0) {
                    accum += throughput * directLightingMediumSpectralMIS(mediumPos, rd, lambda, g, bounce);
                }
                vec2 phaseSeed = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 2.13 + lambda * 0.009, float(bounce) * 7.3 + 15.9));
                vec3 forward = rd;
                vec3 newDir = samplePhaseDirection(forward, g, phaseSeed);
                ro = mediumPos + newDir * RAY_BIAS;
                rd = newDir;
                traceMode = 0;
                lastScatterPdf = phaseHG(dot(forward, newDir), g);
                lastWasDelta = 0;
                continue;
            }
            throughput *= exp(-sigmaT * surfaceDist);
        }

        if (hit.kind == HIT_NONE) {
            accum += throughput * environmentSpectrum(rd, lambda);
            break;
        }

        if (hit.kind == HIT_LIGHT) {
            float weight = 1.0;
            if (lastWasDelta == 0) {
                float lightPdf = lightPdfFromPoint(ro, hit.pos, hit.normal, hit.lightIndex);
                weight = powerHeuristic(lastScatterPdf, lightPdf);
            }
            accum += throughput * lightEmissionSpectrum(hit.lightIndex, lambda) * weight;
            break;
        }

        Material mat = getMaterial(hit.mat);
        float emission = materialEmissionSpectrum(mat, hit.mat, lambda);
        if (emission > 0.00001) {
            accum += throughput * emission;
            break;
        }

        vec3 geomNormal = normalize(hit.normal);
        vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
        vec3 viewDir = normalize(-rd);
        if (includeExplicitLights != 0) {
            accum += throughput * directLightingSurfaceSpectralMIS(hit.pos, shadingNormal, viewDir, mat, hit.mat, lambda, bounce);
        }

        vec2 uChoice = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 0.73 + lambda * 0.021, float(bounce) * 11.0 + 3.7));
        vec2 uDir = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 1.97 + lambda * 0.017, float(bounce) * 23.0 + 8.1));
        SpectralBsdfSample bs = sampleSurfaceBsdfSpectral(shadingNormal, geomNormal, viewDir, mat, hit.mat, lambda, uChoice, uDir);
        if (bs.weight <= 0.0 || bs.pdf <= 0.0) break;

        throughput *= bs.weight;
        ro = hit.pos + ((dot(bs.wi, shadingNormal) >= 0.0) ? shadingNormal : -shadingNormal) * RAY_BIAS;
        rd = normalize(bs.wi);
        traceMode = bs.nextTraceMode;
        lastScatterPdf = bs.pdf;
        lastWasDelta = bs.isDelta;

        if (bounce >= 2) {
            float rr = hash21(gl_FragCoord.xy + vec2(float(iFrame) * 4.03, float(bounce) * 31.0 + lambda * 0.007));
            float p = clamp(throughput, 0.05, 0.98);
            if (rr > p) break;
            throughput /= p;
        }
    }

    return accum;
}

vec3 environmentRGB(vec3 rd) {
    float t = 0.5 * (rd.y + 1.0);
    return mix(vec3(0.028, 0.032, 0.040), vec3(0.105, 0.122, 0.160), t);
}

vec3 evalSurfaceBsdfRGB(vec3 n, vec3 v, vec3 l, Material mat) {
    float NdotV = max(dot(n, v), 0.0);
    float NdotL = max(dot(n, l), 0.0);
    if (NdotV <= 0.0 || NdotL <= 0.0) return vec3(0.0);

    vec3 albedo = saturate(mat.albedo);
    vec3 h = normalize(v + l);
    float NdotH = max(dot(n, h), 0.0);
    float VdotH = max(dot(v, h), 0.0);
    float dielectric = clamp(dielectricF0(mat.ior) * mix(0.5, 1.5, mat.specular), 0.0, 0.98);
    vec3 F0 = mix(vec3(dielectric), albedo, mat.metallic);
    vec3 F = F0 + (vec3(1.0) - F0) * pow(1.0 - clamp(VdotH, 0.0, 1.0), 5.0);

    float alpha = max(0.02, mat.roughness * mat.roughness);
    float D = D_GGX(NdotH, alpha);
    float G = G_Smith(NdotV, NdotL, mat.roughness);
    vec3 spec = (D * G * F) / max(4.0 * NdotV * NdotL, 0.0001);

    vec3 coat = vec3(0.0);
    if (mat.clearcoat > 0.0001) {
        float coatAlpha = max(0.015, mat.clearcoatRoughness * mat.clearcoatRoughness);
        float coatD = D_GGX(NdotH, coatAlpha);
        float coatG = G_Smith(NdotV, NdotL, mat.clearcoatRoughness);
        float coatF = fresnelSchlick1(VdotH, 0.04);
        coat = vec3(mat.clearcoat * coatD * coatG * coatF / max(4.0 * NdotV * NdotL, 0.0001));
    }

    vec3 diff = (vec3(1.0) - F) * (1.0 - mat.metallic) * (1.0 - mat.transmission) * albedo * INV_PI;
    return diff + spec + coat;
}

vec3 directLightingRGBDeterministic(vec3 pos, vec3 n, vec3 v, Material mat) {
    vec3 accum = vec3(0.0);
    for (int i = 0; i < lightCount; ++i) {
        vec3 toLight = getLightPos(i) - pos;
        float dist = length(toLight);
        vec3 wi = toLight / max(dist, 0.0001);
        float visibility = visibilityTransmittance(pos + n * SHADOW_BIAS, wi, max(dist - LIGHT_RADIUS, 0.0), 550.0);
        accum += evalSurfaceBsdfRGB(n, v, wi, mat) * getLightColor(i) * max(dot(n, wi), 0.0) * visibility / (dist * dist + 1.0);
    }
    return accum;
}

vec3 traceRGBPreview(vec3 ro, vec3 rd) {
    SceneHit hit = traceScene(ro, rd, 0, 1);
    if (hit.kind == HIT_NONE) return environmentRGB(rd);
    if (hit.kind == HIT_LIGHT) return getLightColor(hit.lightIndex);

    Material mat = getMaterial(hit.mat);
    vec3 shadingNormal = orientNormalToRay(normalize(hit.normal), rd);
    vec3 viewDir = normalize(-rd);
    vec3 color = mat.emission + directLightingRGBDeterministic(hit.pos, shadingNormal, viewDir, mat);
    color += mat.albedo * 0.018;
    return color;
}

vec3 traceRGBRay(vec3 ro, vec3 rd) {
    vec3 accum = vec3(0.0);
    vec3 throughput = vec3(1.0);
    int traceMode = 0;

    for (int bounce = 0; bounce < 2; ++bounce) {
        if (bounce >= uMaxBounces) break;

        SceneHit hit = traceScene(ro, rd, traceMode, 1);
        if (hit.kind == HIT_NONE) {
            accum += throughput * environmentRGB(rd);
            break;
        }
        if (hit.kind == HIT_LIGHT) {
            accum += throughput * getLightColor(hit.lightIndex);
            break;
        }

        Material mat = getMaterial(hit.mat);
        vec3 geomNormal = normalize(hit.normal);
        vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
        vec3 viewDir = normalize(-rd);

        accum += throughput * (mat.emission + directLightingRGBDeterministic(hit.pos, shadingNormal, viewDir, mat));

        float dielectric = dielectricF0(mat.ior) * mix(0.5, 1.5, mat.specular);
        float cosNV = max(dot(shadingNormal, viewDir), 0.0);
        float F = fresnelSchlick1(cosNV, clamp(mix(dielectric, 0.92, mat.metallic), 0.0, 0.98));
        float transmissionBase = clamp(mat.transmission * (1.0 - mat.metallic), 0.0, 0.98);

        if (uEnableReflections == 0 || bounce >= 1) break;

        if (transmissionBase > F && transmissionBase > 0.02) {
            vec3 refractedDir;
            if (refractRay(rd, geomNormal, mat, 550.0, refractedDir)) {
                throughput *= mix(vec3(1.0), mat.transmissionColor, transmissionBase);
                rd = normalize(refractedDir);
                ro = hit.pos + rd * (RAY_BIAS * 2.0);
                traceMode = 0;
                continue;
            }
        }

        if (F > 0.02) {
            rd = reflect(rd, shadingNormal);
            ro = hit.pos + shadingNormal * RAY_BIAS;
            throughput *= vec3(F);
            traceMode = 1;
            continue;
        }

        break;
    }

    return accum;
}

struct CoherentField {
    vec2 s;
    vec2 p;
};

CoherentField zeroField() {
    CoherentField f;
    f.s = vec2(0.0);
    f.p = vec2(0.0);
    return f;
}

CoherentField unitField() {
    CoherentField f;
    f.s = vec2(0.70710678, 0.0);
    f.p = vec2(0.70710678, 0.0);
    return f;
}

CoherentField fieldAdd(CoherentField a, CoherentField b) {
    CoherentField outField;
    outField.s = a.s + b.s;
    outField.p = a.p + b.p;
    return outField;
}

CoherentField fieldScale(CoherentField f, float s) {
    f.s *= s;
    f.p *= s;
    return f;
}

CoherentField fieldMul(CoherentField f, vec2 ampS, vec2 ampP) {
    f.s = complexMul(f.s, ampS);
    f.p = complexMul(f.p, ampP);
    return f;
}

float coherentDiffractionAmplitude(float lambda, vec3 lightNormal, vec3 outDir) {
    float sinTheta = sqrt(max(0.0, 1.0 - dot(lightNormal, outDir) * dot(lightNormal, outDir)));
    float x = PI * LIGHT_RADIUS * SCENE_PHASE_SCALE * 0.12 * sinTheta / max(lambda, 1.0);
    if (abs(x) < 0.0001) return 1.0;
    return sin(x) / x;
}

CoherentField coherentSurfaceDirect(CoherentField state, vec3 pos, vec3 n, vec3 v, Material mat, int matId, float lambda, int bounce, float seedOffset) {
    vec2 seed0 = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 0.91 + seedOffset, float(bounce) * 13.0 + lambda * 0.019));
    vec2 seed1 = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 3.27 + seedOffset * 2.0, float(bounce) * 29.0 + lambda * 0.011));
    LightSample light = sampleLightConnection(pos, seed0.x, vec2(seed0.y, seed1.x));
    if (light.pdf <= 0.0) return zeroField();
    float NdotL = max(dot(n, light.wi), 0.0);
    if (NdotL <= 0.0) return zeroField();
    float visibility = visibilityTransmittance(pos + n * SHADOW_BIAS, light.wi, light.dist, lambda);
    if (visibility <= 0.0) return zeroField();
    float pdf;
    float f = evalSurfaceBsdfSpectral(n, v, light.wi, mat, matId, lambda, pdf);
    if (f <= 0.0) return zeroField();

    float amplitude = sqrt(max(f * NdotL * visibility / light.pdf, 0.0) * max(lightEmissionSpectrum(light.index, lambda), 0.0));
    float diffAmp = coherentDiffractionAmplitude(lambda, light.normal, -light.wi);
    float phase = TWO_PI * (light.dist * SCENE_PHASE_SCALE) / max(lambda, 1.0);
    vec2 phaseTerm = vec2(cos(phase), sin(phase));
    CoherentField contribution = fieldScale(state, amplitude * diffAmp);
    contribution = fieldMul(contribution, phaseTerm, phaseTerm);
    return contribution;
}

CoherentField coherentMediumDirect(CoherentField state, vec3 pos, vec3 forward, float lambda, float g, int bounce, float seedOffset) {
    vec2 seed0 = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 1.93 + seedOffset, float(bounce) * 7.0 + lambda * 0.013));
    vec2 seed1 = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 4.17 + seedOffset * 2.0, float(bounce) * 19.0 + lambda * 0.017));
    LightSample light = sampleLightConnection(pos, seed0.x, vec2(seed0.y, seed1.x));
    if (light.pdf <= 0.0) return zeroField();
    float visibility = visibilityTransmittance(pos + light.wi * SHADOW_BIAS, light.wi, light.dist, lambda);
    if (visibility <= 0.0) return zeroField();

    float phase = phaseHG(dot(forward, light.wi), g);
    float amplitude = sqrt(max(phase * visibility / light.pdf, 0.0) * max(lightEmissionSpectrum(light.index, lambda), 0.0));
    float segmentPhase = TWO_PI * (light.dist * SCENE_PHASE_SCALE) / max(lambda, 1.0);
    vec2 phaseTerm = vec2(cos(segmentPhase), sin(segmentPhase));
    CoherentField contribution = fieldScale(state, amplitude);
    contribution = fieldMul(contribution, phaseTerm, phaseTerm);
    return contribution;
}

CoherentField traceCoherentFieldEstimate(vec3 ro, vec3 rd, float lambda, float seedOffset) {
    CoherentField accum = zeroField();
    CoherentField state = unitField();
    int traceMode = 0;

    for (int bounce = 0; bounce < HARD_MAX_BOUNCES; ++bounce) {
        if (bounce >= uMaxBounces) break;

        SceneHit hit = traceScene(ro, rd, traceMode, 0);
        float surfaceDist = (hit.kind == HIT_NONE) ? MAX_TRACE_DIST : hit.dist;

        float sigmaS, sigmaA, g;
        getMediumProperties(lambda, sigmaS, sigmaA, g);
        float sigmaT = sigmaS + sigmaA;
        if (sigmaT > 0.0) {
            float xi = hash21(gl_FragCoord.xy + vec2(float(iFrame) * 1.11 + seedOffset, float(bounce) * 41.0 + lambda * 0.009));
            float mediumDist = -log(max(1.0 - xi, 0.000001)) / sigmaT;
            if (mediumDist < surfaceDist) {
                float phase = TWO_PI * (mediumDist * SCENE_PHASE_SCALE) / max(lambda, 1.0);
                vec2 phaseTerm = vec2(cos(phase), sin(phase));
                state = fieldScale(state, sqrt(max(exp(-sigmaT * mediumDist) * (sigmaS / max(sigmaT, 0.0001)), 0.0)));
                state = fieldMul(state, phaseTerm, phaseTerm);

                vec3 mediumPos = ro + rd * mediumDist;
                accum = fieldAdd(accum, coherentMediumDirect(state, mediumPos, rd, lambda, g, bounce, seedOffset));

                vec2 phaseSeed = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 2.71 + seedOffset, float(bounce) * 17.0 + 23.0));
                vec2 randomPhase = vec2(cos(TWO_PI * phaseSeed.y), sin(TWO_PI * phaseSeed.y));
                state = fieldMul(state, randomPhase, randomPhase);
                rd = samplePhaseDirection(rd, g, phaseSeed);
                ro = mediumPos + rd * RAY_BIAS;
                traceMode = 0;
                continue;
            } else {
                float phase = TWO_PI * (surfaceDist * SCENE_PHASE_SCALE) / max(lambda, 1.0);
                vec2 phaseTerm = vec2(cos(phase), sin(phase));
                state = fieldScale(state, sqrt(max(exp(-sigmaT * surfaceDist), 0.0)));
                state = fieldMul(state, phaseTerm, phaseTerm);
            }
        } else if (surfaceDist < MAX_TRACE_DIST) {
            float phase = TWO_PI * (surfaceDist * SCENE_PHASE_SCALE) / max(lambda, 1.0);
            vec2 phaseTerm = vec2(cos(phase), sin(phase));
            state = fieldMul(state, phaseTerm, phaseTerm);
        }

        if (hit.kind == HIT_NONE) break;

        Material mat = getMaterial(hit.mat);
        vec3 geomNormal = normalize(hit.normal);
        vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
        vec3 viewDir = normalize(-rd);
        accum = fieldAdd(accum, coherentSurfaceDirect(state, hit.pos, shadingNormal, viewDir, mat, hit.mat, lambda, bounce, seedOffset));

        vec2 uChoice = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 0.49 + seedOffset, float(bounce) * 31.0 + lambda * 0.023));
        vec2 uDir = hash22(gl_FragCoord.xy + vec2(float(iFrame) * 1.89 + seedOffset * 3.0, float(bounce) * 37.0 + lambda * 0.017));
        SpectralBsdfSample bs = sampleSurfaceBsdfSpectral(shadingNormal, geomNormal, viewDir, mat, hit.mat, lambda, uChoice, uDir);
        if (bs.weight <= 0.0 || bs.pdf <= 0.0) break;

        state = fieldScale(state, sqrt(max(bs.weight, 0.0)));
        state = fieldMul(state, bs.ampS, bs.ampP);
        ro = hit.pos + ((dot(bs.wi, shadingNormal) >= 0.0) ? shadingNormal : -shadingNormal) * RAY_BIAS;
        rd = normalize(bs.wi);
        traceMode = bs.nextTraceMode;

        if (bounce >= 2) {
            float rr = hash21(gl_FragCoord.xy + vec2(float(iFrame) * 5.07 + seedOffset, float(bounce) * 43.0 + lambda * 0.007));
            float p = clamp(sqrt(max(bs.weight, 0.0)), 0.05, 0.98);
            if (rr > p) break;
            state = fieldScale(state, 1.0 / p);
        }
    }

    return accum;
}

float coherentFieldIntensity(CoherentField a, CoherentField b) {
    return max(complexDotReal(a.s, b.s) + complexDotReal(a.p, b.p), 0.0);
}

float sampledWavelengthForLane(int lane, int laneCount, float salt) {
    float jitter = hash21(gl_FragCoord.xy + vec2(float(iFrame) * 0.61803 + salt, float(lane) * 17.173 + salt * 0.37));
    return mix(LAMBDA_MIN, LAMBDA_MAX, (float(lane) + jitter) / float(laneCount));
}

vec3 renderSpectralImage(vec3 ro, vec3 rd, int mode) {
    vec3 rgb = vec3(0.0);
    int laneCount = (mode == 2) ? 8 : 10;

    for (int lane = 0; lane < MAX_SPECTRAL_LANES; ++lane) {
        if (lane >= laneCount) break;

        float lambda = sampledWavelengthForLane(lane, laneCount, float(mode) * 11.0);
        float spectralValue = (mode == 2)
            ? traceSpectralRaySingle(ro, rd, lambda)
            : traceSpectralPathSingle(ro, rd, lambda, (mode == 4) ? 0 : 1);

        if (mode == 4) {
            CoherentField a = zeroField();
            CoherentField b = zeroField();
            for (int i = 0; i < COHERENT_FIELD_SPP; ++i) {
                a = fieldAdd(a, traceCoherentFieldEstimate(ro, rd, lambda, 17.0 + float(i) * 3.0));
                b = fieldAdd(b, traceCoherentFieldEstimate(ro, rd, lambda, 53.0 + float(i) * 5.0));
            }
            spectralValue += coherentFieldIntensity(fieldScale(a, 1.0 / float(COHERENT_FIELD_SPP)), fieldScale(b, 1.0 / float(COHERENT_FIELD_SPP)));
        }

        rgb += spectrumContributionToRGB(lambda, spectralValue) / float(laneCount);
    }

    if (mode >= 3) {
        rgb *= PATH_MODE_DISPLAY_EXPOSURE;
    }

    return rgb;
}

vec3 raytrace(vec3 ro, vec3 rd) {
    if (uTracingMode == 0) return traceRGBPreview(ro, rd);
    if (uTracingMode == 1) return traceRGBRay(ro, rd);
    if (uTracingMode == 2) return renderSpectralImage(ro, rd, 2);
    if (uTracingMode == 4) return renderSpectralImage(ro, rd, 4);
    return renderSpectralImage(ro, rd, 3);
}

vec4 effect(vec4 color, Image prevFrame, vec2 uv, vec2 fragCoord) {
    if (uPassType == 0) {
        return vec4(0.0);
    }

    vec3 prev = Texel(tex, uv).rgb;
    vec3 newColor = raytrace(camPos, getRay(fragCoord));

    if (iFrame == 0) {
        return vec4(newColor, 1.0);
    }

    float blend = 1.0 / float(iFrame + 1);
    vec3 result = mix(prev, newColor, blend);
    return vec4(result, 1.0);
}
