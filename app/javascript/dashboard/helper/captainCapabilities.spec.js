import {
  isCaptainConfigurationAvailable,
  shouldDisplayCopilotPanel,
} from './captainCapabilities';

describe('captainCapabilities', () => {
  it('uses the account capability instead of the source-code edition for advanced settings', () => {
    expect(
      isCaptainConfigurationAvailable({
        enterpriseOnly: true,
        captainEnabled: true,
      })
    ).toBe(true);
    expect(
      isCaptainConfigurationAvailable({
        enterpriseOnly: true,
        captainEnabled: false,
      })
    ).toBe(false);
    expect(
      isCaptainConfigurationAvailable({
        enterpriseOnly: false,
        captainEnabled: false,
      })
    ).toBe(true);
  });

  it('shows Copilot only when the account capability, panel state and loading state allow it', () => {
    expect(
      shouldDisplayCopilotPanel({
        captainEnabled: true,
        panelOpen: true,
        assistantsLoading: false,
      })
    ).toBe(true);
    expect(
      shouldDisplayCopilotPanel({
        captainEnabled: false,
        panelOpen: true,
        assistantsLoading: false,
      })
    ).toBe(false);
    expect(
      shouldDisplayCopilotPanel({
        captainEnabled: true,
        panelOpen: true,
        assistantsLoading: true,
      })
    ).toBe(false);
  });
});
