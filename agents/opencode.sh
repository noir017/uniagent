#!/bin/bash
# opencode-ai（npm 全局，落在 /usr/lib/node_modules）。
set -eux
npm install -g --allow-scripts=opencode-ai opencode-ai
npm cache clean --force
opencode --version
