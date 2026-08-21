require 'rails_helper'

RSpec.describe Captain::Copilot::ResponseJob, type: :job do
  let(:account) { create(:account, limits: { captain_responses: 10 }) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:source_message) do
    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      conversation: conversation,
      message: { 'content' => 'Private prompt' },
      message_type: :user
    ).tap(&:reserve_response!)
  end
  let(:reservation_token) { source_message.response_job_token }
  let(:chat_service) { instance_double(Captain::Copilot::ChatService) }

  before do
    allow(Redis::Alfred).to receive(:set).and_return(true)
    allow(Redis::Alfred).to receive(:delete_if_equals).and_return(true)
    allow(Captain::Copilot::ChatService).to receive(:new).with(source_message).and_return(chat_service)
    allow(chat_service).to receive(:generate_response) do
      source_message.reload.complete_response!
      { 'content' => 'Safe response' }
    end
  end

  def perform(token = reservation_token)
    described_class.perform_now(message_id: source_message.id, reservation_token: token)
  end

  it 'revalidates, claims and generates using only the persisted source message' do
    expect(Captain::Copilot::ChatService).to receive(:new).with(source_message).and_return(chat_service)
    expect(chat_service).to receive(:generate_response)

    perform

    expect(source_message.reload).to be_response_completed
    expect(source_message.response_attempts).to eq(1)
    # Wave E5 moved Captain quota into the LLA ledger; the old
    # `custom_attributes` counter is never written, so asserting it proved nothing.
    expect(account.reload.usage_limits.dig(:captain, :responses)).to include(consumed: 1, reserved: 0)
    expect(Redis::Alfred).to have_received(:delete_if_equals).with(
      format(described_class::LOCK_KEY, account_id: account.id, thread_id: copilot_thread.id),
      kind_of(String)
    )
  end

  it 'ignores a stale or forged reservation token' do
    perform(SecureRandom.uuid)

    expect(Captain::Copilot::ChatService).not_to have_received(:new)
    expect(source_message.reload).to be_response_reserved
    # Wave E5 moved Captain quota into the LLA ledger; the old
    # `custom_attributes` counter is never written, so asserting it proved nothing.
    expect(account.reload.usage_limits.dig(:captain, :responses)).to include(consumed: 0, reserved: 1)
  end

  it 'is a no-op after the response has completed' do
    source_message.update!(response_state: :completed, response_completed_at: Time.current)

    perform

    expect(Captain::Copilot::ChatService).not_to have_received(:new)
    expect(Redis::Alfred).not_to have_received(:set)
  end

  it 'releases the reservation and stores one generic failure if account membership is revoked' do
    AccountUser.find_by!(account: account, user: user).destroy!

    expect { perform }.to change(CopilotMessage, :count).by(1)

    expect(Captain::Copilot::ChatService).not_to have_received(:new)
    expect(source_message.reload).to be_response_released
    expect(source_message.copilot_response.message['content']).to eq(
      I18n.t('captain.copilot_generation_failed', default: 'Copilot could not generate a response. Please try again.')
    )
    # Wave E5 moved Captain quota into the LLA ledger; the old
    # `custom_attributes` counter is never written, so asserting it proved nothing.
    expect(account.reload.usage_limits.dig(:captain, :responses)).to include(consumed: 0, reserved: 0)
  end

  it 'releases the reservation when conversation access is revoked before execution' do
    AccountUser.find_by!(account: account, user: user).update!(role: :agent)

    expect { perform }.to change(CopilotMessage, :count).by(1)

    expect(source_message.reload).to be_response_released
    # Wave E5 moved Captain quota into the LLA ledger; the old
    # `custom_attributes` counter is never written, so asserting it proved nothing.
    expect(account.reload.usage_limits.dig(:captain, :responses)).to include(consumed: 0, reserved: 0)
    expect(Captain::Copilot::ChatService).not_to have_received(:new)
  end
end
