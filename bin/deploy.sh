#!/bin/bash -uxe

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
TEMP=$(mktemp -d)

git worktree add "$TEMP" gh-pages
rsync --archive --delete --exclude .git "$DIR"/../site/build/ "$TEMP"
git -C "$TEMP" add -A
git -C "$TEMP" commit --amend -m "$(date -R)"
git -C "$TEMP" push -f
git worktree remove --force "$TEMP"
