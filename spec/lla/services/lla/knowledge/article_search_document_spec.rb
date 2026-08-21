require 'rails_helper'

RSpec.describe Lla::Knowledge::ArticleSearchDocument do
  let(:article) do
    build(:article,
          title: '<b>Reset password</b>',
          description: 'A **safe** guide',
          content: "First step. Second step.\n\n<script>alert(1)</script> Final step.")
  end

  it 'builds a deterministic, bounded, plain-text search document' do
    terms = described_class.terms(article)

    expect(terms).to include('Reset password', 'Reset password — A safe guide')
    expect(terms.join(' ')).not_to include('<script>', '**')
    expect(terms.size).to be <= described_class::MAX_TERMS
    expect(terms).to all(satisfy { |term| term.bytesize <= described_class::MAX_TERM_BYTES })
    expect(described_class.digest(article)).to match(/\A[0-9a-f]{64}\z/)
  end

  it 'changes the digest when indexable content changes' do
    original = described_class.digest(article)
    article.content = 'Different content'

    expect(described_class.digest(article)).not_to eq(original)
  end
end
