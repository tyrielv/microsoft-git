#!/bin/sh

test_description='virtualfilesystem is sparse-index aware

Verify that apply_virtualfilesystem() does not expand a collapsed sparse
index. apply_virtualfilesystem() runs on every index read, so a forced
expansion there defeats the sparse index in a virtual-filesystem repository.
The clear-skip-worktree pass must still work on the collapsed index: it must
clear CE_SKIP_WORKTREE for the in-cone paths the hook reports as present, and
it must leave out-of-cone sparse-directory entries untouched.'

GIT_TEST_SPLIT_INDEX=0
GIT_TEST_SPARSE_INDEX=

. ./test-lib.sh

# Build a cone-mode sparse-checkout repository, enable index.sparse so the
# index on disk collapses the out-of-cone "out/" directory into a single
# sparse-directory entry, then turn on core.virtualfilesystem with a hook that
# reports both in-cone and out-of-cone paths as present. The out-of-cone path
# is what forced the pre-change code to expand the index.
test_expect_success 'setup a virtualfilesystem repo with a collapsed sparse index' '
	git init vfs &&
	(
		cd vfs &&
		mkdir -p in/deeper out &&
		printf a >r &&
		printf a >in/a &&
		printf a >in/deeper/a &&
		printf a >out/f1 &&
		printf a >out/f2 &&
		git add . &&
		git commit -m init &&
		git config index.sparse true &&
		git sparse-checkout set in &&

		git ls-files --sparse >files &&
		grep "^out/$" files &&
		grep "^in/a$" files &&

		write_script .git/hooks/virtualfilesystem <<-\EOF &&
			printf "r\0"
			printf "in/a\0"
			printf "in/deeper/a\0"
			printf "out/f1\0"
		EOF
		git config core.virtualfilesystem .git/hooks/virtualfilesystem
	)
'

test_expect_success 'apply_virtualfilesystem does not expand the sparse index' '
	rm -f trace2.txt &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C vfs status &&
	test_region ! index ensure_full_index trace2.txt
'

test_expect_success 'status succeeds under index.rejectExpansion' '
	git -C vfs -c index.rejectExpansion=true status
'

test_expect_success 'the index stays sparse after a virtualfilesystem read' '
	git -C vfs status &&
	git -C vfs ls-files --sparse >files &&
	grep "^out/$" files
'

test_expect_success 'skip-worktree is cleared for in-cone present paths without expanding' '
	test_when_finished "git -C vfs checkout -- in/a" &&
	printf changed >>vfs/in/a &&
	rm -f trace2.txt &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C vfs -c index.rejectExpansion=true status --porcelain >out &&
	test_region ! index ensure_full_index trace2.txt &&
	grep "in/a" out
'

test_expect_success 'out-of-cone content stays collapsed and is left untouched' '
	rm -f trace2.txt &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C vfs -c index.rejectExpansion=true status --porcelain >out &&
	test_region ! index ensure_full_index trace2.txt &&
	! grep "out/" out &&
	git -C vfs ls-files --sparse >files &&
	grep "^out/$" files
'

test_done
