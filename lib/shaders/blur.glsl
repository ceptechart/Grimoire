// Separable box blur: run once horizontally, then once vertically.
//
// A box kernel is separable, so two 1D passes produce exactly the same image as a
// single pass over the 2D square -- at 2r samples per pixel instead of r^2.
extern float radius;
extern vec2 direction; // one texel step along the axis being blurred

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 sum = vec4(0.0);
    float samples = 0.0;

    for (float i = -radius; i <= radius; i++) {
        sum += Texel(texture, texture_coords + direction * i);
        samples += 1.0;
    }

    return (sum / samples) * color;
}
