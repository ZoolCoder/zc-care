// Soft blue halo around the cursor, and a short fading trail when the cursor jumps.
float distanceToSegment(vec2 p, vec2 a, vec2 b) {
    vec2 ba = b - a;
    float lengthSquared = dot(ba, ba);
    if (lengthSquared < 1.0) return length(p - a);
    float h = clamp(dot(p - a, ba) / lengthSquared, 0.0, 1.0);
    return length(p - a - ba * h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 terminal = texture(iChannel0, fragCoord / iResolution.xy);
    // Cursor rectangles are top-left corner plus size, with y growing upwards.
    vec2 current = iCurrentCursor.xy + vec2(iCurrentCursor.z, -iCurrentCursor.w) * 0.5;
    vec2 previous = iPreviousCursor.xy + vec2(iPreviousCursor.z, -iPreviousCursor.w) * 0.5;
    float fade = 1.0 - clamp((iTime - iTimeCursorChange) / 0.35, 0.0, 1.0);
    vec3 glow = vec3(0.239, 0.482, 1.0);
    float halo = exp(-length(fragCoord - current) / max(iCurrentCursor.w, 1.0)) * 0.16;
    float trail = exp(-distanceToSegment(fragCoord, previous, current) / max(iCurrentCursor.z * 0.7, 1.0)) * fade * fade * 0.4;
    fragColor = vec4(terminal.rgb + glow * (halo + trail), terminal.a);
}
