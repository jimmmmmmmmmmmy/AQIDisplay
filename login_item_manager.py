"""Opt-in login registration. Construction and status checks never modify launchd."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime

LABEL = 'com.user.openair'


def launch_configuration(executable=None, frozen=None):
    executable = Path(executable or sys.executable).absolute()
    frozen = getattr(sys, 'frozen', False) if frozen is None else frozen
    arguments = [str(executable)] if frozen else [str(executable), str(Path(__file__).resolve().with_name('app.py'))]
    if not all(Path(p).is_file() for p in arguments):
        raise ValueError('Launch executable or script does not exist')
    return {'Label': LABEL, 'ProgramArguments': arguments, 'RunAtLoad': True,
            'KeepAlive': False, 'ProcessType': 'Interactive'}


class LoginItemManager:
    def __init__(self):
        self.plist_path = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
        self.domain = f'gui/{os.getuid()}'
        self.service = self.domain + '/' + LABEL

    def isLoginItemEnabled(self):
        result = subprocess.run(['launchctl', 'print', self.service], capture_output=True)
        return result.returncode == 0

    def _create_and_load_launch_agent(self):
        configuration = launch_configuration()
        self.plist_path.parent.mkdir(parents=True, exist_ok=True)
        if self.plist_path.exists():
            shutil.copy2(self.plist_path, self.plist_path.with_suffix('.plist.backup-' + datetime.now().strftime('%Y%m%d%H%M%S')))
        if self.isLoginItemEnabled():
            subprocess.run(['launchctl', 'bootout', self.service], check=True, capture_output=True)
        with self.plist_path.open('wb') as stream:
            plistlib.dump(configuration, stream)
        subprocess.run(['launchctl', 'enable', self.service], check=True, capture_output=True)
        subprocess.run(['launchctl', 'bootstrap', self.domain, str(self.plist_path)], check=True, capture_output=True)

    def _unload_and_remove_launch_agent(self):
        # Retain the plist as a setting; disabling must not delete it.
        subprocess.run(['launchctl', 'disable', self.service], check=True, capture_output=True)
        if self.isLoginItemEnabled():
            subprocess.run(['launchctl', 'bootout', self.service], check=True, capture_output=True)
