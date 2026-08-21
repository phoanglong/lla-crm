# frozen_string_literal: true

require_relative '../../lib/lla_vips_guard'

# See `lib/lla_vips_guard.rb` for why this exists. In short: Active Storage <= 7.1
# leaves libvips' unsafe loaders enabled (CVE-2026-66066), the variant processor is
# pinned away from vips to avoid them, and this is the belt to that pair of braces
# in case the pin is ever undone.
#
# The Dockerfile also sets `VIPS_BLOCK_UNTRUSTED`, which libvips honours at library
# initialisation in every process in the image, before any Ruby has run. This one
# travels with the code instead, so a checkout running outside that image is covered
# too.
Rails.application.config.after_initialize { LlaVipsGuard.apply! }
