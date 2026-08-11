-- Pure data: no love calls, no requires. Colors are 0xRRGGBB, or { 0xRRGGBB, alpha }
-- when translucent. A new theme is a copy of this file with the same keys.
return {
    name = "Dark",

    colors = {
        canvasBackground  = 0x1E1E1E,
        canvasGridLine    = { 0xFFFFFF, 0.08 },
        canvasGridSubline = { 0xFFFFFF, 0.035 },
        canvasGridOrigin  = { 0xFFFFFF, 0.15 },

        surface      = 0x252526,
        surfaceHover = 0x2D2D30,
        surfacePress = 0x1A1A1A,
        border       = 0x3C3C3C,
        transparent  = { 0x000000, 0 },

        foreground = 0xD4D4D4,
        muted      = 0x8A8A8A,
        accent     = 0x3B82F6,

        elementSurface = 0x2A2A2E,
        elementHeader  = 0x37373D,
        elementBorder  = 0x4A4A52,
        elementTitle   = 0xD4D4D4,

        selection     = 0x65a3c2,
        selectionAlt  = 0x85b1c7,
        marqueeFill   = { 0x3B82F6, 0.12 },
        marqueeBorder = { 0x3B82F6, 0.6 },

        toastSuccess = 0x00c851,
        toastInfo    = 0x33b5e5,
        toastWarn    = 0xffbb33,
        toastError   = 0xff4444,

        shadow = { 0x000000, 0.5 },
    },

    -- `family` is a path to a font file; omit it to use LOVE's built-in font.
    fonts = {
        small  = { family = "res/fnt/ubuntu.ttf", size = 14 },
        medium = { family = "res/fnt/ubuntu.ttf", size = 20 },
        large  = { family = "res/fnt/ubuntu.ttf", size = 26 },
    },

    metrics = {
        cornerRadius = 4,
        selectionWidth = 1,
        borderWidth  = 1,
        shadowOffset = 2,
        shadowBlur   = 4,
    },
}
