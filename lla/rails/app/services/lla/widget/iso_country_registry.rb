# frozen_string_literal: true

# Immutable ISO 3166-1 alpha-2 allowlist owned by LLA (ADR-OMCRM-032). Used to
# validate both configured country allowlists and provider-returned country codes
# so that unassigned two-letter tokens (e.g. "ZZ") or malformed output (e.g. "USA")
# are rejected before they influence a geo decision.
module Lla::Widget::IsoCountryRegistry
  ALPHA2 = Set.new(
    %w[
      AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ
      BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ
      CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ
      DE DJ DK DM DO DZ
      EC EE EG EH ER ES ET
      FI FJ FK FM FO FR
      GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY
      HK HM HN HR HT HU
      ID IE IL IM IN IO IQ IR IS IT
      JE JM JO JP
      KE KG KH KI KM KN KP KR KW KY KZ
      LA LB LC LI LK LR LS LT LU LV LY
      MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ
      NA NC NE NF NG NI NL NO NP NR NU NZ
      OM
      PA PE PF PG PH PK PL PM PN PR PS PT PW PY
      QA
      RE RO RS RU RW
      SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ
      TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ
      UA UG UM US UY UZ
      VA VC VE VG VI VN VU
      WF WS
      YE YT
      ZA ZM ZW
    ]
  ).freeze

  module_function

  def valid?(code)
    ALPHA2.include?(code)
  end

  # Returns the canonical upcased alpha-2 code, or nil when the input is blank,
  # the wrong shape, or not an assigned ISO 3166-1 alpha-2 code.
  def canonical(value)
    code = value.to_s.strip.upcase
    return if code.empty?
    return unless ALPHA2.include?(code)

    code
  end
end
