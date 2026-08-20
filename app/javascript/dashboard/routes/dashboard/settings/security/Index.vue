<script setup>
import { computed } from 'vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import SamlSettings from './components/SamlSettings.vue';
import SamlPaywall from './components/SamlPaywall.vue';

import { usePolicy } from 'dashboard/composables/usePolicy';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
const { shouldShow, shouldShowPaywall } = usePolicy();

const allowedLoginMethods = computed(
  () => window.chatwootConfig.allowedLoginMethods || ['email']
);

const isSamlSsoEnabled = computed(() =>
  allowedLoginMethods.value.includes('saml')
);

// The route stopped asking which edition this is; the panel behind it has to
// stop asking too. Gated on `[CLOUD, ENTERPRISE]` it was false on every LLA
// installation, so an administrator who opened Settings → Security was told to
// "contact your administrator" — while the server had SAML switched on.
const shouldShowSaml = computed(() => {
  const hasPermission = shouldShow(FEATURE_FLAGS.SAML, ['administrator']);
  return hasPermission && isSamlSsoEnabled.value;
});

const showPaywall = computed(() => shouldShowPaywall('saml'));
</script>

<template>
  <SettingsLayout :loading-message="$t('ATTRIBUTES_MGMT.LOADING')">
    <template #header>
      <BaseSettingsHeader
        :title="$t('SECURITY_SETTINGS.TITLE')"
        :description="$t('SECURITY_SETTINGS.DESCRIPTION')"
        :link-text="$t('SECURITY_SETTINGS.LINK_TEXT')"
        feature-name="saml"
      />
    </template>
    <template #body>
      <SamlPaywall v-if="showPaywall" />
      <SamlSettings v-else-if="shouldShowSaml" />
      <div v-else class="mt-6 text-sm text-slate-600">
        {{ $t('SECURITY_SETTINGS.SAML_DISABLED_MESSAGE') }}
      </div>
    </template>
  </SettingsLayout>
</template>
