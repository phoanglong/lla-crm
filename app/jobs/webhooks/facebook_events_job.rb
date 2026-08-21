class Webhooks::FacebookEventsJob < MutexApplicationJob
  queue_as :default
  retry_on LockAcquisitionError, wait: 1.second, attempts: 8

  # `account_id` chỉ có khi sự kiện đến qua webhook riêng của tenant. Khi có, nó giới hạn
  # việc dựng tin trong đúng tài khoản ấy — một page xuất hiện ở hai tenant thì tin không
  # được nhân đôi sang tenant kia.
  def perform(message, account_id = nil)
    response = ::Integrations::Facebook::MessageParser.new(message)

    key = format(::Redis::Alfred::FACEBOOK_MESSAGE_MUTEX, sender_id: response.sender_id, recipient_id: response.recipient_id)
    with_lock(key) do
      process_message(response, account_id)
    end
  end

  def process_message(response, account_id = nil)
    ::Integrations::Facebook::MessageCreator.new(response, account_id: account_id).perform
  end
end
