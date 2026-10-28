// Site settings. The Supabase URL and publishable key are public by design (every browser gets them);
// security comes from the row-level-security rules in setup/1-setup.sql. Never put the service_role / secret key here.
window.SITE_CONFIG = {
  supabaseUrl: "https://lmmqyplwxdmzapfmclec.supabase.co",
  supabaseKey: "sb_publishable_8hW2a3_WqiRVOn9KrNKeqw_ZQnUrEcW",
  // Main web address. Visitors on the *.netlify.app address are sent here so everyone uses one
  // address (sign-ins are saved per address). Set to "" to turn the redirect off.
  canonicalHost: "prep.neuronixai.site"
};
(function(){
  var h = window.SITE_CONFIG.canonicalHost;
  // only the main netlify.app address; deploy previews (which contain "--") are left alone
  if (!h || !/\.netlify\.app$/.test(location.hostname) || location.hostname.indexOf("--") >= 0) return;
  // redirect only if the main address actually answers, so a DNS problem can never strand visitors
  var ctl = window.AbortController ? new AbortController() : null;
  var t = setTimeout(function(){ if (ctl) ctl.abort(); }, 4000);
  fetch("https://" + h + "/config.js?ping=" + Date.now(), { mode: "no-cors", cache: "no-store", signal: ctl ? ctl.signal : undefined })
    .then(function(){ clearTimeout(t); location.replace("https://" + h + location.pathname + location.search + location.hash); })
    .catch(function(){ clearTimeout(t); });
})();
