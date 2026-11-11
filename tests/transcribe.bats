#!/usr/bin/env bats
#
# Unit tests for bin/transcribe.sh (dotfiles-linux-dev#980).
#
# Strategy: no model download, no real audio. `ffmpeg` is a stub on PATH that
# logs its argv and emits bytes, and TRANSCRIBE_PYTHON points at a stub
# interpreter that logs its argv and the byte count it received on stdin, then
# prints a fixed transcript. This pins the wrapper's contract (ffmpeg decodes to
# 16 kHz mono f32le, python receives model + lang, text reaches stdout) without
# asserting anything about the real engine.
#
# Run locally: bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/bin/transcribe.sh"
    STUB_DIR="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUB_DIR"
    FFMPEG_LOG="$BATS_TEST_TMPDIR/ffmpeg.log"
    PY_LOG="$BATS_TEST_TMPDIR/python.log"

    cat > "$STUB_DIR/ffmpeg" <<EOF
#!/bin/bash
echo "\$*" > "$FFMPEG_LOG"
printf 'ABCDEFGH'
EOF
    cat > "$STUB_DIR/fake_python" <<EOF
#!/bin/bash
# argv: -c <script> <model> <lang>
echo "model=\$3 lang=\$4 bytes=\$(wc -c)" > "$PY_LOG"
echo "ola mundo"
EOF
    chmod +x "$STUB_DIR/ffmpeg" "$STUB_DIR/fake_python"

    AUDIO="$BATS_TEST_TMPDIR/note.ogg"
    : > "$AUDIO"
    export TRANSCRIBE_PYTHON="$STUB_DIR/fake_python"
    export PATH="$STUB_DIR:$PATH"
}

@test "prints the transcript and defaults to --lang pt --model small" {
    run "$SCRIPT" "$AUDIO"
    [ "$status" -eq 0 ]
    [ "$output" = "ola mundo" ]
    grep -q 'model=small lang=pt' "$PY_LOG"
}

@test "decodes through ffmpeg to 16 kHz mono float32 on stdout" {
    run "$SCRIPT" "$AUDIO"
    [ "$status" -eq 0 ]
    grep -q -- "-i $AUDIO" "$FFMPEG_LOG"
    grep -q -- '-f f32le -ac 1 -ar 16000 -' "$FFMPEG_LOG"
    grep -q 'bytes=8' "$PY_LOG"
}

@test "--lang and --model are passed through" {
    run "$SCRIPT" --lang en --model tiny "$AUDIO"
    [ "$status" -eq 0 ]
    grep -q 'model=tiny lang=en' "$PY_LOG"
}

@test "missing audio file fails with a clear error" {
    run "$SCRIPT" "$BATS_TEST_TMPDIR/nope.ogg"
    [ "$status" -eq 2 ]
    [[ "$output" == *"audio file not found"* ]]
}

@test "no arguments prints usage and fails" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "unknown option fails" {
    run "$SCRIPT" --bogus "$AUDIO"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown option"* ]]
}

@test "missing engine points at install_faster_whisper" {
    export TRANSCRIBE_PYTHON="$BATS_TEST_TMPDIR/absent_python"
    run "$SCRIPT" "$AUDIO"
    [ "$status" -eq 2 ]
    [[ "$output" == *"install_faster_whisper"* ]]
}

@test "an ffmpeg failure fails the whole pipeline" {
    printf '#!/bin/bash\nexit 1\n' > "$STUB_DIR/ffmpeg"
    run "$SCRIPT" "$AUDIO"
    [ "$status" -ne 0 ]
}
