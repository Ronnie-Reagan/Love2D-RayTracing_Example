extern vec2 iResolution;
extern vec3 camPos;
extern float yaw;
extern float pitch;
extern float camFov;
extern vec3 prevCamPos;
extern float prevYaw;
extern float prevPitch;
extern float prevCamFov;
extern int iFrame;
extern int uPassType;
uniform Image tex;
uniform Image radianceCache;

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
const float INV_PI = 0.31830988618;
const int HARD_MAX_STEPS = 999 * 999;
const int HARD_MAX_BOUNCES = 999 * 999;
const int lightCount = 3;

const float HIT_EPS = 0.0015;
const float NORMAL_EPS = 0.0025;
const float RAY_BIAS = 0.02;
const float SHADOW_BIAS = 0.02;
const float SHADOW_MIN_STEP = 0.01;
const float MARCH_MIN_STEP = 0.001;
const float MAX_TRACE_DIST = 600.0;
const float LIGHT_RADIUS = 0.16;
const float RADIANCE_CACHE_HISTORY = 128.0;
const float LAMBDA_MIN = 400.0;
const float LAMBDA_MAX = 700.0;
const int RADIANCE_CACHE_SPP = 2;
const float REPROJECT_NORMAL_DOT_MIN = 0.965;

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

float heroWavelength(vec2 seed) {
    return mix(LAMBDA_MIN, LAMBDA_MAX, hash21(seed));
}

vec3 wavelengthToDisplayRGB(float lambda) {
    float r = 0.0;
    float g = 0.0;
    float b = 0.0;

    if (lambda < 440.0) {
        r = -(lambda - 440.0) / 60.0;
        b = 1.0;
    } else if (lambda < 490.0) {
        g = (lambda - 440.0) / 50.0;
        b = 1.0;
    } else if (lambda < 510.0) {
        g = 1.0;
        b = -(lambda - 510.0) / 20.0;
    } else if (lambda < 580.0) {
        r = (lambda - 510.0) / 70.0;
        g = 1.0;
    } else if (lambda < 645.0) {
        r = 1.0;
        g = -(lambda - 645.0) / 65.0;
    } else {
        r = 1.0;
    }

    float intensity = 1.0;
    if (lambda < 420.0) {
        intensity = 0.35 + 0.65 * (lambda - LAMBDA_MIN) / 20.0;
    } else if (lambda > 680.0) {
        intensity = 0.35 + 0.65 * (LAMBDA_MAX - lambda) / 20.0;
    }

    return saturate(vec3(r, g, b) * intensity);
}

vec3 spectralInputBasis(float lambda) {
    vec3 basis = vec3(
        gaussian(lambda, 615.0, 42.0) + 0.35 * gaussian(lambda, 690.0, 54.0),
        gaussian(lambda, 545.0, 36.0),
        gaussian(lambda, 460.0, 24.0) + 0.22 * gaussian(lambda, 420.0, 18.0)
    );
    float sum = basis.r + basis.g + basis.b;
    return (sum <= 0.000001) ? vec3(0.3333333) : basis / sum;
}

float sampleSpectrum(vec3 rgb, float lambda) {
    return max(dot(max(rgb, vec3(0.0)), spectralInputBasis(lambda)), 0.0);
}

vec3 spectralToRGB(float lambda, float value) {
    return wavelengthToDisplayRGB(lambda) * value * 2.35;
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

float materialSpecularF0(Material mat, float spectralAlbedo, float lambda) {
    float dielectric = dielectricF0(wavelengthIor(mat, lambda)) * mix(0.5, 1.5, mat.specular);
    dielectric = clamp(dielectric, 0.0, 0.98);
    return mix(dielectric, spectralAlbedo, mat.metallic);
}

float transmissionTint(Material mat, float lambda) {
    return mix(1.0, sampleSpectrum(mat.transmissionColor, lambda), clamp(mat.transmission, 0.0, 1.0));
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

float environmentSpectrum(vec3 rd, float lambda) {
    float t = 0.5 * (rd.y + 1.0);
    vec3 sky = mix(vec3(0.03, 0.035, 0.05), vec3(0.10, 0.12, 0.16), t);
    return sampleSpectrum(sky, lambda);
}

float directLighting(vec3 pos, vec3 normal, vec3 viewDir, Material mat, float lambda) {
    float accum = 0.0;
    float spectralAlbedo = sampleSpectrum(mat.albedo, lambda);
    float diffuseWeight = (1.0 - mat.transmission) * (1.0 - mat.metallic);

    for (int i = 0; i < lightCount; ++i) {
        vec3 lightPos = getLightPos(i);
        vec3 toLight = lightPos - pos;
        float lightDist = length(toLight);
        vec3 lightDir = toLight / max(lightDist, 0.0001);

        float nDotL = max(dot(normal, lightDir), 0.0);
        if (nDotL <= 0.0) continue;

        float visibility = 1.0;
        if (uEnableShadows != 0) {
            float shadowMaxDist = max(0.0, lightDist - LIGHT_RADIUS - 0.03);
            visibility = shadowTrace(pos + normal * SHADOW_BIAS, lightDir, shadowMaxDist);
        }

        vec3 h = normalize(viewDir + lightDir);
        float NdotV = max(dot(normal, viewDir), 0.0);
        float NdotH = max(dot(normal, h), 0.0);
        float VdotH = max(dot(viewDir, h), 0.0);

        float F0 = materialSpecularF0(mat, spectralAlbedo, lambda);
        float F = fresnelSchlick1(VdotH, F0);
        float alpha = max(0.03, mat.roughness * mat.roughness);
        float D = D_GGX(NdotH, alpha);
        float G = G_Smith(NdotV, nDotL, mat.roughness);

        float spec = (D * G * F) / max(4.0 * NdotV * nDotL, 0.0001);

        float coatSpec = 0.0;
        if (mat.clearcoat > 0.0001) {
            float coatAlpha = max(0.02, mat.clearcoatRoughness * mat.clearcoatRoughness);
            float coatD = D_GGX(NdotH, coatAlpha);
            float coatG = G_Smith(NdotV, nDotL, mat.clearcoatRoughness);
            float coatF = fresnelSchlick1(VdotH, 0.04);
            coatSpec = mat.clearcoat * (coatD * coatG * coatF) / max(4.0 * NdotV * nDotL, 0.0001);
        }

        float kd = (1.0 - F) * diffuseWeight;
        float diff = kd * spectralAlbedo * INV_PI;

        float Li = sampleSpectrum(getLightColor(i), lambda) / (lightDist * lightDist + 1.0);
        accum += (diff + spec + coatSpec) * Li * nDotL * visibility;
    }

    return accum;
}

float traceSpectralTransport(vec3 ro, vec3 rd, float lambda, int traceMode, int startBounce, float throughput) {
    float accum = 0.0;

    for (int bounce = startBounce; bounce < HARD_MAX_BOUNCES; ++bounce) {
        if (bounce >= uMaxBounces) break;

        vec3 pos, normal;
        Hit h = march(ro, rd, pos, normal, traceMode);

        if (h.mat < 0) {
            accum += throughput * environmentSpectrum(rd, lambda);
            break;
        }

        Material mat = getMaterial(h.mat);
        float emission = sampleSpectrum(mat.emission, lambda);

        if (emission > 0.00001) {
            accum += throughput * emission * 0.25;
            break;
        }

        vec3 geomNormal = normalize(normal);
        vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
        vec3 viewDir = normalize(-rd);
        accum += throughput * directLighting(pos, shadingNormal, viewDir, mat, lambda);

        vec2 baseSeed = gl_FragCoord.xy
            + vec2(float(iFrame) * 0.61803, float(bounce) * 17.173)
            + vec2(lambda * 0.011, lambda * 0.007);
        vec2 r0 = hash22(baseSeed + vec2(13.3, 7.7));
        vec2 r1 = hash22(baseSeed + vec2(91.1, 47.2));

        float spectralAlbedo = sampleSpectrum(mat.albedo, lambda);
        float cosNV = max(dot(shadingNormal, viewDir), 0.0);
        float F0 = materialSpecularF0(mat, spectralAlbedo, lambda);
        float F = fresnelSchlick1(cosNV, F0);
        float reflectBias = clamp(mat.clearcoat * 0.08, 0.0, 0.18);
        float specChance = clamp(F + reflectBias, 0.02, 0.95);
        float transmissionBase = clamp(mat.transmission * (1.0 - mat.metallic), 0.0, 0.98);
        float transmitChance = clamp((1.0 - specChance) * transmissionBase, 0.0, 0.95 - specChance);
        float diffuseChance = max(1.0 - specChance - transmitChance, 0.0);

        if (r0.x < specChance || (transmitChance <= 0.00001 && diffuseChance <= 0.00001)) {
            vec3 perfect = reflect(rd, shadingNormal);
            float gloss = mix(mat.roughness, mat.clearcoatRoughness, clamp(mat.clearcoat, 0.0, 1.0));
            rd = sampleAroundDirection(perfect, shadingNormal, r1, max(0.02, gloss));
            throughput *= (F + reflectBias) / max(specChance, 0.001);
            traceMode = 1;
            ro = pos + shadingNormal * RAY_BIAS;
        } else if (r0.x < specChance + transmitChance && transmitChance > 0.00001) {
            vec3 refractedDir;
            if (refractRay(rd, geomNormal, mat, lambda, refractedDir)) {
                rd = normalize(refractedDir);
                throughput *= ((1.0 - F) * transmissionBase * transmissionTint(mat, lambda)) / max(transmitChance, 0.001);
                traceMode = 0;
                ro = pos + rd * (RAY_BIAS * 2.0);
            } else {
                vec3 perfect = reflect(rd, shadingNormal);
                rd = sampleAroundDirection(perfect, shadingNormal, r1, max(0.02, mat.roughness));
                traceMode = 1;
                ro = pos + shadingNormal * RAY_BIAS;
            }
        } else if (diffuseChance > 0.00001) {
            rd = cosineSampleHemisphere(shadingNormal, r1);
            float kd = (1.0 - F) * (1.0 - mat.metallic) * (1.0 - mat.transmission);
            throughput *= (kd * spectralAlbedo) / max(diffuseChance, 0.001);
            traceMode = 0;
            ro = pos + shadingNormal * RAY_BIAS;
        } else {
            break;
        }

        if (throughput > 12.0) throughput = 12.0;

        float p = clamp(throughput, 0.05, 0.98);
        if (bounce >= 2) {
            float rr = hash21(gl_FragCoord.xy + vec2(float(iFrame) * 3.1, float(bounce) * 19.7 + lambda * 0.013));
            if (rr > p) break;
            throughput /= p;
        }
    }

    return accum;
}

vec4 renderRadianceCache(vec2 fragCoord) {
    if (uTracingMode != 3 && uTracingMode != 4) {
        return vec4(0.0);
    }

    vec3 ro = camPos;
    vec3 rd = getRay(fragCoord);

    vec3 pos, normal;
    Hit h = march(ro, rd, pos, normal, 0);
    if (h.mat < 0) {
        return vec4(0.0);
    }

    Material mat = getMaterial(h.mat);
    if (max(max(mat.emission.r, mat.emission.g), mat.emission.b) > 0.00001 || mat.transmission > 0.02) {
        return vec4(0.0);
    }

    vec3 geomNormal = normalize(normal);
    vec3 shadingNormal = orientNormalToRay(geomNormal, rd);

    vec3 prevRadiance = vec3(0.0);
    float prevSamples = 0.0;
    vec2 prevUV;
    if (reprojectSurfaceToCamera(pos, geomNormal, h.mat, prevCamPos, prevYaw, prevPitch, prevCamFov, prevUV)) {
        vec4 prev = Texel(tex, prevUV);
        if (prev.a > 0.0) {
            prevRadiance = prev.rgb;
            prevSamples = prev.a * RADIANCE_CACHE_HISTORY;
        }
    }

    vec3 sampleColor = vec3(0.0);
    float validSampleCount = 0.0;

    for (int cacheSample = 0; cacheSample < RADIANCE_CACHE_SPP; ++cacheSample) {
        float cacheIndex = float(cacheSample);
        float lambda = heroWavelength(
            gl_FragCoord.xy
            + vec2(float(iFrame) * 0.731 + cacheIndex * 19.73, 19.7 + cacheIndex * 11.17)
        );
        float diffuseWeight = sampleSpectrum(mat.albedo, lambda) * (1.0 - mat.metallic) * (1.0 - mat.transmission);
        if (diffuseWeight <= 0.00001) {
            continue;
        }

        vec2 seed = gl_FragCoord.xy
            + vec2(float(iFrame) * 0.61803 + cacheIndex * 23.0, 97.2 + cacheIndex * 31.0)
            + vec2(lambda * 0.019, lambda * 0.023);
        vec2 r1 = hash22(seed + vec2(61.2, 13.4));
        vec3 diffuseDir = cosineSampleHemisphere(shadingNormal, r1);
        float indirect = traceSpectralTransport(pos + shadingNormal * RAY_BIAS, diffuseDir, lambda, 0, 1, diffuseWeight);
        sampleColor += spectralToRGB(lambda, indirect);
        validSampleCount += 1.0;
    }

    if (validSampleCount <= 0.0) {
        return vec4(0.0);
    }

    sampleColor /= validSampleCount;
    float newSamples = min(prevSamples + 1.0, RADIANCE_CACHE_HISTORY);
    float blend = 1.0 / max(newSamples, 1.0);
    vec3 cacheColor = mix(prevRadiance, sampleColor, blend);
    return vec4(cacheColor, newSamples / RADIANCE_CACHE_HISTORY);
}

vec3 raytraceSpectralPath(vec3 ro, vec3 rd) {
    float lambda = heroWavelength(gl_FragCoord.xy + vec2(float(iFrame) * 0.61803, 3.17));
    float accumSpectral = 0.0;
    float throughput = 1.0;
    int traceMode = 0;

    for (int bounce = 0; bounce < HARD_MAX_BOUNCES; ++bounce) {
        if (bounce >= uMaxBounces) break;

        vec3 pos, normal;
        Hit h = march(ro, rd, pos, normal, traceMode);

        if (h.mat < 0) {
            accumSpectral += throughput * environmentSpectrum(rd, lambda);
            break;
        }

        Material mat = getMaterial(h.mat);
        float emission = sampleSpectrum(mat.emission, lambda);

        if (emission > 0.00001) {
            accumSpectral += throughput * emission * 0.25;
            break;
        }

        vec3 geomNormal = normalize(normal);
        vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
        vec3 viewDir = normalize(-rd);
        accumSpectral += throughput * directLighting(pos, shadingNormal, viewDir, mat, lambda);

        vec2 baseSeed = gl_FragCoord.xy
            + vec2(float(iFrame) * 0.61803, float(bounce) * 17.173)
            + vec2(lambda * 0.011, lambda * 0.007);
        vec2 r0 = hash22(baseSeed + vec2(13.3, 7.7));
        vec2 r1 = hash22(baseSeed + vec2(91.1, 47.2));

        float spectralAlbedo = sampleSpectrum(mat.albedo, lambda);
        float cosNV = max(dot(shadingNormal, viewDir), 0.0);
        float F0 = materialSpecularF0(mat, spectralAlbedo, lambda);
        float F = fresnelSchlick1(cosNV, F0);
        float reflectBias = clamp(mat.clearcoat * 0.08, 0.0, 0.18);
        float specChance = (uEnableReflections != 0) ? clamp(F + reflectBias, 0.02, 0.95) : 0.0;
        float transmissionBase = clamp(mat.transmission * (1.0 - mat.metallic), 0.0, 0.98);
        float transmitChance = clamp((1.0 - specChance) * transmissionBase, 0.0, 0.95 - specChance);
        float diffuseChance = max(1.0 - specChance - transmitChance, 0.0);

        if (r0.x < specChance || (transmitChance <= 0.00001 && diffuseChance <= 0.00001)) {
            vec3 perfect = reflect(rd, shadingNormal);
            float gloss = mix(mat.roughness, mat.clearcoatRoughness, clamp(mat.clearcoat, 0.0, 1.0));
            rd = sampleAroundDirection(perfect, shadingNormal, r1, max(0.02, gloss));
            throughput *= (F + reflectBias) / max(specChance, 0.001);
            traceMode = 1;
            ro = pos + shadingNormal * RAY_BIAS;
        } else if (r0.x < specChance + transmitChance && transmitChance > 0.00001) {
            vec3 refractedDir;
            if (refractRay(rd, geomNormal, mat, lambda, refractedDir)) {
                rd = normalize(refractedDir);
                throughput *= ((1.0 - F) * transmissionBase * transmissionTint(mat, lambda)) / max(transmitChance, 0.001);
                traceMode = 0;
                ro = pos + rd * (RAY_BIAS * 2.0);
            } else {
                vec3 perfect = reflect(rd, shadingNormal);
                rd = sampleAroundDirection(perfect, shadingNormal, r1, max(0.02, mat.roughness));
                traceMode = 1;
                ro = pos + shadingNormal * RAY_BIAS;
            }
        } else if (diffuseChance > 0.00001) {
            float kd = (1.0 - F) * (1.0 - mat.metallic) * (1.0 - mat.transmission);
            vec2 cacheUV;
            if (
                mat.transmission < 0.02 &&
                (kd * spectralAlbedo) > 0.00001 &&
                projectToScreenUV(pos, camPos, yaw, pitch, camFov, cacheUV)
            ) {
                vec4 cacheTexel = Texel(radianceCache, cacheUV);
                if (cacheTexel.a > 0.0) {
                    accumSpectral += throughput * sampleSpectrum(cacheTexel.rgb, lambda) / max(diffuseChance, 0.001);
                    break;
                }
            }

            rd = cosineSampleHemisphere(shadingNormal, r1);
            throughput *= (kd * spectralAlbedo) / max(diffuseChance, 0.001);
            traceMode = 0;
            ro = pos + shadingNormal * RAY_BIAS;
        } else {
            break;
        }

        if (throughput > 12.0) throughput = 12.0;

        float p = clamp(throughput, 0.05, 0.98);
        if (bounce >= 2) {
            float rr = hash21(gl_FragCoord.xy + vec2(float(iFrame) * 3.1, float(bounce) * 19.7 + lambda * 0.013));
            if (rr > p) break;
            throughput /= p;
        }
    }

    return spectralToRGB(lambda, accumSpectral);
}

vec3 environmentRGB(vec3 rd) {
    float t = 0.5 * (rd.y + 1.0);
    return mix(vec3(0.03, 0.035, 0.05), vec3(0.10, 0.12, 0.16), t);
}

vec3 directLightingRGB(vec3 pos, vec3 normal, vec3 viewDir, Material mat) {
    vec3 accum = vec3(0.0);
    vec3 albedo = saturate(mat.albedo);
    float diffuseWeight = (1.0 - mat.transmission) * (1.0 - mat.metallic);
    float dielectric = dielectricF0(mat.ior) * mix(0.5, 1.5, mat.specular);
    dielectric = clamp(dielectric, 0.0, 0.98);

    for (int i = 0; i < lightCount; ++i) {
        vec3 lightPos = getLightPos(i);
        vec3 toLight = lightPos - pos;
        float lightDist = length(toLight);
        vec3 lightDir = toLight / max(lightDist, 0.0001);

        float nDotL = max(dot(normal, lightDir), 0.0);
        if (nDotL <= 0.0) continue;

        float visibility = 1.0;
        if (uEnableShadows != 0) {
            float shadowMaxDist = max(0.0, lightDist - LIGHT_RADIUS - 0.03);
            visibility = shadowTrace(pos + normal * SHADOW_BIAS, lightDir, shadowMaxDist);
        }

        vec3 h = normalize(viewDir + lightDir);
        float NdotV = max(dot(normal, viewDir), 0.0);
        float NdotH = max(dot(normal, h), 0.0);
        float VdotH = max(dot(viewDir, h), 0.0);
        float F = fresnelSchlick1(VdotH, mix(dielectric, 0.92, mat.metallic));
        float alpha = max(0.03, mat.roughness * mat.roughness);
        float D = D_GGX(NdotH, alpha);
        float G = G_Smith(NdotV, nDotL, mat.roughness);
        float spec = (D * G * F) / max(4.0 * NdotV * nDotL, 0.0001);

        vec3 diff = ((1.0 - F) * diffuseWeight) * albedo * INV_PI;
        vec3 Li = getLightColor(i) / (lightDist * lightDist + 1.0);
        accum += (diff + vec3(spec)) * Li * nDotL * visibility;
    }

    return accum;
}

vec3 traceRGBPreview(vec3 ro, vec3 rd) {
    vec3 pos, normal;
    Hit h = march(ro, rd, pos, normal, 0);
    if (h.mat < 0) {
        return environmentRGB(rd);
    }

    Material mat = getMaterial(h.mat);
    vec3 geomNormal = normalize(normal);
    vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
    vec3 viewDir = normalize(-rd);

    vec3 color = mat.emission * 0.25;
    color += directLightingRGB(pos, shadingNormal, viewDir, mat);
    color += mat.albedo * 0.025;
    return color;
}

vec3 traceRGBRay(vec3 ro, vec3 rd) {
    vec3 accum = vec3(0.0);
    vec3 throughput = vec3(1.0);
    int traceMode = 0;

    for (int bounce = 0; bounce < 2; ++bounce) {
        if (bounce >= uMaxBounces) break;

        vec3 pos, normal;
        Hit h = march(ro, rd, pos, normal, traceMode);
        if (h.mat < 0) {
            accum += throughput * environmentRGB(rd);
            break;
        }

        Material mat = getMaterial(h.mat);
        vec3 geomNormal = normalize(normal);
        vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
        vec3 viewDir = normalize(-rd);

        accum += throughput * (mat.emission * 0.25 + directLightingRGB(pos, shadingNormal, viewDir, mat));

        float dielectric = dielectricF0(mat.ior) * mix(0.5, 1.5, mat.specular);
        float cosNV = max(dot(shadingNormal, viewDir), 0.0);
        float F = fresnelSchlick1(cosNV, clamp(mix(dielectric, 0.92, mat.metallic), 0.0, 0.98));
        float transmissionBase = clamp(mat.transmission * (1.0 - mat.metallic), 0.0, 0.98);

        if (uEnableReflections == 0 || bounce >= 1) {
            break;
        }

        if (transmissionBase > F && transmissionBase > 0.02) {
            vec3 refractedDir;
            if (refractRay(rd, geomNormal, mat, 550.0, refractedDir)) {
                throughput *= mix(vec3(1.0), mat.transmissionColor, transmissionBase);
                rd = normalize(refractedDir);
                ro = pos + rd * (RAY_BIAS * 2.0);
                traceMode = 0;
                continue;
            }
        }

        if (F > 0.02) {
            rd = reflect(rd, shadingNormal);
            ro = pos + shadingNormal * RAY_BIAS;
            throughput *= vec3(F);
            traceMode = 1;
            continue;
        }

        break;
    }

    return accum;
}

vec3 traceSpectralRay(vec3 ro, vec3 rd) {
    float lambda = heroWavelength(gl_FragCoord.xy + vec2(float(iFrame) * 0.61803, 3.17));
    float accumSpectral = 0.0;
    float throughput = 1.0;
    int traceMode = 0;

    for (int bounce = 0; bounce < 2; ++bounce) {
        if (bounce >= uMaxBounces) break;

        vec3 pos, normal;
        Hit h = march(ro, rd, pos, normal, traceMode);
        if (h.mat < 0) {
            accumSpectral += throughput * environmentSpectrum(rd, lambda);
            break;
        }

        Material mat = getMaterial(h.mat);
        vec3 geomNormal = normalize(normal);
        vec3 shadingNormal = orientNormalToRay(geomNormal, rd);
        vec3 viewDir = normalize(-rd);
        accumSpectral += throughput * (sampleSpectrum(mat.emission, lambda) * 0.25 + directLighting(pos, shadingNormal, viewDir, mat, lambda));

        if (uEnableReflections == 0 || bounce >= 1) {
            break;
        }

        float spectralAlbedo = sampleSpectrum(mat.albedo, lambda);
        float cosNV = max(dot(shadingNormal, viewDir), 0.0);
        float F = fresnelSchlick1(cosNV, materialSpecularF0(mat, spectralAlbedo, lambda));
        float transmissionBase = clamp(mat.transmission * (1.0 - mat.metallic), 0.0, 0.98);

        if (transmissionBase > F && transmissionBase > 0.02) {
            vec3 refractedDir;
            if (refractRay(rd, geomNormal, mat, lambda, refractedDir)) {
                throughput *= transmissionTint(mat, lambda);
                rd = normalize(refractedDir);
                ro = pos + rd * (RAY_BIAS * 2.0);
                traceMode = 0;
                continue;
            }
        }

        if (F > 0.02) {
            rd = reflect(rd, shadingNormal);
            ro = pos + shadingNormal * RAY_BIAS;
            throughput *= F;
            traceMode = 1;
            continue;
        }

        break;
    }

    return spectralToRGB(lambda, accumSpectral);
}

vec3 traceWaveOptics(vec3 ro, vec3 rd) {
    vec3 base = raytraceSpectralPath(ro, rd);
    vec3 pos, normal;
    Hit h = march(ro, rd, pos, normal, 0);
    if (h.mat < 0) {
        return base;
    }

    Material mat = getMaterial(h.mat);
    float coherence = clamp((1.0 - mat.roughness) * (0.45 + mat.transmission * 0.55), 0.0, 1.0);
    float phase = length(pos - ro) * 180.0;
    vec3 fringe = 0.5 + 0.5 * cos(vec3(phase, phase * 1.11 + 2.094, phase * 1.23 + 4.188));
    return mix(base, base * (0.65 + 0.75 * fringe), 0.45 * coherence);
}

vec3 raytrace(vec3 ro, vec3 rd) {
    if (uTracingMode == 0) {
        return traceRGBPreview(ro, rd);
    }
    if (uTracingMode == 1) {
        return traceRGBRay(ro, rd);
    }
    if (uTracingMode == 2) {
        return traceSpectralRay(ro, rd);
    }
    if (uTracingMode == 4) {
        return traceWaveOptics(ro, rd);
    }
    return raytraceSpectralPath(ro, rd);
}

vec4 effect(vec4 color, Image prevFrame, vec2 uv, vec2 fragCoord) {
    if (uPassType == 0) {
        return renderRadianceCache(fragCoord);
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
