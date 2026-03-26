#!/usr/bin/env python3
import os
import subprocess

from rucio.db.sqla.util import build_database, create_base_vo, create_root_account

build_database()
create_base_vo()
create_root_account()
print('DB bootstrap complete')