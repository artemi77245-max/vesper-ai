#include <flutter/runtime_effect.glsl>

uniform float u_time;
uniform vec2  u_center_pos;
uniform vec4  u_color;
uniform float u_phase;

out vec4 fragColor;

// --- SDF Примитивы ---
float sdCircle(vec2 p, float r) {
    return length(p) - r;
}

float sdStar4(vec2 p, float r, float mr) {
    vec2 ap = abs(p);
    float c = 0.70710678;
    vec2 q = vec2(ap.x * c - ap.y * c, ap.x * c + ap.y * c);
    ap = abs(q);
    if (ap.y > ap.x) ap = ap.yx;

    float m = mr;
    vec2 a = ap - vec2(r, 0.0);
    vec2 v = vec2(r * (1.0 - m), r * m);
    float h = clamp(dot(a, v) / dot(v, v), 0.0, 1.0);
    return length(a - v * h) * sign(a.x * v.y - a.y * v.x);
}

// --- Вязкое слияние (Liquid metal) ---
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

void main() {
    vec2 p = FlutterFragCoord().xy - u_center_pos;
    float d = 1e5;
    float k = 2.0; // Сила поверхностного натяжения

    if (u_phase == 0.0) {
        // IDLE: Одна целая капля живо двигается (плавает)
        vec2 wiggle = vec2(sin(u_time * 2.0), cos(u_time * 2.5)) * 1.5;
        float radius = 5.5 + 0.5 * sin(u_time * 3.0);
        d = sdCircle(p - wiggle, radius);
    }
    else if (u_phase == 1.0) {
        // SEARCH: Глобус и вылетающие/залетающие капли
        float globe = sdCircle(p, 4.5);
        d = globe;

        // 4 поисковых частицы
        for(int i = 0; i < 4; i++) {
            float t = fract(u_time * 0.6 + float(i) * 0.25); // Цикл от 0 до 1
            float dist = sin(t * 3.1415) * 11.0; // Вылетают на 11px и возвращаются
            float angle = u_time * 1.2 + float(i) * 1.57;
            vec2 pos = vec2(cos(angle), sin(angle)) * dist;
            d = smin(d, sdCircle(p - pos, 1.8), k);
        }
    }
    else if (u_phase == 2.0) {
        // SPLIT: Три капли на месте дёргаются как живые (без ядра)
        for(int i = 0; i < 3; i++) {
            float angle = float(i) * 2.094; // 120 градусов
            vec2 basePos = vec2(cos(angle), sin(angle)) * 8.5; // Отрыв от центра
            vec2 wiggle = vec2(sin(u_time * 4.0 + float(i)*2.0), cos(u_time * 4.5 - float(i)*2.0)) * 1.5;
            d = smin(d, sdCircle(p - basePos - wiggle, 3.2), k);
        }
    }
    else if (u_phase == 3.0) {
        // MERGE: Слияние в бурлящее целое
        for(int i = 0; i < 3; i++) {
            float angle = float(i) * 2.094 + u_time * 5.0; // Быстрое вращение
            vec2 pos = vec2(cos(angle), sin(angle)) * 2.5; // Стянуты к центру
            d = smin(d, sdCircle(p - pos, 3.8), 3.0); // Высокая вязкость
        }
    }
    else if (u_phase == 4.0) {
        // REVEAL: 4-ёх конечная звезда
        float rot = u_time * 0.5; // Легкое вращение
        float cr = cos(rot), sr = sin(rot);
        vec2 pr = vec2(p.x * cr - p.y * sr, p.x * sr + p.y * cr);
        float star = sdStar4(pr, 8.0, 0.35); // 8.0 радиус, 0.35 сжатие лучей

        star -= 0.6 * sin(u_time * 3.5); // Пульсация
        d = star;
    }

    // Сглаживание краев (Anti-aliasing)
    float alpha = 1.0 - smoothstep(0.0, 1.0, d);
    fragColor = u_color * alpha;
}
