import { readdir, readFile } from 'node:fs/promises';

const assetsDirectory = new URL('../build/assets/', import.meta.url);

async function readBuiltCss() {
    const assetNames = await readdir(assetsDirectory);
    const cssNames = assetNames.filter((assetName) => assetName.endsWith('.css'));

    if (cssNames.length === 0) {
        throw new Error('The tablet build did not produce a CSS asset.');
    }

    const stylesheets = await Promise.all(
        cssNames.map((cssName) => readFile(new URL(cssName, assetsDirectory), 'utf8')),
    );

    return stylesheets.join('\n');
}

const css = await readBuiltCss();
const requiredUtilities = [
    ['absolute positioning', '.absolute{position:absolute}'],
    ['flex layout', '.flex{display:flex}'],
    ['viewport height', '.h-screen{height:100vh}'],
];

const missingUtilities = requiredUtilities
    .filter(([, utility]) => !css.includes(utility))
    .map(([name]) => name);

if (missingUtilities.length > 0) {
    throw new Error(`The tablet stylesheet is missing Tailwind utilities: ${missingUtilities.join(', ')}`);
}

console.log('Tablet stylesheet includes the required Tailwind layout utilities.');
