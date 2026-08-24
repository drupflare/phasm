#!/usr/bin/env bash
# Pins the emscripten builder image to a content digest instead of a floating tag.
#
# php-wasm's docker-compose.yml names the image as
# `seanmorris/php-emscripten-builder` with no tag, so every build resolves `:latest` at the
# moment it runs. That is the one input a release body cannot record honestly: the rc hash and
# the php-wasm commit are pinned, the compiler is not, so two builds of "the same inputs" can
# differ by a whole emsdk. Recording the digest after the fact identifies a binary; pinning it
# before the fact is what makes the identity a choice.
#
# How it pins without editing php-wasm: the checkout is fetched, not vendored, so its compose
# file is not ours to change. Pulling by digest and then tagging that image `:latest` locally
# leaves compose resolving the name it already uses to exactly the image named here - compose's
# default pull policy is "missing", so a tag that already exists locally is never re-resolved.
#
# The digest below was read from the registry rather than from a local docker:
#   seanmorris/php-emscripten-builder:latest
#   sha256:e576eaa989829bc1240ad0edfe288f4dce0da4bcdd2036308562c68f26a2bd19
#   linux/amd64, 8 layers, created 2025-04-03
#
# To move the pin, read the new digest the same way and replace it here, in one place:
#   TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io\
# &scope=repository:seanmorris/php-emscripten-builder:pull" | ...)
#   curl -sI -H "Authorization: Bearer $TOKEN" \
#     -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
#     https://registry-1.docker.io/v2/seanmorris/php-emscripten-builder/manifests/latest
#
# Usage:
#   bash src/pin-builder-image.sh            pull the pinned image and tag it locally
#   bash src/pin-builder-image.sh --print    print the pinned reference, pull nothing
set -euo pipefail

BUILDER_IMAGE="${BUILDER_IMAGE:-seanmorris/php-emscripten-builder}"
BUILDER_IMAGE_DIGEST="${BUILDER_IMAGE_DIGEST:-sha256:e576eaa989829bc1240ad0edfe288f4dce0da4bcdd2036308562c68f26a2bd19}"
BUILDER_IMAGE_TAG="${BUILDER_IMAGE_TAG:-latest}"
PINNED="${BUILDER_IMAGE}@${BUILDER_IMAGE_DIGEST}"

if [ "${1:-}" = "--print" ]; then
	echo "$PINNED"
	exit 0
fi

command -v docker > /dev/null || {
	echo "no docker on PATH; the builder image cannot be pinned"
	exit 1
}

echo "pinning $PINNED"
docker pull "$PINNED"
docker tag "$PINNED" "${BUILDER_IMAGE}:${BUILDER_IMAGE_TAG}"

# a tag carries no digest of its own, so this reads the digest back off the image the tag now
# points at. Without it a pull that quietly no-oped would leave whatever :latest already was
got="$(docker image inspect "${BUILDER_IMAGE}:${BUILDER_IMAGE_TAG}" --format '{{index .RepoDigests 0}}')"
if [ "$got" != "$PINNED" ]; then
	echo "::error::${BUILDER_IMAGE}:${BUILDER_IMAGE_TAG} is $got, not the pinned $PINNED" >&2
	exit 1
fi
echo "${BUILDER_IMAGE}:${BUILDER_IMAGE_TAG} is $got"
