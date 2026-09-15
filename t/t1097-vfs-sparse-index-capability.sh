#!/bin/sh

test_description='git version advertises the vfs-sparse-index capability

GVFS probes "git version --build-options" for a capability line before it
enables the sparse index in a virtual-filesystem repository. The feature needs
the sparse-awareness changes in this build (a sparse-aware
apply_virtualfilesystem() and cone-membership evaluation under a virtual
filesystem). Stock git lacks them and produces a silently full index, so GVFS
must detect the difference. This build advertises "feature: vfs-sparse-index"
so GVFS can refuse the feature cleanly when the line is absent.'

. ./test-lib.sh

test_expect_success 'git version --build-options lists the vfs-sparse-index feature' '
	git version --build-options >out &&
	grep "^feature: vfs-sparse-index$" out
'

test_expect_success 'the capability is also present via git --version --build-options' '
	git --version --build-options >out &&
	grep "^feature: vfs-sparse-index$" out
'

test_expect_success 'plain git version does not list build features' '
	git version >out &&
	! grep "^feature: vfs-sparse-index$" out
'

test_done
