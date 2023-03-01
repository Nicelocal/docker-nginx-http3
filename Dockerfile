# https://hg.nginx.org/nginx-quic/fie/tip/src/core/nginx.h
ARG NGINX_VERSION=1.23.3

# https://hg.nginx.org/nginx-quic/shortlog/quic
ARG NGINX_COMMIT=91ad1abfb285

# https://github.com/google/boringssl
ARG BORINGSSL_COMMIT=028bae7ddc67b6061d80c17b0be4e2f60d94731b

# http://hg.nginx.org/njs
ARG NJS_VERSION=0.7.10

# https://hg.nginx.org/nginx-quic/file/quic/README#l72
ARG CONFIG="\
		--build=quic-$NGINX_COMMIT-boringssl-$BORINGSSL_COMMIT \
		--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--modules-path=/usr/lib/nginx/modules \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/var/run/nginx.pid \
		--lock-path=/var/run/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
		--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
		--user=nginx \
		--group=nginx \
		--with-http_ssl_module \
		--with-http_realip_module \
		--with-http_addition_module \
		--with-http_sub_module \
		--with-http_dav_module \
		--with-http_flv_module \
		--with-http_mp4_module \
		--with-http_gunzip_module \
		--with-http_gzip_static_module \
		--with-http_random_index_module \
		--with-http_secure_link_module \
		--with-http_stub_status_module \
		--with-http_auth_request_module \
		--with-http_xslt_module=dynamic \
		--with-threads \
		--with-stream \
		--with-stream_ssl_module \
		--with-stream_ssl_preread_module \
		--with-stream_realip_module \
		--with-http_slice_module \
		--with-mail \
		--with-mail_ssl_module \
		--with-compat \
		--with-file-aio \
		--with-http_v2_module \
		--with-http_v3_module \
		--add-module=/usr/src/njs-$NJS_VERSION/nginx \
	"

FROM ubuntu:22.04 AS base

ARG NGINX_VERSION
ARG NGINX_COMMIT
ARG BORINGSSL_COMMIT
ARG NJS_VERSION
ARG CONFIG

RUN apt update

RUN \
	apt install --no-install-recommends -y \
		curl \
		ca-certificates \
		gcc \
		libc-dev \
		make \
		golang \
		musl-dev \
		ninja-build \
		libssl-dev \
		libpcre3-dev \
		zlib1g-dev \
		gnupg \
		libxslt-dev \
		\
		autoconf \
		libtool \
		automake \
		g++ \
		cmake \
		\
		libreadline-dev

WORKDIR /usr/src/

RUN \
	echo "Cloning nginx $NGINX_VERSION (rev $NGINX_COMMIT from 'quic' branch) ..." \
	&& curl -L https://hg.nginx.org/nginx-quic/archive/$NGINX_COMMIT.tar.gz > nginx-quic.tar.gz \
	&& tar zxvf nginx-quic.tar.gz --directory /usr/src/

# hadolint ignore=SC2086
RUN \
	echo "Cloning boringssl ..." \
	&& curl -L https://github.com/google/boringssl/archive/$BORINGSSL_COMMIT.tar.gz > boringssl.tar.gz \
	&& echo https://github.com/google/boringssl/archive/$BORINGSSL_COMMIT.tar.gz \
	&& tar zxvf boringssl.tar.gz --directory /usr/src/ \
	&& echo "Building boringssl ..." \
	&& cd /usr/src/boringssl-$BORINGSSL_COMMIT \
	&& mkdir build \
	&& cd build \
	&& cmake -GNinja .. \
	&& ninja

RUN \
	echo "Cloning and configuring njs ..." \
	&& curl -L http://hg.nginx.org/njs/archive/$NJS_VERSION.tar.gz > nginx-njs.tar.gz \
	&& tar zxvf nginx-njs.tar.gz --directory /usr/src/ \
	&& cd /usr/src/njs-$NJS_VERSION \
	&& ./configure \
	&& make njs \
	&& mv /usr/src/njs-$NJS_VERSION/build/njs /usr/sbin/njs \
	&& echo "njs v$(njs -v)"

RUN \
	echo "Building nginx ..." \
	&& cd /usr/src/nginx-quic-$NGINX_COMMIT \
	&& ./auto/configure $CONFIG \
		--with-cc-opt="-I../boringssl-$BORINGSSL_COMMIT/include" \
		--with-ld-opt="-L../boringssl-$BORINGSSL_COMMIT/build/ssl \
		-L../boringssl-$BORINGSSL_COMMIT/build/crypto" \
	&& make -j"$(getconf _NPROCESSORS_ONLN)"

RUN \
	cd /usr/src/nginx-quic-$NGINX_COMMIT \
	&& make install \
	&& rm -rf /etc/nginx/html/ \
	&& mkdir /etc/nginx/conf.d/ \
	&& strip /usr/sbin/nginx* \
	&& strip /usr/lib/nginx/modules/*.so \
	\
	# https://tools.ietf.org/html/rfc7919
	# https://github.com/mozilla/ssl-config-generator/blob/master/docs/ffdhe2048.txt
	&& curl -L https://ssl-config.mozilla.org/ffdhe2048.txt > /etc/ssl/dhparam.pem \
	\
	# Bring in gettext so we can get `envsubst`, then throw
	# the rest away. To do this, we need to install `gettext`
	# then move `envsubst` out of the way so `gettext` can
	# be deleted completely, then move `envsubst` back.
	&& apt install --no-install-recommends -y gettext \
	\
	&& readelf -d /usr/sbin/nginx /usr/sbin/njs /usr/lib/nginx/modules/*.so /usr/bin/envsubst | awk '/NEEDED/{ gsub(/(\[|\])/, ""); print $(NF)}' \
		| while read n; do dpkg-query -S $n 2>/dev/null; done \
		| sed 's/^\([^:]\+\):.*$/\1/' \
		| uniq \
		| sort -u > /tmp/runDeps.txt

FROM ubuntu:22.04
ARG NGINX_VERSION
ARG NGINX_COMMIT

ENV NGINX_VERSION $NGINX_VERSION
ENV NGINX_COMMIT $NGINX_COMMIT

COPY --from=base /tmp/runDeps.txt /tmp/runDeps.txt
COPY --from=base /etc/nginx /etc/nginx
COPY --from=base /usr/lib/nginx/modules/*.so /usr/lib/nginx/modules/
COPY --from=base /usr/sbin/nginx /usr/sbin/
COPY --from=base /usr/bin/envsubst /usr/local/bin/envsubst
COPY --from=base /etc/ssl/dhparam.pem /etc/ssl/dhparam.pem
COPY --from=base /usr/sbin/njs /usr/sbin/njs

# hadolint ignore=SC2046
RUN \
	&& addgroup --gid 1001 --system nginx \
	&& adduser --uid 1000 --disabled-password --system --home /var/cache/nginx --shell /sbin/nologin --ingroup nginx nginx \
	&& apt update && apt install --no-install-recommends -y tzdata $(cat /tmp/runDeps.txt) \
	&& rm /tmp/runDeps.txt \
	&& ln -s /usr/lib/nginx/modules /etc/nginx/modules \
	# forward request and error logs to docker log collector
	&& mkdir /var/log/nginx \
	&& touch /var/log/nginx/access.log /var/log/nginx/error.log \
	&& ln -sf /dev/stdout /var/log/nginx/access.log \
	&& ln -sf /dev/stderr /var/log/nginx/error.log

COPY nginx.conf /etc/nginx/nginx.conf
COPY ssl_common.conf /etc/nginx/conf.d/ssl_common.conf

# show env
RUN env | sort

# njs version
RUN njs -v

# test the configuration
RUN nginx -V; nginx -t

EXPOSE 8080 8443

STOPSIGNAL SIGTERM

# prepare to switching to non-root - update file permissions
RUN chown --verbose nginx:nginx \
	/var/run/nginx.pid

USER nginx
CMD ["nginx", "-g", "daemon off;"]
