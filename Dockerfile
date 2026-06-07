# syntax=docker/dockerfile:1

# Multi-stage build for production.
# See: https://blog.saeloun.com/2026/05/04/rails-containerization-best-practices/

# Base image.
FROM docker.io/library/ruby:3.4.3-slim AS base

# Install dependencies.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl \
      libjemalloc2 \
      libvips \
      libpq-dev \
      postgresql-client \
      && rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /rails

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    MALLOC_ARENA_MAX="2"

# Build stage.
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      pkg-config \
      && rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

RUN bundle exec bootsnap precompile --gemfile app/ lib/
RUN bin/rails assets:precompile

# Runtime stage.
FROM base

ENV LD_PRELOAD="libjemalloc.so.2"

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

RUN useradd rails --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER rails:rails

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000

CMD ["bin/thrust", "./bin/rails", "server"]
