# frozen_string_literal: true

require 'rails_helper'

# The cases the deterministic two-snapshot tests cannot prove on their own: real
# threads racing on one row, the rotation budget at its boundary, and what happens to
# durable evidence when the portal it names is deleted.
#
# Outside the 19-path focused suite on purpose (see the negative contract file), and
# run the same way in both EE modes:
#
#   bundle exec rspec spec/lla/negative/g4a_concurrency_and_lifecycle_spec.rb
#   DISABLE_ENTERPRISE=true bundle exec rspec spec/lla/negative/g4a_concurrency_and_lifecycle_spec.rb
RSpec.describe 'Lla::CustomDomains concurrency and lifecycle' do # rubocop:disable RSpec/DescribeClass
  let(:challenge) { Lla::CustomDomains::OwnershipChallenge }
  let(:domains) { Lla::CustomDomains::Domain }
  let(:tombstones) { Lla::CustomDomains::Tombstone }
  let(:barrier) { instance_double(Lla::CustomDomains::Fence) }

  describe 'two workers on one challenge' do
    # Real connections, so the fence is proved by PostgreSQL rather than by a
    # savepoint. Everything created here is removed again in `after`.
    self.use_transactional_tests = false

    let!(:account) { create(:account) }
    let!(:portal) { create(:portal, account: account) }
    let!(:domain) do
      Lla::CustomDomains::LifecycleService.new(portal: portal).request!('docs.example.com')
    end

    after do
      Lla::CustomDomains::Operation.delete_all
      Lla::CustomDomains::Tombstone.delete_all
      Lla::CustomDomains::Domain.delete_all
      Portal.where(account_id: account.id).delete_all
      Account.where(id: account.id).delete_all
    end

    # Both threads start from the same snapshot and are released together, so the
    # only thing that can separate them is the conditional write itself.
    def race(*actions)
      barrier = Concurrent::CyclicBarrier.new(actions.size)
      actions.map do |action|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            barrier.wait
            begin
              action.call
            rescue StandardError => e
              e
            end
          end
        end
      end.map(&:value)
    end

    it 'lets exactly one concurrent rotation through and charges exactly one attempt' do
      snapshots = Array.new(2) { domains.find(domain.id) }

      results = race(-> { challenge.rotate!(snapshots[0]) }, -> { challenge.rotate!(snapshots[1]) })

      issued = results.grep(Lla::CustomDomains::OwnershipChallenge::Issued)
      expect(issued.size).to eq(1)
      expect(results.grep(Lla::CustomDomains::OwnershipChallenge::Stale).size).to eq(1)
      expect(domain.reload.challenge_rotations).to eq(1)
      expect(challenge.resolve(domain, issued.first.id)).to eq(issued.first.body)
    end

    it 'never lets a revoke and a rotation from the same snapshot both take effect' do
      snapshots = Array.new(2) { domains.find(domain.id) }

      rotation, revoked = race(-> { challenge.rotate!(snapshots[0]) }, -> { challenge.revoke!(snapshots[1]) })
      domain.reload

      if rotation.is_a?(Lla::CustomDomains::OwnershipChallenge::Issued)
        # The rotation won: the revoke read a challenge that no longer exists and
        # must not have erased the replacement.
        expect(revoked).to be(false)
        expect(domain.challenge_rotations).to eq(1)
        expect(challenge.resolve(domain, rotation.id)).to eq(rotation.body)
      else
        # The revoke won: the rotation is stale, spends nothing, and writes nothing.
        expect(rotation).to be_a(Lla::CustomDomains::OwnershipChallenge::Stale)
        expect(revoked).to be(true)
        expect(domain.challenge_rotations).to eq(0)
        expect(domain.challenge_id_digest).to be_nil
      end
    end
  end

  describe 'the rotation budget' do
    let(:account) { create(:account) }
    let(:portal) { create(:portal, account: account) }
    let(:domain) { Lla::CustomDomains::LifecycleService.new(portal: portal).request!('docs.example.com') }

    it 'is spent exactly once per successful rotation and then refuses to mint more' do
      max = Lla::CustomDomains::Domain::MAX_CHALLENGE_ROTATIONS
      max.times { challenge.rotate!(domain.reload) }

      expect(domain.reload.challenge_rotations).to eq(max)
      expect { challenge.rotate!(domain) }.to raise_error(challenge::RotationExhausted)
      # And the ceiling is not a Ruby-side opinion: the database refuses to hold a
      # row above it, whatever writes the row.
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute(
            "UPDATE lla_custom_domains SET challenge_rotations = #{max + 1} WHERE id = #{domain.id}"
          )
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /chk_lla_custom_domains_version/)
    end

    it 'leaves the live token untouched when the budget is exhausted' do
      max = Lla::CustomDomains::Domain::MAX_CHALLENGE_ROTATIONS
      max.times { challenge.rotate!(domain.reload) }
      live = domain.reload.challenge_id_digest

      expect { challenge.rotate!(domain) }.to raise_error(challenge::RotationExhausted)

      expect(domain.reload).to have_attributes(challenge_id_digest: live, challenge_rotations: max)
    end

    it 'does not expire a challenge the administrator already replaced' do
      Lla::CustomDomains::LifecycleService.new(portal: portal).fail!(domain, code: 'lla_custom_domain_ownership_unverified')
      Lla::CustomDomains::LifecycleService.new(portal: portal).retry_verification!(domain.reload)
      domain.reload.update_columns(challenge_expires_at: 1.hour.ago) # rubocop:disable Rails/SkipsModelValidations
      # The scan sees an expired challenge; a retry replaces it before the write.
      allow(Lla::CustomDomains::Domain).to receive(:lock).and_wrap_original do |original|
        challenge.rotate!(Lla::CustomDomains::Domain.find(domain.id))
        original.call
      end

      Lla::CustomDomains::ReconciliationJob.perform_now

      expect(domain.reload).to have_attributes(state: 'ownership_pending', last_error_code: nil)
      expect(domain.challenge_id_digest).to be_present
    end
  end

  describe 'evidence when the portal it names is deleted' do
    let(:account) { create(:account) }
    let(:portal) { create(:portal, account: account) }

    def evidence!
      raw = 'bad host.example.com'
      tombstones.create!(account_id: account.id, portal_id: portal.id, source_portal_id: portal.id,
                         reason: 'legacy_hostname_unsupported',
                         source_value_digest: Digest::SHA256.hexdigest(raw),
                         source_value_preview: tombstones.safe_preview(raw))
    end

    it 'survives the deletion, keeps naming the portal and stops referencing it' do
      item = evidence!

      portal.destroy!

      expect(item.reload).to have_attributes(portal_id: nil, source_portal_id: portal.id,
                                             state: 'manual_adoption_required')
      expect(item.account_id).to eq(account.id)
    end

    it 'refuses a raw portal delete that would leave the reference dangling' do
      item = evidence!

      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute("DELETE FROM portals WHERE id = #{portal.id}")
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_lla_custom_domain_tombstones_portal_tenant/)
      expect(item.reload.portal_id).to eq(portal.id)
    end
  end

  describe 'a worker result that must actually be written' do
    let(:account) { create(:account) }
    let(:portal) { create(:portal, account: account) }
    let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
    let(:service) { Lla::CustomDomains::OperationService }
    let(:domain) { lifecycle.request!('docs.example.com') }

    def activate!
      domain.update!(state: 'provisioning', ownership_verified_at: Time.current)
      lifecycle.activate!(domain, resource_id: nil, status: 'pending')
      domain.reload
    end

    # The fenced branches are all "write nothing when the row moved" — which is also
    # what a branch that cannot write at all looks like from the outside. This is the
    # positive half: the reconcile result is applied and the operation succeeds.
    it 'writes the reconciled provider status and marks the operation succeeded' do
      activate!
      lease = service.claim!(service.enqueue!(domain: domain, operation_type: 'reconcile'))

      result = Lla::CustomDomains::OperationExecutor.new(lease).perform

      expect(result).to be_present
      expect(domain.reload).to have_attributes(provider_status: 'local', state: 'active')
      expect(domain.provider_synced_at).to be_present
      expect(Lla::CustomDomains::Operation.find(lease.id).state).to eq('succeeded')
    end

    # Destroying the domain detaches its operations, and that write locks every one
    # of them. Taken after the domain row it closes a cycle against any worker that
    # holds one of those operations and is waiting for the domain.
    it 'locks this domain operations before the domain row when finishing a removal' do
      activate!
      service.enqueue!(domain: domain, operation_type: 'reconcile')
      lifecycle.release!
      lease = service.claim!(Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id,
                                                                    operation_type: 'remove'))
      locks = []
      collect = ->(_name, _start, _finish, _id, payload) { locks << payload[:sql] if payload[:sql].include?('FOR UPDATE') }

      ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') do
        Lla::CustomDomains::OperationExecutor.new(lease).perform
      end

      siblings = locks.rindex { |sql| sql.include?('lla_custom_domain_operations') && sql.include?('custom_domain_id') }
      domain_row = locks.index { |sql| sql.include?('FROM "lla_custom_domains"') }
      expect(siblings).not_to be_nil
      expect(domain_row).not_to be_nil
      expect(siblings).to be < domain_row
      expect(Lla::CustomDomains::Domain.exists?(id: domain.id)).to be(false)
    end
  end

  describe 'the barrier itself' do
    let(:account) { create(:account) }
    let(:portal) { create(:portal, account: account) }
    let(:lifecycle) { Lla::CustomDomains::LifecycleService.new(portal: portal) }
    let(:service) { Lla::CustomDomains::OperationService }
    let(:domain) { lifecycle.request!('docs.example.com') }

    def verify_lease
      service.claim!(Lla::CustomDomains::Operation.find_by!(custom_domain_id: domain.id,
                                                            operation_type: 'verify'))
    end

    # One order for everyone: the domain's operation rows by ascending id — this
    # worker's own lease among them — and only then the domain row. A lease-first
    # lock would be a second, per-worker order, and two workers on two operations of
    # one domain could take them in opposite sequences.
    it 'locks the operation rows of the domain, by id, before its lease and the domain row' do
      service.enqueue!(domain: domain, operation_type: 'reconcile')
      lease = verify_lease
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      locks = []
      collect = ->(_name, _start, _finish, _id, payload) { locks << payload[:sql] if payload[:sql].include?('FOR UPDATE') }

      ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') do
        Lla::CustomDomains::OperationExecutor.new(lease).perform
      end

      siblings = locks.index { |sql| sql.include?('"custom_domain_id" = ') && sql.include?('ORDER BY') }
      own_lease = locks.index { |sql| sql.include?('lla_custom_domain_operations') && sql.include?('"id" = ') }
      domain_row = locks.index { |sql| sql.include?('FROM "lla_custom_domains"') }
      expect([siblings, own_lease, domain_row]).to all(be_present)
      expect(siblings).to be < own_lease
      expect(own_lease).to be < domain_row
    end

    it 'hands the claim back when PostgreSQL picks this worker as the deadlock victim' do
      lease = verify_lease
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      allow(Lla::CustomDomains::Fence).to receive(:new).and_return(barrier)
      allow(barrier).to receive_messages(held?: true)
      allow(barrier).to receive(:succeeding!).and_raise(ActiveRecord::Deadlocked, 'deadlock detected')

      expect(Lla::CustomDomains::OperationExecutor.new(lease).perform).to eq(:deferred)

      expect(Lla::CustomDomains::Operation.find(lease.id))
        .to have_attributes(state: 'deferred', claim_digest: nil, last_error_code: 'lla_custom_domain_contended')
    end

    # A rescue clause cannot catch what another rescue clause raises: if handing the
    # claim back discovers the lease is gone, that has to be an outcome, not a job
    # failure.
    it 'does not escape when the deadlocked worker has already lost its lease' do
      lease = verify_lease
      allow(Lla::CustomDomains::OwnershipVerifier).to receive(:verify).and_return(:verified)
      allow(Lla::CustomDomains::Fence).to receive(:new).and_return(barrier)
      allow(barrier).to receive_messages(held?: true)
      allow(barrier).to receive(:succeeding!).and_raise(ActiveRecord::Deadlocked, 'deadlock detected')
      allow(service).to receive(:defer!).and_raise(service::LeaseLost)

      expect(Lla::CustomDomains::OperationExecutor.new(lease).perform).to eq(:lease_lost)
    end

    # `find_each` would impose its own batch order and hand back the oldest rows, so
    # a batch full of stale terminal operations would hide every newer failure.
    it 'recovers the newest terminal operation even behind a full batch of older ones' do
      stub_const('Lla::CustomDomains::ReconciliationJob::BATCH_SIZE', 2)
      2.times do
        stale = create(:portal, account: account)
        stale_domain = Lla::CustomDomains::LifecycleService.new(portal: stale).request!("s#{stale.id}.example.com")
        Lla::CustomDomains::Operation.where(custom_domain_id: stale_domain.id)
                                     .update_all(state: 'cancelled', completed_at: Time.current, claim_digest: nil) # rubocop:disable Rails/SkipsModelValidations
      end
      Lla::CustomDomains::Operation.where(custom_domain_id: domain.id)
                                   .update_all(state: 'dead_lettered', completed_at: Time.current, claim_digest: nil) # rubocop:disable Rails/SkipsModelValidations

      expect { Lla::CustomDomains::ReconciliationJob.perform_now }
        .to change { Lla::CustomDomains::Operation.where(custom_domain_id: domain.id).count }.by(1)
      expect(Lla::CustomDomains::Operation.where(custom_domain_id: domain.id).where.not(recovery_attempt: 0))
        .to exist
    end
  end

  describe 'the legacy backfill when two tenants collapse onto one hostname' do
    let(:migration) do
      require Rails.root.join('db/migrate/20260817180000_create_lla_custom_domain_lifecycle.rb')
      CreateLlaCustomDomainLifecycle.new.tap { |instance| instance.verbose = false }
    end

    def set_raw_domain(portal, value)
      ActiveRecord::Base.connection.execute(
        "UPDATE portals SET custom_domain = #{ActiveRecord::Base.connection.quote(value)} WHERE id = #{portal.id}"
      )
    end

    def backfill!
      Lla::CustomDomains::Domain.delete_all
      Lla::CustomDomains::Tombstone.delete_all
      migration.send(:backfill_custom_domains)
    end

    it 'gives the hostname to the portal that was actually serving it' do
      incumbent = create(:portal, account: create(:account), custom_domain: 'docs.example.com')
      claimant = create(:portal, account: create(:account))
      set_raw_domain(claimant, 'DOCS.Example.COM')

      backfill!

      expect(Lla::CustomDomains::Domain.pluck(:portal_id)).to eq([incumbent.id])
      expect(tombstones.where(source_portal_id: claimant.id).pluck(:reason)).to eq(['legacy_hostname_duplicate'])
    end

    it 'gives it to nobody when neither tenant held the value that routed' do
      first = create(:portal, account: create(:account))
      second = create(:portal, account: create(:account))
      set_raw_domain(first, 'DOCS.Example.COM')
      set_raw_domain(second, 'docs.example.com.')

      backfill!

      expect(Lla::CustomDomains::Domain.count).to eq(0)
      expect(tombstones.pluck(:reason)).to eq(%w[legacy_hostname_contested legacy_hostname_contested])
      expect(tombstones.pluck(:source_portal_id)).to contain_exactly(first.id, second.id)
    end

    it 'refuses to hand over a hostname to a value that could never have been a Host' do
      # Fullwidth "docs" — NFKC folds it to `docs`, so the canonicalizer produces the
      # same hostname, but no client ever sent this string.
      squatter = create(:portal, account: create(:account))
      set_raw_domain(squatter, "\uFF44\uFF4F\uFF43\uFF53.example.com")

      backfill!

      expect(Lla::CustomDomains::Domain.count).to eq(0)
      expect(tombstones.pluck(:reason, :hostname, :source_portal_id))
        .to eq([['legacy_hostname_unroutable', 'docs.example.com', squatter.id]])
    end

    it 'is not fooled by a character whose lowercase is ASCII' do
      # U+212A KELVIN SIGN lowercases to a plain "k", so a case-insensitive compare
      # alone would read this as the case variant of a hostname it never matched.
      squatter = create(:portal, account: create(:account))
      set_raw_domain(squatter, "\u212Aiosk.example.com")

      backfill!

      expect(Lla::CustomDomains::Domain.count).to eq(0)
      expect(tombstones.pluck(:reason, :hostname)).to eq([['legacy_hostname_unroutable', 'kiosk.example.com']])
    end

    it 'still lets one account keep a hostname none of its own portals spelled canonically' do
      account = create(:account)
      first = create(:portal, account: account)
      second = create(:portal, account: account)
      set_raw_domain(first, 'DOCS.Example.COM')
      set_raw_domain(second, 'docs.example.com.')

      backfill!

      expect(Lla::CustomDomains::Domain.pluck(:portal_id)).to eq([first.id])
      expect(tombstones.pluck(:reason)).to eq(['legacy_hostname_duplicate'])
    end
  end

  # Deliberately asserted, not assumed. Deleting an account is deleting the tenant,
  # and every LLA table cascades with it — including evidence and queued teardown
  # snapshots. A remote object can therefore outlive the only record of it, so an
  # operator has to reap outstanding obligations *before* deleting an account. This
  # example exists so that contract is explicit and cannot change silently.
  describe 'deleting the whole tenant' do
    it 'takes the evidence with it, because the evidence is that tenant data' do
      account = create(:account)
      portal = create(:portal, account: account)
      raw = 'bad host.example.com'
      tombstones.create!(account_id: account.id, portal_id: portal.id, source_portal_id: portal.id,
                         reason: 'legacy_hostname_unsupported',
                         source_value_digest: Digest::SHA256.hexdigest(raw),
                         source_value_preview: tombstones.safe_preview(raw))

      ActiveRecord::Base.connection.execute("DELETE FROM accounts WHERE id = #{account.id}")

      expect(tombstones.where(account_id: account.id).count).to eq(0)
    end
  end

  describe 'an obligation an operator already dealt with' do
    let(:account) { create(:account) }

    def abandoned_operation
      Lla::CustomDomains::OperationService.enqueue_teardown!(
        account_id: account.id, hostname: 'docs.example.com', provider: 'cloudflare',
        provider_resource_id: 'cf-resource-a', domain_version: 1
      )
    end

    # The reconciler re-reads the same abandoned teardown on every tick for as long
    # as the operation is retained. Re-reporting must not undo the resolution or
    # raise the alert again, or the item can never be closed.
    it 'stays resolved however many times the reconciler reports it again' do
      recorder = Lla::CustomDomains::TombstoneRecorder
      operation = abandoned_operation
      item = recorder.record_abandoned_teardown!(operation)
      item.resolve!(reference: 'ops-1')
      events = []
      allow(Lla::CustomDomains::Telemetry).to receive(:emit) { |name, **| events << name }

      3.times { recorder.record_abandoned_teardown!(operation) }

      expect(item.reload).to have_attributes(state: 'resolved', resolved_by_reference: 'ops-1')
      expect(tombstones.count).to eq(1)
      expect(events).to be_empty
    end
  end

  describe 'the immutable audit reference' do
    it 'refuses to name a portal that no longer exists when the evidence is written' do
      account = create(:account)
      foreign_portal = create(:portal, account: create(:account))
      foreign_id = foreign_portal.id
      foreign_portal.destroy!
      raw = 'bad host.example.com'

      evidence = tombstones.new(account_id: account.id, source_portal_id: foreign_id,
                                reason: 'legacy_hostname_unsupported',
                                source_value_digest: Digest::SHA256.hexdigest(raw),
                                source_value_preview: tombstones.safe_preview(raw))

      expect(evidence).not_to be_valid
      expect(evidence.errors[:source_portal_id]).to include('must be a portal of this account')
    end

    it 'refuses to name a portal of another account' do
      account = create(:account)
      foreign_portal = create(:portal, account: create(:account))
      raw = 'bad host.example.com'

      evidence = tombstones.new(account_id: account.id, source_portal_id: foreign_portal.id,
                                reason: 'legacy_hostname_unsupported',
                                source_value_digest: Digest::SHA256.hexdigest(raw),
                                source_value_preview: tombstones.safe_preview(raw))

      expect(evidence).not_to be_valid
      expect(evidence.errors[:source_portal_id]).to include('must be a portal of this account')
    end
  end
end
