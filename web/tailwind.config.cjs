const phone = require('../../sd-phone/web/tailwind.config.cjs');

/** @type {import('tailwindcss').Config} */
module.exports = {
    ...phone,
    // Every class this build ships is written in sd-phone's source. Scanning only the tablet
    // project builds cleanly and ships a near-empty stylesheet. Keep these paths relative to this
    // config: an absolute workspace path contains `[scripts-individual]`, which fast-glob treats as
    // a character class instead of a literal directory.
    content: {
        relative: true,
        files: ['./index.html', './src/**/*.{ts,tsx}', '../../sd-phone/web/src/**/*.{ts,tsx}'],
    },
};
