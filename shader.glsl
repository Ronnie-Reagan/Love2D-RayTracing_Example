extern vec2 iResolution;
extern vec3 camPos;
extern float yaw;
extern float pitch;
extern int iFrame;
uniform Image tex;

extern int uMaxBounces;
extern int uMaxSteps;
extern int uEnableShadows;
extern int uEnableReflections;
extern int uSceneVariant;
extern int uMeshTriCount;
extern vec2 uMeshTexSize;
uniform Image meshVerts;
uniform Image meshNormals;
uniform Image meshMatA;
uniform Image meshMatB;

const int HARD_MAX_MESH_TRIS = 8192;
const int IMPORTED_MAT_ID = 1000;

vec4 gImportedMatA = vec4(0.8, 0.8, 0.8, 1.0); // rgb = albedo, a = roughness
vec4 gImportedMatB = vec4(0.0, 0.0, 0.0, 0.0); // rgb = emission, a = metallic

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

struct Hit {
    float dist;
    int mat;
};

struct Material {
    vec3 albedo;
    vec3 emission;
    float metallic;
    float roughness;
};

vec3 saturate(vec3 v) {
    return clamp(v, vec3(0.0), vec3(1.0));
}

float saturate1(float v) {
    return clamp(v, 0.0, 1.0);
}

vec3 getRay(vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution) / iResolution.y;
    float cp = cos(pitch), sp = sin(pitch), cy = cos(yaw), sy = sin(yaw);
    vec3 forward = vec3(cp * sy, sp, cp * cy);
    vec3 right = vec3(cy, 0.0, -sy);
    vec3 up = cross(right, forward);
    return normalize(forward + uv.x * right + uv.y * up);
}

float hash11(float p) {
    return fract(sin(p * 127.1) * 43758.5453123);
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

Material getMaterial(int mat) {
    Material m;
    m.albedo = vec3(0.8);
    m.emission = vec3(0.0);
    m.metallic = 0.0;
    m.roughness = 1.0;

    if (mat == IMPORTED_MAT_ID) {
        m.albedo = saturate(gImportedMatA.rgb);
        m.emission = max(gImportedMatB.rgb, vec3(0.0));
        m.metallic = clamp(gImportedMatB.a, 0.0, 1.0);
        m.roughness = clamp(gImportedMatA.a, 0.02, 1.0);
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
        m.albedo = vec3(0.03, 0.035, 0.04);
        m.metallic = 0.0;
        m.roughness = 0.03;
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
        if (i == 1) return vec3( 0.0, 4.2, -5.0);
        return vec3(2.8, 3.8, -2.0);
    }

    if (uSceneVariant == 2) {
        if (i == 0) return vec3(-10.5, 6.0, -8.0);
        if (i == 1) return vec3(  0.0, 6.8, -17.0);
        return vec3(10.5, 6.0, -8.0);
    }

    if (uSceneVariant == 1) {
        if (i == 0) return vec3(-2.4, 2.0, -2.2);
        if (i == 1) return vec3( 0.0, 2.7, -5.3);
        return vec3(2.4, 2.0, -2.2);
    }

    if (i == 0) return vec3(-1.8, 2.0, -2.2);
    if (i == 1) return vec3( 0.0, 2.4, -4.4);
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
    float cp = cos(pitch);
    float sp = sin(pitch);
    float cy = cos(yaw);
    float sy = sin(yaw);

    forward = normalize(vec3(cp * sy, sp, cp * cy));
    right   = normalize(vec3(cy, 0.0, -sy));
    up      = normalize(cross(right, forward));
}

vec3 toViewCameraLocal(vec3 p) {
    vec3 forward, right, up;
    getCameraBasis(forward, right, up);

    vec3 d = p - camPos;
    return vec3(
        dot(d, right),
        dot(d, up),
        dot(d, forward)
    );
}

vec2 getMeshVertexUV(int col, int row) {
    return vec2(
        (float(col) + 0.5) / uMeshTexSize.x,
        (float(row) + 0.5) / uMeshTexSize.y
    );
}

vec2 getMeshMaterialUV(int row) {
    return vec2(
        0.5,
        (float(row) + 0.5) / uMeshTexSize.y
    );
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
    if (dot(faceNormal, rd) > 0.0) {
        faceNormal = -faceNormal;
    }

    return true;
}

Hit traceImportedMesh(vec3 ro, vec3 rd, out vec3 pos, out vec3 normal) {
    float bestT = 1e20;
    int bestMat = -1;
    vec3 bestNormal = vec3(0.0);
    vec4 bestMatA = vec4(0.8, 0.8, 0.8, 1.0);
    vec4 bestMatB = vec4(0.0);

    for (int i = 0; i < HARD_MAX_MESH_TRIS; ++i) {
        if (i >= uMeshTriCount) break;

        vec3 v0 = readMeshPosTexel(0, i).xyz;
        vec3 v1 = readMeshPosTexel(1, i).xyz;
        vec3 v2 = readMeshPosTexel(2, i).xyz;

        vec3 n0 = readMeshNormalTexel(0, i).xyz;
        vec3 n1 = readMeshNormalTexel(1, i).xyz;
        vec3 n2 = readMeshNormalTexel(2, i).xyz;

        float t;
        vec3 bary;
        vec3 faceNormal;

        if (intersectTriangle(ro, rd, v0, v1, v2, t, bary, faceNormal)) {
            if (t < bestT) {
                bestT = t;

                vec3 interpNormal = normalize(
                    n0 * bary.x +
                    n1 * bary.y +
                    n2 * bary.z
                );

                if (length(interpNormal) < 0.0001) {
                    interpNormal = faceNormal;
                }

                if (dot(interpNormal, rd) > 0.0) {
                    interpNormal = -interpNormal;
                }

                bestNormal = interpNormal;
                bestMatA = readMeshMaterialATexel(i);
                bestMatB = readMeshMaterialBTexel(i);
                bestMat = IMPORTED_MAT_ID;
            }
        }
    }

    if (bestMat >= 0) {
        gImportedMatA = bestMatA;
        gImportedMatB = bestMatB;
        pos = ro + rd * bestT;
        normal = bestNormal;
        return Hit(bestT, bestMat);
    }

    pos = ro + rd * MAX_TRACE_DIST;
    normal = vec3(0.0);
    return Hit(1e5, -1);
}

float shadowTraceImportedMesh(vec3 ro, vec3 rd, float maxDist) {
    for (int i = 0; i < HARD_MAX_MESH_TRIS; ++i) {
        if (i >= uMeshTriCount) break;

        vec3 v0 = readMeshPosTexel(0, i).xyz;
        vec3 v1 = readMeshPosTexel(1, i).xyz;
        vec3 v2 = readMeshPosTexel(2, i).xyz;

        float t;
        vec3 bary;
        vec3 faceNormal;

        if (intersectTriangle(ro, rd, v0, v1, v2, t, bary, faceNormal)) {
            if (t < maxDist) {
                return 0.0;
            }
        }
    }

    return 1.0;
}

Hit mapReflectionCamera(vec3 p) {
    vec3 q = toViewCameraLocal(p);

    // Put most of the body slightly behind the actual eye/lens point.
    float body       = sdRoundedBox(q - vec3( 0.00,  0.00, -0.22), vec3(0.18, 0.12, 0.10), 0.03);
    float rearBody   = sdRoundedBox(q - vec3(-0.10,  0.00, -0.29), vec3(0.08, 0.09, 0.05), 0.02);
    float sideGrip   = sdRoundedBox(q - vec3( 0.13, -0.01, -0.23), vec3(0.05, 0.08, 0.07), 0.02);
    float topHandle  = sdRoundedBox(q - vec3( 0.02,  0.13, -0.21), vec3(0.10, 0.025, 0.06), 0.015);

    float lensOuter  = sdCappedCylinderZ(q - vec3(0.00, 0.00, 0.02), 0.11, 0.07);
    float lensInner  = sdCappedCylinderZ(q - vec3(0.00, 0.00, 0.10), 0.05, 0.05);
    float lensGlass  = sdCappedCylinderZ(q - vec3(0.00, 0.00, 0.145), 0.01, 0.045);

    float micPod     = sdSphere(q - vec3(0.10, 0.11, -0.02), 0.025);
    float tallyLamp  = sdSphere(q - vec3(-0.08, 0.05, 0.08), 0.012);

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

    // shell
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x, roomCenter.y - roomHalf.y - wallThickness, roomCenter.z), vec3(roomHalf.x, wallThickness, roomHalf.z)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x, roomCenter.y + roomHalf.y + wallThickness, roomCenter.z), vec3(roomHalf.x, wallThickness, roomHalf.z)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x - roomHalf.x - wallThickness, roomCenter.y, roomCenter.z), vec3(wallThickness, roomHalf.y, roomHalf.z)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x + roomHalf.x + wallThickness, roomCenter.y, roomCenter.z), vec3(wallThickness, roomHalf.y, roomHalf.z)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x, roomCenter.y, roomCenter.z - roomHalf.z - wallThickness), vec3(roomHalf.x, roomHalf.y, wallThickness)), 0));
    h = opUnion(h, Hit(sdBox(p - vec3(roomCenter.x, roomCenter.y, roomCenter.z + roomHalf.z + wallThickness), vec3(roomHalf.x, roomHalf.y, wallThickness)), 0));

    // long walkway / plinth
    h = opUnion(h, Hit(sdRoundedBox(p - vec3(0.0, 0.40, -16.0), vec3(2.8, 0.22, 20.0), 0.08), 13));

    // side mirror grids: 4 columns x 4 rows per wall = 32 mirrors total
    const float panelHalfW = 1.6;
    const float panelHalfH = 1.05;
    const float panelHalfT = 0.035;
    const float frameInset = 0.14;
    const float mirrorInset = 0.06;

    for (int xi = 0; xi < 4; ++xi) {
        float x = -14.4 + float(xi) * 9.6;
        for (int yi = 0; yi < 4; ++yi) {
            float y = 1.0 + float(yi) * 1.9;

            vec3 leftFrameCenter  = vec3(-21.72, y, x - 1.2);
            vec3 leftMirrorCenter = vec3(-21.55, y, x - 1.2);
            vec3 rightFrameCenter  = vec3(21.72, y, x - 1.2);
            vec3 rightMirrorCenter = vec3(21.55, y, x - 1.2);

            h = opUnion(h, Hit(sdBox(p - leftFrameCenter,  vec3(panelHalfT, panelHalfH + frameInset, panelHalfW + frameInset)), 13));
            h = opUnion(h, Hit(sdBox(p - leftMirrorCenter, vec3(panelHalfT, panelHalfH, panelHalfW)), 12));

            h = opUnion(h, Hit(sdBox(p - rightFrameCenter,  vec3(panelHalfT, panelHalfH + frameInset, panelHalfW + frameInset)), 13));
            h = opUnion(h, Hit(sdBox(p - rightMirrorCenter, vec3(panelHalfT, panelHalfH, panelHalfW)), 12));
        }
    }

    // back wall mirrors: 4 columns x 2 rows = 8 more, total 40 mirrors
    for (int xi = 0; xi < 4; ++xi) {
        float x = -14.0 + float(xi) * 9.33;
        for (int yi = 0; yi < 2; ++yi) {
            float y = 1.6 + float(yi) * 3.0;
            vec3 backFrameCenter  = vec3(x, y, -39.72);
            vec3 backMirrorCenter = vec3(x, y, -39.55);

            h = opUnion(h, Hit(sdBox(p - backFrameCenter,  vec3(panelHalfW + frameInset, panelHalfH + 0.18, panelHalfT)), 13));
            h = opUnion(h, Hit(sdBox(p - backMirrorCenter, vec3(panelHalfW, panelHalfH + mirrorInset, panelHalfT)), 12));
        }
    }

    // central sculptural mirrored slabs for stronger recursive reflections
    for (int i = 0; i < 3; ++i) {
        float z = -10.0 - float(i) * 8.0;
        h = opUnion(h, Hit(sdRoundedBox(p - vec3(-6.0, 1.7, z), vec3(0.22, 1.7, 2.8), 0.03), 12));
        h = opUnion(h, Hit(sdRoundedBox(p - vec3( 6.0, 1.7, z - 2.0), vec3(0.22, 1.7, 2.8), 0.03), 12));
    }

    return h;
}


Hit map(vec3 p, int traceMode) {
    Hit h = Hit(1e5, -1);

    if (uSceneVariant == 0) {
        h = opUnion(h, Hit(sdBox(p - vec3( 0.0, -0.15, -4.5), vec3(5.5, 0.15, 5.5)), 0));
        h = opUnion(h, Hit(sdBox(p - vec3( 0.0,  4.15, -4.5), vec3(5.5, 0.15, 5.5)), 0));
        h = opUnion(h, Hit(sdBox(p - vec3(-5.35, 2.0, -4.5), vec3(0.15, 2.0, 5.5)), 1));
        h = opUnion(h, Hit(sdBox(p - vec3( 5.35, 2.0, -4.5), vec3(0.15, 2.0, 5.5)), 2));
        h = opUnion(h, Hit(sdBox(p - vec3( 0.0, 2.0, -9.85), vec3(5.5, 2.0, 0.15)), 4));

        h = opUnion(h, Hit(sdSphere(p - vec3(-1.6, 1.0, -3.4), 1.0), 3));
        h = opUnion(h, Hit(sdSphere(p - vec3( 1.5, 0.8, -4.8), 0.8), 1));
        h = opUnion(h, Hit(sdBox   (p - vec3( 0.1, 0.75, -2.3), vec3(0.7, 0.7, 0.7)), 2));
        h = opUnion(h, Hit(sdBox   (p - vec3( 2.6, 0.65, -6.1), vec3(0.65, 0.65, 0.65)), 4));

    } else if (uSceneVariant == 1) {
        h = opUnion(h, Hit(sdBox(p - vec3( 0.0, -0.15, -4.8), vec3(6.5, 0.15, 6.5)), 0));
        h = opUnion(h, Hit(sdBox(p - vec3( 0.0,  4.75, -4.8), vec3(6.5, 0.15, 6.5)), 0));
        h = opUnion(h, Hit(sdBox(p - vec3(-6.35, 2.3, -4.8), vec3(0.15, 2.3, 6.5)), 1));
        h = opUnion(h, Hit(sdBox(p - vec3( 6.35, 2.3, -4.8), vec3(0.15, 2.3, 6.5)), 1));
        h = opUnion(h, Hit(sdBox(p - vec3( 0.0, 2.3, -11.15), vec3(6.5, 2.3, 0.15)), 2));

        h = opUnion(h, Hit(sdBox(p - vec3(-4.0, 1.1, -8.8), vec3(0.45, 1.1, 0.45)), 4));
        h = opUnion(h, Hit(sdBox(p - vec3( 4.0, 1.1, -8.8), vec3(0.45, 1.1, 0.45)), 4));

        h = opUnion(h, Hit(sdSphere(p - vec3(-2.1, 1.1, -3.0), 1.1), 3));
        h = opUnion(h, Hit(sdSphere(p - vec3( 0.2, 0.7, -3.2), 0.7), 4));
        h = opUnion(h, Hit(sdSphere(p - vec3( 2.0, 0.9, -4.7), 0.9), 2));
        h = opUnion(h, Hit(sdBox   (p - vec3(-0.8, 0.6, -5.5), vec3(0.6, 0.6, 0.6)), 1));
        h = opUnion(h, Hit(sdBox   (p - vec3( 2.8, 0.5, -2.6), vec3(0.5, 0.5, 0.5)), 0));

    } else {
        h = opUnion(h, mapMirrorHall(p));
    }

    //for (int i = 0; i < lightCount; ++i) {
    //    int lightMat = 5 + i;
    //    h = opUnion(h, Hit(sdSphere(p - getLightPos(i), LIGHT_RADIUS), lightMat));
    //}

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

        if (d < HIT_EPS) {
            return 0.0;
        }

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

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    float f = pow(1.0 - clamp(cosTheta, 0.0, 1.0), 5.0);
    return F0 + (1.0 - F0) * f;
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

vec3 evalDirectBRDF(Material mat, vec3 n, vec3 v, vec3 l) {
    vec3 h = normalize(v + l);

    float NdotL = max(dot(n, l), 0.0);
    float NdotV = max(dot(n, v), 0.0);
    float NdotH = max(dot(n, h), 0.0);
    float VdotH = max(dot(v, h), 0.0);

    vec3 F0 = mix(vec3(0.04), mat.albedo, mat.metallic);
    vec3 F = fresnelSchlick(VdotH, F0);

    float alpha = max(0.03, mat.roughness * mat.roughness);
    float D = D_GGX(NdotH, alpha);
    float G = G_Smith(NdotV, NdotL, mat.roughness);

    vec3 spec = (D * G * F) / max(4.0 * NdotV * NdotL, 0.0001);

    vec3 kd = (1.0 - F) * (1.0 - mat.metallic);
    vec3 diff = kd * mat.albedo * INV_PI;

    return diff + spec;
}

vec3 environmentColor(vec3 rd) {
    float t = 0.5 * (rd.y + 1.0);
    vec3 sky = mix(vec3(0.03, 0.035, 0.05), vec3(0.10, 0.12, 0.16), t);
    return sky;
}

vec3 directLighting(vec3 pos, vec3 normal, vec3 viewDir, Material mat, vec3 throughput) {
    vec3 accum = vec3(0.0);

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

        vec3 Li = getLightColor(i) / (lightDist * lightDist + 1.0);
        vec3 brdf = evalDirectBRDF(mat, normal, viewDir, lightDir);

        accum += throughput * brdf * Li * nDotL * visibility;
    }

    return accum;
}

vec3 raytrace(vec3 ro, vec3 rd) {
    vec3 accum = vec3(0.0);
    vec3 throughput = vec3(1.0);

    int traceMode = 0; // 0 = normal scene only, 1 = allow reflection-only objects

    for (int bounce = 0; bounce < HARD_MAX_BOUNCES; ++bounce) {
        if (bounce >= uMaxBounces) break;

        vec3 pos, normal;
        Hit h = march(ro, rd, pos, normal, traceMode);

        if (h.mat < 0) {
            accum += throughput * environmentColor(rd);
            break;
        }

        Material mat = getMaterial(h.mat);

        float emissiveStrength = mat.emission.r + mat.emission.g + mat.emission.b;
        bool hitLight = emissiveStrength > 0.0;

        if (hitLight) {
            accum += throughput * mat.emission * 0.25;
            break;
        }

        vec3 viewDir = normalize(-rd);
        accum += directLighting(pos, normal, viewDir, mat, throughput);

        vec2 baseSeed = gl_FragCoord.xy + vec2(float(iFrame) * 0.61803, float(bounce) * 17.173);
        vec2 r0 = hash22(baseSeed + vec2(13.3, 7.7));
        vec2 r1 = hash22(baseSeed + vec2(91.1, 47.2));

        vec3 F0 = mix(vec3(0.04), mat.albedo, mat.metallic);
        float cosNV = max(dot(normal, viewDir), 0.0);
        vec3 F = fresnelSchlick(cosNV, F0);

        float specChance = (uEnableReflections != 0)
            ? clamp(max(max(F.r, F.g), F.b), 0.08, 0.95)
            : 0.0;

        if (r0.x < specChance) {
            vec3 perfect = reflect(rd, normal);
            rd = sampleAroundDirection(perfect, normal, r1, max(0.02, mat.roughness));
            throughput *= F / max(specChance, 0.001);
            traceMode = 1; // reflection ray can see the camera prop
        } else {
            rd = cosineSampleHemisphere(normal, r1);
            vec3 kd = (1.0 - F) * (1.0 - mat.metallic);
            throughput *= (kd * mat.albedo) / max(1.0 - specChance, 0.001);
            traceMode = 0; // diffuse ray cannot see the camera prop
        }

        ro = pos + normal * RAY_BIAS;

        float lum = dot(throughput, vec3(0.2126, 0.7152, 0.0722));
        if (lum > 12.0) {
            throughput *= 12.0 / lum;
        }

        float p = clamp(max(max(throughput.r, throughput.g), throughput.b), 0.05, 0.98);
        if (bounce >= 2) {
            float rr = hash21(gl_FragCoord.xy + vec2(float(iFrame) * 3.1, float(bounce) * 19.7));
            if (rr > p) break;
            throughput /= p;
        }
    }

    return accum;
}

vec4 effect(vec4 color, Image prevFrame, vec2 uv, vec2 fragCoord) {
    vec3 prev = Texel(tex, uv).rgb;
    vec3 rayOrigin = camPos;
    vec3 rayDir = getRay(fragCoord);

    vec3 newColor = raytrace(rayOrigin, rayDir);

    if (iFrame == 0) {
        return vec4(newColor, 1.0);
    }

    float blend = 1.0 / float(iFrame + 1);
    vec3 result = mix(prev, newColor, blend);
    return vec4(result, 1.0);
}