# frozen_string_literal: true

# The write barrier every custom-domain worker result has to pass.
#
# A result is computed from rows that were read before a provider call that takes
# real time. Between that read and the write, an administrator can release or
# repoint the domain and the reconciler can hand the work to a successor. So a
# result is never "check, then write" — it is one transaction that, in exactly one
# lock order:
#
#   1. locks every operation row of the domain, by ascending id — one fixed order
#      that every worker on that domain follows, including its own lease row,
#   2. re-reads the operation `FOR UPDATE` and compares the lease token
#      (`OperationService.hold!`),
#   3. re-reads the domain `FOR UPDATE`, bound to the operation's tenant, and proves
#      it is still the exact `(id, account_id, version, hostname)` the operation was
#      issued for,
#   4. lets the caller perform its lifecycle write as a conditional update on that
#      same identity, and finalizes the operation inside the same transaction.
#
# Anything failing aborts all of it. A worker that lost its lease, or whose domain
# moved, performs zero domain mutation and never marks its operation succeeded.
class Lla::CustomDomains::Fence
  # The domain is no longer the row this operation was issued for. Raised inside the
  # fenced transaction, so nothing the worker computed is written.
  class DomainMoved < StandardError; end

  Service = Lla::CustomDomains::OperationService

  def initialize(lease)
    @lease = lease
  end

  # Cheap pre-flight so a reclaimed worker stops before it opens a socket.
  def held?
    Lla::CustomDomains::Operation.exists?(id: lease.id, state: 'claimed', claim_digest: Service.digest_for(lease.token))
  end

  def apply!(domain = nil)
    # `requires_new` so this is a real rollback boundary even inside an outer
    # transaction: a lost lease must undo the lifecycle write, not merely stop the
    # next statement.
    Lla::CustomDomains::Operation.transaction(requires_new: true) do
      lock_operations!
      Service.hold!(lease)
      yield(domain && fenced_domain!(domain))
    end
  end

  # The common shape of a successful branch: one conditional write that must either
  # happen exactly as issued or not at all. A falsey predicate means the row moved
  # between the provider call and the write, so the lifecycle write *and* the
  # operation finalization are both discarded.
  def succeeding!(domain)
    apply!(domain) do |fresh|
      raise DomainMoved unless yield(fresh)

      Service.succeed!(lease)
    end
  end

  # Failure metadata is a domain write like any other, so it takes the same locks in
  # the same order and the same conditional write. The operation is finalized inside
  # that transaction too: a worker cannot record "this attempt failed" and then lose
  # the race to describe why. The block runs only for the terminal attempt, on a
  # domain that is still the one this operation was issued for — a retry that will
  # run again writes nothing to the domain.
  def failing(domain, code)
    Lla::CustomDomains::Operation.transaction(requires_new: true) do
      lock_operations!
      Service.hold!(lease)
      fresh = Lla::CustomDomains::Domain.lock.find_by(id: domain.id, account_id: operation.account_id)
      result = Service.fail!(lease, code: code)
      next if fresh.blank? || operation.stale_for?(fresh) || result.state != 'dead_lettered'

      yield(fresh)
    end
  end

  private

  attr_reader :lease

  def operation
    lease.operation
  end

  # Destroying a domain row inside the barrier detaches its operations
  # (`dependent: :nullify`), which locks every one of them — after the domain row,
  # and in whatever order the update happens to touch them. Both halves of that are
  # taken here instead: **before** the domain row, and by ascending id, so every
  # worker on this domain acquires the same rows in the same sequence. That includes
  # this worker's own lease row, which is why `hold!` runs after this and not before
  # it: a lease-first lock would be a second, per-worker order and could itself close
  # a cycle.
  def lock_operations!
    return if operation.custom_domain_id.blank?

    Lla::CustomDomains::Operation.where(custom_domain_id: operation.custom_domain_id)
                                 .order(:id).lock.pluck(:id)
  end

  # The domain row, locked, and proved to still be the exact tenant-bound row this
  # operation was issued for.
  def fenced_domain!(domain)
    fresh = Lla::CustomDomains::Domain.lock.find_by(id: domain.id, account_id: operation.account_id)
    raise DomainMoved if operation.stale_for?(fresh)

    fresh
  end
end
