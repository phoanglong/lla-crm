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

// ReDoc chỉ phát hành bản standalone dưới dạng UMD tự chứa (đã gói sẵn React,
// MobX, styled-components). Không import nó như ES module: interop CommonJS của
// Rollup sinh ra một `import "null"` không giải được, và trình duyệt ném
// `Failed to resolve module specifier "null"` ngay khi nạp chunk.
// Vì vậy lấy URL asset (`?url`, Vite chỉ copy nguyên file, không transform) rồi
// nạp bằng thẻ <script> đúng như ReDoc thiết kế — vẫn self-host, không CDN.
import redocStandaloneUrl from 'redoc/bundles/redoc.standalone.js?url';

const REDOC_SCRIPT_ID = 'redoc-standalone-script';

const loadRedocScript = () =>
  new Promise((resolve, reject) => {
    if (window.Redoc) {
      resolve(window.Redoc);
      return;
    }

    const existing = document.getElementById(REDOC_SCRIPT_ID);
    const script = existing || document.createElement('script');

    const onLoad = () => {
      if (window.Redoc) resolve(window.Redoc);
      else reject(new Error('redoc bundle loaded without window.Redoc'));
    };
    const onError = () =>
      reject(
        new Error(`unable to load redoc bundle from ${redocStandaloneUrl}`)
      );

    script.addEventListener('load', onLoad, { once: true });
    script.addEventListener('error', onError, { once: true });

    if (!existing) {
      script.id = REDOC_SCRIPT_ID;
      script.src = redocStandaloneUrl;
      script.async = true;
      document.head.appendChild(script);
    }
  });

const initializeApiDocs = async () => {
  const container = document.querySelector('[data-api-docs]');
  if (!container) return;

  try {
    const redoc = await loadRedocScript();
    redoc.init(
      container.dataset.schemaUrl,
      { hideHostname: true, nativeScrollbars: true },
      container
    );
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error('[super_admin/api_docs] redoc init failed', error);
    container.textContent =
      'Không thể tải trình xem API. Hãy tải OpenAPI JSON bằng nút phía trên.';
    container.classList.add('p-8', 'text-sm', 'text-red-700');
  }
};

document.addEventListener('DOMContentLoaded', () => {
  initializeAccountSuspensionForm();
  initializeApiDocs();
});
