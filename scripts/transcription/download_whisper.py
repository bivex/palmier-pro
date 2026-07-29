#!/usr/bin/env python3
"""
Whisper Large V3 Turbo (MLX) Downloader with Progress Tracking
"""

import sys
import os
import time
from huggingface_hub import snapshot_download

MODEL_ID = "mlx-community/whisper-large-v3-turbo"

def main():
    print("STARTING:0.0", flush=True)
    try:
        path = snapshot_download(repo_id=MODEL_ID)
        print("PROGRESS:1.00", flush=True)
        print(f"DONE:{path}", flush=True)
    except Exception as e:
        print(f"ERROR:{str(e)}", sys.stderr, flush=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
