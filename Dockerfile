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
      libyaml-0-2 \
      imagemagick \
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

# Bundler resilience: parallel fetches with retries (transient registry hiccups
# killed earlier builds mid-run).
ENV BUNDLE_RETRY="5" \
    BUNDLE_JOBS="8"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libyaml-dev \
      pkg-config \
      && rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

RUN bundle exec bootsnap precompile --gemfile app/ lib/
# The app boots a full production env during precompile (its encrypted
# credentials initializer demands a secret); SECRET_KEY_BASE_DUMMY=1 lets Rails
# derive a build-time throwaway secret without baking anything sensitive.
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

# Runtime stage.
FROM base

ENV LD_PRELOAD="libjemalloc.so.2"

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

RUN useradd rails --create-home --shell /bin/bash && \
    mkdir -p db log storage tmp && \
    chown -R rails:rails db log storage tmp
USER rails:rails

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000

CMD ["bin/thrust", "./bin/rails", "server"]
