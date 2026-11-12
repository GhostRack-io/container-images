#!/bin/bash
# Resolves each base of images.toml to the digest its tag names on Docker
# Hub now, and rewrites images.toml when one moved. Alpine follows its
# current release: when a newer one is out, the entry of a release (a
# MAJOR.MINOR tag) moves its version, display name and base tag to it.
# Alpine edge, and any other entry whose tag is not a release, keeps its
# tag and only its digest moves.
#
#   scripts/update-bases.sh
#
# Prints one line per change; prints nothing and leaves images.toml as it
# is when every base is current. Needs curl and python3.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "${repo}/scripts/lib.sh"

accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

# token REPOSITORY: an anonymous pull token of Docker Hub.
token() {
    curl -fsS --retry 3 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$1:pull" \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["token"])'
}

# digest REPOSITORY TAG: the digest of what TAG names (the multi-platform
# index where there is one).
digest() {
    local found
    found=$(curl -fsS --retry 3 -I -H "Authorization: Bearer $(token "$1")" -H "Accept: ${accept}" \
        "https://registry-1.docker.io/v2/$1/manifests/$2" \
        | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p')
    [[ ${found} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "update-bases.sh: no digest for $1:$2" >&2; return 1; }
    echo "${found}"
}

# latest_release REPOSITORY: the highest MAJOR.MINOR tag.
latest_release() {
    curl -fsS --retry 3 -H "Authorization: Bearer $(token "$1")" \
        "https://registry-1.docker.io/v2/$1/tags/list?n=10000" \
        | python3 -c '
import json, re, sys
tags = [t for t in json.load(sys.stdin)["tags"] if re.fullmatch(r"[0-9]+\.[0-9]+", t)]
print(max(tags, key=lambda t: tuple(map(int, t.split(".")))))'
}

changes=()
while IFS=$'\t' read -r -u 3 name version family _init _stop base display_name _memory _level; do
    reference=${base%@*}
    path=${reference#docker.io/}
    repository=${path%:*}
    tag=${path##*:}
    new_version=${version}
    new_display=${display_name}
    if [[ ${family} == alpine && ${tag} =~ ^[0-9]+\.[0-9]+$ ]]; then
        release=$(latest_release "${repository}")
        if [[ ${release} != "${tag}" ]]; then
            tag=${release}
            new_version=${release}
            new_display="Alpine Linux ${release}"
        fi
    fi
    new_base="docker.io/${repository}:${tag}@$(digest "${repository}" "${tag}")"
    if [[ ${new_base} != "${base}" || ${new_version} != "${version}" ]]; then
        echo "${name}:${version}: ${base} -> ${new_base}"
        changes+=("${name}" "${version}" "${new_version}" "${new_display}" "${new_base}")
    fi
done 3< <(images_tsv)

[[ ${#changes[@]} == 0 ]] && exit 0
python3 - "${repo}/images.toml" "${changes[@]}" << 'PYTHON'
import json, re, sys
path, rest = sys.argv[1], sys.argv[2:]
text = open(path).read()
head, *blocks = re.split(r"(?m)^(?=\[\[image\]\]\n)", text)
for i in range(0, len(rest), 5):
    name, version, new_version, new_display, new_base = rest[i:i + 5]
    for n, block in enumerate(blocks):
        if re.search(rf'(?m)^name = {re.escape(json.dumps(name))}$', block) and \
                re.search(rf'(?m)^version = {re.escape(json.dumps(version))}$', block):
            block = re.sub(r'(?m)^version = .*$', lambda _: f"version = {json.dumps(new_version)}", block)
            block = re.sub(r'(?m)^display_name = .*$', lambda _: f"display_name = {json.dumps(new_display)}", block)
            block = re.sub(r'(?m)^base = .*$', lambda _: f"base = {json.dumps(new_base)}", block)
            blocks[n] = block
            break
    else:
        sys.exit(f"update-bases.sh: no entry {name}:{version} to rewrite")
open(path, "w").write(head + "".join(blocks))
PYTHON
images_tsv > /dev/null
