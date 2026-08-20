import { usePolicy } from '../usePolicy';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConfig } from 'dashboard/composables/useConfig';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables/useAccount');
vi.mock('dashboard/composables/useConfig');

const ACCOUNT_ID = 7;

const ADMIN = {
  accounts: [{ id: ACCOUNT_ID, permissions: ['administrator'] }],
};

const AGENT = {
  accounts: [{ id: ACCOUNT_ID, permissions: ['agent'] }],
};

/**
 * @param {object} options
 * @param {string[]} options.enabledFeatures features switched on for the account
 * @param {boolean} options.branded          installation renamed away from "Chatwoot"
 * @param {boolean} options.cloud            Chatwoot Cloud
 * @param {boolean} options.enterprise       the enterprise/ overlay is present
 * @param {object}  options.user             the signed-in user
 */
const setup = ({
  enabledFeatures = [],
  branded = true,
  cloud = false,
  enterprise = false,
  enterprisePlanName = 'community',
  user = ADMIN,
} = {}) => {
  useMapGetter.mockImplementation(getter => {
    const values = {
      getCurrentUser: user,
      'accounts/isFeatureEnabledonAccount': (_accountId, flag) =>
        enabledFeatures.includes(flag),
      'globalConfig/isOnChatwootCloud': cloud,
      'globalConfig/isACustomBrandedInstance': branded,
    };
    return { value: values[getter] };
  });
  useAccount.mockReturnValue({ accountId: { value: ACCOUNT_ID } });
  useConfig.mockReturnValue({ isEnterprise: enterprise, enterprisePlanName });

  return usePolicy();
};

describe('usePolicy', () => {
  beforeEach(() => vi.clearAllMocks());

  describe('shouldShow', () => {
    it('shows a capability the account has, on a plain self-hosted installation', () => {
      const { shouldShow } = setup({ enabledFeatures: [FEATURE_FLAGS.SAML] });

      expect(shouldShow(FEATURE_FLAGS.SAML, ['administrator'])).toBe(true);
    });

    it('hides a capability the account does not have', () => {
      const { shouldShow } = setup({ enabledFeatures: [] });

      expect(shouldShow(FEATURE_FLAGS.CAPTAIN, ['administrator'])).toBe(false);
    });

    it('shows a route that declares no capability at all', () => {
      const { shouldShow } = setup({ enabledFeatures: [] });

      expect(shouldShow(null, ['administrator'])).toBe(true);
    });

    it('refuses on permissions before it ever looks at the capability', () => {
      const { shouldShow } = setup({
        enabledFeatures: [FEATURE_FLAGS.SAML],
        user: AGENT,
      });

      expect(shouldShow(FEATURE_FLAGS.SAML, ['administrator'])).toBe(false);
    });

    // The regression this guards: the answer used to be "true, whatever the
    // flag says" for an installation that had not been renamed. With the
    // `[CLOUD, ENTERPRISE]` gate gone, that would have published every gated
    // screen there.
    it('still honours the capability when the installation has not been rebranded', () => {
      const { shouldShow } = setup({ enabledFeatures: [], branded: false });

      expect(shouldShow(FEATURE_FLAGS.CAPTAIN, ['administrator'])).toBe(false);
    });

    it('answers the same for a premium capability as for any other', () => {
      const off = setup({ enabledFeatures: [], branded: false });
      expect(off.shouldShow(FEATURE_FLAGS.SLA, ['administrator'])).toBe(false);

      const on = setup({
        enabledFeatures: [FEATURE_FLAGS.SLA],
        branded: false,
      });
      expect(on.shouldShow(FEATURE_FLAGS.SLA, ['administrator'])).toBe(true);
    });

    it('keeps the cloud upsell: a premium capability shows so the paywall can explain it', () => {
      const { shouldShow } = setup({
        enabledFeatures: [],
        branded: false,
        cloud: true,
      });

      expect(shouldShow(FEATURE_FLAGS.SLA, ['administrator'])).toBe(true);
    });

    it('keeps the enterprise upsell for an installation without a premium plan', () => {
      const { shouldShow } = setup({
        enabledFeatures: [],
        branded: false,
        enterprise: true,
        enterprisePlanName: 'community',
      });

      expect(shouldShow(FEATURE_FLAGS.SLA, ['administrator'])).toBe(true);
    });

    it('ignores a stale third argument left over from the edition gate', () => {
      const { shouldShow } = setup({ enabledFeatures: [] });

      expect(
        shouldShow(FEATURE_FLAGS.CAPTAIN, ['administrator'], ['cloud'])
      ).toBe(false);
    });
  });
});
