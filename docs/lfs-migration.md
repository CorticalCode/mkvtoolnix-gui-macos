# LFS Migration: Existing Clones

If you cloned this repo before 2026-04-15, your local copy includes ~534 MB of pre-built dependency archives that are now managed as opt-in downloads. New clones are ~1 MB.

This is a one-time migration. Once complete, your repo stays lightweight and future pulls will not re-download the binaries.

## Recommended: Re-clone

The simplest fix is to delete your existing clone and start fresh:

```sh
cd ..
rm -rf mkvtoolnix-gui-macos
git clone https://github.com/CorticalCode/mkvtoolnix-gui-macos.git
cd mkvtoolnix-gui-macos
```

Your local build cache (`/opt/mtx/prefix/proven/`) is not affected — it lives outside the repo and will be picked up by future builds automatically.

## Alternative: Manual cleanup

If you have local branches or uncommitted work you want to preserve:

```sh
# 1. Pull the latest changes (includes .lfsconfig)
git pull

# 2. Remove the smudged binary files
rm proven/arm/*.tar.gz proven/intel/*.tar.gz

# 3. Restore as lightweight pointer files (~130 bytes each)
GIT_LFS_SKIP_SMUDGE=1 git checkout -- proven/

# 4. Prune the LFS object cache
git lfs prune

# 5. Verify
du -sh .    # should be ~1-2 MB
```

## Why is this necessary?

The repo now includes a `.lfsconfig` file that tells Git LFS not to download dependency archives automatically. However, if your clone already has the full binaries from before this change, Git considers them "up to date" and won't replace them — even with the new config.

The manual cleanup removes the old binaries so Git can restore the lightweight pointer files in their place.

## After migration

No further action needed. Future `git pull` operations will not re-download the binaries. If you need the pre-built dependencies for building, use:

```sh
./build-local.sh --restore-cache
```

See [Build Workflow](build-workflow.md) for full details on all build options.
