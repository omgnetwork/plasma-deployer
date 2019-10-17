FROM erlang:21-alpine

MAINTAINER Ino Murko <ino@omise.co>

# Create and set home directory
WORKDIR /opt/plasma_deployer

# Configure required environment
ENV MIX_ENV prod

# elixir expects utf8.
ENV ELIXIR_VERSION="v1.8.2" \
	LANG=C.UTF-8

RUN set -xe \
	&& ELIXIR_DOWNLOAD_URL="https://github.com/elixir-lang/elixir/archive/${ELIXIR_VERSION}.tar.gz" \
	&& ELIXIR_DOWNLOAD_SHA256="cf9bf0b2d92bc4671431e3fe1d1b0a0e5125f1a942cc4fdf7914b74f04efb835" \
	&& buildDeps=' \
		ca-certificates \
		curl \
		make \
	' \
	&& apk add --no-cache --virtual .build-deps $buildDeps \
	&& curl -fSL -o elixir-src.tar.gz $ELIXIR_DOWNLOAD_URL \
	&& echo "$ELIXIR_DOWNLOAD_SHA256  elixir-src.tar.gz" | sha256sum -c - \
	&& mkdir -p /usr/local/src/elixir \
	&& tar -xzC /usr/local/src/elixir --strip-components=1 -f elixir-src.tar.gz \
	&& rm elixir-src.tar.gz \
	&& cd /usr/local/src/elixir \
	&& make install clean \
	&& apk del .build-deps

#lets add plasma contract to the dir
RUN apk add --no-cache git
RUN git clone https://github.com/omisego/plasma-contracts .
RUN git checkout 7b8a2643568556c1d126749724666bc37edc8141
RUN ls

COPY mix.* ./
COPY . .

RUN mix do local.hex --force, local.rebar --force
RUN mix deps.get
RUN MIX_ENV=prod mix escript.build

###node for truffle
RUN apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/v3.7/main/ nodejs=10.14.2-r0
RUN apk add --update npm
RUN apk add --update \
    python \
    python-dev \
    py-pip \
    build-base \
  && pip install virtualenv \
  && rm -rf /var/cache/apk/*

#last bits to get things going, npm install from contracts
RUN cd plasma_framework && npm install
# curl for healthchecks
RUN apk add --no-cache curl
RUN cd ../

CMD [ "./plasma_deployer" ]