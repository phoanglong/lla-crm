# frozen_string_literal: true

require 'rails_helper'

# Hợp đồng của điểm nối mở rộng LLA (ADR-OMCRM-032).
# Không phụ thuộc bất kỳ tệp nào trong enterprise/.
describe ChatwootApp do
  # enterprise?/lla? đều memoize, phải xoá giữa các ví dụ
  def reset_memoization!
    described_class.instance_variables.each do |ivar|
      described_class.remove_instance_variable(ivar)
    end
  end

  before { reset_memoization! }
  after { reset_memoization! }

  describe '.env_flag?' do
    it 'trả về false khi biến không được đặt hoặc là chuỗi rỗng' do
      expect(described_class.env_flag?('LLA_TEST_FLAG_UNSET')).to be false
      with_env('LLA_TEST_FLAG', '') { expect(described_class.env_flag?('LLA_TEST_FLAG')).to be false }
      with_env('LLA_TEST_FLAG', '   ') { expect(described_class.env_flag?('LLA_TEST_FLAG')).to be false }
    end

    it 'trả về true cho các giá trị bật' do
      %w[true TRUE t yes y 1 on enabled].each do |value|
        with_env('LLA_TEST_FLAG', value) { expect(described_class.env_flag?('LLA_TEST_FLAG')).to be true }
      end
    end

    it 'trả về false cho mọi giá trị phủ định' do
      %w[false FALSE f no n 0 off].each do |value|
        with_env('LLA_TEST_FLAG', value) { expect(described_class.env_flag?('LLA_TEST_FLAG')).to be false }
      end
    end
  end

  describe '.enterprise?' do
    it 'trả về false (không phải nil) khi DISABLE_ENTERPRISE bật' do
      with_env('DISABLE_ENTERPRISE', 'true') { expect(described_class.enterprise?).to be false }
    end

    it 'không bị tắt bởi DISABLE_ENTERPRISE=false' do
      with_env('DISABLE_ENTERPRISE', 'false') do
        expect(described_class.enterprise?).to eq(described_class.root.join('enterprise').exist?)
      end
    end
  end

  describe '.lla?' do
    it 'nhận diện thư mục lla/rails/app' do
      expect(described_class.lla?).to be(described_class.root.join('lla/rails/app').exist?)
    end
  end

  describe '.extensions' do
    it 'luôn xếp lla sau cùng để Lla:: thắng Enterprise:: khi cả hai tồn tại' do
      expect(described_class.extensions.last).to eq('lla') if described_class.lla?
    end

    it 'chỉ còn lla khi enterprise/ bị tắt' do
      with_env('DISABLE_ENTERPRISE', 'true') do
        reset_memoization!
        expect(described_class.extensions).not_to include('enterprise')
        expect(described_class.extensions).to include('lla')
      end
    end
  end

  describe 'cơ chế prepend' do
    it 'prepend module Lla:: vào class CE qua prepend_mod_with' do
      stub_const('LlaSeamProbe', Class.new { def label = 'ce' })
      stub_const('Lla::LlaSeamProbe', Module.new { def label = "lla+#{super}" })

      LlaSeamProbe.prepend_mod_with('LlaSeamProbe')

      expect(LlaSeamProbe.new.label).to eq('lla+ce')
    end
  end

  def with_env(key, value)
    previous = ENV.fetch(key, nil)
    ENV[key] = value
    reset_memoization!
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
    reset_memoization!
  end
end
