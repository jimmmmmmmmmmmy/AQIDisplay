# Build with: .venv/bin/python -m PyInstaller OpenAir.spec
analysis = Analysis(['app.py'], pathex=[], binaries=[], datas=[], hiddenimports=[],
                    hookspath=[], hooksconfig={}, runtime_hooks=[], excludes=[])
pyz = PYZ(analysis.pure)
exe = EXE(pyz, analysis.scripts, [], exclude_binaries=True, name='OpenAir',
          debug=False, bootloader_ignore_signals=False, strip=False, upx=False,
          console=False, target_arch=None, codesign_identity=None, entitlements_file=None)
collection = COLLECT(exe, analysis.binaries, analysis.datas, strip=False, upx=False, name='OpenAir')
app = BUNDLE(collection, name='OpenAir.app', icon='air_icon.icns',
             bundle_identifier='com.user.openair',
             info_plist={'LSUIElement': True, 'CFBundleShortVersionString': '0.2.0',
                         'NSHighResolutionCapable': True})
