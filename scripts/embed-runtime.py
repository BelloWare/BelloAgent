#!/usr/bin/env python3
"""Xcode copy phase. The generated resources remain outside the repository."""
import os
from pathlib import Path
import shutil
source = Path(os.environ['PI_BUILD_ROOT']).resolve() / 'bundle'
app = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['CONTENTS_FOLDER_PATH']
for name, destination in [('Helpers', app / 'Helpers'), ('Host', app / 'Resources/Host'), ('Transcript', app / 'Resources/Transcript')]:
    assert (source / name).is_dir(), f'Run scripts/build-bundle.py first: {source / name}'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source / name, destination, symlinks=True)
