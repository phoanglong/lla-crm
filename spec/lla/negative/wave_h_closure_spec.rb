# frozen_string_literal: true

require 'rails_helper'

# Wave H closure: inbox assignment capacity and the balanced strategy, owned by LLA
# and working with enterprise off. Each example below fails on the tree as it was
# before this wave.
RSpec.describe 'Wave H closure' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }

  describe 'the balanced assignment order' do
    # It used to be declared as `enum assignment_order: { round_robin: 0 }` unless
    # the process was in enterprise mode, with `balanced` added back from an
    # enterprise concern. With enterprise off the value simply did not exist, so a
    # row already holding 1 could not even be read.
    it 'exists whether or not enterprise is loaded' do
      expect(AssignmentPolicy.assignment_orders).to include('round_robin' => 0, 'balanced' => 1)
    end

    it 'reads a persisted 1 back as balanced rather than raising' do
      policy = create(:assignment_policy, account: account)
      ActiveRecord::Base.connection.execute(
        "UPDATE assignment_policies SET assignment_order = 1 WHERE id = #{policy.id}"
      )

      expect(policy.reload.assignment_order).to eq('balanced')
      expect(policy).to be_balanced
    end

    it 'is defined exactly once, so loading an extension cannot redefine it' do
      expect(AssignmentPolicy.assignment_orders.keys).to eq(%w[round_robin balanced])
    end
  end

  describe 'Lla::AutoAssignment::BalancedSelector' do
    let(:users) { create_list(:user, 3, account: account, role: :agent) }
    let(:members) do
      users.map { |user| create(:inbox_member, inbox: inbox, user: user) }
    end

    def open_conversations(user, count)
      count.times { create(:conversation, account: account, inbox: inbox, assignee: user, status: :open) }
    end

    it 'chooses the agent carrying the least open work in this inbox' do
      open_conversations(users[0], 3)
      open_conversations(users[1], 1)
      open_conversations(users[2], 2)

      expect(described_selector.select_agent(members).id).to eq(users[1].id)
    end

    it 'counts only conversations in this inbox' do
      other_inbox = create(:inbox, account: account)
      create(:inbox_member, inbox: other_inbox, user: users[1])
      5.times { create(:conversation, account: account, inbox: other_inbox, assignee: users[1], status: :open) }
      open_conversations(users[0], 1)

      expect(described_selector.select_agent(members).id).to eq(users[1].id)
    end

    it 'counts only open conversations' do
      create(:conversation, account: account, inbox: inbox, assignee: users[0], status: :resolved)
      open_conversations(users[1], 1)
      open_conversations(users[2], 1)

      expect(described_selector.select_agent(members).id).to eq(users[0].id)
    end

    # `min_by` over an unordered relation returned the same agent every time, which
    # is most visible on a fresh inbox where every agent is tied at zero.
    it 'rotates between tied agents instead of always returning the same one' do
      selector = described_selector
      picked = Array.new(6) { selector.select_agent(members).id }

      expect(picked.uniq.length).to be >= 2
    end

    it 'ignores an agent who is not a member of this inbox' do
      outsider = create(:inbox_member, inbox: create(:inbox, account: account), user: create(:user, account: account))

      expect(described_selector.select_agent(members + [outsider]).id).to be_in(users.map(&:id))
    end

    it 'does not give a duplicated member double weight' do
      open_conversations(users[0], 1)
      open_conversations(users[1], 1)
      duplicated = [members[2], members[2], members[0], members[1]]

      expect(described_selector.select_agent(duplicated).id).to eq(users[2].id)
    end

    it 'returns nil when nobody is eligible' do
      expect(described_selector.select_agent([])).to be_nil
    end

    # The round-robin selector answers with a `User`, and the caller writes the
    # result straight into `conversation.assignee`. Returning the `InboxMember`
    # instead type-checks in a unit test and raises in production.
    it 'answers with the same type the round-robin selector answers with' do
      expect(described_selector.select_agent(members)).to be_a(User)
    end

    it 'produces an agent the assignment service can actually assign' do
      conversation = create(:conversation, account: account, inbox: inbox, assignee: nil, status: :open)
      chosen = described_selector.select_agent(members)

      expect(AutoAssignment::AssignmentService.new(inbox: inbox).send(:assign_conversation, conversation, chosen))
        .to be(true)
      expect(conversation.reload.assignee_id).to eq(chosen.id)
    end

    it 'still assigns when the tie-break counter is unavailable' do
      allow(Redis::Alfred).to receive(:incr).and_raise(Redis::CannotConnectError)

      expect(described_selector.select_agent(members)).to be_present
    end

    def described_selector
      Lla::AutoAssignment::BalancedSelector.new(inbox: inbox)
    end
  end

  describe 'AutoAssignment::AssignmentService selector choice' do
    let(:service) { AutoAssignment::AssignmentService.new(inbox: inbox) }

    def attach(policy)
      create(:inbox_assignment_policy, inbox: inbox, assignment_policy: policy)
      inbox.reload
    end

    it 'uses the balanced selector when the inbox policy says balanced' do
      attach(create(:assignment_policy, account: account, assignment_order: :balanced))

      expect(service.send(:selector)).to be_a(Lla::AutoAssignment::BalancedSelector)
    end

    it 'uses round robin when there is no policy' do
      expect(service.send(:selector)).to be_a(AutoAssignment::RoundRobinSelector)
    end

    it 'uses round robin when the policy is round robin' do
      attach(create(:assignment_policy, account: account, assignment_order: :round_robin))

      expect(service.send(:selector)).to be_a(AutoAssignment::RoundRobinSelector)
    end

    it 'falls back to round robin when the balanced policy is disabled' do
      attach(create(:assignment_policy, account: account, assignment_order: :balanced, enabled: false))

      expect(service.send(:selector)).to be_a(AutoAssignment::RoundRobinSelector)
    end

    # A policy belonging to another account must not be able to change how this
    # inbox assigns, however it came to be attached.
    it 'falls back to round robin for a policy owned by another account' do
      foreign = create(:assignment_policy, account: create(:account), assignment_order: :balanced)
      create(:inbox_assignment_policy, inbox: inbox, assignment_policy: foreign)
      inbox.reload

      expect(service.send(:selector)).to be_a(AutoAssignment::RoundRobinSelector)
    end
  end

  describe 'capacity at the moment of assignment' do
    let(:user) { create(:user, account: account, role: :agent) }
    let(:service) { AutoAssignment::AssignmentService.new(inbox: inbox) }

    before do
      account.enable_features('advanced_assignment')
      account.save!
      create(:inbox_member, inbox: inbox, user: user)
      policy = create(:agent_capacity_policy, account: account)
      create(:inbox_capacity_limit, agent_capacity_policy: policy, inbox: inbox, conversation_limit: 1)
      account.account_users.find_by(user_id: user.id).update!(agent_capacity_policy: policy)
    end

    # The eligibility filter runs before the write. Between the two, another worker
    # can fill the agent's last slot; the row lock protects the conversation, not
    # the agent's limit. The re-read inside the transaction is what refuses it.
    it 'refuses to assign an agent who filled up after being selected' do
      conversation = create(:conversation, account: account, inbox: inbox, assignee: nil, status: :open)
      create(:conversation, account: account, inbox: inbox, assignee: user, status: :open)

      expect(service.send(:claim_and_assign, conversation, user)).to be(false)
      expect(conversation.reload.assignee_id).to be_nil
    end

    it 'assigns while the agent is still under the limit' do
      conversation = create(:conversation, account: account, inbox: inbox, assignee: nil, status: :open)

      expect(service.send(:claim_and_assign, conversation, user)).to be(true)
      expect(conversation.reload.assignee_id).to eq(user.id)
    end
  end

  describe 'the inbox assignment limit' do
    let(:administrator) { create(:user, account: account, role: :administrator) }

    def update_limit(value)
      patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            params: { auto_assignment_config: { max_assignment_limit: value } },
            headers: administrator.create_new_auth_token, as: :json
    end

    # The only controller that permitted this parameter was an enterprise
    # extension, so with enterprise off strong parameters dropped it silently: the
    # request succeeded and the limit was never set.
    it 'can be set through the API with enterprise off', type: :request do
      update_limit(5)

      expect(response).to have_http_status(:success)
      expect(inbox.reload.auto_assignment_config['max_assignment_limit']).to eq(5)
    end

    it 'refuses zero', type: :request do
      update_limit(0)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'refuses a negative limit', type: :request do
      update_limit(-1)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'refuses a value that is not an integer', type: :request do
      update_limit('5 agents')
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'refuses a limit large enough to be meaningless', type: :request do
      update_limit(1_000_000)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'is not writable by an agent', type: :request do
      agent = create(:user, account: account, role: :agent)
      patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            params: { auto_assignment_config: { max_assignment_limit: 5 } },
            headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(inbox.reload.auto_assignment_config['max_assignment_limit']).to be_nil
    end
  end

  describe 'AccountUser tenancy' do
    it 'refuses a capacity policy belonging to another account' do
      membership = account.account_users.first || create(:account_user, account: account)
      membership.agent_capacity_policy = create(:agent_capacity_policy, account: create(:account))

      expect(membership).not_to be_valid
      expect(membership.errors[:agent_capacity_policy]).to be_present
    end

    it 'accepts a capacity policy from the same account' do
      membership = account.account_users.first || create(:account_user, account: account)
      membership.agent_capacity_policy = create(:agent_capacity_policy, account: account)

      expect(membership).to be_valid
    end
  end
end
