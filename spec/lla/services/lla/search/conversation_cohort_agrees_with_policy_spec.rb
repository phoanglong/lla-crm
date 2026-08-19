# frozen_string_literal: true

require 'rails_helper'

# `Lla::Search::ConversationCohort` and `ConversationPolicy#show?` are two
# expressions of one rule: what may this member read. Two expressions drift. Review
# found two drifts that had already happened — both in the safe direction (search
# under-returned), but a drift the other way is a disclosure.
#
# So this file does not test the cohort's opinion. It tests that the cohort and the
# policy agree, record by record, across the permutations that matter. Anything the
# policy allows and the cohort hides is a functional gap; anything the cohort shows
# and the policy refuses is a leak, and the second assertion names it as such.
RSpec.describe 'Lla::Search::ConversationCohort agrees with ConversationPolicy' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }
  let(:team) { create(:team, account: account) }
  let(:member) { create(:user, account: account, role: :agent) }
  let(:colleague) { create(:user, account: account, role: :agent) }

  def account_user_for(user)
    account.account_users.find_by(user_id: user.id)
  end

  def cohort_for(user, inbox_ids: [inbox.id])
    Lla::Search::ConversationCohort.new(
      account: account,
      user: user,
      account_user: account_user_for(user),
      inbox_ids: inbox_ids
    )
  end

  def policy_allows?(user, conversation)
    ConversationPolicy.new(
      { user: user, account: account, account_user: account_user_for(user) },
      conversation
    ).show?
  end

  def assign_role(user, permissions)
    role = create(:custom_role, account: account, permissions: permissions)
    account_user_for(user).update!(custom_role: role)
    role
  end

  def conversation_in(target_inbox, assignee: nil, team: nil)
    create(:conversation, account: account, inbox: target_inbox, assignee: assignee, team: team)
  end

  def participated_conversation
    conversation_in(inbox, assignee: colleague).tap do |record|
      ConversationParticipant.create!(conversation: record, user: member, account: account)
    end
  end

  # Every conversation a member could plausibly encounter, one per reachability path.
  def conversation_matrix
    {
      own: conversation_in(inbox, assignee: member),
      unassigned: conversation_in(inbox),
      colleagues: conversation_in(inbox, assignee: colleague),
      participating: participated_conversation,
      via_team: conversation_in(other_inbox, assignee: colleague, team: team),
      unreachable: conversation_in(other_inbox, assignee: colleague)
    }
  end

  def disagreements(user, conversations, inbox_ids: [inbox.id])
    visible = cohort_for(user, inbox_ids: inbox_ids).relation
    conversations.filter_map do |label, conversation|
      searchable = visible.exists?(id: conversation.id)
      openable = policy_allows?(user, conversation)
      next if searchable == openable

      { record: label, searchable: searchable, openable: openable }
    end
  end

  before do
    create(:inbox_member, inbox: inbox, user: member)
    create(:inbox_member, inbox: inbox, user: colleague)
    create(:inbox_member, inbox: other_inbox, user: colleague)
  end

  # The permission sets a role can actually hold. `conversation_manage` is the
  # broadest; the interesting case is the pair, which the elsif ladder got wrong.
  [
    [],
    %w[conversation_manage],
    %w[conversation_unassigned_manage],
    %w[conversation_participating_manage],
    %w[conversation_unassigned_manage conversation_participating_manage],
    %w[conversation_manage conversation_participating_manage]
  ].each do |permissions|
    context "with a custom role granting #{permissions.presence&.join(' + ') || 'nothing'}" do
      it 'shows in search exactly what the policy opens' do
        conversations = conversation_matrix
        assign_role(member, permissions)

        expect(disagreements(member, conversations)).to be_empty
      end

      it 'never shows anything the policy refuses' do
        conversations = conversation_matrix
        assign_role(member, permissions)

        leaks = disagreements(member, conversations).select { |d| d[:searchable] && !d[:openable] }

        expect(leaks).to be_empty, "search disclosed records the policy refuses: #{leaks.inspect}"
      end
    end
  end

  context 'with no custom role at all' do
    it 'shows in search exactly what the policy opens' do
      conversations = conversation_matrix

      expect(disagreements(member, conversations)).to be_empty
    end
  end

  # The two drifts review found, named individually so a regression says which one.
  describe 'the drifts this file was written for' do
    it 'keeps the participating grant when the role also grants unassigned' do
      conversations = conversation_matrix
      assign_role(member, %w[conversation_unassigned_manage conversation_participating_manage])

      visible = cohort_for(member).relation

      expect(visible.exists?(id: conversations[:participating].id)).to be(true)
      expect(visible.exists?(id: conversations[:unassigned].id)).to be(true)
      expect(visible.exists?(id: conversations[:colleagues].id)).to be(false)
    end

    it 'reaches a conversation that is only visible through team membership' do
      conversations = conversation_matrix
      create(:team_member, team: team, user: member)

      visible = cohort_for(member).relation

      expect(policy_allows?(member, conversations[:via_team])).to be(true)
      expect(visible.exists?(id: conversations[:via_team].id)).to be(true)
      expect(visible.exists?(id: conversations[:unreachable].id)).to be(false)
    end

    # Found by making the cohort and the policy agree: they disagreed on what a role
    # with an empty permission list means. The policy read it as *no role* and handed
    # back full base access — the opposite of what its own comment promises, and
    # reachable, because `permissions` has no presence validation.
    it 'refuses a role that grants nothing, instead of ignoring it' do
      conversations = conversation_matrix
      role = assign_role(member, [])

      expect(role.permissions).to eq([])
      expect(policy_allows?(member, conversations[:own])).to be(false)
      expect(policy_allows?(member, conversations[:unassigned])).to be(false)
      expect(cohort_for(member).relation.exists?(id: conversations[:own].id)).to be(false)
    end

    it 'ignores a role belonging to another account, leaving ordinary agent access' do
      conversations = conversation_matrix
      foreign_role = create(:custom_role, account: create(:account), permissions: %w[conversation_participating_manage])
      # `update_column` on purpose: `Lla::AccountUser` refuses a cross-account role at
      # write time, and the row under test is one that predates that validation.
      account_user_for(member).update_column(:custom_role_id, foreign_role.id) # rubocop:disable Rails/SkipsModelValidations

      expect(policy_allows?(member, conversations[:colleagues])).to be(true)
      expect(cohort_for(member).relation.exists?(id: conversations[:colleagues].id)).to be(true)
    end

    it 'does not widen anything when the member belongs to no team' do
      conversations = conversation_matrix

      visible = cohort_for(member).relation

      expect(visible.exists?(id: conversations[:via_team].id)).to be(false)
      expect(visible.exists?(id: conversations[:unreachable].id)).to be(false)
    end
  end
end
