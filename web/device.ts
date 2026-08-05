import type { DeviceProfile } from '@/device/types';

// The tablet. Geometry is an 11" iPad held in landscape (1180x820 logical points); everything a
// tablet cannot do is a `false` here rather than a branch in an app.
export const device: DeviceProfile = {
    id:           'tablet',
    // sd-tablet registers one callback and forwards the envelope into sd-phone's client, so it
    // never has to mirror the ~460 action names this UI posts.
    rpcAction:    'rpc',
    calls:        false,
    payphone:     false,
    admin:        false,
    // Its own device, so its own first-run wizard: settings are stored per device, and this is
    // where the tablet's language, passcode, theme and wallpaper get chosen rather than inherited.
    setup:        true,
    // No cellular radio, so no dialler.
    excludedApps: ['phone'],
    // A landscape slab is too wide to sit in a corner without crowding the edge of the screen.
    defaultAlign: 'middle-center',
    screen: {
        // Landscape: wider than it is tall. PhoneShell skips its camera rotate-to-landscape
        // transform when w > h, since this device is already there. 1366x1024 is the 12.9" iPad
        // Pro in landscape. With the bezel that is a 1042-tall frame, so at the maximum phoneScale
        // of 100 (scale 1.0) it wants 1090px of a 1080p screen and loses 10px top and bottom. The
        // default scale is 50, which renders it at 0.7, so this only bites a player who has
        // deliberately pushed the slider to full on a 1080p monitor.
        w:      1366,
        h:      1024,
        // Thin, like a current iPad: the same absolute rail the phone uses, which is what sells
        // it as a modern device rather than a scaled-up one. Real bezels do not grow with the
        // panel, so keeping this at the phone's 9 is more accurate than scaling it with w.
        bezel:  9,
        // Anodised slab, not a polished phone rail. The phone's gradient swings +/-30% either side
        // of the base colour, which sells a 458px-tall edge but spreads into a broad shine across
        // 1384px; matte keeps the same ramp shape at roughly a third of the contrast and halves
        // the sheen with it.
        finish: 'matte',
        // Thinner than the phone's 3.5. An iPad's buttons are barely proud of the case, and a
        // fatter rail button on a device this size reads as a games console.
        buttonWidth: 3,
        // Float the dock as a tray sized to its icons instead of stretching it across 1366px.
        dockFill: false,
        // Still a slab rather than a big phone, but the thinner rail needs a slightly softer
        // corner or the frame reads as a sharp-edged box. Screen radius derives as radius - bezel,
        // so this is a 15px inner corner against the old 8.
        radius: 24,
        island: false,
        // An iPad has no mute switch, so no screenshot button either. Held in landscape the
        // rails are the short edges: power top-right, the volume pair opposite it. Offsets are
        // measured down the 1042-tall frame.
        buttons: [
            { side: 'left',  y: 120, h: 80,  role: 'volumeUp' },
            { side: 'left',  y: 220, h: 80,  role: 'volumeDown' },
            { side: 'right', y: 120, h: 100, role: 'power' },
        ],
        // Icons are laid out at padX + col * colStride, so the last column's right edge must
        // land padX short of the screen: 80 + 7*158 + 100 = 1286, and 1366 - 1286 = 80.
        // Five rows clear the dock: stripTop 70 + rowY0 12 + 5*152 = 842 of 1024.
        grid: {
            cols:      8,
            rows:      5,
            padX:      80,
            icon:      100,
            colStride: 158,
            rowY0:     12,
            rowStride: 152,
            stripTop:  70,
        },
    },
};
