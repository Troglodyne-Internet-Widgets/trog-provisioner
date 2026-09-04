#!/bin/bash

VERSION=$1

export NICE_PERL_NAME=$(find /opt/perl5 -maxdepth 1 -mindepth 1 -type d | tail -n1 | xargs basename)
if [ ! $(/opt/perl5/$NICE_PERL_NAME/bin/perl -MImage::Magick -e 'print "OK" if Image::Magick::VERSION') ]; then
	mkdir -p /tmp/imagick
	curl -L https://download.imagemagick.org/archive/releases/ImageMagick-$VERSION.tar.xz -o /tmp/imagick/imagemagick.tar.xz
	cd /tmp/imagick && tar --one-top-level=src --strip-components=1 -xf /tmp/imagick/imagemagick.tar.xz
	cd /tmp/imagick/src && ./configure --with-perl=/opt/perl5/$NICE_PERL_NAME/bin/perl --with-gslib=yes --with-lzma=yes --with-jxl=yes --with-heic=yes --with-gvc=yes --with-gslib=yes --with-freetype=yes --with-fontconfig=yes --with-djvu=yes --with-zip=yes --with-zstd=yes --with-zlib=yes --with-xml=yes --with-webp=yes --with-tiff=yes --with-png=yes --with-raw=yes --with-pango=yes --with-tcmalloc=yes
	cd /tmp/imagick/src && make -j8
	cd /tmp/imagick/src && make install
	grep -q "/usr/local/lib" /etc/ld.so.conf || echo "/usr/local/lib/" >> /etc/ld.so.conf
	ldconfig
	/opt/perl5/$NICE_PERL_NAME/bin/perl -MImage::Magick -e 'print $Image::Magick::VERSION'
fi
