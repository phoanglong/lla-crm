# frozen_string_literal: true

# Rails 7.1 defaults to libvips, which is affected by CVE-2026-66066 when
# processing untrusted uploads. Both supported LLA runtime paths install
# ImageMagick, so keep variants on the unaffected processor until the framework
# is upgraded to a patched Active Storage release.
Rails.application.config.active_storage.variant_processor = :mini_magick
