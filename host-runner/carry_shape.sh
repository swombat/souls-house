# Shape digest of a resident's carried volume (#426 slice 3C). Runs inside the
# pinned restic image (Alpine busybox) on the house before the carry snapshot
# and on the server after restore_carry, so both sides use the same tools.
#
# Prints exactly two lines and nothing else:
#   entries <count>
#   shape <sha256>
# No file name, size or content leaves the volume. The digest covers four
# streams, each in the same byte-sorted order:
#   1. every relative path, NUL-separated (injective whatever a name holds);
#   2. per path: type, permission bits, uid:gid, one fixed-format line with
#      no name in it;
#   3. per regular file: its size (directory sizes differ by filesystem);
#   4. per symlink: its target as stored, NUL-terminated. Links are read,
#      never followed: find does not descend through them.
# Content is not hashed here: restic hashes it at backup and
# `restic restore --verify` re-reads it after restore.
# set -e with pipefail: a failed find, sort or stat fails the digest instead
# of describing a smaller tree. Every value is taken by assignment, so a
# failure inside a command substitution stops the script too.
set -eo pipefail
cd "$1"
list="$(mktemp)"
files="$(mktemp)"
links="$(mktemp)"
find . -mindepth 1 -print0 | LC_ALL=C sort -z > "$list"
find . -type f -print0 | LC_ALL=C sort -z > "$files"
find . -type l -print0 | LC_ALL=C sort -z > "$links"
paths="$(sha256sum < "$list" | cut -c1-64)"
attrs="$(xargs -0 -r stat -c '%F|%a|%u:%g' < "$list" | sha256sum | cut -c1-64)"
sizes="$(xargs -0 -r stat -c '%s' < "$files" | sha256sum | cut -c1-64)"
targets="$(xargs -0 -r -n1 sh -c 'readlink -n "$1"; printf "\0"' readlink < "$links" | sha256sum | cut -c1-64)"
entries="$(tr -cd '\0' < "$list" | wc -c | tr -d ' ')"
shape="$(printf '%s %s %s %s\n' "$paths" "$attrs" "$sizes" "$targets" | sha256sum | cut -c1-64)"
rm -f "$list" "$files" "$links"
printf 'entries %s\nshape %s\n' "$entries" "$shape"
