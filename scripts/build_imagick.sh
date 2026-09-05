#!/bin/bash

# Every failure here used to be silent and cascading: curl could not reach the
# archive, tar was handed a file that was not there, three cd's into a directory
# that did not exist each failed on their own, and the only thing that reported
# anything was post_install noticing the exit status at the very end.
set -euo pipefail

VERSION=${1:-}
[ -n "$VERSION" ] || { echo "build_imagick.sh: no version given" >&2; exit 2; }

# The perl recipe builds this, and imagemagick's bindings are built against it.
# imagemagick did not declare that it needs it, so on a guest without it the
# find below found nothing, the name came out empty, and every line after ran
# against "/opt/perl5//bin/perl".
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
# -f so a 404 fails here instead of arriving as "tar: Cannot open", and --retry
# because the archive is not always reachable first time.
curl -fL --retry 3 --retry-delay 5 \
    "https://download.imagemagick.org/archive/releases/ImageMagick-$VERSION.tar.xz" \
    -o /tmp/imagick/imagemagick.tar.xz

cd /tmp/imagick && tar --one-top-level=src --strip-components=1 -xf /tmp/imagick/imagemagick.tar.xz
cd /tmp/imagick/src
./configure --with-perl="$PERL" --with-gslib=yes --with-lzma=yes --with-jxl=yes --with-heic=yes --with-gvc=yes --with-gslib=yes --with-freetype=yes --with-fontconfig=yes --with-djvu=yes --with-zip=yes --with-zstd=yes --with-zlib=yes --with-xml=yes --with-webp=yes --with-tiff=yes --with-png=yes --with-raw=yes --with-pango=yes --with-tcmalloc=yes
# As many jobs as the guest has processors; it gets two by default, and -j8
# oversubscribes that fourfold.
make -j"$(nproc 2>/dev/null || echo 2)"
make install
grep -q "/usr/local/lib" /etc/ld.so.conf || echo "/usr/local/lib/" >> /etc/ld.so.conf
ldconfig
"$PERL" -MImage::Magick -e 'print $Image::Magick::VERSION'
