# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lla::ProductVersion do
  it 'uses independent product and Chatwoot compatibility versions' do
    expect(described_class.name).to eq('LLA CRM')
    expect(described_class.current).to eq(Rails.root.join('VERSION_LLA').read.strip)
    expect(described_class.compatibility_product).to eq('Chatwoot')
    expect(described_class.compatibility_version).to eq(Rails.root.join('VERSION_CW').read.strip)
  end

  it 'keeps the JavaScript package version aligned with the product version' do
    package = JSON.parse(Rails.root.join('package.json').read)

    expect(package['version']).to eq(described_class.current)
  end
end
