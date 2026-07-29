#!/usr/bin/env python3
"""
Audio transcription script using Whisper Large V3 Turbo (MLX format)
"""

import mlx_whisper
import argparse
import json
import sys
import threading
import time
from pathlib import Path


class LoadingSpinner:
    """Simple loading spinner animation with percentage"""

    def __init__(self, message="Loading"):
        self.message = message
        self.running = False
        self.thread = None
        self.frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        self.percent = 0

    def _spin(self):
        while self.running:
            for frame in self.frames:
                if not self.running:
                    break
                sys.stdout.write(f"\r{self.message} {frame} {self.percent}%")
                sys.stdout.flush()
                time.sleep(0.1)
                self.percent = min(self.percent + 1, 99)

    def start(self):
        self.running = True
        self.percent = 0
        self.thread = threading.Thread(target=self._spin)
        self.thread.daemon = True
        self.thread.start()

    def stop(self, final_message="Done"):
        self.running = False
        if self.thread:
            self.thread.join()
        sys.stdout.write(f"\r{final_message} 100%\n")
        sys.stdout.flush()


def transcribe_audio(
    audio_path: str,
    model_path: str = "mlx-community/whisper-large-v3-turbo",
    language: str = None,
    task: str = "transcribe",
    verbose: bool = False
):
    """
    Transcribe audio file using Whisper Large V3 Turbo.

    Args:
        audio_path: Path to audio file
        model_path: Path or HuggingFace repo for the model
        language: Language code (e.g., 'en', 'es', 'zh', 'uk', 'ru'). Auto-detect if None
        task: 'transcribe' or 'translate'
        verbose: Print verbose output
    """
    if verbose:
        print(f"Model path: {model_path}")
        print(f"Audio file: {audio_path}")
        print()

    options = {
        "task": task,
    }

    if language:
        options["language"] = language

    spinner = LoadingSpinner("Loading model & Transcribing")
    spinner.start()

    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=model_path,
        **options
    )

    spinner.stop("Transcription complete!")

    return result


def main():
    parser = argparse.ArgumentParser(
        description="Transcribe audio using Whisper Large V3 Turbo (MLX)"
    )
    parser.add_argument(
        "audio_file",
        help="Path to audio file to transcribe"
    )
    parser.add_argument(
        "-m", "--model",
        default="mlx-community/whisper-large-v3-turbo",
        help="Model path or HuggingFace repo (default: mlx-community/whisper-large-v3-turbo)"
    )
    parser.add_argument(
        "-l", "--language",
        help="Language code (auto-detect if not specified)"
    )
    parser.add_argument(
        "-t", "--task",
        choices=["transcribe", "translate"],
        default="transcribe",
        help="Task to perform (default: transcribe)"
    )
    parser.add_argument(
        "-o", "--output",
        help="Output file for JSON results"
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Print verbose output"
    )

    args = parser.parse_args()

    result = transcribe_audio(
        audio_path=args.audio_file,
        model_path=args.model,
        language=args.language,
        task=args.task,
        verbose=args.verbose
    )

    print("\n" + "─" * 60)
    print("TRANSCRIPTION:")
    print("─" * 60)
    print(result.get("text", ""))
    print("─" * 60)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
            print(f"\nFull results saved to: {args.output}")


if __name__ == "__main__":
    main()
