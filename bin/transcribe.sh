#!/bin/bash
#
# Local voice-note transcription (dotfiles-linux-dev#980): audio path in, text out.
#
# Usage:
#   bin/transcribe.sh [--lang <code>] [--model <size>] <audio-file>
#
# Defaults: --lang pt, --model small (CPU, int8). Text goes to stdout, so the
# result pipes or redirects cleanly.
#
# Why ffmpeg decodes instead of faster-whisper: faster-whisper's own decoder
# (PyAV) fails with the av version pip resolves today (`TypeError: open() got an
# unexpected keyword argument 'metadata_errors'`). System ffmpeg turns any input
# (WhatsApp .ogg, .m4a, ...) into raw 16 kHz mono float32 on a pipe, and the
# samples go to transcribe() as a numpy array, so the av pairing no longer
# matters.
#
# Needs: ffmpeg on PATH and the faster-whisper engine from `install_faster_whisper`
# (the whisper-ctranslate2 pipx venv). Both are overridable, so tests never need
# the real thing:
#   TRANSCRIBE_PYTHON   python interpreter that can import faster_whisper
#   PIPX_HOME           where the pipx venv lives (default: ~/.local/share/pipx)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

LANG_CODE="pt"
MODEL="small"
AUDIO=""

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
    print_status "error" "$1"
    exit 2
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --lang)    [[ $# -ge 2 ]] || die "--lang needs a value"; LANG_CODE="$2"; shift ;;
            --model)   [[ $# -ge 2 ]] || die "--model needs a value"; MODEL="$2"; shift ;;
            -*)        die "unknown option: $1" ;;
            *)         [[ -z "$AUDIO" ]] || die "only one audio file at a time"; AUDIO="$1" ;;
        esac
        shift
    done
    [[ -n "$AUDIO" ]] || { usage >&2; exit 2; }
    [[ -f "$AUDIO" ]] || die "audio file not found: $AUDIO"
}

resolve_python() {
    if [[ -n "${TRANSCRIBE_PYTHON:-}" ]]; then
        printf '%s' "$TRANSCRIBE_PYTHON"
        return
    fi
    printf '%s' "${PIPX_HOME:-$HOME/.local/share/pipx}/venvs/whisper-ctranslate2/bin/python"
}

# Reads raw float32 samples on stdin; prints the transcript.
PY_TRANSCRIBE='
import sys
import numpy as np
from faster_whisper import WhisperModel

model_size, lang = sys.argv[1], sys.argv[2]
audio = np.frombuffer(sys.stdin.buffer.read(), dtype=np.float32)
if audio.size == 0:
    sys.exit("no audio samples decoded")
model = WhisperModel(model_size, device="cpu", compute_type="int8")
segments, _ = model.transcribe(audio, language=lang)
print(" ".join(s.text.strip() for s in segments))
'

main() {
    parse_args "$@"

    command_exists ffmpeg || die "ffmpeg not found — install it first (system package)"

    local python_bin
    python_bin="$(resolve_python)"
    [[ -x "$python_bin" ]] || die "faster-whisper engine not found at $python_bin — run install_faster_whisper"

    ffmpeg -nostdin -loglevel error -i "$AUDIO" -f f32le -ac 1 -ar 16000 - \
        | "$python_bin" -c "$PY_TRANSCRIBE" "$MODEL" "$LANG_CODE"
}

main "$@"
