const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const sharp = require('../backend/node_modules/sharp');

const repositoryRoot = path.resolve(__dirname, '..');
const sourceDirectory = path.join(
  repositoryRoot,
  'flutter',
  'assets',
  'branding',
  'source',
);
const sourceWithWordmark = path.join(
  sourceDirectory,
  'materialkompass_logo_mit_schriftzug.svg',
);
const sourceIcon = path.join(
  sourceDirectory,
  'materialkompass_logo_ohne_schriftzug.svg',
);

function option(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

function ensureDirectory(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function importSource(optionName, destination) {
  const supplied = option(optionName);
  if (supplied) {
    ensureDirectory(destination);
    fs.copyFileSync(path.resolve(supplied), destination);
  }
  if (!fs.existsSync(destination)) {
    throw new Error(
      `${optionName} fehlt und ${path.relative(repositoryRoot, destination)} ist nicht vorhanden.`,
    );
  }
}

async function renderTransparent(source, destination, width, height) {
  ensureDirectory(destination);
  await sharp(source)
    .resize({ width, height, fit: 'contain' })
    .png()
    .toFile(destination);
}

async function renderSquare(
  source,
  destination,
  size,
  { scale = 0.84, background = '#FFFFFF' } = {},
) {
  const logoSize = Math.max(1, Math.round(size * scale));
  const logo = await sharp(source)
    .resize({ width: logoSize, height: logoSize, fit: 'contain' })
    .png()
    .toBuffer();
  const offset = Math.round((size - logoSize) / 2);
  ensureDirectory(destination);
  let image = sharp({
    create: {
      width: size,
      height: size,
      channels: 4,
      background,
    },
  })
    .composite([{ input: logo, left: offset, top: offset }]);
  const transparentBackground = typeof background === 'object'
    && Number(background.alpha) < 1;
  if (!transparentBackground) {
    image = image.flatten({ background }).removeAlpha();
  }
  await image.png().toFile(destination);
}

async function main() {
  importSource('--with-wordmark', sourceWithWordmark);
  importSource('--icon', sourceIcon);

  await renderTransparent(
    sourceWithWordmark,
    path.join(
      repositoryRoot,
      'flutter',
      'assets',
      'branding',
      'materialkompass_logo_mit_schriftzug.png',
    ),
    800,
    267,
  );
  await renderTransparent(
    sourceIcon,
    path.join(
      repositoryRoot,
      'flutter',
      'assets',
      'branding',
      'materialkompass_logo_ohne_schriftzug.png',
    ),
    1024,
    1024,
  );
  await renderTransparent(
    sourceWithWordmark,
    path.join(
      repositoryRoot,
      'backend',
      'src',
      'assets',
      'materialkompass-logo-with-wordmark.png',
    ),
    1200,
    400,
  );

  const webDirectory = path.join(repositoryRoot, 'flutter', 'web');
  await renderSquare(sourceIcon, path.join(webDirectory, 'favicon.png'), 64, {
    scale: 0.88,
    background: { r: 255, g: 255, b: 255, alpha: 0 },
  });
  for (const size of [192, 512]) {
    await renderSquare(
      sourceIcon,
      path.join(webDirectory, 'icons', `Icon-${size}.png`),
      size,
      { scale: 0.84 },
    );
    await renderSquare(
      sourceIcon,
      path.join(webDirectory, 'icons', `Icon-maskable-${size}.png`),
      size,
      { scale: 0.68 },
    );
  }

  const androidDirectory = path.join(
    repositoryRoot,
    'flutter',
    'android',
    'app',
    'src',
    'main',
    'res',
  );
  for (const [density, size] of Object.entries({
    mdpi: 48,
    hdpi: 72,
    xhdpi: 96,
    xxhdpi: 144,
    xxxhdpi: 192,
  })) {
    await renderSquare(
      sourceIcon,
      path.join(androidDirectory, `mipmap-${density}`, 'ic_launcher.png'),
      size,
    );
  }

  const iosDirectory = path.join(
    repositoryRoot,
    'flutter',
    'ios',
    'Runner',
    'Assets.xcassets',
    'AppIcon.appiconset',
  );
  const iosIcons = {
    'Icon-App-20x20@1x.png': 20,
    'Icon-App-20x20@2x.png': 40,
    'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29,
    'Icon-App-29x29@2x.png': 58,
    'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40,
    'Icon-App-40x40@2x.png': 80,
    'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120,
    'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76,
    'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
  };
  for (const [fileName, size] of Object.entries(iosIcons)) {
    await renderSquare(sourceIcon, path.join(iosDirectory, fileName), size);
  }

  const macDirectory = path.join(
    repositoryRoot,
    'flutter',
    'macos',
    'Runner',
    'Assets.xcassets',
    'AppIcon.appiconset',
  );
  for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
    await renderSquare(
      sourceIcon,
      path.join(macDirectory, `app_icon_${size}.png`),
      size,
    );
  }

  const windowsPng = path.join(
    repositoryRoot,
    'tmp',
    'branding',
    'windows-app-icon.png',
  );
  await renderSquare(sourceIcon, windowsPng, 1024);
  const python = process.env.PYTHON || 'python';
  const icoResult = spawnSync(
    python,
    [
      path.join(__dirname, 'png_to_ico.py'),
      windowsPng,
      path.join(
        repositoryRoot,
        'flutter',
        'windows',
        'runner',
        'resources',
        'app_icon.ico',
      ),
    ],
    { stdio: 'inherit' },
  );
  if (icoResult.status !== 0) {
    throw new Error('Das Windows-Icon konnte nicht erzeugt werden.');
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
