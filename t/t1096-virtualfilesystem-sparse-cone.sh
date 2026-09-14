#!/bin/sh

test_description='cone-mode membership is honored under a virtual filesystem

Verify that path_in_sparse_checkout() and path_matches_pattern_list() consult
the cone-mode sparse-checkout patterns when the sparse index feature is active
(cone-mode sparse-checkout with index.sparse), even while core.virtualfilesystem
is set. Without this, every path is treated as in-cone under a virtual
filesystem, so convert_to_sparse() can never collapse an out-of-cone directory
into a sparse-directory entry.

When the feature is off (index.sparse false), a virtual-filesystem repository
must behave exactly as before: every path is treated as in-cone and nothing
collapses.'

GIT_TEST_SPLIT_INDEX=0
GIT_TEST_SPARSE_INDEX=

. ./test-lib.sh

# Build a cone-mode sparse-checkout repository restricted to "in/", with
# index.sparse turned off first so the on-disk index stays expanded, then
# enable core.virtualfilesystem with a hook that reports the in-cone paths as
# present. The out-of-cone entries keep CE_SKIP_WORKTREE, which is required
# before an out-of-cone directory can collapse. The expanded baseline is the
# original virtual-filesystem behavior: nothing collapses while the feature is
# off, even though "out/" is outside the cone. This exercises the feature-off
# path of both gates: is_sparse_index_allowed() is false, so every path is
# treated as in-cone exactly as before.
test_expect_success 'setup an expanded cone-mode virtualfilesystem repo (feature off)' '
	git init gb &&
	(
		cd gb &&
		mkdir -p in/deeper out &&
		printf a >r &&
		printf a >in/a &&
		printf a >in/deeper/a &&
		printf a >out/f1 &&
		printf a >out/f2 &&
		git add . &&
		git commit -m init &&
		git config index.sparse false &&
		git sparse-checkout set in &&

		write_script .git/hooks/virtualfilesystem <<-\EOF &&
			printf "r\0"
			printf "in/a\0"
			printf "in/deeper/a\0"
		EOF
		git config core.virtualfilesystem .git/hooks/virtualfilesystem &&

		git ls-files --sparse >files &&
		grep "^out/f1$" files &&
		grep "^out/f2$" files &&
		! grep "^out/$" files
	)
'

# Core proof: with the feature on, the out-of-cone "out/" directory collapses
# into a single sparse-directory entry, even though core.virtualfilesystem is
# set. Before this change, path_in_sparse_checkout() returned "in checkout" for
# every path under a virtual filesystem, so convert_to_sparse() never collapsed
# and "out/" stayed expanded as it did in the setup above.
test_expect_success 'out-of-cone directory collapses under virtualfilesystem when index.sparse is on' '
	git -C gb config index.sparse true &&
	git -C gb sparse-checkout reapply &&
	git -C gb ls-files --sparse >collapsed &&
	grep "^out/$" collapsed &&
	! grep "^out/f1$" collapsed &&
	! grep "^out/f2$" collapsed &&
	grep "^in/a$" collapsed &&
	grep "^in/deeper/a$" collapsed
'

# The collapse and a following read must not force the sparse index to expand.
test_expect_success 'status stays collapsed under index.rejectExpansion' '
	rm -f trace2.txt &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C gb -c index.rejectExpansion=true status &&
	test_region ! index ensure_full_index trace2.txt &&
	git -C gb ls-files --sparse >files &&
	grep "^out/$" files
'

# A modified in-cone file is still reported while the out-of-cone directory
# stays a collapsed sparse-directory entry.
test_expect_success 'in-cone changes are reported without expanding' '
	test_when_finished "git -C gb checkout -- in/a" &&
	printf changed >>gb/in/a &&
	rm -f trace2.txt &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C gb -c index.rejectExpansion=true status --porcelain >out &&
	test_region ! index ensure_full_index trace2.txt &&
	grep "in/a" out &&
	! grep "out/" out
'

# A repository with core.virtualfilesystem but no cone-mode sparse-checkout is
# the classic VFS configuration. is_sparse_index_allowed() is false there
# (no cone patterns), so both gates keep the original behavior and every path
# is treated as in-cone.
test_expect_success 'non-cone virtualfilesystem repo is unaffected' '
	git init novfscone &&
	(
		cd novfscone &&
		mkdir -p in out &&
		printf a >in/a &&
		printf a >out/f1 &&
		git add . &&
		git commit -m init &&

		write_script .git/hooks/virtualfilesystem <<-\EOF &&
			printf "in/a\0"
			printf "out/f1\0"
		EOF
		git config core.virtualfilesystem .git/hooks/virtualfilesystem &&

		git status --porcelain >out.txt &&
		test_must_be_empty out.txt
	)
'

test_done
