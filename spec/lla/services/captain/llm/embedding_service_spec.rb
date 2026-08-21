require 'rails_helper'

RSpec.describe Captain::Llm::EmbeddingService, type: :service do
  def configure_embedding_model(value)
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_EMBEDDING_MODEL').tap do |config|
      config.value = value
      config.locked = false
      config.save!
    end
  end

  describe '.embedding_model' do
    it 'uses the installation embedding model when configured' do
      configure_embedding_model('text-embedding-ada-002')

      expect(described_class.embedding_model).to eq('text-embedding-ada-002')
    end

    it 'falls back to the default embedding model when the installation value is blank' do
      configure_embedding_model('')

      expect(described_class.embedding_model).to eq(LlmConstants::DEFAULT_EMBEDDING_MODEL)
    end
  end

  describe '#get_embedding' do
    let(:account) { create(:account) }
    let(:vector) { Array.new(1536, 0.1) }
    let(:embedding_response) { double('embedding_response', vectors: vector) } # rubocop:disable RSpec/VerifiedDoubles

    it 'sends a registered installation embedding model to RubyLLM' do
      configure_embedding_model('text-embedding-ada-002')

      expect(RubyLLM).to receive(:embed).with('search text', model: 'text-embedding-ada-002').and_return(embedding_response)

      expect(described_class.new(account_id: account.id).get_embedding('search text')).to eq(vector)
    end

    it 'rejects an unregistered model before calling the provider' do
      configure_embedding_model('custom-embedding-model')

      expect(RubyLLM).not_to receive(:embed)
      expect { described_class.new(account_id: account.id).get_embedding('search text') }
        .to raise_error(described_class::UnsupportedModel, 'embedding model is not registered')
    end

    it 'rejects a provider vector with the wrong dimensions' do
      allow(RubyLLM).to receive(:embed).and_return(Struct.new(:vectors).new([0.1, 0.2]))

      expect { described_class.new(account_id: account.id).get_embedding('search text') }
        .to raise_error(described_class::InvalidEmbedding, 'embedding dimension does not match profile')
    end

    it 'rejects non-finite values and oversized input' do
      invalid_vector = vector.tap { |values| values[4] = Float::INFINITY }
      allow(RubyLLM).to receive(:embed).and_return(Struct.new(:vectors).new(invalid_vector))

      expect { described_class.new(account_id: account.id).get_embedding('search text') }
        .to raise_error(described_class::InvalidEmbedding, 'embedding contains a non-finite value')
      expect { described_class.new(account_id: account.id).get_embedding('x' * 32_001) }
        .to raise_error(described_class::InvalidEmbedding, 'embedding input is invalid')
    end
  end
end
