const path = require('node:path');
const phone = require('../../sd-phone/web/tailwind.config.cjs');

// fast-glob only reads forward slashes, so an absolute path has to be posix-ified on Windows.
const phoneSrc = path.resolve(__dirname, '../../sd-phone/web/src').replace(/\\/g, '/');

/** @type {import('tailwindcss').Config} */
module.exports = {
    ...phone,
    // Every class this build ships is written in sd-phone's source. Scanning only the tablet
    // project builds cleanly and ships a near-empty stylesheet.
    content: ['./index.html', './src/**/*.{ts,tsx}', phoneSrc + '/**/*.{ts,tsx}'],
};
