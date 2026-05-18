# VFS Skip-Worktree Audit: Potential Issues in microsoft/git

Audit of places in the microsoft/git codebase where skip-worktree entries
interact with filesystem operations in ways that are valid for
sparse-checkout / Scalar clones but can cause problems in VFS (ProjFS)
clones.

## Background

In a VFS repo, files with `CE_SKIP_WORKTREE` set may exist only as virtual
ProjFS projections — they appear in stat/readdir (ProjFS intercepts) but
have no physical NTFS entry. Operations like `unlink()`, `open(O_EXCL)`,
or even `lstat()` (which creates placeholders) can fail or cause unwanted
side effects.

Two bugs in this class have already been fixed:
- **PR #865**: `unpack-trees.c:deleted_entry()` — propagate
  `CE_NEW_SKIP_WORKTREE` to avoid lstats during branch switch
- **PR #915**: `builtin/checkout.c:update_some()` — preserve
  `CE_SKIP_WORKTREE` to avoid unlink during `checkout <tree> -- <path>`

This report catalogs remaining potential issues.

## Risk Levels

- **HIGH**: Confirmed or very likely to cause failures/placeholder creation
  on VFS repos under normal usage
- **MEDIUM**: Can trigger under specific conditions or edge cases
- **LOW**: Properly guarded, or only triggered in unusual scenarios

---

## Category 1: CE_SKIP_WORKTREE Cleared on Replacement Entries

These are the same class of bug as PR #915: a new cache entry replaces an
existing one without preserving skip-worktree, leading to unnecessary
filesystem operations.

### 1.1 `merge-ort.c` — merge result entries (MEDIUM)

**Location**: `merge-ort.c:2057`
```c
ce->ce_flags = create_ce_flags(0);
```

When merge-ort creates result entries (e.g. for .gitattributes or resolved
paths), skip-worktree is not preserved from the original index entry.
Later, `checkout()` in merge-ort may write these to disk unnecessarily.

However, merge-ort has some awareness of skip-worktree at line 4712:
```c
if (ce_skip_worktree(ce))
    errs |= checkout_entry(ce, &state, NULL, NULL);
```
This *intentionally* materializes conflicted skip-worktree entries so the
user can resolve them. The risk is for *clean* merge results that don't
need materialization.

**Triggered by**: `git merge`, `git cherry-pick`, `git rebase` (ort backend)

### 1.2 `builtin/stash.c` — stash apply/pop (MEDIUM)

**Location**: `builtin/stash.c:2057` (approximate)

Stash apply creates new cache entries and explicitly clears skip-worktree:
```c
ce->ce_flags &= ~CE_SKIP_WORKTREE;
```

This forces materialization during stash pop/apply, which may be
intentional (user wants their stashed changes back on disk) but on a VFS
repo could trigger unnecessary placeholder creation for files that weren't
modified in the stash.

**Triggered by**: `git stash pop`, `git stash apply --index`

### 1.3 `builtin/update-index.c:do_add()` (LOW)

**Location**: `builtin/update-index.c:294`
```c
ce->ce_flags = create_ce_flags(0);
```

Creates entries without skip-worktree. This is a low-level plumbing
command rarely used directly. VFS repos would not typically hit this path
in normal workflows.

**Triggered by**: `git update-index`

### 1.4 `apply.c` — patch application (LOW)

**Location**: `apply.c:294` (approximate)
```c
ce->ce_flags = create_ce_flags(0);
```

When `git apply --index` creates replacement entries, skip-worktree is
not preserved. In practice, `git apply` on a VFS repo would typically
operate on hydrated (non-skip-worktree) files.

**Triggered by**: `git apply --index`, `git am`

### 1.5 `builtin/mv.c` — move clearing skip-worktree (LOW)

**Location**: `builtin/mv.c:590`
```c
dst_ce->ce_flags &= ~CE_SKIP_WORKTREE;
```

This intentionally clears skip-worktree when moving a file from
out-of-cone to in-cone in sparse-checkout. Followed immediately by
`checkout_entry()`. On VFS, this could fail if the destination path
is a virtual projection, but `git mv` in a VFS repo would typically
involve hydrated files.

**Triggered by**: `git mv` (sparse-checkout cone transitions)

---

## Category 2: Filesystem Operations Without Skip-Worktree Guards

### 2.1 `unpack-trees.c:verify_uptodate_1()` (HIGH)

**Location**: `unpack-trees.c:2274-2279`
```c
if ((ce->ce_flags & CE_VALID) || ce_skip_worktree(ce))
    ; /* keep checking */
...
if (!lstat(ce->name, &st)) {
```

This function *intentionally* stats skip-worktree entries to verify they
haven't been modified. The comment says "CE_SKIP_WORKTREE cheat, we better
check again." On a VFS repo, this lstat triggers ProjFS placeholder
creation for every skip-worktree entry that reaches this code path.

The caller `verify_uptodate()` has a fast-path exit when both
`CE_SKIP_WORKTREE` and `CE_NEW_SKIP_WORKTREE` are set (line 2312), which
handles the common case during branch switches. But entries that have
`CE_SKIP_WORKTREE` without `CE_NEW_SKIP_WORKTREE` (e.g. during reset or
read-tree operations) will still hit the lstat.

**Triggered by**: `git checkout`, `git merge`, `git reset`, `git read-tree`
(any operation using unpack-trees that modifies skip-worktree entries)

### 2.2 `unpack-trees.c:verify_absent_1()` (MEDIUM)

**Location**: `unpack-trees.c:2515-2570`

Does `lstat(ce->name)` without checking skip-worktree. The caller
`verify_absent()` skips entries with `CE_NEW_SKIP_WORKTREE`, so the common
path is protected. But entries losing skip-worktree (transitioning from
sparse to non-sparse) will be statted.

PR #865 fixed the `deleted_entry()` caller which was passing entries
without `CE_NEW_SKIP_WORKTREE` propagated from the index.

**Triggered by**: Branch switches, merges adding new paths

### 2.3 `entry.c:checkout_entry_ca()` — unlink before write (MEDIUM)

**Location**: `entry.c:580-581`
```c
} else if (unlink(path.buf))
    return error_errno("unable to unlink old '%s'", path.buf);
```

When `checkout_entry_ca()` is called for a file that stat reports as
existing, it calls `unlink()` before writing. On ProjFS, stat succeeds
(virtual projection) but unlink fails (no physical NTFS entry). This is
the root cause of bug 62275980, fixed by preventing `checkout_entry_ca()`
from being called for skip-worktree entries (PR #915).

Any code path that calls `checkout_entry()` for a skip-worktree entry
without first clearing skip-worktree or materializing the file will hit
this. The key is ensuring callers don't reach here for virtual files.

**Triggered by**: Any caller of `checkout_entry()` for skip-worktree entries

### 2.4 `entry.c:unlink_entry()` — removal of virtual files (MEDIUM)

**Location**: `entry.c:598-610`
```c
if (remove_or_warn(ce->ce_mode, ce->name))
    return;
```

Called during checkout/merge when entries are marked `CE_WT_REMOVE`. No
skip-worktree check. On VFS, unlink of a virtual file would fail. However,
entries marked for removal typically have skip-worktree cleared already by
the unpack-trees machinery.

**Triggered by**: Branch switches removing files, `git checkout` removing
entries in no-overlay mode

### 2.5 `diff-lib.c:check_removed()` for merged entries (LOW)

**Location**: `diff-lib.c:42-78`

`check_removed()` does `lstat(ce->name)` without checking skip-worktree.
However, `run_diff_files()` skips skip-worktree entries at line 229:
```c
if (ce_uptodate(ce) || ce_skip_worktree(ce))
    continue;
```

The one gap: merged/conflicted entries (stage > 0) at line 154-161 call
`check_removed()` without this guard. Merged entries in a VFS repo are
unusual but possible during conflict resolution.

**Triggered by**: `git diff` with unmerged entries in VFS repos

---

## Category 3: Stat/Refresh Operations

### 3.1 `read-cache.c:refresh_cache_ent()` (LOW)

**Location**: `read-cache.c:1364`

Properly guards: `if (ce_skip_worktree(ce)) { ce_mark_uptodate(ce); return; }`

Callers can override with `CE_MATCH_IGNORE_SKIP_WORKTREE`, but this is
intentional for operations that need to verify on-disk state.

### 3.2 `preload-index.c:preload_thread()` (LOW)

**Location**: `preload-index.c` (parallel lstat preloading)

Properly guards: `if (ce_skip_worktree(ce)) continue;`

### 3.3 `read-cache.c:ie_match_stat()` (LOW)

**Location**: `read-cache.c:382`

Properly guards: `if (!ignore_skip_worktree && ce_skip_worktree(ce)) return 0;`

---

## Recommendations

### Priority 1 (address alongside PR #915)
- **verify_uptodate_1()**: Consider adding a `core_virtualfilesystem`
  fast-path that skips the lstat entirely for VFS entries, similar to the
  `verify_uptodate()` wrapper's existing `CE_NEW_SKIP_WORKTREE` check.

### Priority 2 (investigate for future PRs)
- **merge-ort clean result entries**: Verify that clean merge results for
  skip-worktree entries don't cause unnecessary materialization.
- **stash apply**: Determine if selective skip-worktree clearing (only for
  files actually in the stash) would be beneficial for VFS.

### Priority 3 (monitor)
- **diff-lib merged entries**: Edge case, low probability in practice.
- **apply.c / update-index.c**: Plumbing commands, rarely hit in VFS
  workflows.

---

## Investigation Results (May 2026)

Detailed analysis of each finding, tested against a GVFS-mounted repo
(ForTests) with ProjFS.  Placeholder creation tracked via the
`VFSForGit.sqlite` Placeholder table; entries measured before/after
operations following `gvfs dehydrate`.

### Category 2 (Filesystem Operations) — Reassessed

#### 2.1 verify_uptodate_1() — CONFIRMED, low practical impact

The lstat fires during `git reset --mixed` (the default reset mode).
The code path: `oneway_merge()` → `merged_entry()` → `verify_uptodate()`
→ `verify_uptodate_1()` → lstat.  This triggers because:

- Mixed reset sets `o->update = 0`
- `skip_sparse_checkout` becomes 1 (line 1961: `!o->update`)
- `mark_new_skip_worktree()` does not run
- `verify_uptodate()` wrapper requires BOTH `CE_SKIP_WORKTREE` and
  `CE_NEW_SKIP_WORKTREE` for the fast-path — without the latter, it
  falls through to `verify_uptodate_1()`
- In `verify_uptodate_1()`, skip-worktree entries explicitly bypass the
  `o->reset` fast-path (line 2274: "CE_SKIP_WORKTREE cheat")

**Repro (ForTests)**: Created a commit modifying a virtual file, then
dehydrated.  `git reset HEAD~1` created 2 new ProjFS directory
placeholders (from 4 → 6) for the path leading to the modified file.

**Practical impact is low** because `git reset --mixed` checks the OLD
index entry (current HEAD) against the working tree.  The files being
checked are ones that differ between current HEAD and target — typically
files the user recently committed, which already have placeholders from
the user's editing workflow.  New placeholder creation only occurs after
dehydration or for files the user never directly accessed (e.g. after
rebase).

**Fix**: Add `core_virtualfilesystem && ce_skip_worktree(ce)` guard in
`verify_uptodate_1()` after the `index_only` check.  Defense-in-depth.
Branch: `tyrielv/vfs-skip-worktree-verify-uptodate`.

#### 2.2 verify_absent_1() — ALREADY PROTECTED

PR #865 propagates `CE_NEW_SKIP_WORKTREE` from index entries to tree
entries in `merged_entry_override()`, and `verify_absent_if_directory()`
skips entries with `CE_NEW_SKIP_WORKTREE`.  The common checkout/merge
paths are protected.

#### 2.3 checkout_entry_ca() — ALREADY FIXED

PR #915 prevents callers from reaching `checkout_entry_ca()` for
skip-worktree entries.  No remaining gap.

#### 2.4 unlink_entry() — PROTECTED BY GVFS FLAG

`apply_sparse_checkout()` line 593 checks
`GVFS_NO_DELETE_OUTSIDE_SPARSECHECKOUT` (bit 3 of `core.gvfs`).  When
set, `CE_WT_REMOVE` is NOT added for entries transitioning to
skip-worktree.  Since VFS repos have this flag in `core.gvfs`,
`unlink_entry()` is never called for virtual files.

Line 578-579 also clears `CE_WT_REMOVE` for entries that were AND remain
skip-worktree, providing a second layer of protection.

#### 2.5 diff-lib check_removed() — MINIMAL IMPACT

`check_removed()` lstats unmerged (stage > 0) entries without a
skip-worktree guard.  However, unmerged entries in a VFS repo have
already been materialized by merge-ort's
`record_conflicted_index_entries()` (line 4712-4713), so the lstat finds
a real file and is cheap.

### Category 1 (CE_SKIP_WORKTREE Cleared) — Reassessed

#### 1.1 merge-ort create_ce_flags(0) — NOT A REAL ISSUE

The `create_ce_flags(0)` at line 2057 only applies to `.gitattributes`
entries in a **temporary attr_index** used for reading merge attributes.
It does NOT affect the main merge result index.

merge-ort's `checkout()` function uses `twoway_merge` with `update=1`,
which triggers `mark_new_skip_worktree()` and properly preserves
skip-worktree for clean results.  Conflicted entries are intentionally
materialized (line 4712-4713) so the user can resolve them.

#### 1.2 stash apply — CORRECTLY SCOPED

`unstage_changes_unless_new()` diffs `orig_tree` (pre-merge state)
against the post-merge index, so it only processes files that the stash
actually modified.  The `ce->ce_flags &= ~CE_SKIP_WORKTREE` at line 559
and the lstat at line 539 are correctly limited to stash-changed files.
Materializing these files is the intended behavior — the user stashed
them and wants them restored to the working tree.
