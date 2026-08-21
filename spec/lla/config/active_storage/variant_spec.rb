require 'rails_helper'

RSpec.describe ActiveStorage::Variant do
  it 'processes untrusted image variants without the vulnerable libvips path' do
    expect(Rails.application.config.active_storage.variant_processor).to eq(:mini_magick)
  end
end
