extern vec2 iResolution;
extern vec3 camPos;
extern float yaw;
extern float pitch;
extern int iFrame;
uniform Image tex;


// === Camera ===
vec3 getRay(vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution) / iResolution.y;
    float cp = cos(pitch), sp = sin(pitch), cy = cos(yaw), sy = sin(yaw);
    vec3 forward = vec3(cp * sy, sp, cp * cy);
    vec3 right = vec3(cy, 0.0, -sy);
    vec3 up = cross(right, forward);
    return normalize(forward + uv.x * right + uv.y * up);
}

// === Scene ===
float sdGround(vec3 p) {
    return p.y;
}
float sdBox(vec3 p, vec3 b) {
    vec3 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}
float sdSphere(vec3 p, float r) {
    return length(p) - r;
}
float sdPlane(vec3 p, vec3 n, float h) {
    return dot(p, n) + h;
}
vec3 getSkyColor(vec3 rd) {
    float sun = pow(max(dot(rd, normalize(vec3(0.3, 0.5, 0.1))), 0.0), 1000.0);
    float sky = 0.5 * (rd.y + 1.0);
    return vec3(0.6, 0.7, 1.0) * sky + vec3(1.2, 1.0, 0.8) * sun;
}


struct Hit {
    float dist;
    int mat;
};

Hit map(vec3 p) {
    Hit h = Hit(10e10, -1);
    float d;

    d = sdGround(p);
    if (d < h.dist) { h.dist = d; h.mat = 0; }

    d = sdBox(p - vec3(0.0, 0.5, 0.0), vec3(0.5));
    if (d < h.dist) { h.dist = d; h.mat = 1; }
                        // Z, Y, X,          D, H, W
    d = sdBox(p - vec3(0.0, 5.0, 0.0), vec3(5.0, 0.1, 5.0)); 
    if (d < h.dist) { h.dist = d; h.mat = 0; } // ROOF

    d = sdBox(p - vec3(-5.0, 0.5, 0.0), vec3(0.5, 5.0, 5.0));
    if (d < h.dist) { h.dist = d; h.mat = 0; } // SOUTH
    
    d = sdBox(p - vec3(5.0, 0.5, 0.0), vec3(0.5, 5.0, 5.0));
    if (d < h.dist) { h.dist = d; h.mat = 0; } // NORTH
    
    d = sdBox(p - vec3(0.0, 0.5, 5.0), vec3(5.0, 5.0, 0.5));
    if (d < h.dist) { h.dist = d; h.mat = 0; } // EAST
    
    d = sdBox(p - vec3(0.0, 0.5, -5.0), vec3(5.0, 5.0, 0.5));
    if (d < h.dist) { h.dist = d; h.mat = 0; } // EAST


    d = sdSphere(p - vec3(1.2, 0.5, 0.0), 0.5);
    if (d < h.dist) { h.dist = d; h.mat = 2; }

    return h;
}

bool isMirror(int mat) {
    return mat == 2; // Sphere
}

vec3 getAlbedo(int mat) {
    if (mat == 0) return vec3(0.8);              // Walls/floor
    if (mat == 1) return vec3(1.0, 0.4, 0.2);     // Box
    if (mat == 2) return vec3(1.0);              // Chrome sphere (will be handled as mirror)
    if (mat == 3) return vec3(1.0, 0.4, 0.6);    // Sun thing
    return vec3(0.0);
}

const int lightCount = 2;
vec3 lights[lightCount] = vec3[](vec3(2, 3, 1), vec3(-3, 4, -2));
vec3 lightColors[lightCount] = vec3[](vec3(20), vec3(10, 15, 30));

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 78.233);
    return fract(p.x * p.y);
}

vec3 cosineSampleHemisphere(vec3 n, vec2 r) {
    float phi = 6.283185 * r.x;
    float r2 = sqrt(r.y);
    vec3 local = vec3(r2 * cos(phi), r2 * sin(phi), sqrt(1.0 - r.y));
    vec3 up = abs(n.y) < 0.999 ? vec3(0,1,0) : vec3(1,0,0);
    vec3 t = normalize(cross(up, n));
    vec3 b = cross(n, t);
    return normalize(local.x*t + local.y*b + local.z*n);
}

Hit march(vec3 ro, vec3 rd, out vec3 pos, out vec3 normal) {
    float t = 0.0;
    for (int i = 0; i < 1920 * 1080; ++i) {
        vec3 p = ro + rd * t;
        Hit h = map(p);
        if (h.dist < 0.0001) {
            pos = p;
            vec2 e = vec2(0.0001, 0);
            normal = normalize(vec3(
                map(p + e.xyy).dist - map(p - e.xyy).dist,
                map(p + e.yxy).dist - map(p - e.yxy).dist,
                map(p + e.yyx).dist - map(p - e.yyx).dist
            ));
            return h;
        }
        t += h.dist;
        if (t > 10000) break;
    }
    pos = ro + rd * t;
    normal = vec3(0);
    return Hit(1e5, -1);
}

const float PI = 3.1415926535;

vec3 getEmission(int mat) {
    if (mat == 3) return vec3(10.01, 9.98, 10); // light
    if (mat == 0) return vec3(0.01);
    return vec3(0.0);
}

vec3 raytrace(vec3 ro, vec3 rd) {
    vec3 accum = vec3(0.0);
    vec3 throughput = vec3(1.0);

    for (int bounce = 0; bounce < 8; ++bounce) {
        vec3 pos, normal;
        Hit h = march(ro, rd, pos, normal);
        if (h.mat < 0) {
            accum += throughput * getSkyColor(rd);
            break;
        }

        vec3 albedo = getAlbedo(h.mat);
        accum += throughput * getEmission(h.mat);
        // === Mirror material ===
        if (h.mat == 2) { // chrome sphere
            rd = reflect(rd, normal);
            ro = pos + normal * 0.01;
            continue;
        }

        // === Direct lighting with shadow rays ===
        for (int i = 0; i < lightCount; ++i) {
            vec3 toLight = lights[i] - pos;
            float lightDist = length(toLight);
            vec3 lightDir = toLight / lightDist;

            vec3 dummyPos, dummyNorm;
            Hit shadow = march(pos + normal * 0.001, lightDir, dummyPos, dummyNorm);

            if (shadow.dist > lightDist - 0.001) {
                float nDotL = max(dot(normal, lightDir), 0.0);
                vec3 light = lightColors[i] * nDotL / (lightDist * lightDist);
                accum += throughput * albedo * light;
            }
        }


        // === Next bounce direction ===
        vec2 seed = gl_FragCoord.xy + float(iFrame) * vec2(0.37, 0.71) + float(bounce) * vec2(13.3, 7.7);
        vec2 rand = vec2(hash(seed), hash(seed + 19.1));

        rd = cosineSampleHemisphere(normal, rand);
        ro = pos + normal * 0.01;

        float cosTheta = max(dot(normal, rd), 0.0);
        throughput *= albedo * cosTheta / (1.0 / PI);
        throughput *= 0.98; // small artificial damping to control runaway energy

        // === Russian Roulette termination ===
        //float p = max(max(throughput.r, throughput.g), throughput.b);
        //if (bounce >= 1) {
        //    if (hash(gl_FragCoord.xy + float(bounce)) > p) break;
        //    throughput /= p;
        //}
    }

    return accum;
}

vec4 effect(vec4 color, Image prevFrame, vec2 uv, vec2 fragCoord) {
    vec3 prev = Texel(tex, uv).rgb;
    vec3 rayOrigin = camPos;
    vec3 rayDir = getRay(fragCoord);
    vec3 newColor = raytrace(rayOrigin, rayDir);

    if (iFrame == 0) return vec4(newColor, 1.0);

    const float alpha = 0.02; // Controls blending rate: lower = more stable
    vec3 result = mix(prev, newColor, alpha);


    return vec4(result, 1.0);
}
