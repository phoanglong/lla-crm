<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useAlert } from 'dashboard/composables';
import { useMapGetter, useStore } from 'dashboard/composables/store.js';
import PortalSettings from 'dashboard/components-next/HelpCenter/Pages/PortalSettingsPage/PortalSettings.vue';

const SSL_STATUS_FETCH_INTERVAL = 5000;

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const router = useRouter();
const { updateUISettings } = useUISettings();

const portals = useMapGetter('portals/allPortals');
const isFetching = useMapGetter('portals/isFetchingPortals');
const getPortalBySlug = useMapGetter('portals/portalBySlug');

// Non-empty only while the server has actually accepted a domain change; the DNS
// instructions dialog is keyed off it.
const domainInstructionsFor = ref('');

const getNextAvailablePortal = deletedPortalSlug =>
  portals.value?.find(portal => portal.slug !== deletedPortalSlug) ?? null;

const getDefaultLocale = slug => {
  return getPortalBySlug.value(slug)?.meta?.default_locale;
};

// The custom-domain lifecycle is an LLA capability, not a hosting plan: the status
// endpoint itself reports capability, provider readiness and the caller's
// permission, and performs no external request when the capability is off.
const fetchSSLStatus = () => {
  const { portalSlug } = route.params;
  store.dispatch('portals/sslStatus', {
    portalSlug,
  });
};

// A rejected reverification (not applicable, rotation budget spent, forbidden) must
// be visible: without this the button would silently do nothing.
const reverifyCustomDomain = async () => {
  const { portalSlug } = route.params;
  try {
    await store.dispatch('portals/customDomainReverify', { portalSlug });
    useAlert(
      t(
        'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.REVERIFY_STARTED'
      )
    );
  } catch (error) {
    useAlert(
      error?.message ||
        t(
          'HELP_CENTER.PORTAL_SETTINGS.CONFIGURATION_FORM.CUSTOM_DOMAIN.LIFECYCLE.ERROR'
        )
    );
  }
};

const fetchPortalAndItsCategories = async (slug, locale) => {
  const selectedPortalParam = { portalSlug: slug, locale };
  await Promise.all([
    store.dispatch('portals/index'),
    store.dispatch('portals/show', selectedPortalParam),
    store.dispatch('categories/index', selectedPortalParam),
    store.dispatch('agents/get'),
    store.dispatch('inboxes/get'),
  ]);
};

const updateRouteAfterDeletion = async deletedPortalSlug => {
  const nextPortal = getNextAvailablePortal(deletedPortalSlug);
  if (nextPortal) {
    const {
      slug,
      meta: { default_locale: defaultLocale },
    } = nextPortal;
    await fetchPortalAndItsCategories(slug, defaultLocale);
    router.push({
      name: 'portals_articles_index',
      params: { portalSlug: slug, locale: defaultLocale },
    });
  } else {
    router.push({ name: 'portals_new' });
  }
};

const refreshPortalRoute = async (newSlug, defaultLocale) => {
  // This is to refresh the portal route and update the UI settings
  // If there is slug change, this will be called to refresh the route and UI settings
  await fetchPortalAndItsCategories(newSlug, defaultLocale);
  updateUISettings({
    last_active_portal_slug: newSlug,
    last_active_locale_code: defaultLocale,
  });
  await router.replace({
    name: 'portals_settings_index',
    params: { portalSlug: newSlug },
  });
};

// Returns whether the server accepted the change, so callers can gate success-only
// affordances (DNS instructions, status polling) on it.
const updatePortalSettings = async portalObj => {
  const { portalSlug } = route.params;
  try {
    const defaultLocale = getDefaultLocale(portalSlug);
    await store.dispatch('portals/update', {
      ...portalObj,
      portalSlug: portalSlug || portalObj?.slug,
    });

    // If there is a slug change, this will refresh the route and update the UI settings
    if (portalObj?.slug && portalSlug !== portalObj.slug) {
      await refreshPortalRoute(portalObj.slug, defaultLocale);
    }
    useAlert(
      t('HELP_CENTER.PORTAL_SETTINGS.API.UPDATE_PORTAL.SUCCESS_MESSAGE')
    );
    return true;
  } catch (error) {
    useAlert(
      error?.message ||
        t('HELP_CENTER.PORTAL_SETTINGS.API.UPDATE_PORTAL.ERROR_MESSAGE')
    );
    return false;
  }
};

const deletePortal = async selectedPortalForDelete => {
  const { slug } = selectedPortalForDelete;
  try {
    await store.dispatch('portals/delete', { portalSlug: slug });
    await updateRouteAfterDeletion(slug);
    useAlert(
      t('HELP_CENTER.PORTAL.PORTAL_SETTINGS.DELETE_PORTAL.API.DELETE_SUCCESS')
    );
  } catch (error) {
    useAlert(
      error?.message ||
        t('HELP_CENTER.PORTAL.PORTAL_SETTINGS.DELETE_PORTAL.API.DELETE_ERROR')
    );
  }
};

const handleSendCnameInstructions = async payload => {
  try {
    await store.dispatch('portals/sendCnameInstructions', payload);
    useAlert(
      t(
        'HELP_CENTER.PORTAL.PORTAL_SETTINGS.SEND_CNAME_INSTRUCTIONS.API.SUCCESS_MESSAGE'
      )
    );
  } catch (error) {
    useAlert(
      error?.message ||
        t(
          'HELP_CENTER.PORTAL.PORTAL_SETTINGS.SEND_CNAME_INSTRUCTIONS.API.ERROR_MESSAGE'
        )
    );
  }
};

const handleUpdatePortal = updatePortalSettings;
const handleUpdatePortalConfiguration = async portalObj => {
  const saved = await updatePortalSettings(portalObj);
  if (!saved || !portalObj?.custom_domain) return;

  // Only after the server accepted the hostname: DNS instructions for a rejected
  // domain would be actively misleading.
  domainInstructionsFor.value = portalObj.custom_domain;

  // Refresh the lifecycle shortly after a domain change so the new state shows up.
  setTimeout(() => {
    fetchSSLStatus();
  }, SSL_STATUS_FETCH_INTERVAL);
};

const handleCloseInstructions = () => {
  domainInstructionsFor.value = '';
};
const handleDeletePortal = deletePortal;
</script>

<template>
  <PortalSettings
    :portals="portals"
    :is-fetching="isFetching"
    :domain-instructions-for="domainInstructionsFor"
    @update-portal="handleUpdatePortal"
    @update-portal-configuration="handleUpdatePortalConfiguration"
    @delete-portal="handleDeletePortal"
    @refresh-status="fetchSSLStatus"
    @reverify-domain="reverifyCustomDomain"
    @close-instructions="handleCloseInstructions"
    @send-cname-instructions="handleSendCnameInstructions"
  />
</template>
