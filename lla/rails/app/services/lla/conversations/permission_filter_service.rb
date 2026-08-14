# frozen_string_literal: true

# Lọc hội thoại theo vai trò tuỳ chỉnh. Prepend lên
# Conversations::PermissionFilterService (MIT) — bản CE chỉ biết administrator và
# agent thường; bản này bổ sung nhánh cho agent có custom role.
#
# Quy tắc, theo mức rộng dần (quyền trước bao trùm quyền sau):
#   conversation_manage               → mọi hội thoại trong các inbox được gán
#   conversation_unassigned_manage    → hội thoại chưa gán + hội thoại của chính mình
#   conversation_participating_manage → hội thoại của chính mình + nơi mình tham gia
# Mọi nhánh đều bị giới hạn trong các inbox mà agent là thành viên.
module Lla::Conversations::PermissionFilterService
  def perform
    return super unless custom_role_agent?

    filter_by_permissions
  end

  private

  def custom_role_agent?
    account_user.present? && account_user.agent? && account_user.custom_role_id.present?
  end

  def permissions
    account_user.custom_role&.permissions.presence || []
  end

  def inbox_scoped_conversations
    conversations.where(inbox: user.inboxes.where(account_id: account.id))
  end

  def filter_by_permissions
    return inbox_scoped_conversations if permissions.include?('conversation_manage')
    return unassigned_and_own_conversations if permissions.include?('conversation_unassigned_manage')
    return own_and_participating_conversations if permissions.include?('conversation_participating_manage')

    # Có custom role nhưng không có quyền hội thoại nào: chỉ thấy việc của mình.
    inbox_scoped_conversations.where(assignee_id: user.id)
  end

  def unassigned_and_own_conversations
    inbox_scoped_conversations.where(assignee_id: [nil, user.id])
  end

  def own_and_participating_conversations
    inbox_scoped_conversations
      .where(id: participating_conversation_ids)
      .or(inbox_scoped_conversations.where(assignee_id: user.id))
  end

  def participating_conversation_ids
    ConversationParticipant.where(user_id: user.id, account_id: account.id).select(:conversation_id)
  end
end
