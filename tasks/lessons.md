# Lessons Learned

## 2026-03-28: ALWAYS TEST BEFORE COMMIT

**Pattern:** Made code changes and told user to commit without running `zig build` first.

**Result:** 7 commits to fix issues that could have been caught with a single local build.

**Rule:**
- ALWAYS run `zig build` locally before telling user to commit or deploy
- NEVER assume code changes will work without verification
- For Zig projects: `/opt/zig-0.16.0-dev/zig build` must pass before any commit recommendation

**Specific Mistakes:**
1. Changed `std.posix.write()` without verifying it exists in Zig 0.16 - it doesn't
2. Assumed Zig 0.16 I/O buffered writer would work - it didn't
3. Made assumptions about Alpine vs Debian without testing the actual issue first

**Correct Approach:**
1. Make code change
2. Run `zig build` locally
3. If build fails, fix it
4. Only then tell user to commit/deploy
