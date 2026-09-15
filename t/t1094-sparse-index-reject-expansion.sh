#!/bin/sh

test_description='index.rejectExpansion makes sparse-index expansion fatal

Verify the diagnostic config option index.rejectExpansion. When enabled, an
attempt to expand a collapsed sparse index to a full index becomes a fatal
error that carries the expansion reason, instead of silently expanding. The
option is default off, and it has no effect when the index is already full.

The option fires on any expansion, including a transient one. A command that
names an out-of-cone path expands to resolve it, then re-collapses the index
before writing, so the on-disk index stays sparse. The option cannot tell a
transient expansion from a persistent one, so it dies on both.'

GIT_TEST_SPLIT_INDEX=0
GIT_TEST_SPARSE_INDEX=

. ./test-lib.sh

# Create a cone-mode sparse-checkout with index.sparse enabled so that the
# index on disk collapses folder1/ into a single sparse-directory entry.
test_expect_success 'setup a repo with a collapsed sparse index' '
	git init sparse-repo &&
	(
		cd sparse-repo &&
		mkdir -p deep/deeper1 folder1 &&
		echo a >a &&
		echo a >deep/a &&
		echo a >deep/deeper1/a &&
		echo a >folder1/a &&
		git add . &&
		git commit -m init &&
		git config index.sparse true &&
		git sparse-checkout set deep/deeper1 &&
		git status &&
		git ls-files --sparse >files &&
		grep "^folder1/$" files
	)
'

# A normal (non sparse) repo whose index is always full.
test_expect_success 'setup a repo with a full index' '
	git init full-repo &&
	(
		cd full-repo &&
		mkdir -p deep/deeper1 folder1 &&
		echo a >a &&
		echo a >deep/deeper1/a &&
		echo a >folder1/a &&
		git add . &&
		git commit -m init
	)
'

test_expect_success 'expansion is allowed and happens by default' '
	rm -f trace2.txt &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C sparse-repo reset -- folder1/a &&
	test_region index ensure_full_index trace2.txt
'

# Naming an out-of-cone path expands the index transiently, but the command
# re-collapses it before writing, so the on-disk index stays sparse. This is
# the healthy transient case that index.rejectExpansion still dies on.
test_expect_success 'a transient path-lookup expansion re-collapses on disk' '
	rm -f trace2.txt &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C sparse-repo reset -- folder1/a &&
	test_region index ensure_full_index trace2.txt &&
	git -C sparse-repo ls-files --sparse >files &&
	grep "^folder1/$" files
'

test_expect_success 'index.rejectExpansion turns expansion into a fatal error' '
	test_must_fail git -C sparse-repo -c index.rejectExpansion=true \
		reset -- folder1/a 2>err &&
	test_grep "refusing to expand a sparse index" err &&
	test_grep "index.rejectExpansion is enabled" err
'

test_expect_success 'the fatal error carries the expansion reason' '
	test_must_fail git -C sparse-repo -c index.rejectExpansion=true \
		reset -- folder1/a 2>err &&
	# The message format is "...enabled): <reason>"; assert a non-empty
	# reason follows the enabled marker.
	sed -n "s/.*index.rejectExpansion is enabled): //p" err >reason &&
	test -s reason
'

test_expect_success 'index.rejectExpansion has no effect on a full index' '
	git -C full-repo -c index.rejectExpansion=true status &&
	git -C full-repo -c index.rejectExpansion=true reset -- folder1/a &&
	git -C full-repo -c index.rejectExpansion=true commit --allow-empty -m x
'

test_expect_success 'index.rejectExpansion defaults to off' '
	rm -f trace2.txt &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C sparse-repo reset -- folder1/a &&
	test_region index ensure_full_index trace2.txt
'

test_done
