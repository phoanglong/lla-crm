import '../dashboard/assets/scss/super_admin/index.scss';

const initializeAccountSuspensionForm = () => {
  const form = document.querySelector('[data-account-suspension-form]');
  if (!form) return;

  const status = form.querySelector('[data-account-status-select]');
  const fields = form.querySelector('[data-account-suspension-fields]');
  if (!status || !fields) return;

  const category = fields.querySelector('[data-suspension-category]');
  const reason = fields.querySelector('[data-suspension-reason]');
  const controls = [category, reason];
  const originalStatus = form.dataset.originalStatus;
  const hasHistory = form.dataset.hasSuspensionHistory === 'true';

  const updateFields = () => {
    const isSuspended = status.value === 'suspended';
    const hasEnteredDetails = controls.some(
      control => control.value.trim().length > 0
    );
    const detailsRequired =
      isSuspended &&
      (originalStatus === 'active' || hasHistory || hasEnteredDetails);

    fields.classList.toggle('hidden', !isSuspended);
    controls.forEach(control => {
      control.disabled = !isSuspended;
      control.required = detailsRequired;
    });
  };

  status.addEventListener('change', updateFields);
  controls.forEach(control => control.addEventListener('input', updateFields));
  updateFields();
};

const initializeApiDocs = async () => {
  const container = document.querySelector('[data-api-docs]');
  if (!container) return;

  try {
    const redocModule = await import('redoc/bundles/redoc.standalone.js');
    const redoc = redocModule.default || redocModule.Redoc || redocModule;
    redoc.init(
      container.dataset.schemaUrl,
      { hideHostname: true, nativeScrollbars: true },
      container
    );
  } catch {
    container.textContent =
      'Không thể tải trình xem API. Hãy tải OpenAPI JSON bằng nút phía trên.';
    container.classList.add('p-8', 'text-sm', 'text-red-700');
  }
};

document.addEventListener('DOMContentLoaded', () => {
  initializeAccountSuspensionForm();
  initializeApiDocs();
});
