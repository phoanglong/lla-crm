# frozen_string_literal: true

require 'rails_helper'
require 'lla_vips_guard'

# CVE-2026-66066 / GHSA-xr9x-r78c-5hrm: libvips exposes loaders its own authors mark
# as unsafe on untrusted input, and Active Storage <= 7.1 never disables them, so an
# uploaded file can be made to read arbitrary paths — `secret_key_base` among them.
# Rails 7.1 has no patched release, so this application relies on two mitigations,
# and both are asserted here rather than assumed.
RSpec.describe LlaVipsGuard do
  before { require 'vips' }

  after { Vips.block_untrusted(false) }

  it 'keeps Active Storage off the affected processor, which is what closes the advisory today' do
    expect(ActiveStorage.variant_processor).to eq(:mini_magick)
  end

  it 'does nothing when the processor is not vips, because there is nothing to protect' do
    expect(Vips).not_to receive(:block_untrusted).with(true)
    expect(described_class.apply!(processor: :mini_magick)).to eq(:not_applicable)
  end

  it 'blocks untrusted loaders when the processor is pointed back at vips' do
    expect(described_class.apply!(processor: :vips)).to eq(:blocked)
  end

  it 'runs a ruby-vips new enough for the block to exist' do
    expect(Vips).to respond_to(:block_untrusted)
    expect(Gem::Version.new(Vips::VERSION)).to be >= Gem::Version.new(described_class::MINIMUM_RUBY_VIPS)
  end

  it 'links a libvips new enough to honour a block at all' do
    expect(Gem::Version.new(Vips.version_string.split('-').first)).to be >= Gem::Version.new('8.13')
  end

  # `block_untrusted` is write-only, so the proof has to be behavioural. Blocked, an
  # untrusted loader answers "operation is blocked". Unblocked, this same call
  # reports the file does not exist — which is to say, it went and looked.
  it 'actually refuses an untrusted loader afterwards, and not before' do
    missing = Rails.root.join('tmp/does-not-exist.hdr').to_s

    expect { Vips::Image.analyzeload(missing) }.to raise_error(Vips::Error, /unable to open file/)

    described_class.apply!(processor: :vips)

    expect { Vips::Image.analyzeload(missing) }.to raise_error(Vips::Error, /operation is blocked/)
  end

  it 'refuses to boot rather than pretend, when ruby-vips cannot be told to block' do
    stub_const('Vips::VERSION', '2.1.4')
    allow(Vips).to receive(:respond_to?).with(:block_untrusted).and_return(false)

    expect { described_class.apply!(processor: :vips) }
      .to raise_error(/too old to block untrusted libvips operations/)
  end
end
