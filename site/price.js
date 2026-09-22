/* ============================================================
   SINGLE SOURCE OF TRUTH for the kiddyproof license price.

   Change AMOUNT below and every price on the site follows: the body
   copy, and the value reported to the Meta pixel on checkout intent.
   Nothing else should ever hardcode a price.

   To show the price in copy:      <span data-kp-price></span>
   To read it from other scripts:  window.KIDDYPROOF_PRICE
                                   -> { amount, currency, display }

   Loaded synchronously (no defer) so the value exists before any
   inline script runs. It is ~1KB and blocks for a negligible moment.
   ============================================================ */
(function () {
  // --- the only place a price is written ---
  var AMOUNT   = 9.99;
  var CURRENCY = 'USD';
  var LOCALE   = 'en-US';

  // Derive the display string rather than storing it separately, so the
  // number and the text can never disagree.
  var display;
  try {
    display = new Intl.NumberFormat(LOCALE, {
      style: 'currency',
      currency: CURRENCY
    }).format(AMOUNT);
  } catch (e) {
    // Intl is universally supported, but a missing price is worse than an
    // unlocalised one — fall back rather than render nothing.
    display = '$' + AMOUNT.toFixed(2);
  }

  window.KIDDYPROOF_PRICE = {
    amount: AMOUNT,
    currency: CURRENCY,
    display: display
  };

  function paint() {
    var nodes = document.querySelectorAll('[data-kp-price]');
    for (var i = 0; i < nodes.length; i++) nodes[i].textContent = display;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', paint);
  } else {
    paint();
  }
})();
