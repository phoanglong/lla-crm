import CaptainBulkActionsAPI from 'dashboard/api/captain/bulkActions';
import captainBulkActionsStore from './bulkActions';

vi.mock('dashboard/api/captain/bulkActions', () => ({
  default: { create: vi.fn() },
}));
vi.mock('widget/helpers/uuid', () => ({ default: () => 'lla-operation-id' }));

describe('Captain bulk actions store', () => {
  it('adds an opaque idempotency key to every operation payload', async () => {
    CaptainBulkActionsAPI.create.mockResolvedValue({ data: { success: true } });
    const commit = vi.fn();

    await captainBulkActionsStore.actions.processBulkAction(
      { commit },
      { type: 'AssistantDocument', actionType: 'sync', ids: [7, 8] }
    );

    expect(CaptainBulkActionsAPI.create).toHaveBeenCalledWith({
      type: 'AssistantDocument',
      ids: [7, 8],
      operation_id: 'lla-operation-id',
      fields: { status: 'sync' },
    });
  });
});
