#!/bin/sh

# Usage: ./docker.sh
#
# Example: ./docker.sh        #< build all images

namespace="registry.gitlab.com/dxld/cabal-helper/ci"

tmpdir=$(mktemp -p "${TMPDIR:-/tmp/}" -d cabal-helper-docker-XXXX) || exit 1

dldir="/tmp/cabal-helper-docker-dl"

GHC_BASE=https://downloads.haskell.org/~ghc
HACKAGE_BASE=https://hackage.haskell.org/package
STACK_BASE=https://github.com/commercialhaskell/stack/releases/download

image=debian:buster
cabal=3.0.0.0
stack=2.1.3

ghc_arch=x86_64-deb8-linux
ghcs='8.8.1 8.6.5 8.4.4 8.2.2 8.0.2'

stack_url="${STACK_BASE}/v${stack}/stack-${stack}-linux-x86_64-static.tar.gz"
stack_file="$(basename "$stack_url")"

mkdir -p "$dldir"
printf '%s\n' $ghcs > "$tmpdir"/ghcs

{
        echo "$stack_url"
        for ghc in $ghcs; do
                echo "${GHC_BASE}/${ghc}/ghc-${ghc}-${ghc_arch}.tar.xz"
        done
} | tee "$tmpdir"/ghc-urls | xargs -n1 -P$(nproc) sh -ue -c '
  cd "$1"
  wget -nv -nc -c "$3"
  cp "$(basename "$3")"  "$2"
' urldl "$dldir" "$tmpdir"

ghc_files=""
for url in $(cat "$tmpdir"/ghc-urls); do
        ghc_files=""$(basename "$url")" $ghc_files"
done

cat > "$tmpdir"/install-ghc.sh <<"EOF"
$!/bin/sh
set -eux
ghc=$1; shift
tar -xf ghc-${ghc}-*.tar.xz
cd ghc-${ghc}
./configure --prefix=/usr/local/ghc-${ghc}
make install
ln -s /usr/local/ghc-${ghc}/bin/*-${ghc} /usr/local/bin
for f in /usr/local/ghc-${ghc}/bin/*-${ghc}; do
    ln -s "$f" /usr/local/bin/"$(basename "${f%.*}")"
done
cd ..
EOF

cat > "$tmpdir"/Dockerfile <<EOF
FROM $image AS base

## ensure locale is set during build
ENV LANG C.UTF-8

WORKDIR /root

RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      alex happy wget git xz-utils gpgv ca-certificates build-essential \
      libgmp3-dev libtinfo-dev libtinfo5 zlib1g-dev netbase pkg-config && \
    apt-get clean


FROM base AS build

COPY ghcs install-ghc.sh $ghc_files /root/
COPY $cabal_file $cabal_bin_file $stack_file /root/

RUN apt-get install -y --no-install-recommends ghc cabal-install

RUN cd /usr/local/bin && \
    tar -xvf /root/${stack_file} \
        --strip-components 1 --wildcards '*/stack' && \
    stack --help >/dev/null

RUN cat ghcs | xargs -P$(nproc) -n1 sh install-ghc.sh

RUN cabal update && \
    cabal install cabal-install-${cabal} --ghc-option=-j && \
    cp -L ~/.cabal/bin/cabal /usr/local/bin

FROM base
COPY --from=build /usr/local/ /usr/local/

EOF

tag="${namespace}:ghc-$(printf '%s' "$ghcs" | tr ' ' '-')--cabal-install-${cabal}--stack-${stack}"
docker build -t "$tag" "$tmpdir"

for ghc in $ghcs; do
        stag="${namespace}:ghc-${ghc}--cabal-install-${cabal}--stack-${stack}"
        printf '%s\n' \
               "FROM $tag" \
               'ENV PATH="/usr/local/ghc-'"${ghc}"'/bin:${PATH}"' \
                | docker build -t "$stag" -
done
