export const isCaptainConfigurationAvailable = ({
  enterpriseOnly = false,
  captainEnabled = false,
}) => !enterpriseOnly || Boolean(captainEnabled);

export const shouldDisplayCopilotPanel = ({
  captainEnabled = false,
  panelOpen = false,
  assistantsLoading = false,
}) => Boolean(captainEnabled && panelOpen && !assistantsLoading);
