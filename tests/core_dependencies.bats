#!/usr/bin/env bats
#
# #767: geomview (3D geometry viewer) had no consumer; it must stay out of the
# core dependencies and the workspace Utilities lists.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "install_core_dependencies does not install geomview" {
    run grep -i geomview "$REPO_ROOT/distro_config/install_coding_lib/bootstrappers.sh"
    [ "$status" -ne 0 ]
}

@test "ubuntu_workspace.sh does not list geomview" {
    run grep -i geomview "$REPO_ROOT/distro_config/ubuntu_workspace.sh"
    [ "$status" -ne 0 ]
}
