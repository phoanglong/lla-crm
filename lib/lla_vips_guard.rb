# frozen_string_literal: true

# CVE-2026-66066 / GHSA-xr9x-r78c-5hrm. libvips ships loaders its own authors mark
# as unfuzzed and unsafe on untrusted input, and Active Storage <= 7.1 never
# disables them, so an uploaded file alone can make libvips read a path the request
# had no business reading — `secret_key_base` among them, which turns a file read
# into remote code execution. Generating a variant is not a separate requirement:
# analysing the upload is enough. There is no patched Rails 7.1 release.
#
# `lla/rails/config/initializers/active_storage_security.rb` pins the variant
# processor to `:mini_magick`, which keeps Active Storage away from libvips entirely
# and is what closes the advisory today. This guard is for the case that pin does
# not cover: someone points the processor back at `:vips`. Then the advisory's own
# documented workaround has to already be in force.
#
# It lives here rather than inline in the initializer so it can be called, and
# therefore tested, without re-reading and re-evaluating a config file.
module LlaVipsGuard
  MINIMUM_RUBY_VIPS = '2.2.1'

  module_function

  # Returns :not_applicable when Active Storage is not using vips, :blocked when the
  # block was applied. Raises rather than warn when it cannot apply one: a security
  # control that reports success while doing nothing is worse than no control.
  def apply!(processor: ActiveStorage.variant_processor)
    return :not_applicable unless processor == :vips

    require_vips!
    ensure_blockable!
    Vips.block_untrusted(true)
    :blocked
  end

  def require_vips!
    require 'vips'
  rescue LoadError => e
    # Configured for vips with no libvips to talk to: variant processing in this
    # deployment is already broken. Saying so here beats failing later, on
    # somebody's upload.
    raise "active_storage.variant_processor is :vips but libvips could not be loaded (#{e.message}). " \
          'Install libvips, or leave the processor on :mini_magick.'
  end

  def ensure_blockable!
    return if Vips.respond_to?(:block_untrusted) &&
              Gem::Version.new(Vips::VERSION) >= Gem::Version.new(MINIMUM_RUBY_VIPS)

    raise 'ruby-vips is too old to block untrusted libvips operations ' \
          "(need >= #{MINIMUM_RUBY_VIPS} for Vips.block_untrusted, loaded #{Vips::VERSION}). " \
          'See CVE-2026-66066.'
  end
end
