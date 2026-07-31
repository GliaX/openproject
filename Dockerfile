# Custom OpenProject image = upstream all-in-one + the
# openproject-meeting_markdown_export plugin.
#
# This mirrors the prior Docker-host build: FROM the moving upstream :17 tag and
# `bundle install` the plugin Gemfile. Because BUNDLE_FROZEN is off, bundler
# re-resolves dependencies, so a rebuild tracks the latest upstream 17.x gems.
# The currently DEPLOYED image (ghcr.io/gliax/openproject:17.0.4) was imported
# from the prior build to preserve the exact running version; rebuilds are an
# explicit upgrade — see README.md "Image build & version drift".
FROM openproject/openproject:17

# The published runtime image ships no compiler; re-add just enough to build the
# extra gem (matches upstream docker/prod/setup/preinstall-common.sh).
USER root
RUN apt-get update -qq \
 && apt-get install -yq --no-install-recommends \
      build-essential libssl-dev libyaml-dev libpq-dev libclang-dev libffi-dev git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --chown=app:app Gemfile.plugins Gemfile.lock /app/

USER app
RUN bundle config set frozen false \
 && bundle config set without 'development test' \
 && bundle install --jobs 4 \
 && bundle config set frozen true
