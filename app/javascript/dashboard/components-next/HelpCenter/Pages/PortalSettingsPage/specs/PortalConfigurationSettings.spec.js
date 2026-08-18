import { mount } from '@vue/test-utils';
import { createI18n } from 'vue-i18n';
import PortalConfigurationSettings from '../PortalConfigurationSettings.vue';
import helpCenter from 'dashboard/i18n/locale/en/helpCenter.json';

const i18n = createI18n({
  legacy: false,
  locale: 'en',
  messages: { en: { HELP_CENTER: helpCenter.HELP_CENTER } },
});

const dialogStub = name => ({
  name,
  template: '<div />',
  setup() {
    const dialogRef = { open: vi.fn(), close: vi.fn() };
    return { dialogRef };
  },
});

const stubs = {
  AddCustomDomainDialog: dialogStub('AddCustomDomainDialog'),
  DNSConfigurationDialog: dialogStub('DNSConfigurationDialog'),
  // No explicit re-emit: the click listener falls through to the root element, so a
  // single trigger produces exactly one handler call.
  Button: {
    props: ['label', 'disabled'],
    template: '<button :disabled="disabled">{{ label }}</button>',
  },
};

const buildPortal = (sslSettings = {}) => ({
  id: 1,
  slug: 'docs',
  custom_domain: 'docs.example.com',
  ssl_settings: {
    capability_enabled: false,
    provider_ready: false,
    can_manage: true,
    configured: true,
    reverify_available: false,
    retry_available: false,
    ...sslSettings,
  },
});

const mountComponent = (portal = buildPortal(), props = {}) =>
  mount(PortalConfigurationSettings, {
    props: { activePortal: portal, isFetchingStatus: false, ...props },
    global: { plugins: [i18n], stubs, directives: { tooltip: {} } },
  });

describe('PortalConfigurationSettings custom domain', () => {
  it('renders the domain without any hosting-plan input', () => {
    const wrapper = mountComponent();
    expect(wrapper.find('[data-testid="custom-domain-address"]').text()).toBe(
      'docs.example.com'
    );
  });

  it('shows the ownership-pending state and its instruction', () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'ownership_pending',
        capability_enabled: true,
      })
    );

    expect(
      wrapper.find('[data-testid="custom-domain-status"]').text()
    ).toContain('Awaiting domain ownership proof');
    expect(
      wrapper.find('[data-testid="custom-domain-helper"]').text()
    ).toContain('CNAME record');
  });

  it('shows live only for an active proved domain', () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'active',
        status: 'local',
        capability_enabled: true,
        provider_ready: true,
      })
    );

    expect(
      wrapper.find('[data-testid="custom-domain-status"]').text()
    ).toContain('Live');
    expect(
      wrapper.find('[data-testid="custom-domain-reverify"]').exists()
    ).toBe(false);
  });

  it('never claims live while the provider has not reported the hostname', () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'active',
        status: 'pending_validation',
        capability_enabled: true,
        provider_ready: true,
      })
    );

    const status = wrapper.find('[data-testid="custom-domain-status"]');
    expect(status.exists()).toBe(true);
    expect(status.text()).toContain('Waiting for the domain provider');
    expect(status.text()).not.toContain('Live');
  });

  it('offers reverification only when the server says it is available', async () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'active',
        status: 'local',
        capability_enabled: true,
        reverify_required: true,
        reverify_available: true,
        ownership_source: 'legacy_import',
      })
    );

    expect(
      wrapper.find('[data-testid="custom-domain-status"]').text()
    ).toContain('Reverification required');
    await wrapper
      .find('[data-testid="custom-domain-reverify"]')
      .trigger('click');
    expect(wrapper.emitted('reverifyDomain')).toHaveLength(1);
  });

  it('hides the reverify action when the server reports it as unavailable', () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'active',
        status: 'local',
        capability_enabled: true,
        reverify_required: true,
        reverify_available: false,
      })
    );

    expect(
      wrapper.find('[data-testid="custom-domain-reverify"]').exists()
    ).toBe(false);
  });

  it('offers a retry on a failed domain instead of leaving a dead end', async () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'failed',
        capability_enabled: true,
        retry_available: true,
      })
    );

    const button = wrapper.find('[data-testid="custom-domain-reverify"]');
    expect(button.text()).toContain('Retry verification');
    await button.trigger('click');
    expect(wrapper.emitted('reverifyDomain')).toHaveLength(1);
  });

  it('does not treat a disabled provider as success and explains readiness', () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'active',
        status: 'local',
        capability_enabled: true,
      })
    );

    expect(
      wrapper.find('[data-testid="custom-domain-helper"]').text()
    ).toContain('No external domain provider is configured');
  });

  it('explains a disabled capability instead of pretending the domain is fine', () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'ownership_pending',
        capability_enabled: false,
      })
    );

    expect(
      wrapper.find('[data-testid="custom-domain-helper"]').text()
    ).toContain('Custom domains are turned off');
  });

  it('surfaces the manual-intervention outcome', () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'removing',
        capability_enabled: true,
        manual_intervention_required: true,
      })
    );

    expect(
      wrapper.find('[data-testid="custom-domain-status"]').text()
    ).toContain('Needs administrator attention');
    expect(
      wrapper.find('[data-testid="custom-domain-helper"]').text()
    ).toContain('administrator needs to complete it');
  });

  it('hides every mutation from a caller the server will not let manage the domain', () => {
    const wrapper = mountComponent(
      buildPortal({
        lifecycle_state: 'active',
        status: 'local',
        capability_enabled: true,
        can_manage: false,
        reverify_required: true,
        reverify_available: false,
      })
    );

    expect(wrapper.find('[data-testid="custom-domain-edit"]').exists()).toBe(
      false
    );
    expect(
      wrapper.find('[data-testid="custom-domain-reverify"]').exists()
    ).toBe(false);
    expect(
      wrapper.find('[data-testid="custom-domain-helper"]').text()
    ).toContain('Only a workspace administrator');
  });

  it('disables adding a domain when the caller cannot manage it', () => {
    const portal = buildPortal({ can_manage: false, configured: false });
    portal.custom_domain = '';
    const wrapper = mountComponent(portal);

    expect(
      wrapper.find('[data-testid="custom-domain-add"]').attributes('disabled')
    ).toBeDefined();
  });

  it('does not show DNS instructions until the server accepted the change', async () => {
    const wrapper = mountComponent();
    const dialog = wrapper.findComponent({ name: 'DNSConfigurationDialog' });

    wrapper
      .findComponent({ name: 'AddCustomDomainDialog' })
      .vm.$emit('addCustomDomain', 'new.example.com');
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('updatePortalConfiguration')).toHaveLength(1);
    expect(dialog.vm.dialogRef.open).not.toHaveBeenCalled();

    await wrapper.setProps({ domainInstructionsFor: 'new.example.com' });
    expect(dialog.vm.dialogRef.open).toHaveBeenCalledTimes(1);
  });

  it('never renders upstream support branding', () => {
    const wrapper = mountComponent(
      buildPortal({ lifecycle_state: 'failed', capability_enabled: true })
    );

    expect(wrapper.text()).not.toContain('chatwoot');
    expect(
      wrapper.find('[data-testid="custom-domain-status"]').text()
    ).toContain('Verification failed');
  });
});
