# Custom OpenProject image = upstream all-in-one + the
# openproject-meeting_markdown_export plugin.
#
# We layer the plugin onto the PINNED upstream image and `bundle install`
# against the upstream Gemfile.lock (kept in the image, NOT shipped here).
# Bundler converges on the locked versions and only adds the plugin, so rails
# stays at the OpenProject-supported 8.0.x instead of jumping to 8.1.x.
FROM openproject/openproject:17.6.0

# The published runtime image ships no compiler; re-add just enough to build the
# extra gem (matches upstream docker/prod/setup/preinstall-common.sh).
USER root
RUN apt-get update -qq \
 && apt-get install -yq --no-install-recommends \
      build-essential libssl-dev libyaml-dev libpq-dev libclang-dev libffi-dev git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --chown=app:app Gemfile.plugins /app/Gemfile.plugins

USER app
# Add the plugin on top of the upstream lockfile (converge, don't re-resolve).
RUN bundle config set frozen false \
 && bundle config set without 'development test' \
 && bundle install --jobs 4 \
 && bundle config set frozen true

# Restore the all-in-one image's runtime user (root). The entrypoint runs
# supervisord as root and checks the external DB via `su postgres -c psql ...`;
# leaving USER=app (set above for bundle install) makes that fail.
USER root
