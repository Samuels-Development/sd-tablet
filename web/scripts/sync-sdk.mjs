import { copyFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, '..');
const phoneWeb = resolve(webRoot, '../../sd-phone/web');

const FILES = ['sdphone-sdk.js', 'sdphone-sdk.d.ts'];

const SOURCES = [
    { dir: join(phoneWeb, 'public'), label: 'sd-phone/web/public (source checkout)' },
    { dir: join(phoneWeb, 'build'), label: 'sd-phone/web/build (release install)' },
];

const source = SOURCES.find(candidate => FILES.every(file => existsSync(join(candidate.dir, file))));

if (!source) {
    console.error(
        [
            '',
            'sync:sdk could not find the sd-phone SDK files.',
            '',
            `Looked for ${FILES.join(' and ')} in:`,
            ...SOURCES.map(candidate => `  - ${candidate.dir}`),
            '',
            'sd-tablet borrows these from sd-phone, so sd-phone must sit next to sd-tablet in the',
            'same folder. A source checkout carries them in web/public; a release install carries',
            'them in web/build instead.',
            '',
            'If sd-phone is there but has never been built, run "npm run build" in sd-phone/web first.',
            '',
        ].join('\n'),
    );
    process.exit(1);
}

const target = join(webRoot, 'public');
mkdirSync(target, { recursive: true });

for (const file of FILES) {
    copyFileSync(join(source.dir, file), join(target, file));
}

console.log(`sync:sdk: copied ${FILES.join(', ')} from ${source.label}`);
