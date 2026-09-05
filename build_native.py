"""Build a standalone, locally signed Tahoe app using Apple's installed SDK."""
from pathlib import Path
from datetime import datetime
import argparse
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=root / 'dist-native')
args = parser.parse_args()
subprocess.run(['swift', 'build', '-c', 'release', '--product', 'OpenAir'], cwd=root, check=True)
bin_dir = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip())
bundle = args.output.resolve() / 'OpenAir.app'
if bundle.exists():
    bundle.rename(bundle.with_name('OpenAir.previous-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.app'))
(bundle / 'Contents/MacOS').mkdir(parents=True)
(bundle / 'Contents/Resources').mkdir()
shutil.copy2(bin_dir / 'OpenAir', bundle / 'Contents/MacOS/OpenAir')
shutil.copy2(root / 'air_icon.icns', bundle / 'Contents/Resources/air_icon.icns')
info = {'CFBundleIdentifier': 'com.openair.mac', 'CFBundleName': 'OpenAir',
        'CFBundleDisplayName': 'OpenAir', 'CFBundleExecutable': 'OpenAir',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.3.3',
        'CFBundleVersion': '6', 'CFBundleIconFile': 'air_icon',
        'LSMinimumSystemVersion': '26.0', 'LSUIElement': True,
        'NSHighResolutionCapable': True}
with (bundle / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
print('Built:', bundle)
