import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';

// OAuth/SDK channels need installation-level app credentials to be usable. When
// the credential is missing the channel is "not configured" and is hidden from
// onboarding entirely. Channels without an entry (Website, Telegram, Line, …)
// need no installation credential and are always considered configured.
// Mirrors the availability checks in ChannelItem.vue.
export function useChannelConfig() {
  const globalConfig = useMapGetter('globalConfig/get');
  const isOnChatwootCloud = useMapGetter('globalConfig/isOnChatwootCloud');
  const { isCloudFeatureEnabled } = useAccount();
  const installationConfig = window.chatwootConfig || {};
  const accountId = useMapGetter('getCurrentAccountId');
  const getAccount = useMapGetter('accounts/getAccount');
  // Ứng dụng của chính tenant cũng làm cho kênh "đã cấu hình" — không chỉ ứng dụng của
  // bản cài đặt.
  const tenantApp = platform =>
    Boolean(
      getAccount.value?.(accountId.value)?.platform_apps?.[platform]?.app_id
    );

  const CHANNEL_CONFIGURED = {
    // WhatsApp is onboarded only via Meta embedded signup, which needs both the
    // app id (not the 'none' sentinel) and the signup configuration id.
    whatsapp: () =>
      (!isOnChatwootCloud.value ||
        isCloudFeatureEnabled(FEATURE_FLAGS.WHATSAPP_EMBEDDED_SIGNUP_FLOW)) &&
      Boolean(installationConfig.whatsappAppId) &&
      installationConfig.whatsappAppId !== 'none' &&
      Boolean(installationConfig.whatsappConfigurationId),
    facebook: () =>
      Boolean(installationConfig.fbAppId) || tenantApp('facebook'),
    instagram: () =>
      (Boolean(installationConfig.instagramAppId) || tenantApp('instagram')) &&
      isCloudFeatureEnabled(FEATURE_FLAGS.CHANNEL_INSTAGRAM),
    tiktok: () =>
      Boolean(installationConfig.tiktokAppId) || tenantApp('tiktok'),
    gmail: () => Boolean(installationConfig.googleOAuthClientId),
    outlook: () => Boolean(globalConfig.value.azureAppId),
  };

  const isConfigured = type => CHANNEL_CONFIGURED[type]?.() ?? true;

  return { isConfigured };
}
