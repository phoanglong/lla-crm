# frozen_string_literal: true

require 'rails_helper'

# The defect this file exists for, found by review rather than by the suite:
#
# `claim_and_assign` locked the conversation row and then re-read the agent's open
# conversation count. That stops two workers claiming the SAME conversation. It does
# nothing about two workers claiming TWO DIFFERENT conversations for the SAME agent:
# the two transactions lock different rows, `SKIP LOCKED` does not serialise them,
# and under READ COMMITTED both read the same pre-commit count, both pass the check,
# and both commit. The ceiling is exceeded by up to (workers - 1).
#
# A single-threaded suite cannot see this, which is why it survived a green run.
#
# Worker counts here are bounded by the test connection pool (`RAILS_MAX_THREADS`,
# 5 by default) minus the example's own connection. A thread that cannot check out a
# connection would raise before reaching the barrier and leave the rest waiting on it
# forever, so every barrier wait is time-bounded and every thread body records its
# error instead of dying silently.
RSpec.describe 'Lla::AutoAssignment::AssignmentService capacity under concurrency', type: :service do # rubocop:disable RSpec/DescribeClass
  self.use_transactional_tests = false

  let(:barrier_timeout) { 20 }

  # The service is a private module prepended onto the community class, and the claim
  # is a private method. Driving it directly is deliberate: `perform_bulk_assignment`
  # loops in one thread, so it can never produce the interleaving under test.
  def claim(inbox, conversation, agent)
    AutoAssignment::AssignmentService.new(inbox: inbox)
                                     .send(:claim_and_assign, conversation, agent)
  end

  def build_world(conversation_limit:, conversations:)
    account = Account.create!(name: "LLA capacity concurrency #{SecureRandom.hex(6)}")
    account.enable_features!('advanced_assignment')
    account.save!

    inbox = create(:inbox, account: account, enable_auto_assignment: true)
    agent = create(:user, account: account, role: :agent, availability: :online)
    create(:inbox_member, inbox: inbox, user: agent)

    policy = create(:agent_capacity_policy, account: account, name: "cap-#{SecureRandom.hex(4)}")
    create(:inbox_capacity_limit,
           agent_capacity_policy: policy,
           inbox: inbox,
           conversation_limit: conversation_limit)
    agent.account_users.find_by(account: account).update!(agent_capacity_policy: policy)

    rows = Array.new(conversations) do
      create(:conversation, account: account, inbox: inbox, assignee: nil, status: :open)
    end

    [account, inbox, agent, rows]
  end

  def open_assignments(agent, inbox)
    agent.assigned_conversations.where(inbox_id: inbox.id, status: :open).count
  end

  # Cleanup has to be exhaustive and it has to prove it was.
  #
  # `Account` declares almost every association `dependent: :destroy_async`, and so
  # does `Inbox`, so `Account.destroy_all` deletes one row and enqueues the rest as
  # jobs the test queue adapter never runs. A transactional example does not care. This
  # group is not transactional — the workers need committed rows on other connections —
  # so anything left behind stays in a database every later spec shares.
  #
  # That is not theoretical. The first version of this file leaked contacts and
  # working hours, and the whole-suite run failed in `Sms::IncomingMessageService`
  # (`Contact.all.first`) and `WorkingHour` (`WorkingHour.today` calls a global
  # `first.inbox`) — six failures in files this branch never touched.
  def destroy_world(account)
    return if account.blank?

    inbox_ids = Inbox.where(account_id: account.id).ids
    user_ids = AccountUser.where(account_id: account.id).pluck(:user_id)

    Conversation.where(account_id: account.id).find_each(&:destroy)
    ContactInbox.where(inbox_id: inbox_ids).delete_all
    Contact.where(account_id: account.id).find_each(&:destroy)
    InboxMember.where(inbox_id: inbox_ids).delete_all
    InboxCapacityLimit.where(inbox_id: inbox_ids).delete_all
    WorkingHour.where(inbox_id: inbox_ids).delete_all
    Inbox.where(id: inbox_ids).find_each(&:destroy)
    AgentCapacityPolicy.where(account_id: account.id).delete_all
    AccountUser.where(account_id: account.id).delete_all
    User.where(id: user_ids).find_each(&:destroy)
    Account.where(id: account.id).delete_all

    assert_nothing_left_behind(account.id, inbox_ids, user_ids)
  end

  # The self-check. Without it, a table added to the fixture later leaks silently and
  # the failure lands in somebody else's spec file, hours of bisecting away.
  def assert_nothing_left_behind(account_id, inbox_ids, user_ids)
    leftovers = {
      accounts: Account.where(id: account_id).count,
      account_users: AccountUser.where(account_id: account_id).count,
      users: User.where(id: user_ids).count,
      inboxes: Inbox.where(id: inbox_ids).count,
      conversations: Conversation.where(account_id: account_id).count,
      contacts: Contact.where(account_id: account_id).count,
      contact_inboxes: ContactInbox.where(inbox_id: inbox_ids).count,
      inbox_members: InboxMember.where(inbox_id: inbox_ids).count,
      working_hours: WorkingHour.where(inbox_id: inbox_ids).count,
      inbox_capacity_limits: InboxCapacityLimit.where(inbox_id: inbox_ids).count,
      agent_capacity_policies: AgentCapacityPolicy.where(account_id: account_id).count
    }.reject { |_table, count| count.zero? }

    raise "this spec leaked rows into the shared test database: #{leftovers.inspect}" if leftovers.any?
  end

  # One worker: reload everything on its own connection, wait for the others, claim.
  def claim_worker(inbox, agent, conversation, barrier, results)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        worker_inbox = Inbox.find(inbox.id)
        worker_agent = User.find(agent.id)
        worker_conversation = Conversation.find(conversation.id)
        barrier.wait(barrier_timeout)
        results[:granted] << claim(worker_inbox, worker_conversation, worker_agent)
      end
    rescue StandardError => e
      results[:errors] << "#{e.class}: #{e.message}"
    end
  end

  # Every worker claims a different conversation for the same agent, all released at
  # the same instant. Returns [granted, errors].
  def race_for(inbox, agent, conversations)
    barrier = Concurrent::CyclicBarrier.new(conversations.size)
    results = { granted: Concurrent::Array.new, errors: Concurrent::Array.new }

    conversations
      .map { |conversation| claim_worker(inbox, agent, conversation, barrier, results) }
      .each { |worker| worker.join(barrier_timeout * 2) }

    [results[:granted], results[:errors]]
  end

  it 'never pushes an agent past the inbox limit, however the workers interleave' do
    account, inbox, agent, conversations = build_world(conversation_limit: 2, conversations: 4)

    granted, errors = race_for(inbox, agent, conversations)

    expect(errors).to be_empty
    # Both statements matter. The first is the invariant the product promises; the
    # second says the claim did not simply refuse everybody in order to stay under it.
    expect(open_assignments(agent, inbox)).to eq(2)
    expect(granted.count(true)).to eq(2)
  ensure
    destroy_world(account)
  end

  it 'lets exactly one of two simultaneous claims through when one seat is left' do
    account, inbox, agent, conversations = build_world(conversation_limit: 1, conversations: 2)

    granted, errors = race_for(inbox, agent, conversations)

    expect(errors).to be_empty
    expect(granted.count(true)).to eq(1)
    expect(granted.count(false)).to eq(1)
    expect(open_assignments(agent, inbox)).to eq(1)
  ensure
    destroy_world(account)
  end

  # The threaded examples prove the outcome. This one proves the mechanism, so that
  # deleting the lock cannot stay green on a lucky schedule: while another connection
  # holds the same advisory key, a claim must block rather than proceed.
  it 'blocks on the per-agent advisory lock, so removing it cannot pass unnoticed' do
    account, inbox, agent, conversations = build_world(conversation_limit: 5, conversations: 1)
    key = "lla:auto_assignment:capacity:#{inbox.id}:#{agent.id}"
    blocked = Concurrent::AtomicBoolean.new(false)
    holding = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute(
            Conversation.sanitize_sql_array(['SELECT pg_advisory_xact_lock(hashtextextended(?, 0))', key])
          )
          holding.count_down
          release.wait(barrier_timeout)
        end
      end
    end

    holding.wait(barrier_timeout)

    claimer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET statement_timeout = '750ms'")
        begin
          claim(Inbox.find(inbox.id), Conversation.find(conversations.first.id), User.find(agent.id))
        rescue ActiveRecord::QueryCanceled, ActiveRecord::StatementInvalid
          blocked.make_true
        ensure
          connection.execute('SET statement_timeout = 0')
        end
      end
    end
    claimer.join(barrier_timeout)

    release.count_down
    holder.join(barrier_timeout)

    expect(blocked.true?).to be(true)
    expect(open_assignments(agent, inbox)).to eq(0)
  ensure
    release&.count_down
    destroy_world(account)
  end

  # Serialising every claim would be a performance regression for installations that
  # do not enforce capacity at all, so the lock is only taken when it protects a limit.
  it 'takes no lock when the account does not enforce capacity' do
    account, inbox, agent, conversations = build_world(conversation_limit: 1, conversations: 1)
    account.disable_features!('advanced_assignment')
    account.save!

    key = "lla:auto_assignment:capacity:#{inbox.id}:#{agent.id}"
    holding = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute(
            Conversation.sanitize_sql_array(['SELECT pg_advisory_xact_lock(hashtextextended(?, 0))', key])
          )
          holding.count_down
          release.wait(barrier_timeout)
        end
      end
    end
    holding.wait(barrier_timeout)

    result = nil
    claimer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET statement_timeout = '2s'")
        result = claim(Inbox.find(inbox.id), Conversation.find(conversations.first.id), User.find(agent.id))
      ensure
        connection.execute('SET statement_timeout = 0')
      end
    end
    claimer.join(barrier_timeout)

    release.count_down
    holder.join(barrier_timeout)

    expect(result).to be(true)
  ensure
    release&.count_down
    destroy_world(account)
  end
end
