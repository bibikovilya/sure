ARG RUBY_VERSION=3.4.7
FROM ruby:${RUBY_VERSION}-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# libvips42 supports ActiveStorage image variants through image_processing/ruby-vips
# for existing profile/avatar images. AccountStatement.original_file only stores
# PDF/CSV/XLSX originals, but the devcontainer needs this broader image stack.
RUN apt-get update -qq \
  && apt-get -y install --no-install-recommends \
    apt-utils \
    build-essential \
    curl \
    git \
    imagemagick \
    iproute2 \
    libvips42 \
    libpq-dev \
    libyaml-dev \
    libyaml-0-2 \
    openssh-client \
    vim \
    procps \
    chromium \
    chromium-driver \
    gnupg \
    lsb-release \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update -qq \
  && apt-get -y install --no-install-recommends postgresql-client-16 \
  && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set environment variable for Chrome/Chromium browser path
ENV BROWSER_PATH=/usr/bin/chromium

RUN gem install bundler foreman

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
  && apt-get install -y nodejs \
  && rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /workspace
