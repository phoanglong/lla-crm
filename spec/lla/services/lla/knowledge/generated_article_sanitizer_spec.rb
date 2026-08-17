require 'rails_helper'

RSpec.describe Lla::Knowledge::GeneratedArticleSanitizer do
  it 'removes executable HTML, event handlers and active markdown schemes' do
    result = described_class.call(
      title: '<b>Safe title</b>',
      description: '<i>Summary</i>',
      content: '<script>alert(1)</script><img src=x onerror=alert(2)> [run](javascript:alert(3))'
    )

    expect(result).to include(title: 'Safe title', description: 'Summary')
    expect(result[:content]).not_to match(/script|onerror|javascript:/i)
    expect(result[:content]).to include('[run](#)')
  end

  it 'bounds every generated field' do
    result = described_class.call(title: 't' * 100, description: 'd' * 300, content: 'c' * 20_000)

    expect(result.transform_values { |value| value&.length }).to eq(title: 80, description: 200, content: 18_000)
  end
end
