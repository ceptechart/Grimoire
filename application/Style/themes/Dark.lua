-- Pure data: no love calls, no requires. Colors are 0xRRGGBB, or { 0xRRGGBB, alpha }
-- when translucent. A new theme is a copy of this file with the same keys.
return {
    name = "Dark",

    colors = {
        -- Canvas.lua: the pan/zoom surface behind all board content.
        canvasBackground  = 0x1E1E1E, -- love.graphics.clear color
        canvasGridLine    = { 0xFFFFFF, 0.08 },  -- major grid lines, one per `spacing`
        canvasGridSubline = { 0xFFFFFF, 0.035 }, -- minor grid lines between major lines
        canvasGridOrigin  = { 0xFFFFFF, 0.15 },  -- the axis line(s) through world (0, 0)

        -- General-purpose chrome tones, shared by the menu bar, status bar, dropdown
        -- menus, dialogs, and toasts (UI.lua, Dialog.lua, Toast.lua, Panel.lua).
        surface      = 0x252526, -- default panel fill: bars, dropdown menus, dialogs, toasts
        surfaceHover = 0x2D2D30, -- bar/menu button fill on hover
        surfacePress = 0x1A1A1A, -- bar/menu button fill while pressed
        border       = 0x3C3C3C, -- panel outline for bars, dropdown menus, dialogs
        transparent  = { 0x000000, 0 }, -- explicit "no fill"/"no border" for Panel

        foreground = 0xD4D4D4, -- default text color (labels, dialog body text, edit fields)
        muted      = 0x8A8A8A, -- secondary text: status bar readouts, dialog message text
        accent     = 0x3B82F6, -- app-name label in the menu bar; the brand blue reused by tool/dialog selection colors below

        -- PanelElement.lua / UnknownElement.lua: the default board element (and the
        -- fallback drawn for an element type this build doesn't recognize).
        elementSurface = 0x2A2A2E, -- element body fill
        elementHeader  = 0x37373D, -- title bar strip at the top of the element
        elementBorder  = 0x4A4A52, -- element outline (PanelElement only; UnknownElement uses toastWarn instead)
        elementTitle   = 0xD4D4D4, -- title text drawn in the header

        -- Inline text editing: the field a label turns into while it's being typed
        -- in, and the caret and selection drawn over it.
        editFieldSurface = 0x1E1E1E, -- filled box behind the text being edited
        editFieldBorder  = 0x48679c, -- accent border for the box (currently unused: drawn commented-out in TextEditSession:drawIn)
        textCaret        = 0xD4D4D4, -- blinking one-pixel-wide caret rect
        textSelection    = { 0x3B82F6, 0.45 }, -- highlight rect behind selected text

        -- Modal confirm dialogs: the screen-dimming backdrop, plus three button
        -- tones -- primary (the recommended action), danger (discarding work), and
        -- secondary (everything else). Filled rather than flat like the menu bar's
        -- buttons, so they read as buttons on their own without a bar around them.
        overlay = { 0x000000, 0.55 }, -- DialogManager: backdrop dimming the app behind an open dialog

        -- Dialog.lua BUTTON_STYLES: fill/hover/press for each button `style`.
        dialogPrimary      = 0x3B82F6, -- "primary" style -- the recommended action (e.g. Save)
        dialogPrimaryHover = 0x5B97F7,
        dialogPrimaryPress = 0x2E6BCC,

        dialogDanger      = 0xE5484D, -- "danger" style -- a destructive action (e.g. Discard)
        dialogDangerHover = 0xEC6569,
        dialogDangerPress = 0xC33338,

        dialogSecondary      = 0x33333A, -- "secondary" style -- everything else (e.g. Cancel)
        dialogSecondaryHover = 0x3D3D45,
        dialogSecondaryPress = 0x28282D,

        dialogButtonText = 0xFFFFFF, -- label text on all three button styles above

        -- Tool palette: circular buttons floating over the canvas rather than sitting
        -- in a bar, so they're a step lighter than `surface` to read as being above
        -- the board. The selected tool takes the accent fill.
        toolSurface       = 0x2D2D30, -- tool button fill, and the collapse toggle above it
        toolSurfaceHover  = 0x3A3A40, -- tool/toggle button fill on hover
        toolSurfacePress  = 0x1A1A1A, -- tool/toggle button fill while pressed
        toolSelected      = 0x3B82F6, -- fill for the currently active tool's button
        toolSelectedHover = 0x5B97F7, -- active tool's button fill on hover
        toolIcon          = 0x9A9A9A, -- icon tint for an unselected tool button
        toolIconHover     = 0xD4D4D4, -- icon tint for an unselected tool button on hover
        toolIconSelected  = 0xFFFFFF, -- icon tint for the active tool's button

        -- Board:drawSelectionOutlines: outline around selected elements, blended
        -- between the two colors over time for a slow pulse.
        selection     = 0x65a3c2,
        selectionAlt  = 0x85b1c7,
        marqueeFill   = { 0x3B82F6, 0.12 }, -- MarqueeGesture -- fill of the drag-to-select rect
        marqueeBorder = { 0x3B82F6, 0.6 },  -- MarqueeGesture -- outline of the drag-to-select rect

        -- Toast.lua: border + icon + label tint for each toast type
        -- (Toast.SUCCESS/INFO/WARN/ERROR). toastWarn doubles as UnknownElement's
        -- border color (see elementBorder above).
        toastSuccess = 0x00c851,
        toastInfo    = 0x33b5e5,
        toastWarn    = 0xffbb33,
        toastError   = 0xff4444,

        shadow = { 0x000000, 0.5 }, -- Shadow.lua drop-shadow tint, used by Panel and Label
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
