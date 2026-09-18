#!/bin/bash

# Stop at the first failure, so that the error names the step that failed.
set -euo pipefail

VERSION=${1:-}
[ -n "$VERSION" ] || { echo "build_imagick.sh: no version given" >&2; exit 2; }

# The perl recipe builds this perl, and the Image::Magick bindings are built
# against it.
[ -d /opt/perl5 ] || {
    echo "build_imagick.sh: /opt/perl5 is not there; the perl recipe has to run first" >&2
    exit 2
}

NICE_PERL_NAME=$(find /opt/perl5 -maxdepth 1 -mindepth 1 -type d | tail -n1 | xargs -r basename)
[ -n "$NICE_PERL_NAME" ] || { echo "build_imagick.sh: no perl installed under /opt/perl5" >&2; exit 2; }

PERL="/opt/perl5/$NICE_PERL_NAME/bin/perl"
[ -x "$PERL" ] || { echo "build_imagick.sh: $PERL is not executable" >&2; exit 2; }

if "$PERL" -MImage::Magick -e 'exit($Image::Magick::VERSION ? 0 : 1)' 2>/dev/null; then
    echo "Image::Magick is already built against $PERL"
    exit 0
fi

mkdir -p /tmp/imagick
# -f makes a 404 fail here and not later in tar.  --retry is there because the
# archive is not always reachable on the first try.
curl -fL --retry 3 --retry-delay 5 \
    "https://download.imagemagick.org/archive/releases/ImageMagick-$VERSION.tar.xz" \
    -o /tmp/imagick/imagemagick.tar.xz

cd /tmp/imagick && tar --one-top-level=src --strip-components=1 -xf /tmp/imagick/imagemagick.tar.xz
cd /tmp/imagick/src
./configure --with-perl="$PERL" --with-gslib=yes --with-lzma=yes --with-jxl=yes --with-heic=yes --with-gvc=yes --with-gslib=yes --with-freetype=yes --with-fontconfig=yes --with-djvu=yes --with-zip=yes --with-zstd=yes --with-zlib=yes --with-xml=yes --with-webp=yes --with-tiff=yes --with-png=yes --with-raw=yes --with-pango=yes --with-tcmalloc=yes
# One job for each processor on the guest, which gets two by default.
make -j"$(nproc 2>/dev/null || echo 2)"
make install
grep -q "/usr/local/lib" /etc/ld.so.conf || echo "/usr/local/lib/" >> /etc/ld.so.conf
ldconfig
"$PERL" -MImage::Magick -e 'print $Image::Magick::VERSION'
