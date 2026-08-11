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

        -- Inline text editing: the field a label turns into while it's being typed
        -- in, and the caret and selection drawn over it.
        editFieldSurface = 0x1E1E1E,
        editFieldBorder  = 0x3B82F6,
        textCaret        = 0xD4D4D4,
        textSelection    = { 0x3B82F6, 0.45 },

        -- Modal confirm dialogs: the screen-dimming backdrop, plus three button
        -- tones -- primary (the recommended action), danger (discarding work), and
        -- secondary (everything else). Filled rather than flat like the menu bar's
        -- buttons, so they read as buttons on their own without a bar around them.
        overlay = { 0x000000, 0.55 },

        dialogPrimary      = 0x3B82F6,
        dialogPrimaryHover = 0x5B97F7,
        dialogPrimaryPress = 0x2E6BCC,

        dialogDanger      = 0xE5484D,
        dialogDangerHover = 0xEC6569,
        dialogDangerPress = 0xC33338,

        dialogSecondary      = 0x33333A,
        dialogSecondaryHover = 0x3D3D45,
        dialogSecondaryPress = 0x28282D,

        dialogButtonText = 0xFFFFFF,

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
